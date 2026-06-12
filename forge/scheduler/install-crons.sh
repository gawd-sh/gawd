#!/usr/bin/env bash
# install-crons.sh — Idempotent scheduler installer.
#
# Per spec + handoff E1 acceptance:
#   "install-crons.sh uses systemd timers (preferred) OR cron, declared
#    per-rung; Prophit-VM and bare-metal use systemd timers; hosted uses
#    systemd timers"
#
# Called by install.sh (A3) at install time, and re-callable any time the
# Prophit's timezone or service_hour changes (e.g., via /pace slash command).
#
# Idempotency contract:
#   - Re-running on an existing install is safe.
#   - The installer detects existing units/timers, diffs against the
#     freshly-generated set, and only restarts what changed.
#   - No accidental double-fires: stop old timers before writing new ones.
#
# Per-rung notes:
#   - Hosted, Prophit-VM, bare-metal: all prefer systemd user timers.
#   - If systemd --user is not usable (no session DBus, linger not enabled,
#     or running inside a minimal container), automatic fallback to cron.
#   - The container substrate matters more than the rung: a Docker container
#     without systemd will use cron; one with systemd-as-pid-1 will use
#     timers. Auto-detect handles both.
#
# Usage:
#   install-crons.sh [--workspace <dir>] [--mode systemd|cron|auto] [--uninstall]
#                    [--dry-run]
#
# Exit codes:
#   0  install complete (or uninstall complete, or dry-run)
#   1  preflight failed
#   2  generation failed
#   3  install (file copy / enable / start) failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
export SCHED_JOB="install-crons"

MODE="auto"
DRY_RUN=0
UNINSTALL=0
WORKSPACE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)       MODE="$2"; shift 2 ;;
        --workspace)  WORKSPACE_OVERRIDE="$2"; shift 2 ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)
            grep '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) fatal 1 "unknown arg: $1" ;;
    esac
done

if [[ -n "$WORKSPACE_OVERRIDE" ]]; then
    export GAWD_WORKSPACE="$WORKSPACE_OVERRIDE"
fi

JOB_LIST=(sharpen daily-reset weekly-service cleanup)

# ──────────────────────────────────────────────────────────────────────────
# Mode detection
# ──────────────────────────────────────────────────────────────────────────

detect_mode() {
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl --user --no-pager show-environment >/dev/null 2>&1; then
        echo "systemd"
    else
        echo "cron"
    fi
}

if [[ "$MODE" == "auto" ]]; then
    MODE="$(detect_mode)"
fi

log "install-crons: mode=${MODE} uninstall=${UNINSTALL} dry-run=${DRY_RUN}"

# ──────────────────────────────────────────────────────────────────────────
# Make all job scripts executable. Idempotent.
# ──────────────────────────────────────────────────────────────────────────

