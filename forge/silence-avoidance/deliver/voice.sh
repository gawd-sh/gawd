#!/usr/bin/env bash
# deliver/voice.sh — Voice (TTS) fallback delivery.
#
# Renders the static voice template through whichever TTS provider is
# configured. Per handoff acceptance criteria + spec §19.6:
#   "If TTS itself is down, deliver the text via Telegram as a
#    degraded-of-degraded fallback."
#
# This is the only delivery that has its own internal fallback path
# (voice -> telegram). It must always emit SOMETHING.
#
# Usage:
#   deliver/voice.sh <prophit_id> <rendered_text>
#
# Exit:
#   0  delivered via TTS OR delivered via Telegram fallback
#   1  both paths failed (only possible if config is broken AND telegram down)

set -euo pipefail

prophit_id="${1:-}"
message="${2:-}"

if [[ -z "$prophit_id" || -z "$message" ]]; then
    printf 'usage: deliver/voice.sh <prophit_id> <message>\n' >&2
    exit 1
fi

DELIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${GAWD_FALLBACK_CONFIG:-${HOME}/.gawd/fallbacks/config.json}"

# Source logger.
if [[ -f /usr/local/lib/gawd/observability/logger.sh ]]; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source /usr/local/lib/gawd/observability/logger.sh
else
    log_info()  { printf '[fb-voice] [info]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_warn()  { printf '[fb-voice] [warn]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_error() { printf '[fb-voice] [error] %s: %s\n'  "${1:-}" "${*:2}" >&2; }
fi

# Read TTS endpoint config. Voice TTS is implementation-pluggable; this
# script knows the contract but not the specific provider. The contract:
#   .voice.tts_endpoint    - POST URL accepting JSON { text, voice_id }
#   .voice.tts_voice_id    - voice identifier (per-Gawd)
#   .voice.tts_token_file  - optional bearer token file
tts_endpoint=""
tts_voice_id=""
tts_token_file=""
if [[ -f "$CONFIG_FILE" ]]; then
    tts_endpoint="$(jq -r '.voice.tts_endpoint // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    tts_voice_id="$(jq -r '.voice.tts_voice_id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    tts_token_file="$(jq -r '.voice.tts_token_file // empty' "$CONFIG_FILE" 2>/dev/null || true)"
fi

# Degrade-to-telegram helper.
degrade_to_telegram() {
    log_warn fb-voice "voice path degraded; routing static fallback through telegram for prophit=$prophit_id"
    if "$DELIVER_DIR/telegram.sh" "$prophit_id" "$message"; then
        log_info fb-voice "degraded-to-telegram delivered prophit=$prophit_id"
        return 0
    else
        log_error fb-voice "degraded-to-telegram ALSO failed prophit=$prophit_id"
        return 1
    fi
}

# Dry-network mode: simulate TTS not available.
if [[ "${GAWD_FALLBACK_NO_NETWORK:-0}" == "1" ]]; then
    log_info fb-voice "GAWD_FALLBACK_NO_NETWORK=1 — degrading voice to telegram"
    if [[ "${GAWD_FALLBACK_TEST_SUPPRESS_DEGRADE:-0}" == "1" ]]; then
        log_info fb-voice "test mode — suppressing telegram degradation"
        exit 0
    fi
    degrade_to_telegram
    exit $?
fi

# If no TTS endpoint configured, degrade.
if [[ -z "$tts_endpoint" ]]; then
    log_warn fb-voice "no voice.tts_endpoint configured — degrading to telegram"
    degrade_to_telegram
    exit $?
fi

# Read TTS token if specified.
auth_header=()
if [[ -n "$tts_token_file" && -r "$tts_token_file" ]]; then
    tts_token="$(< "$tts_token_file")"
    tts_token="${tts_token%$'\n'}"
    if [[ -n "$tts_token" ]]; then
        auth_header=(-H "Authorization: Bearer $tts_token")
    fi
fi

# Build payload.
payload="$(jq -nc \
    --arg t "$message" \
    --arg v "$tts_voice_id" \
    '{text:$t, voice_id:$v}')"

# Attempt TTS. Short timeout — if TTS is slow, we degrade.
if curl -sS \
    --max-time 8 \
    --connect-timeout 3 \
    -H 'Content-Type: application/json' \
    "${auth_header[@]}" \
    -X POST \
    --data "$payload" \
    "$tts_endpoint" >/dev/null 2>&1
then
    log_info fb-voice "delivered via TTS prophit=$prophit_id bytes=${#message}"
    exit 0
fi

log_warn fb-voice "TTS endpoint failed or timed out — degrading to telegram"
degrade_to_telegram
exit $?
