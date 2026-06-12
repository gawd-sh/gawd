#!/usr/bin/env bash
# probes/mcp-plugin-check.sh — Probe 3: Telegram channel plugin liveness.
#
# OpenClaw exposes Telegram as a channel (channels.telegram in openclaw.json).
# A "plugin disconnect" in the Dasra incident context means the Telegram polling
# loop inside the gateway process has stopped (no new DMs delivered), even though
# the gateway HTTP server is alive.
#
# Detection strategy (two tiers):
#   Tier A: Check that the gateway process is still alive AND the channel is
#           configured as enabled in openclaw.json. If gateway is dead,
#           probe 1 (gateway-health) already fires — this probe reports consistent.
#   Tier B: Check the gateway log for explicit Telegram polling errors in the
#           last 200 lines. Conservative — only fires on explicit disconnect
#           evidence; probe 5 (last-activity) catches the broader no-reply case.
#
# On disconnect detection:
#   - Writes a marker flag: $GAWD_HOME/state/mcp-plugin-disconnected
#   - Engine/deliver scripts read this flag to bypass the MCP plugin and use
#     direct-curl delivery instead.
#   - Logs the disconnect and triggers a direct-curl alert to the operator.
#
# Exits:
#   0  probe passed
#   1  probe failed (disconnect detected — alert fired)
#   2  probe inconclusive
#
# Stdout: {"probe":"mcp-plugin","status":"ok|fail|warn","detail":"..."}
#
# Spec: §19.2 Layer 7, §19.6 "Telegram MCP plugin disconnected"

set -euo pipefail

PROBE_NAME="mcp-plugin"

: "${GAWD_HOME:=${HOME}/.gawd}"
: "${OPENCLAW_HOME:=${HOME}/.openclaw}"
: "${OPENCLAW_CONFIG:=${OPENCLAW_HOME}/openclaw.json}"
: "${GATEWAY_URL:=${GAWD_GATEWAY_URL:-http://127.0.0.1:18789}}"
: "${CURL_TIMEOUT:=${GAWD_PROBE_CURL_TIMEOUT:-5}}"

# Path for the disconnect flag (read by deliver/telegram.sh to choose direct-curl path).
DISCONNECT_FLAG="${GAWD_HOME}/state/mcp-plugin-disconnected"

# Telegram env file for direct-curl alerts (GawdFather-specific path; daemon
# installs use ${GAWD_HOME}/secrets/telegram-bot.env or similar).
TG_ENV_FILE="${HOME}/.claude/channels/telegram/.env"
TG_SECRETS_JSON="${OPENCLAW_HOME}/secrets/secrets.json"

# Admin chat ID for disconnect alerts.
: "${GAWD_ADMIN_CHAT_ID:=}"  # set GAWD_ADMIN_CHAT_ID at install; no default is safe (empty = alert silently skipped)

_result() {
    local status="$1" detail="$2"
    printf '{"probe":"%s","status":"%s","detail":"%s"}\n' \
        "$PROBE_NAME" "$status" "$detail"
}

# ── Alert helper ──────────────────────────────────────────────────────────────
# Defined first so it can be called anywhere below.

_send_disconnect_alert() {
    # Read token without echoing it. Prefer GawdFather env file; fall back to
    # secrets.json. Never log the token.
    local tg_token="" chat_id="$GAWD_ADMIN_CHAT_ID"

    if [[ -f "$TG_ENV_FILE" ]]; then
        tg_token="$(grep '^TELEGRAM_BOT_TOKEN=' "$TG_ENV_FILE" 2>/dev/null \
            | cut -d= -f2- | tr -d '\n\r')"
    fi
    if [[ -z "$tg_token" ]] && [[ -f "$TG_SECRETS_JSON" ]]; then
        tg_token="$(python3 -c \
            "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('telegram_bot_token',''))" \
            "$TG_SECRETS_JSON" 2>/dev/null || true)"
        chat_id_from_secrets="$(python3 -c \
            "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('telegram_admin_chat_id',''))" \
            "$TG_SECRETS_JSON" 2>/dev/null || true)"
        [[ -n "$chat_id_from_secrets" ]] && chat_id="$chat_id_from_secrets"
    fi

    if [[ -z "$tg_token" || -z "$chat_id" ]]; then
        printf '[mcp-plugin-check] ALERT: Telegram disconnect detected but no token available for direct-curl alert\n' >&2
        return 0
    fi

    # Direct-curl delivery — bypasses the MCP plugin entirely.
    local msg
    msg="WATCHDOG ALERT: Telegram MCP plugin disconnect detected. Gateway is alive but Telegram polling may be dead. Switching to direct-curl delivery path. Manual check: journalctl or gateway.log"

    curl -sf \
        --max-time 10 \
        -X POST "https://api.telegram.org/bot${tg_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${msg}" \
        >/dev/null 2>&1 || \
        printf '[mcp-plugin-check] WARN: direct-curl alert failed (Telegram API unreachable)\n' >&2

    # Unset to avoid lingering in memory.
    unset tg_token
}

