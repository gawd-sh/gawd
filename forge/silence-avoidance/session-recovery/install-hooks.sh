#!/usr/bin/env bash
# install-hooks.sh — Install the session-recovery sweep + on-terminal-error
# trigger plumbing.
#
# What this installer DOES:
#   1. chmod +x every script in this directory.
#   2. Register the 5-minute sweep cron. Two integration paths:
#        a. PREFERRED — append a job entry to forge/scheduler/ if E1 is
#           present (the canonical Gawd scheduler). The scheduler will
#           regenerate the unit/timer files on its next install run.
#        b. FALLBACK — write a standalone systemd user timer (or crontab
#           entry, auto-detected) that fires sweep.sh every 5 minutes.
#   3. Probe OpenClaw for a gateway terminal-error hook. As of OpenClaw
#      2026.4.29 there is no first-class hook API for terminal-error
#      events. We document the absence in the runbook and fall back to:
#        - L7 watchdog's session-wedge-check probe (already installed,
#          fires every 60s; calls our recover.sh on detection)
#        - sweep cron (every 5 min; safety net)
#      If a future OpenClaw release exposes a hook, this script is the
#      single place to update.
#
# What this installer does NOT do:
#   - Live-deploy to anything. This is forge content. The forge artifact
#     is install-time content; the actual deploy is done by the daemon
#     install.sh on the Prophit's substrate.
#   - Touch the gateway process. We never restart it.
#   - Modify OpenClaw config files (openclaw.json). Out of scope.
#
# Idempotency:
#   - Re-runnable. Detects existing units / crontab entries and only
#     writes if changed.
#   - --uninstall reverses the install (removes timer + cron entry).
#
# Usage:
#   install-hooks.sh                    # auto-detect mode + register
#   install-hooks.sh --mode systemd     # force systemd user timer
#   install-hooks.sh --mode cron        # force crontab entry
#   install-hooks.sh --mode forge-scheduler   # register into E1 scheduler
#   install-hooks.sh --uninstall
#   install-hooks.sh --dry-run
#   install-hooks.sh --no-cron          # skip cron registration entirely
#                                       # (use when L7 watchdog handles 100%)
#
# Exit codes:
#   0  install (or uninstall) complete
#   1  preflight failed
#   2  install failed (file write / systemctl error)

set -uo pipefail

# SR_SRC_DIR is where this installer + the source scripts live (the forge tree).
SR_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# BLOCKER 10 (rc3): the canonical INSTALLED location of recover.sh + sweep.sh is
#   ${GAWD_HOME}/engine/session-recovery/
# This is the path the L7 watchdog (watchdog/sweep.sh) reads as
#   ${GAWD_HOME}/engine/session-recovery/{recover,sweep}.sh.
# Previously install-hooks.sh never copied anything there and pointed systemd's
# ExecStart at the in-place forge path, so the watchdog's G4 lookup always
# missed → safety net silently no-op'd. We now COPY the scripts to the
# canonical install dir and point ExecStart at the installed copy.
: "${GAWD_HOME:=${HOME}/.gawd}"
SR_INSTALL_DIR="${GAWD_HOME}/engine/session-recovery"

# SR_DIR is the directory ExecStart / cron entries point at. After staging it
# is the installed copy; if staging is skipped it falls back to the source.
SR_DIR="$SR_INSTALL_DIR"

MODE="auto"
UNINSTALL=0
DRY_RUN=0
NO_CRON=0

usage() {
    grep '^# ' "$0" | sed 's/^# //'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)      MODE="${2:-}"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --no-cron)   NO_CRON=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

log() {
    printf '[%s install-hooks] %s\n' "$(date -Iseconds)" "$*" >&2
}

# ── Step 1: chmod (source tree) ───────────────────────────────────────────────

