#!/usr/bin/env bash
# quiet.sh — /quiet [duration] slash command handler
#
# Per spec §13.2 + handoff E4. Routes inter-Gawd traffic to the gossip channel
# (auto-creating it on first invocation). Optional duration argument: `Nh`,
# `Nd`, `Nw`. Default: indefinite.
#
# Usage:
#   quiet.sh [--duration <Nh|Nd|Nw>]
#            [--prophit-id <telegram-user-id>]
#            [--prophit-chat-id <telegram-chat-id>]
#            [--state <dir>]
#
# Behavior:
#   1. Parse optional duration; compute expires_at.
#   2. Update ~/.gawd/state/inter-gawd-routing.json: mode=quiet, set_at, expires_at.
#   3. If ~/.gawd/state/gossip-channel.json absent, invoke gossip-channel.sh.
#   4. Send Telegram acknowledgment to the Prophit ("the gods will whisper now").
#
# Exit codes:
#   0  routing flipped to quiet (channel may still be pending creation)
#   1  args error
#   2  malformed duration
#   3  gossip-channel.sh failed
#   4  state write failed
#
# Spec ref: §13.2 (slash commands), §13.3 (gossip channel mechanics), §17.9
#           (graceful degradation when household-gawds.json is empty).

set -euo pipefail

# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../observability/logger.sh"

DURATION=""
PROPHIT_ID=""
PROPHIT_CHAT_ID="${PROPHIT_CHAT_ID:-}"
STATE_DIR="${HOME}/.gawd/state"

usage() { grep '^# ' "$0" | sed 's/^# //'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
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
GOSSIP_FILE="${STATE_DIR}/gossip-channel.json"

# ── parse duration ────────────────────────────────────────────────────────────

EXPIRES_AT=""
if [[ -n "$DURATION" ]]; then
  # Accept Nh / Nd / Nw (N = positive integer)
  if [[ "$DURATION" =~ ^([0-9]+)([hdw])$ ]]; then
    n="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    seconds=0
    case "$unit" in
      h) seconds=$((n * 3600)) ;;
      d) seconds=$((n * 86400)) ;;
      w) seconds=$((n * 604800)) ;;
    esac
    # GNU date supports -d "+N seconds" relative; portable on Linux containers
    EXPIRES_AT=$(date -u -d "@$(( $(date +%s) + seconds ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    if [[ -z "$EXPIRES_AT" ]]; then
      # BSD date fallback (rare on Linux Gawds, but just in case)
      EXPIRES_AT=$(date -u -r "$(( $(date +%s) + seconds ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    fi
    if [[ -z "$EXPIRES_AT" ]]; then
      log_error inter-gawd "could not compute expires_at for duration=${DURATION}"
      exit 2
    fi
  else
    log_warn inter-gawd "malformed duration '${DURATION}' (expected Nh/Nd/Nw)"
    exit 2
  fi
fi

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log_info inter-gawd "/quiet invoked by prophit=${PROPHIT_ID:-unknown} duration=${DURATION:-indefinite} expires_at=${EXPIRES_AT:-never}"

# ── update routing state ──────────────────────────────────────────────────────

tmpfile=$(mktemp "${ROUTING_FILE}.tmp.XXXXXX")
if [[ -n "$EXPIRES_AT" ]]; then
  jq -n \
    --arg mode "quiet" \
    --arg setat "$NOW_ISO" \
    --arg exp "$EXPIRES_AT" \
    --arg pid "$PROPHIT_ID" \
    '{
      mode: $mode,
      set_at: $setat,
      expires_at: $exp,
      set_by_prophit_id: (if $pid == "" then null else $pid end)
    } | with_entries(select(.value != null))' > "$tmpfile" || { rm -f "$tmpfile"; exit 4; }
else
  jq -n \
    --arg mode "quiet" \
    --arg setat "$NOW_ISO" \
    --arg pid "$PROPHIT_ID" \
    '{
      mode: $mode,
      set_at: $setat,
      set_by_prophit_id: (if $pid == "" then null else $pid end)
    } | with_entries(select(.value != null))' > "$tmpfile" || { rm -f "$tmpfile"; exit 4; }
fi
mv "$tmpfile" "$ROUTING_FILE"
log_info inter-gawd "routing state updated: mode=quiet"

# ── create gossip channel if absent ───────────────────────────────────────────

if [[ ! -f "$GOSSIP_FILE" ]]; then
  GOSSIP_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../gossip-channel.sh"
  if [[ -x "$GOSSIP_SH" ]]; then
    if ! "$GOSSIP_SH" \
         --state "$STATE_DIR" \
         ${PROPHIT_CHAT_ID:+--prophit-chat-id "$PROPHIT_CHAT_ID"}; then
      rc=$?
      log_error inter-gawd "gossip-channel.sh exited ${rc}"
      # Per §17.9: graceful degradation — routing is still set to quiet;
      # the channel may be in pending state. We do not roll back the routing
      # state on gossip-channel failure; the operator will see a "pending"
      # channel and the Prophit will get a re-attempt next /quiet.
      exit 3
    fi
  else
    log_warn inter-gawd "gossip-channel.sh not found at ${GOSSIP_SH}; routing flipped but channel not created"
  fi
fi

# ── ack the Prophit on Telegram ───────────────────────────────────────────────

TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-${HOME}/.secrets/telegram.token}"
if [[ -n "$PROPHIT_CHAT_ID" ]] && [[ -r "$TELEGRAM_TOKEN_FILE" ]]; then
  TOKEN="$(cat "$TELEGRAM_TOKEN_FILE")"
  if [[ -n "$EXPIRES_AT" ]]; then
    ack_msg="Whispering, then. The gods will speak among themselves until ${EXPIRES_AT}."
  else
    ack_msg="Whispering, then. The gods will speak among themselves. Call /loud to bring us back."
  fi
  curl -sf -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
       -d chat_id="$PROPHIT_CHAT_ID" \
       -d text="$ack_msg" >/dev/null 2>&1 \
    && log_info inter-gawd "/quiet ack sent to Prophit" \
    || log_warn inter-gawd "/quiet ack telegram send failed"
fi

exit 0
