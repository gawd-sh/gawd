#!/usr/bin/env bash
# watchdog/install.sh — Idempotent installer for the Layer 7 healing watchdog.
#
# What it does:
#   1. Creates the systemd user timer (watchdog-sweep.timer) at 60-second interval.
#   2. Creates the corresponding service unit (watchdog-sweep.service).
#   3. Enables and starts the timer (unless --no-start).
#   4. Copies probe scripts to $INSTALL_DIR.
#   5. Updates (does NOT disable) the existing 5-min gateway-watchdog.sh cron
#      to call sweep.sh instead of running standalone.
#   6. Creates state directories.
#   7. Runs a preflight bash -n check on all scripts.
#
# The existing cron for gateway-watchdog.sh is KEPT as a belt-and-suspenders
# fallback in case the systemd timer fails. It calls sweep.sh at 5-minute
# intervals (slower cadence, same effect). Per DOCTRINE §5.3 the existing cron
# is backed up before modification.
#
# Usage:
#   install.sh [--user <username>] [--install-dir <dir>] [--no-start] [--dry-run]
#
# Defaults:
#   --user        current user
#   --install-dir $HOME/.gawd/watchdog
#   --no-start    (flag) skip systemd enable+start; write units only
#   --dry-run     (flag) print what would happen; do nothing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_USER="${USER:-$(id -un)}"
INSTALL_DIR="${HOME}/.gawd/watchdog"
NO_START=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)        shift; RUN_USER="${1:-}";;
        --install-dir) shift; INSTALL_DIR="${1:-}";;
        --no-start)    NO_START=1;;
        --dry-run)     DRY_RUN=1;;
        -h|--help)
            sed -n '/^#/{ s/^# \{0,1\}//; p }' "$0" | head -40
            exit 0;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 1;;
    esac
    shift || true
done

log()  { printf '[watchdog-install] %s\n' "$*"; }
warn() { printf '[watchdog-install] WARN: %s\n' "$*" >&2; }
fail() { printf '[watchdog-install] ERROR: %s\n' "$*" >&2; exit 1; }

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SWEEP_SCRIPT="${INSTALL_DIR}/sweep.sh"
PROBES_INSTALL_DIR="${INSTALL_DIR}/probes"
STATE_DIR="${INSTALL_DIR}/state"

# Also the state path sweep.sh expects by default.
SWEEP_STATE_DIR="${SCRIPT_DIR}/state"
LAST_SWEEP_JSON="${SWEEP_STATE_DIR}/last-sweep.json"

# ── 1. Syntax-check all scripts ───────────────────────────────────────────────