step_chmod() {
    local f
    for f in "$SR_SRC_DIR"/*.sh; do
        [[ -f "$f" ]] || continue
        if [[ ! -x "$f" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                log "DRY-RUN: chmod +x ${f}"
            else
                chmod 0755 "$f"
                log "chmod +x ${f}"
            fi
        fi
    done
    if [[ -f "$SR_SRC_DIR/lib/common.sh" && ! -x "$SR_SRC_DIR/lib/common.sh" ]]; then
        # common.sh is sourced, not executed; readable is enough. No-op.
        :
    fi
}

# ── Step 1b: stage scripts to the canonical install dir (BLOCKER 10) ──────────
# Copies the session-recovery scripts AND their lib/ dependency to
# ${GAWD_HOME}/engine/session-recovery/ so the L7 watchdog finds recover.sh +
# sweep.sh at the path it actually looks up. recover.sh sources lib/common.sh
# (relative to its own dir) and calls clear.sh/detect.sh siblings, so the whole
# set must travel together. Idempotent.
stage_scripts() {
    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: would stage session-recovery scripts to ${SR_INSTALL_DIR}"
        return 0
    fi
    # If the source and install dirs are the same path, nothing to copy.
    if [[ "$SR_SRC_DIR" -ef "$SR_INSTALL_DIR" ]] 2>/dev/null; then
        log "source and install dir are identical (${SR_INSTALL_DIR}); skipping stage"
        return 0
    fi
    mkdir -p "$SR_INSTALL_DIR/lib" "$SR_INSTALL_DIR/runbook" || {
        log "ERROR: cannot create ${SR_INSTALL_DIR}"
        return 2
    }
    local f base
    # Top-level executable scripts (recover.sh, sweep.sh, clear.sh, detect.sh,
    # on-terminal-error.sh). Do NOT recopy install-hooks.sh into the runtime dir.
    for f in "$SR_SRC_DIR"/*.sh; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == "install-hooks.sh" ]] && continue
        install -m 0755 "$f" "$SR_INSTALL_DIR/$base"
    done
    # lib/ dependency (sourced — 0644 is fine, but keep 0755 for consistency).
    if [[ -f "$SR_SRC_DIR/lib/common.sh" ]]; then
        install -m 0755 "$SR_SRC_DIR/lib/common.sh" "$SR_INSTALL_DIR/lib/common.sh"
    fi
    # Runbook (referenced by the systemd unit's Documentation= line). Best-effort.
    if [[ -d "$SR_SRC_DIR/runbook" ]]; then
        for f in "$SR_SRC_DIR/runbook"/*; do
            [[ -f "$f" ]] || continue
            install -m 0644 "$f" "$SR_INSTALL_DIR/runbook/$(basename "$f")" 2>/dev/null || true
        done
    fi
    log "staged session-recovery scripts to ${SR_INSTALL_DIR}"
}

# ── Step 2: detect cron mode ──────────────────────────────────────────────────

detect_mode() {
    # Preference: if E1 scheduler is present, register into it.
    if [[ -x /usr/local/lib/gawd/scheduler/install-crons.sh ]]; then
        echo "forge-scheduler"
        return
    fi
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl --user --no-pager show-environment >/dev/null 2>&1; then
        echo "systemd"
        return
    fi
    echo "cron"
}

if [[ "$MODE" == "auto" ]]; then
    MODE="$(detect_mode)"
fi
log "mode=${MODE} uninstall=${UNINSTALL} dry-run=${DRY_RUN} no-cron=${NO_CRON}"

# ── Step 3: cron registration ─────────────────────────────────────────────────

UNIT_NAME="gawd-session-recovery-sweep"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

CRON_MARKER_BEGIN="# === BEGIN session-recovery sweep (managed by install-hooks.sh) ==="
CRON_MARKER_END="# === END session-recovery sweep ==="

write_systemd_units() {
    mkdir -p "$UNIT_DIR"
    local service="$UNIT_DIR/${UNIT_NAME}.service"
    local timer="$UNIT_DIR/${UNIT_NAME}.timer"

    local service_text
    service_text="$(cat <<EOF
[Unit]
Description=Gawd session-recovery sweep (Layer 4 / G4)
Documentation=file://${SR_DIR}/runbook/session-recovery.md

[Service]
Type=oneshot
ExecStart=${SR_DIR}/sweep.sh
StandardOutput=journal
StandardError=journal
# Keep this very lightweight; sweep is read-mostly + a small write on wedge.
MemoryHigh=64M
MemoryMax=128M
CPUWeight=10
EOF
)"

    local timer_text
    timer_text="$(cat <<EOF
[Unit]
Description=Timer for Gawd session-recovery sweep

[Timer]
Unit=${UNIT_NAME}.service
# Every 5 minutes; OnBootSec=2min so we don't fire the instant the daemon
# boots (give it a moment to settle).
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=15
AccuracySec=15
# Persistent=false: do not replay missed firings.
Persistent=false

[Install]
WantedBy=timers.target
EOF
)"

    local svc_existing="" tim_existing=""
    [[ -f "$service" ]] && svc_existing="$(cat "$service")"
    [[ -f "$timer"   ]] && tim_existing="$(cat "$timer")"

    if [[ "$svc_existing" == "$service_text" && "$tim_existing" == "$timer_text" ]]; then
        log "systemd units unchanged"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: would install ${service} and ${timer}"
        return 0
    fi

    printf '%s\n' "$service_text" > "$service"
    printf '%s\n' "$timer_text"   > "$timer"
    chmod 0644 "$service" "$timer"
    log "wrote ${service} and ${timer}"

    if ! systemctl --user daemon-reload; then
        log "WARN: daemon-reload failed"
    fi
    if ! systemctl --user enable --now "${UNIT_NAME}.timer"; then
        log "ERROR: enable --now failed for ${UNIT_NAME}.timer"
        return 2
    fi
    log "enabled ${UNIT_NAME}.timer"
}

write_crontab_entry() {
    local cron_fragment
    cron_fragment="*/5 * * * * ${SR_DIR}/sweep.sh >/dev/null 2>&1"

    local existing
    if ! existing="$(crontab -l 2>/dev/null)"; then
        existing=""
    fi

    local stripped
    stripped="$(printf '%s\n' "$existing" | awk -v b="$CRON_MARKER_BEGIN" -v e="$CRON_MARKER_END" '
        BEGIN { skipping=0 }
        $0 == b { skipping=1; next }
        $0 == e { skipping=0; next }
        skipping == 0 { print }
    ')"

    local desired
    desired="$(printf '%s\n%s\n%s\n%s\n' \
        "$stripped" \
        "$CRON_MARKER_BEGIN" \
        "$cron_fragment" \
        "$CRON_MARKER_END")"

    if [[ "$existing" == "$desired" ]]; then
        log "crontab unchanged"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: would install crontab entry: ${cron_fragment}"
        return 0
    fi

    if ! printf '%s\n' "$desired" | crontab -; then
        log "ERROR: crontab install failed"
        return 2
    fi
    log "crontab entry installed"
}

