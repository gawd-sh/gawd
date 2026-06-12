#!/usr/bin/env bash
# deliver/dashboard.sh — Dashboard fallback delivery.
#
# Primary path: POST to dashboard's SSE/event endpoint (G6 dependency).
# Fallback path: write a queued message file the dashboard polls.
#
# This is part of Layer 6. Per spec §19.3.2, the dashboard infrastructure
# is SEPARATE from the LLM chain — if LLMs are down, the dashboard's web
# server is still up, so this delivery path should work even in the worst
# LLM-chain scenario.
#
# Usage:
#   deliver/dashboard.sh <prophit_id> <rendered_html>
#
# Exit:
#   0  delivered (SSE push succeeded OR file-queue write succeeded)
#   1  config missing
#   2  both delivery paths failed

set -euo pipefail

prophit_id="${1:-}"
message="${2:-}"

if [[ -z "$prophit_id" || -z "$message" ]]; then
    printf 'usage: deliver/dashboard.sh <prophit_id> <message>\n' >&2
    exit 1
fi

CONFIG_FILE="${GAWD_FALLBACK_CONFIG:-${HOME}/.gawd/fallbacks/config.json}"
QUEUE_DIR="${GAWD_DASHBOARD_QUEUE_DIR:-${HOME}/.gawd/dashboard/queue}"

# Source logger.
if [[ -f /usr/local/lib/gawd/observability/logger.sh ]]; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source /usr/local/lib/gawd/observability/logger.sh
else
    log_info()  { printf '[fb-dashboard] [info]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_warn()  { printf '[fb-dashboard] [warn]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_error() { printf '[fb-dashboard] [error] %s: %s\n'  "${1:-}" "${*:2}" >&2; }
fi

# Resolve dashboard endpoint. G6 will provide; for now, may be absent.
sse_url=""
if [[ -f "$CONFIG_FILE" ]]; then
    sse_url="$(jq -r '.dashboard.sse_url // empty' "$CONFIG_FILE" 2>/dev/null || true)"
fi

# Try SSE push first.
if [[ -n "$sse_url" && "${GAWD_FALLBACK_NO_NETWORK:-0}" != "1" ]]; then
    payload="$(jq -nc \
        --arg p "$prophit_id" \
        --arg msg "$message" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{type:"fallback", prophit:$p, ts:$ts, html:$msg}')"
    if curl -sS \
        --max-time 5 \
        --connect-timeout 3 \
        -H 'Content-Type: application/json' \
        -X POST \
        --data "$payload" \
        "$sse_url" >/dev/null 2>&1
    then
        log_info fb-dashboard "delivered via SSE prophit=$prophit_id bytes=${#message}"
        exit 0
    else
        log_warn fb-dashboard "SSE push failed, falling back to file queue"
    fi
fi

# File-queue fallback (always available; dashboard polls).
mkdir -p "$QUEUE_DIR"
chmod 0700 "$QUEUE_DIR" 2>/dev/null || true

# One-file-per-message; dashboard reads + removes (or moves to processed).
# Filename: <ts>-<prophit>-<random>.json — sortable by time.
ts_filename="$(date -u +%Y%m%dT%H%M%SZ)"
rand_suffix="$RANDOM-$$"
queue_file="${QUEUE_DIR}/${ts_filename}-${prophit_id}-${rand_suffix}.json"

# Atomic write: temp + rename.
tmp="$(mktemp "${queue_file}.XXXXXX")"
if jq -nc \
    --arg p "$prophit_id" \
    --arg msg "$message" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:"fallback", prophit:$p, ts:$ts, html:$msg}' \
    > "$tmp" 2>/dev/null
then
    chmod 0600 "$tmp"
    mv "$tmp" "$queue_file"
    log_info fb-dashboard "queued via file prophit=$prophit_id path=$queue_file bytes=${#message}"
    exit 0
else
    rm -f "$tmp"
    log_error fb-dashboard "both SSE and file-queue delivery failed"
    exit 2
fi