log "bash -n preflight on all watchdog scripts"
all_ok=1
for f in "$SCRIPT_DIR/sweep.sh" \
          "$SCRIPT_DIR/probes"/*.sh \
          "$SCRIPT_DIR/install.sh"; do
    [[ -f "$f" ]] || continue
    if bash -n "$f" 2>/dev/null; then
        log "  ok: $(basename "$f")"
    else
        warn "  FAIL bash -n: $f"
        all_ok=0
    fi
done
[[ $all_ok -eq 1 ]] || fail "syntax errors found; aborting install"

# ── 2. Create directories ─────────────────────────────────────────────────────

log "creating install directories"
if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$INSTALL_DIR" "$PROBES_INSTALL_DIR" "$STATE_DIR" \
             "$SWEEP_STATE_DIR" "$SYSTEMD_USER_DIR"
fi

# ── 3. Copy scripts ───────────────────────────────────────────────────────────

log "copying sweep.sh and probes to $INSTALL_DIR"
if [[ "$DRY_RUN" -eq 0 ]]; then
    install -m 0755 "$SCRIPT_DIR/sweep.sh" "$SWEEP_SCRIPT"
    for probe in "$SCRIPT_DIR/probes"/*.sh; do
        [[ -f "$probe" ]] || continue
        install -m 0755 "$probe" "${PROBES_INSTALL_DIR}/$(basename "$probe")"
    done
fi

# ── 4. Write systemd service unit ─────────────────────────────────────────────

SERVICE_FILE="${SYSTEMD_USER_DIR}/watchdog-sweep.service"
log "writing ${SERVICE_FILE}"
if [[ "$DRY_RUN" -eq 0 ]]; then
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Gawd healing watchdog — Layer 7 sweep (gateway + session + MCP + auth + activity)
Documentation=file://${INSTALL_DIR}/README.md

[Service]
Type=oneshot
# Load per-Prophit env — tolerant (leading dash): unit starts even if file absent.
# "alerting off until set" behavior is intentional per install.sh step 4.5.
EnvironmentFile=-%h/.gawd/admin-env
ExecStart=${SWEEP_SCRIPT}
StandardOutput=journal
StandardError=journal
Environment=GAWD_HOME=${HOME}/.gawd
Environment=GAWD_PROPHIT_ID=${RUN_USER}
Environment=GAWD_PRIMARY_CHANNEL=telegram

[Install]
WantedBy=default.target
EOF
fi

# ── 5. Write systemd timer unit ───────────────────────────────────────────────

TIMER_FILE="${SYSTEMD_USER_DIR}/watchdog-sweep.timer"
log "writing ${TIMER_FILE}"
if [[ "$DRY_RUN" -eq 0 ]]; then
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Gawd healing watchdog — 60-second sweep timer
Documentation=file://${INSTALL_DIR}/README.md

[Timer]
# First sweep 30s after boot (let gateway settle).
OnBootSec=30s
# Then every 60s.
OnUnitActiveSec=60s
AccuracySec=5s
Unit=watchdog-sweep.service

[Install]
WantedBy=timers.target
EOF
fi

# ── 6. Enable and start the timer ─────────────────────────────────────────────

if [[ "$NO_START" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    log "reloading systemd user daemon"
    systemctl --user daemon-reload

    log "enabling and starting watchdog-sweep.timer"
    systemctl --user enable watchdog-sweep.timer
    systemctl --user start watchdog-sweep.timer

    log "timer status:"
    systemctl --user status watchdog-sweep.timer --no-pager || true
elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY_RUN: would reload daemon, enable and start watchdog-sweep.timer"
elif [[ "$NO_START" -eq 1 ]]; then
    log "--no-start: units written but not started; run:"
    log "  systemctl --user daemon-reload"
    log "  systemctl --user enable --now watchdog-sweep.timer"
fi

# ── 7. Update existing cron (belt-and-suspenders) ─────────────────────────────
# The existing 5-minute gateway-watchdog.sh cron stays active as a fallback.
# We add a second cron entry that calls sweep.sh at 5-minute offsets.
# DOCTRINE §5.3: backup before touching the crontab.

EXISTING_CRON_SCRIPT="${HOME}/.openclaw/workspace/scripts/gateway-watchdog.sh"
if [[ -f "$EXISTING_CRON_SCRIPT" ]]; then
    BAK_DEST="${EXISTING_CRON_SCRIPT}.bak.watchdog-extension-$(date +%s)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        cp "$EXISTING_CRON_SCRIPT" "$BAK_DEST"
        log "backed up existing watchdog: $BAK_DEST"
    else
        log "DRY_RUN: would back up $EXISTING_CRON_SCRIPT to $BAK_DEST"
    fi
fi

# Check if sweep.sh cron is already registered.
cron_entry="*/1 * * * * bash ${SWEEP_SCRIPT} >> ${HOME}/.gawd/watchdog/logs/sweep-cron.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "$SWEEP_SCRIPT"; then
    log "sweep.sh already in crontab; no change"
else
    if [[ "$DRY_RUN" -eq 0 ]]; then
        mkdir -p "${HOME}/.gawd/watchdog/logs"
        # Add sweep.sh as a cron entry at a 30s offset from the timer using
        # the nearest minute mark. Note: cron is minute-granularity; the
        # systemd timer does the 60s cadence. This cron is a belt-and-suspenders
        # 5-minute fallback.
        cron_bns_entry="*/5 * * * * bash ${SWEEP_SCRIPT} >> ${HOME}/.gawd/watchdog/logs/sweep-cron.log 2>&1"
        # crontab -l exits 1 when no crontab exists yet. Capture it with a
        # guarded fallback so `set -e` (inherited by this subshell) does not
        # abort before `crontab -` writes. (Metatron cadence fix 2026-05-28 —
        # removes the install.sh assembly-layer pre-seed workaround.)
        { crontab -l 2>/dev/null || true; printf '%s\n' "$cron_bns_entry"; } | crontab -
        log "added sweep.sh belt-and-suspenders cron (5-min interval)"
    else
        log "DRY_RUN: would add sweep.sh to crontab (5-min belt-and-suspenders)"
    fi
fi

# ── 8. Initialize last-sweep.json with empty state ────────────────────────────

if [[ ! -f "$LAST_SWEEP_JSON" && "$DRY_RUN" -eq 0 ]]; then
    cat > "$LAST_SWEEP_JSON" <<'EOF'
{
  "timestamp": "never",
  "timestamp_central": "never",
  "duration_ms": 0,
  "dry_run": false,
  "probes": {
    "gateway-health":    "pending",
    "session-wedge":     "pending",
    "mcp-plugin":        "pending",
    "auth-staleness":    "pending",
    "last-activity":     "pending"
  },
  "actions_taken": []
}
EOF
    log "initialized last-sweep.json"
fi

log "install complete"
log ""
log "  Sweep script: ${SWEEP_SCRIPT}"
log "  State file:   ${LAST_SWEEP_JSON}"
log "  Systemd:      systemctl --user list-timers watchdog-sweep.timer"
log "  Manual run:   bash ${SWEEP_SCRIPT}"
log "  Dry-run:      bash ${SWEEP_SCRIPT} --dry-run"
log ""