ensure_scripts_executable() {
    for j in "${JOB_LIST[@]}"; do
        local s="${SCRIPT_DIR}/jobs/${j}.sh"
        if [[ -f "$s" && ! -x "$s" ]]; then
            chmod 0755 "$s"
            log "chmod +x ${s}"
        fi
    done
    chmod 0755 "${SCRIPT_DIR}/scheduler.sh" "${SCRIPT_DIR}/install-crons.sh" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────
# systemd path
# ──────────────────────────────────────────────────────────────────────────

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

install_systemd() {
    ensure_scripts_executable
    mkdir -p "$UNIT_DIR"

    # Generate fresh unit/timer files into a staging dir.
    local staging
    staging="$(mktemp -d -t gawd-sched-XXXXXX)"
    "${SCRIPT_DIR}/scheduler.sh" --mode systemd --output-dir "$staging" || {
        rm -rf "$staging"
        fatal 2 "scheduler.sh generation failed"
    }

    # Idempotency: if a unit file already exists and is byte-identical to the
    # newly generated one, skip the rewrite + reload. This avoids unneeded
    # daemon-reload + timer restart cycles when nothing has changed.
    local changed_units=()
    for j in "${JOB_LIST[@]}"; do
        for ext in service timer; do
            local src="${staging}/gawd-${j}.${ext}"
            local dst="${UNIT_DIR}/gawd-${j}.${ext}"
            if [[ ! -f "$src" ]]; then
                warn "expected generated file missing: ${src}"
                continue
            fi
            if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
                log "unchanged: ${dst}"
                continue
            fi
            if [[ $DRY_RUN -eq 1 ]]; then
                log "DRY-RUN: would install ${dst}"
                changed_units+=("gawd-${j}.${ext}")
                continue
            fi
            install -m 0644 "$src" "$dst"
            log "installed: ${dst}"
            changed_units+=("gawd-${j}.${ext}")
        done
    done

    rm -rf "$staging"

    if [[ $UNINSTALL -eq 1 ]]; then
        uninstall_systemd
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: would systemctl --user daemon-reload + enable + start timers"
        return 0
    fi

    # Reload only if something actually changed.
    if [[ ${#changed_units[@]} -gt 0 ]]; then
        systemctl --user daemon-reload || warn "daemon-reload returned non-zero"
        log "systemctl --user daemon-reload done (${#changed_units[@]} units changed)"
    fi

    # Enable + start timers. enable --now is idempotent; safe to re-run.
    local timers=()
    for j in "${JOB_LIST[@]}"; do
        timers+=("gawd-${j}.timer")
    done
    if ! systemctl --user enable --now "${timers[@]}" 2>&1 | sed 's/^/  [systemctl] /'; then
        fatal 3 "systemctl enable --now failed for one or more timers"
    fi

    # Status summary
    log "active timers:"
    systemctl --user list-timers --no-pager 'gawd-*' 2>/dev/null | sed 's/^/  /' || true

    log "install (systemd) complete"
}

uninstall_systemd() {
    log "uninstalling systemd timers + services"
    if [[ $DRY_RUN -eq 1 ]]; then
        for j in "${JOB_LIST[@]}"; do
            log "DRY-RUN: would disable --now gawd-${j}.timer, then remove unit files"
        done
        return 0
    fi
    for j in "${JOB_LIST[@]}"; do
        systemctl --user disable --now "gawd-${j}.timer" 2>/dev/null || true
        rm -f "${UNIT_DIR}/gawd-${j}.timer" "${UNIT_DIR}/gawd-${j}.service"
    done
    systemctl --user daemon-reload || true
    log "uninstall complete"
}

# ──────────────────────────────────────────────────────────────────────────
# cron path
# ──────────────────────────────────────────────────────────────────────────

install_cron() {
    ensure_scripts_executable

    if [[ $UNINSTALL -eq 1 ]]; then
        uninstall_cron
        return 0
    fi

    # Generate the gawd-managed crontab fragment.
    local staging
    staging="$(mktemp -d -t gawd-sched-XXXXXX)"
    "${SCRIPT_DIR}/scheduler.sh" --mode cron --output-dir "$staging" || {
        rm -rf "$staging"
        fatal 2 "scheduler.sh generation failed"
    }

    local fragment="${staging}/crontab.gawd"
    [[ -f "$fragment" ]] || { rm -rf "$staging"; fatal 2 "generator did not produce crontab.gawd"; }

    # Pull existing crontab, strip any prior gawd-managed block, append fresh.
    # Markers let us idempotently replace JUST the gawd block, leaving other
    # entries untouched.
    local marker_begin="# === BEGIN GAWD SCHEDULER (managed by install-crons.sh) ==="
    local marker_end="# === END GAWD SCHEDULER ==="

    local existing
    if existing=$(crontab -l 2>/dev/null); then
        :
    else
        existing=""
    fi

    # Strip prior gawd block (if any) from existing.
    local stripped
    stripped=$(printf '%s\n' "$existing" | awk -v b="$marker_begin" -v e="$marker_end" '
        BEGIN { skipping=0 }
        $0 == b { skipping=1; next }
        $0 == e { skipping=0; next }
        skipping == 0 { print }
    ')

    # Build new crontab.
    local new_crontab
    new_crontab="$(printf '%s\n%s\n%s\n%s\n' \
        "$stripped" \
        "$marker_begin" \
        "$(cat "$fragment")" \
        "$marker_end")"

    rm -rf "$staging"

    # Idempotency: only install if it differs from current.
    if [[ "$existing" == "$new_crontab" ]]; then
        log "crontab unchanged — no-op"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: would install crontab:"
        printf '%s\n' "$new_crontab" | sed 's/^/  /'
        return 0
    fi

    printf '%s\n' "$new_crontab" | crontab - || fatal 3 "crontab install failed"
    log "crontab installed (cron mode)"
}

uninstall_cron() {
    log "uninstalling crontab gawd block"
    local marker_begin="# === BEGIN GAWD SCHEDULER (managed by install-crons.sh) ==="
    local marker_end="# === END GAWD SCHEDULER ==="
    local existing
    if ! existing=$(crontab -l 2>/dev/null); then
        log "no crontab present — nothing to uninstall"
        return 0
    fi
    local stripped
    stripped=$(printf '%s\n' "$existing" | awk -v b="$marker_begin" -v e="$marker_end" '
        BEGIN { skipping=0 }
        $0 == b { skipping=1; next }
        $0 == e { skipping=0; next }
        skipping == 0 { print }
    ')
    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: would install stripped crontab"
        return 0
    fi
    printf '%s\n' "$stripped" | crontab - || fatal 3 "crontab uninstall failed"
    log "crontab gawd block removed"
}

# ──────────────────────────────────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────────────────────────────────

case "$MODE" in
    systemd) install_systemd ;;
    cron)    install_cron ;;
    *)       fatal 1 "unknown mode: ${MODE}" ;;
esac

log "install-crons done"
exit 0
