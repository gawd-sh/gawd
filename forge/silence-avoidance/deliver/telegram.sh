#!/usr/bin/env bash
# deliver/telegram.sh — Telegram fallback delivery via direct curl.
#
# Per GAWDFATHER-DOCTRINE §7.5: the Telegram MCP plugin may be the thing
# that's down. The fallback path must NEVER depend on it. We call the
# Bot API directly with curl.
#
# Per feedback_diagnose_secrets_without_leaking: the token is read from a
# file (chmod 0600); it is NEVER echoed, NEVER logged, NEVER written to a
# transcript.
#
# Token location (per reference_bot_identities; Lilith pattern):
#   ${GAWD_TELEGRAM_TOKEN_FILE:-$HOME/.gawd/.secrets/telegram.token}
#
# Prophit -> chat_id mapping comes from:
#   ${GAWD_FALLBACK_CONFIG:-$HOME/.gawd/fallbacks/config.json}
# Under .prophits.<id>.telegram_chat_id
#
# Usage:
#   deliver/telegram.sh <prophit_id> <rendered_message>
#
# Exit:
#   0  delivered (Bot API returned ok:true)
#   1  config / token / chat_id missing
#   2  network/api failure (curl non-zero or ok:false)

set -euo pipefail

prophit_id="${1:-}"
message="${2:-}"

if [[ -z "$prophit_id" || -z "$message" ]]; then
    printf 'usage: deliver/telegram.sh <prophit_id> <message>\n' >&2
    exit 1
fi

TOKEN_FILE="${GAWD_TELEGRAM_TOKEN_FILE:-${HOME}/.gawd/.secrets/telegram.token}"
CONFIG_FILE="${GAWD_FALLBACK_CONFIG:-${HOME}/.gawd/fallbacks/config.json}"

# Source logger if available — but never log token contents.
if [[ -f /usr/local/lib/gawd/observability/logger.sh ]]; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source /usr/local/lib/gawd/observability/logger.sh
else
    log_info()  { printf '[fb-telegram] [info]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_warn()  { printf '[fb-telegram] [warn]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_error() { printf '[fb-telegram] [error] %s: %s\n'  "${1:-}" "${*:2}" >&2; }
fi

# Resolve chat_id WITHOUT echoing it back (chat_id is sensitive identity data).
chat_id=""
if [[ -f "$CONFIG_FILE" ]]; then
    chat_id="$(jq -r --arg p "$prophit_id" '.prophits[$p].telegram_chat_id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
fi

if [[ -z "$chat_id" || "$chat_id" == "null" ]]; then
    log_error fb-telegram "no telegram_chat_id configured for prophit=$prophit_id in $CONFIG_FILE"
    exit 1
fi

# Read token. NEVER echo, NEVER log.
if [[ ! -r "$TOKEN_FILE" ]]; then
    log_error fb-telegram "telegram token file unreadable (path elided for safety)"
    exit 1
fi
# Read into a local variable; do NOT export.
TG_TOKEN="$(< "$TOKEN_FILE")"
TG_TOKEN="${TG_TOKEN%$'\n'}"  # strip trailing newline if any
TG_TOKEN="${TG_TOKEN// /}"     # strip spaces (defensive)

if [[ -z "$TG_TOKEN" ]]; then
    log_error fb-telegram "telegram token file is empty"
    exit 1
fi

# Dry-network mode for tests: if GAWD_FALLBACK_NO_NETWORK=1, do not actually
# call the API; print a marker and exit 0. Used by test-no-network-required.
if [[ "${GAWD_FALLBACK_NO_NETWORK:-0}" == "1" ]]; then
    log_info fb-telegram "GAWD_FALLBACK_NO_NETWORK=1 — would have sent ${#message} bytes to chat_id (elided)"
    printf 'NO_NETWORK_MODE: would deliver %d bytes\n' "${#message}" >&2
    exit 0
fi

# Build the API URL. Token is sensitive; we never log the URL, only "api.telegram.org" generically.
api_url="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

# Build the JSON payload via jq (handles escaping safely).
payload="$(jq -nc \
    --arg cid "$chat_id" \
    --arg txt "$message" \
    '{chat_id: ($cid | tonumber? // $cid), text: $txt, disable_web_page_preview: true}')"

# POST with bounded retry (§19-H4). The fallback path is the last line of
# defense against silence, so a single transient network blip or a 429 must not
# make us give up. 3 attempts max; honor HTTP 429 retry_after; short backoff
# otherwise. Short per-attempt timeouts — we cannot block forever.
attempt=0
max_attempts=3
last_err_code=""
last_err_desc=""
while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))

    response="$(curl -sS \
        --max-time 10 \
        --connect-timeout 5 \
        -H 'Content-Type: application/json' \
        -X POST \
        --data "$payload" \
        "$api_url" 2>&1)" || {
        log_warn fb-telegram "curl to api.telegram.org failed (transport) attempt=${attempt}/${max_attempts}"
        (( attempt < max_attempts )) && sleep $(( attempt * 2 ))
        continue
    }

    # Check Bot API's ok field.
    ok="$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null || printf 'false')"
    if [[ "$ok" == "true" ]]; then
        log_info fb-telegram "delivered prophit=$prophit_id bytes=${#message} attempt=${attempt}"
        exit 0
    fi

    # Not ok. Surface error_code + description for ops, but never include token.
    last_err_code="$(printf '%s' "$response" | jq -r '.error_code // "?"' 2>/dev/null)"
    last_err_desc="$(printf '%s' "$response" | jq -r '.description // "?"' 2>/dev/null)"
    log_warn fb-telegram "Bot API rejected: code=$last_err_code desc=$last_err_desc attempt=${attempt}/${max_attempts}"

    if [[ "$attempt" -lt "$max_attempts" ]]; then
        if [[ "$last_err_code" == "429" ]]; then
            # Honor Telegram's retry_after (seconds) when throttled.
            retry_after="$(printf '%s' "$response" | jq -r '.parameters.retry_after // empty' 2>/dev/null || true)"
            if [[ -n "$retry_after" && "$retry_after" =~ ^[0-9]+$ ]]; then
                # Cap the wait so we never block the fallback path absurdly long.
                (( retry_after > 15 )) && retry_after=15
                sleep "$retry_after"
            else
                sleep $(( attempt * 2 ))
            fi
        else
            sleep $(( attempt * 2 ))
        fi
    fi
done

log_error fb-telegram "Bot API delivery failed after ${max_attempts} attempts (last: code=$last_err_code desc=$last_err_desc)"
exit 2