register_into_forge_scheduler() {
    # E1's scheduler is the canonical scheduler. We do NOT modify it
    # in-place (E1 owns its own JOB_TABLE). Instead, we drop a "drop-in"
    # job script into forge/scheduler/jobs/ that calls our sweep.sh, and
    # surface a clear message that the operator should re-run E1's
    # install-crons.sh to actually register the new job.
    local jobs_dir="/usr/local/lib/gawd/scheduler/jobs"
    local job_path="${jobs_dir}/session-recovery-sweep.sh"

    if [[ ! -d "$jobs_dir" ]]; then
        log "forge scheduler not present at ${jobs_dir} — falling back to standalone systemd"
        write_systemd_units
        return $?
    fi

    local desired_content
    desired_content="$(cat <<EOF
#!/usr/bin/env bash
# session-recovery-sweep.sh — drop-in job for forge/scheduler.
#
# Generated by /usr/local/lib/gawd/silence-avoidance/session-recovery/install-hooks.sh
# Do not edit by hand. Re-run install-hooks.sh to regenerate.
#
# This is intentionally thin: forge/scheduler/lib/common.sh already
# provides log/lock/run_or_stub; we use them so the job stays
# stub-tolerant and idempotent.

set -uo pipefail
SCHED_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/usr/local/lib/gawd/scheduler/lib/common.sh
source "\${SCHED_DIR}/lib/common.sh"
export SCHED_JOB="session-recovery-sweep"

lock_acquire "\$SCHED_JOB"
run_or_stub "session-recovery-sweep" \\
    "${SR_DIR}/sweep.sh"
exit 0
EOF
)"

    local existing=""
    [[ -f "$job_path" ]] && existing="$(cat "$job_path")"
    if [[ "$existing" == "$desired_content" ]]; then
        log "forge-scheduler drop-in unchanged: ${job_path}"
    else
        if [[ $DRY_RUN -eq 1 ]]; then
            log "DRY-RUN: would write ${job_path}"
        else
            printf '%s\n' "$desired_content" > "$job_path"
            chmod 0755 "$job_path"
            log "wrote forge-scheduler drop-in: ${job_path}"
        fi
    fi

    log "NOTE: re-run /usr/local/lib/gawd/scheduler/install-crons.sh"
    log "      to add this job to the active scheduler. Until then, install"
    log "      will also write a standalone systemd timer as a safety net."

    # Safety net: also install the standalone systemd timer so the sweep
    # runs even if the operator forgets to re-run install-crons.sh.
    write_systemd_units
}

