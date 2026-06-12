#!/usr/bin/env bash
# probes/mcp-plugin-check.sh — Probe 3: Telegram MCP plugin liveness check.
#
# The Telegram plugin can disconnect while the gateway process stays alive.
# When this happens, the gateway receives messages but cannot deliver replies
# (the plugin that handles outbound delivery is dead). This probe detects
# that split-brain state.
#
# Detection approach:
#   1. Read the gateway's plugin-status endpoint if available.
#   2. Fallback: scan recent gateway.log for MCP disconnect signals.
#   3. Fallback 2: check that the plugin-socket / handler file exists and is
#      recent (touched by the gateway on plugin activity).
#
# Exits 0 if Telegram plugin is live.
# Exits 1 if plugin is detected disconnected.
# Exits 2 on probe infrastructure error (cannot determine state).
#
# Outputs one of: ok | fail | unknown
#
# On FAIL: sweep.sh switches Telegram delivery to direct-curl path (G2
# deliver/telegram.sh already implements this; sweep.sh sets
# GAWD_TELEGRAM_DIRECT=1 for the remainder of the sweep's action phase).
#
# Spec: §19.2 Layer 7, §19.6 "Telegram MCP plugin disconnected"
# No LLM. Pure bash + curl + jq.

set -euo pipefail
trap 'printf "unknown\n"; exit 2' ERR

GATEWAY_URL="${GAWD_GATEWAY_URL:-http://127.0.0.1:18789}"
GATEWAY_LOG="${GAWD_GATEWAY_LOG:-${HOME}/gateway.log}"
PROBE_TIMEOUT_S="${PROBE_TIMEOUT_S:-5}"

# ── Method 1: Gateway plugin-status endpoint ─────────────────────────────────
# OpenClaw exposes plugin status at /plugins/status (if version supports it).
plugin_response="$(curl -sf --max-time "${PROBE_TIMEOUT_S}" \
    "${GATEWAY_URL}/plugins/status" 2>/dev/null || true)"

if [[ -n "$plugin_response" ]]; then
    # Response is JSON. Look for telegram plugin status.
    tg_status="$(printf '%s' "$plugin_response" | jq -r '
        .plugins // .entries // [] |
        to_entries[] |
        select(
            (.key | test("telegram"; "i"))
            or (.value.name // "" | test("telegram"; "i"))
        ) |
        (.value.connected // .value.status // "unknown")
    ' 2>/dev/null | head -1 || true)"

    if [[ "$tg_status" == "true" ]] || [[ "$tg_status" == "connected" ]] || [[ "$tg_status" == "active" ]]; then
        printf "ok\n"
        exit 0
    elif [[ "$tg_status" == "false" ]] || [[ "$tg_status" == "disconnected" ]]; then
        printf "fail\n"
        exit 1
    fi
    # Unknown status value — fall through to log check
fi

# ── Method 2: Gateway log scan ────────────────────────────────────────────────
# Look for disconnect signals in the last 200 lines of the gateway log.
# These strings are observable in real incidents.
DISCONNECT_PATTERNS='(telegram.*disconnect|plugin.*telegram.*error|MCP.*telegram.*fail|telegram.*plugin.*lost|telegram.*plugin.*dead)'
RECONNECT_PATTERNS='(telegram.*connect(ed)?|telegram.*plugin.*ready|telegram.*plugin.*started)'

if [[ -f "$GATEWAY_LOG" ]]; then
    recent_log="$(tail -n 200 "$GATEWAY_LOG" 2>/dev/null || true)"
    last_disconnect_line="$(printf '%s\n' "$recent_log" | grep -iE "$DISCONNECT_PATTERNS" | tail -1 || true)"
    last_reconnect_line="$(printf '%s\n' "$recent_log" | grep -iE "$RECONNECT_PATTERNS" | tail -1 || true)"

    if [[ -n "$last_disconnect_line" ]]; then
        if [[ -z "$last_reconnect_line" ]]; then
            # Disconnected and no subsequent reconnect
            printf "fail\n"
            exit 1
        fi
        # Both present: compare line order in log (last one wins)
        disconnect_pos="$(printf '%s\n' "$recent_log" | grep -n "$last_disconnect_line" | tail -1 | cut -d: -f1 || true)"
        reconnect_pos="$(printf '%s\n' "$recent_log" | grep -n "$last_reconnect_line" | tail -1 | cut -d: -f1 || true)"
        if [[ -n "$disconnect_pos" && -n "$reconnect_pos" ]]; then
            if (( disconnect_pos > reconnect_pos )); then
                printf "fail\n"
                exit 1
            fi
        fi
    fi
fi

# ── Method 3: Plugin activity marker file ─────────────────────────────────────
# Some gateway versions touch a plugin-heartbeat file. Check recency.
PLUGIN_HEARTBEAT="${HOME}/.openclaw/plugin-heartbeat/telegram"
if [[ -f "$PLUGIN_HEARTBEAT" ]]; then
    now="$(date +%s)"
    mtime="$(stat -c %Y "$PLUGIN_HEARTBEAT" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    # Heartbeat older than 5 minutes while gateway is alive = suspect
    if (( age > 300 )); then
        printf "fail\n"
        exit 1
    else
        printf "ok\n"
        exit 0
    fi
fi

# ── Cannot determine definitively ─────────────────────────────────────────────
# If we get here: gateway is alive (probe 1 passed), log has no disconnect
# signal, and no heartbeat file. Treat as ok — no evidence of disconnect.
printf "ok\n"
exit 0
