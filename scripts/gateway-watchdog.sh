#!/usr/bin/env bash
# gateway-watchdog.sh — 5-minute cron; detects gateway crash-loops and alerts.
# Hardening item 2.15 (gawd-tarball-hardening-2026-04-29.md).
#
# EXTENDED 2026-05-27 to invoke the Layer 7 healing watchdog sweep (sweep.sh)
# when available. The sweep handles: wedged sessions, MCP plugin disconnects,
# auth staleness, and last-activity probes — covering the failure modes
# uncovered by the 2026-05-27 Dasra incident.
#
# Original checks (binstub integrity + crash-loop detection) are FULLY PRESERVED.
# This extension adds a call to sweep.sh when the script is installed, and
# falls back gracefully if it is not.
#
# Also checks for missing openclaw binstub (hardening 2.17 — npm update -g risk).
#
# Install via cron (handled by install.sh):
#   */5 * * * * bash $HOME/.openclaw/workspace/scripts/gateway-watchdog.sh \
#          >> $HOME/.openclaw/logs/gateway-watchdog-cron.log 2>&1
#
# Secrets: reads telegram_bot_token and telegram_admin_chat_id from
# ~/.openclaw/secrets/secrets.json. Never echoes the token to stdout.
#
# Backup: gateway-watchdog.sh.bak.watchdog-extension-2026-05-27
set -euo pipefail

SECRETS_JSON="${HOME}/.openclaw/secrets/secrets.json"
LOG="${HOME}/.openclaw/logs/gateway-watchdog-cron.log"
RESTART_THRESHOLD=50

# Layer 7 sweep script (installed by forge/watchdog/install.sh).
# Paths to try, in order of preference.
# M-4 (phase4-20260609): candidate #2 was /srv/gawd/forge/watchdog/sweep.sh
# (Dasra-internal forge path, dead in-container). Replaced with the canonical
# in-image install path /usr/local/lib/gawd/watchdog/sweep.sh.
SWEEP_CANDIDATES=(
    "${HOME}/.gawd/watchdog/sweep.sh"
    "/usr/local/lib/gawd/watchdog/sweep.sh"
)

mkdir -p "$(dirname "$LOG")"

_alert() {
    local msg="$1"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ALERT: $msg" >> "$LOG"
    # Send Telegram alert — reads token programmatically, never echoes it.
    if [[ -f "$SECRETS_JSON" ]]; then
        local tg_token chat_id
        tg_token="$(python3 -c \
            "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('telegram_bot_token',''))" \
            "$SECRETS_JSON" 2>/dev/null || true)"
        chat_id="$(python3 -c \
            "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('telegram_admin_chat_id',''))" \
            "$SECRETS_JSON" 2>/dev/null || true)"
        if [[ -n "$tg_token" && -n "$chat_id" ]]; then
            curl -sf -X POST \
                "https://api.telegram.org/bot${tg_token}/sendMessage" \
                -d "chat_id=${chat_id}" \
                -d "text=GAWD WATCHDOG: ${msg}" \
                > /dev/null || true
            # Never expose tg_token in log or stdout.
        fi
    fi
}

# ── Original Check 1: openclaw binstub integrity (hardening 2.17) ─────────────
# The npm update -g bug can silently remove the binstub while the gateway
# keeps running in memory — window closes at next restart.
OPENCLAW_BIN=""
for candidate in /usr/local/bin/openclaw /usr/bin/openclaw; do
    if [[ -x "$candidate" ]]; then
        OPENCLAW_BIN="$candidate"
        break
    fi
done
if [[ -z "$OPENCLAW_BIN" ]]; then
    _alert "openclaw binstub missing or non-executable — gateway restart will fail on next exit. Check: npm install -g openclaw@<version>"
fi

# ── Original Check 2: crash-loop detection in system openclaw units ───────────
if command -v systemctl > /dev/null 2>&1; then
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        restarts="$(systemctl show "$svc" --property=NRestarts --value 2>/dev/null || echo 0)"
        if [[ "$restarts" -gt "$RESTART_THRESHOLD" ]]; then
            _alert "$svc crash-loop: ${restarts} restarts — stopping and disabling"
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done < <(systemctl list-units --state=failed --no-legend 'openclaw*' 2>/dev/null | awk '{print $1}')

    # ── Original Check 3: user-systemd openclaw units ─────────────────────────
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        restarts="$(systemctl --user show "$svc" --property=NRestarts --value 2>/dev/null || echo 0)"
        if [[ "$restarts" -gt "$RESTART_THRESHOLD" ]]; then
            _alert "user/$svc crash-loop: ${restarts} restarts — stopping and disabling"
            systemctl --user stop "$svc" 2>/dev/null || true
            systemctl --user disable "$svc" 2>/dev/null || true
        fi
    done < <(systemctl --user list-units --state=failed --no-legend 'openclaw*' 2>/dev/null | awk '{print $1}')
fi

# ── Layer 7 Extension: invoke sweep.sh for deep-health probes ─────────────────
# sweep.sh handles: gateway HTTP probe, session-wedge detection, MCP plugin
# disconnect, auth-staleness (v1.1 stub), and last-activity stale.
# If sweep.sh is not yet installed, log a one-time notice and skip.
SWEEP_SCRIPT=""
for candidate in "${SWEEP_CANDIDATES[@]}"; do
    if [[ -x "$candidate" ]]; then
        SWEEP_SCRIPT="$candidate"
        break
    fi
done

if [[ -n "$SWEEP_SCRIPT" ]]; then
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') INFO: invoking Layer 7 sweep: $SWEEP_SCRIPT" >> "$LOG"
    # Run the sweep; capture output; do not let a sweep failure kill this cron.
    sweep_out="$(bash "$SWEEP_SCRIPT" 2>&1)" || true
    # Log sweep output (without any secret content — sweep.sh is responsible
    # for its own no-secrets discipline).
    if [[ -n "$sweep_out" ]]; then
        echo "$sweep_out" >> "$LOG" 2>/dev/null || true
    fi
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') INFO: Layer 7 sweep complete" >> "$LOG"
else
    # Sweep not installed yet — log once per run so the operator knows.
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') INFO: Layer 7 sweep not installed (sweep.sh not found); run forge/watchdog/install.sh to enable deep-health probes" >> "$LOG"
fi