uninstall_systemd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: would disable --now ${UNIT_NAME}.timer and remove units"
        return 0
    fi
    systemctl --user disable --now "${UNIT_NAME}.timer" 2>/dev/null || true
    rm -f "$UNIT_DIR/${UNIT_NAME}.service" "$UNIT_DIR/${UNIT_NAME}.timer"
    systemctl --user daemon-reload 2>/dev/null || true
    log "uninstalled systemd units"
}

uninstall_crontab() {
    local existing
    if ! existing="$(crontab -l 2>/dev/null)"; then
        log "no crontab present — nothing to uninstall"
        return 0
    fi
    local stripped
    stripped="$(printf '%s\n' "$existing" | awk -v b="$CRON_MARKER_BEGIN" -v e="$CRON_MARKER_END" '
        BEGIN { skipping=0 }
        $0 == b { skipping=1; next }
        $0 == e { skipping=0; next }
        skipping == 0 { print }
    ')"
    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: would install stripped crontab"
        return 0
    fi
    printf '%s\n' "$stripped" | crontab - || return 2
    log "crontab gawd block removed"
}

uninstall_forge_drop_in() {
    local job_path="/usr/local/lib/gawd/scheduler/jobs/session-recovery-sweep.sh"
    if [[ -f "$job_path" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            log "DRY-RUN: would remove ${job_path}"
        else
            rm -f "$job_path"
            log "removed ${job_path}"
        fi
    fi
}

# ── Step 4: gateway hook probe (advisory) ─────────────────────────────────────

probe_gateway_hook() {
    # As of OpenClaw 2026.4.29 there is no first-class hook API for the
    # terminal-error event. Document this in the runbook; the L7 watchdog +
    # sweep cron are the proven trigger path.
    local openclaw_bin
    openclaw_bin="$(command -v openclaw 2>/dev/null || true)"
    if [[ -z "$openclaw_bin" ]]; then
        log "openclaw binary not in PATH — skipping hook probe (sweep cron suffices)"
        return 0
    fi
    # If a future release adds e.g. `openclaw hooks register --event=terminal-error`,
    # this is where we'd call it. For now, just log presence.
    log "openclaw=${openclaw_bin} — no terminal-error hook API yet (using watchdog+sweep)"
    return 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

step_chmod

if [[ $UNINSTALL -eq 1 ]]; then
    uninstall_systemd
    uninstall_crontab
    uninstall_forge_drop_in
    log "uninstall complete"
    exit 0
fi

# Stage scripts to the canonical install dir BEFORE we write any unit/cron that
# references SR_DIR (= the install dir). If staging fails, abort — pointing a
# timer at a non-existent path would re-introduce BLOCKER 10.
if ! stage_scripts; then
    log "ERROR: staging scripts to ${SR_INSTALL_DIR} failed; aborting"
    exit 2
fi

probe_gateway_hook

if [[ $NO_CRON -eq 1 ]]; then
    log "--no-cron given; skipping cron registration (L7 watchdog only)"
    exit 0
fi

case "$MODE" in
    forge-scheduler) register_into_forge_scheduler ;;
    systemd)         write_systemd_units ;;
    cron)            write_crontab_entry ;;
    *) log "unknown mode: ${MODE}"; exit 1 ;;
esac

log "install complete"
exit 0
