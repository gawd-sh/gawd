#!/usr/bin/env bash
# loud.sh — /loud slash command handler
#
# Per spec §13.2 + handoff E4. Restores inter-Gawd traffic to the main channel.
# The gossip channel is NOT deleted — it persists so the Prophit retains
# retroactive access. /loud is idempotent.
#
# Usage:
#   loud.sh [--prophit-id <telegram-user-id>]
#           [--prophit-chat-id <telegram-chat-id>]
#           [--state <dir>]
#
# Exit codes:
#   0  routing flipped to loud (or already loud)
#   1  args error
#   2  state write failed
#
# Spec ref: §13.2 (slash commands), §13.3 (gossip channel persists, never deleted).

set -euo pipefail

# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../observability/logger.sh"

PROPHIT_ID=""
PROPHIT_CHAT_ID="${PROPHIT_CHAT_ID:-}"
STATE_DIR="${HOME}/.gawd/state"

usage() { grep '^# ' "$0" | sed 's/^# //'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prophit-id) PROPHIT_ID="$2"; shift 2 ;;
    --prophit-chat-id) PROPHIT_CHAT_ID="$2"; shift 2 ;;
    --state) STATE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
ROUTING_FILE="${STATE_DIR}/inter-gawd-routing.json"

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log_info inter-gawd "/loud invoked by prophit=${PROPHIT_ID:-unknown}"

tmpfile=$(mktemp "${ROUTING_FILE}.tmp.XXXXXX")
jq -n \
  --arg mode "loud" \
  --arg setat "$NOW_ISO" \
  --arg pid "$PROPHIT_ID" \
  '{
    mode: $mode,
    set_at: $setat,
    set_by_prophit_id: (if $pid == "" then null else $pid end)
  } | with_entries(select(.value != null))' > "$tmpfile" || { rm -f "$tmpfile"; exit 2; }
mv "$tmpfile" "$ROUTING_FILE"
log_info inter-gawd "routing state updated: mode=loud (gossip channel persists, not deleted)"

# ── ack the Prophit on Telegram ───────────────────────────────────────────────

TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-${HOME}/.secrets/telegram.token}"
if [[ -n "$PROPHIT_CHAT_ID" ]] && [[ -r "$TELEGRAM_TOKEN_FILE" ]]; then
  TOKEN="$(cat "$TELEGRAM_TOKEN_FILE")"
  ack_msg="Loud again. The gods speak in your hearing."
  curl -sf -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
       -d chat_id="$PROPHIT_CHAT_ID" \
       -d text="$ack_msg" >/dev/null 2>&1 \
    && log_info inter-gawd "/loud ack sent to Prophit" \
    || log_warn inter-gawd "/loud ack telegram send failed"
fi

exit 0