# ── Read Telegram config from openclaw.json ──────────────────────────────────

telegram_enabled="false"
if command -v jq >/dev/null 2>&1 && [[ -f "$OPENCLAW_CONFIG" ]]; then
    telegram_enabled="$(jq -r '.channels.telegram.enabled // false' \
        "$OPENCLAW_CONFIG" 2>/dev/null || echo "false")"
fi

if [[ "$telegram_enabled" != "true" ]]; then
    # Telegram channel not enabled in this deployment — probe is irrelevant.
    _result "ok" "telegram channel not enabled; probe skipped"
    exit 0
fi

# ── Tier A: gateway process liveness ─────────────────────────────────────────
# If gateway is dead, gateway-health probe fires separately; we report consistent.
gw_ok=0
if curl -sf --max-time "$CURL_TIMEOUT" --connect-timeout 3 \
        "${GATEWAY_URL}/health" >/dev/null 2>&1; then
    gw_ok=1
fi

if [[ $gw_ok -eq 0 ]]; then
    # Gateway is down; gateway-health already fired. Stay consistent, not redundant.
    _result "warn" "gateway unreachable; mcp-plugin state indeterminate (gateway-health will handle)"
    # Clear any existing disconnect flag — gateway down is a different failure mode.
    rm -f "$DISCONNECT_FLAG" 2>/dev/null || true
    exit 2
fi

# ── Tier B: Telegram channel state from gateway log ──────────────────────────
# We check for the disconnect flag being stale vs fresh — if it was set and
# gateway has since restarted clean, clear it.
if [[ -f "$DISCONNECT_FLAG" ]]; then
    flag_age=$(( $(date +%s) - $(stat -c %Y "$DISCONNECT_FLAG" 2>/dev/null || echo 0) ))
    # If flag is old (>10 min) and gateway is now alive, clear it — likely recovered.
    if (( flag_age > 600 )); then
        rm -f "$DISCONNECT_FLAG" 2>/dev/null || true
    fi
fi

# Primary signal: check gateway log for Telegram plugin error lines in the last
# 200 lines. Probe is conservative: only fires when we see EXPLICIT disconnect evidence.
GATEWAY_LOG="${GAWD_GATEWAY_LOG:-${HOME}/gateway.log}"
disconnect_evidence=0

if [[ -f "$GATEWAY_LOG" ]]; then
    # Look for Telegram polling error / unhandled promise rejection in recent lines.
    if tail -n 200 "$GATEWAY_LOG" 2>/dev/null \
        | grep -qiE "(telegram.*error|polling.*failed|getUpdates.*failed|ETELEGRAM|plugin.*disconnect|channel.*telegram.*fail)" \
          2>/dev/null; then
        disconnect_evidence=1
    fi
fi

if [[ $disconnect_evidence -eq 1 ]]; then
    mkdir -p "$(dirname "$DISCONNECT_FLAG")"
    touch "$DISCONNECT_FLAG"
    _send_disconnect_alert
    _result "fail" "Telegram plugin disconnect evidence in gateway log"
    exit 1
fi

# ── All checks passed ─────────────────────────────────────────────────────────

# Clear disconnect flag if previously set and no current evidence.
if [[ -f "$DISCONNECT_FLAG" ]]; then
    rm -f "$DISCONNECT_FLAG" 2>/dev/null || true
fi

_result "ok" "Telegram channel enabled; no disconnect evidence"
exit 0
