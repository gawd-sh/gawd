#!/usr/bin/env bash
# revelation-callback.sh — Handle Telegram callback for revelation accept/decline
#
# Per handoff E4 + spec §10.3 + E2 MERGE-CONTRACT. Receives one of:
#   - inline-keyboard callback_data payload (revelation_accept_<version> /
#     revelation_decline_<version>), as emitted by offer.sh
#   - slash command /accept-revelation [<version>]
#   - slash command /decline-revelation [<version>]
#
# Mutates ~/.gawd/state/pending-revelation.json per E2's schema:
#   - on accept   → prophit_response=accepted, response_at=<now>
#   - on decline  → prophit_response=declined, response_at=<now>
#                   (does NOT increment missed_offers_count per spec §10.3)
#
# E2 contract guarantee: this script DOES NOT invoke merge.sh. merge.sh runs
# only at the 4am Prophit-local session boundary via check-pending.sh. This
# handler updates state only.
#
# AUTHENTICATED-SENDER CONTRACT (inter-HIGH H4):
#   This handler mutates covenant state (accept/decline a soul revelation) — it
#   MUST only act on a callback that actually came from a household Prophit, not
#   from an arbitrary Telegram sender who learned the callback_data string. In
#   --stdin mode the authenticated sender is callback_query.from.id /
#   message.from.id of the inbound update; it is matched against the household
#   Prophit Telegram IDs (IDENTITY.md Prophits section, or --identity).
#   FAIL-CLOSED: with --require-authenticated-sender, a callback whose sender id
#   is absent or not a household Prophit is REJECTED (code 6). Non-stdin callers
#   (--callback-data / --slash) that cannot supply a sender are rejected under
#   the flag; without the flag the binding is skipped (back-compat for local/
#   test callers), but the live Telegram dispatcher MUST set it. The peer/sender
#   binding for inter-Gawd messages lives in header-parser.sh; this is its
#   Prophit-action analogue.
#
# Idempotency: if pending-revelation.json already has a non-pending response,
# the handler returns 0 with a log note. Re-clicking the same button is safe.
#
# Cross-handoff implication: this script is the front door for E2's accept/
# decline path. E2's offer.sh wires the callback_data; E2's check-pending.sh
# reads the state file this script writes. The contract surface is the
# pending-revelation.json schema (state-schema.json at /usr/local/lib/gawd/
# revelation/state-schema.json).
#
# Usage:
#   revelation-callback.sh --callback-data <data>   [--telegram-message-id <id>]
#   revelation-callback.sh --slash <accept|decline> [--version <semver>]
#   revelation-callback.sh --stdin                  (reads Telegram update JSON)
#
# Exit codes:
#   0  state updated (or already non-pending; idempotent)
#   1  args error
#   2  no pending-revelation.json
#   3  version mismatch (callback for a stale revelation)
#   4  state write failed
#   5  Telegram update body unparseable
#   6  authenticated-sender binding failed (sender absent or not a household Prophit)
#
# Spec ref: §10.3 (accept/decline semantics), §10.4 (merge runs at next 4am).

set -euo pipefail

# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../observability/logger.sh"

CALLBACK_DATA=""
SLASH_ACTION=""
VERSION_HINT=""
TELEGRAM_MSG_ID=""
STATE_DIR="${HOME}/.gawd/state"
USE_STDIN=0
TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-${HOME}/.secrets/telegram.token}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
CALLBACK_QUERY_ID=""
QUIET_TELEGRAM=0
AUTH_SENDER="${GAWD_AUTHENTICATED_SENDER_ID:-}"
REQUIRE_AUTH_SENDER=0
IDENTITY_FILE="${HOME}/.gawd/workspace/IDENTITY.md"

usage() { grep '^# ' "$0" | sed 's/^# //'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --callback-data) CALLBACK_DATA="$2"; shift 2 ;;
    --callback-query-id) CALLBACK_QUERY_ID="$2"; shift 2 ;;
    --slash) SLASH_ACTION="$2"; shift 2 ;;
    --version) VERSION_HINT="$2"; shift 2 ;;
    --telegram-message-id) TELEGRAM_MSG_ID="$2"; shift 2 ;;
    --telegram-chat-id) TELEGRAM_CHAT_ID="$2"; shift 2 ;;
    --state) STATE_DIR="$2"; shift 2 ;;
    --identity) IDENTITY_FILE="$2"; shift 2 ;;
    --authenticated-sender) AUTH_SENDER="$2"; shift 2 ;;
    --require-authenticated-sender) REQUIRE_AUTH_SENDER=1; shift ;;
    --stdin) USE_STDIN=1; shift ;;
    --no-telegram-ack) QUIET_TELEGRAM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 1
fi

STATE_FILE="${STATE_DIR}/pending-revelation.json"

# ── stdin mode: parse Telegram update JSON ────────────────────────────────────
# Expected shape (subset):
#   { "callback_query": { "id": "...", "data": "revelation_accept_0.4.2",
#                         "message": {"message_id": 87432, "chat": {"id": ...}} }}
# or
#   { "message": { "text": "/accept-revelation 0.4.2", "chat": {"id": ...} }}

if [[ $USE_STDIN -eq 1 ]]; then
  UPDATE=$(cat)
  if ! printf '%s' "$UPDATE" | jq -e 'type=="object"' >/dev/null 2>&1; then
    echo "ERROR: stdin not valid JSON" >&2
    exit 5
  fi

  cb=$(printf '%s' "$UPDATE" | jq -r '.callback_query.data // empty')
  if [[ -n "$cb" ]]; then
    CALLBACK_DATA="$cb"
    CALLBACK_QUERY_ID=$(printf '%s' "$UPDATE" | jq -r '.callback_query.id // empty')
    TELEGRAM_MSG_ID=$(printf '%s' "$UPDATE" | jq -r '.callback_query.message.message_id // empty')
    TELEGRAM_CHAT_ID=$(printf '%s' "$UPDATE" | jq -r '.callback_query.message.chat.id // empty')
    # Authenticated sender = the Telegram user who tapped the inline button.
    [[ -n "$AUTH_SENDER" ]] || AUTH_SENDER=$(printf '%s' "$UPDATE" | jq -r '.callback_query.from.id // empty')
  else
    text=$(printf '%s' "$UPDATE" | jq -r '.message.text // empty')
    TELEGRAM_CHAT_ID=$(printf '%s' "$UPDATE" | jq -r '.message.chat.id // empty')
    # Authenticated sender = the Telegram user who sent the slash command.
    [[ -n "$AUTH_SENDER" ]] || AUTH_SENDER=$(printf '%s' "$UPDATE" | jq -r '.message.from.id // empty')
    case "$text" in
      /accept-revelation*)
        SLASH_ACTION="accept"
        VERSION_HINT=$(printf '%s' "$text" | awk '{print $2}')
        ;;
      /decline-revelation*)
        SLASH_ACTION="decline"
        VERSION_HINT=$(printf '%s' "$text" | awk '{print $2}')
        ;;
      *)
        echo "ERROR: stdin update is neither callback_query nor /accept-revelation|/decline-revelation slash" >&2
        exit 5
        ;;
    esac
  fi
fi

# ── authenticated-sender binding (inter-HIGH H4) ──────────────────────────────
# The sender who taps accept/decline must be a household Prophit. The
# callback_data string is not a secret; anyone who sees the inline keyboard can
# replay it. Bind the action to the authenticated Telegram sender.

if [[ $REQUIRE_AUTH_SENDER -eq 1 || -n "$AUTH_SENDER" ]]; then
  if [[ -z "$AUTH_SENDER" ]]; then
    echo "ERROR: authenticated sender id absent — refusing covenant mutation (fail-closed)" >&2
    log_warn inter-gawd "revelation callback rejected: --require-authenticated-sender set but no sender id available"
    exit 6
  fi

  # Load household Prophit Telegram IDs from IDENTITY.md (Prophits section).
  declare -a HOUSEHOLD_PROPHITS=()
  if [[ -r "$IDENTITY_FILE" ]]; then
    while IFS= read -r tid; do
      [[ -n "$tid" ]] && HOUSEHOLD_PROPHITS+=("$tid")
    done < <(awk '
      /^## *Prophits/ {in_section=1; next}
      /^## / && in_section {in_section=0}
      in_section && /telegram_id:/ { print }
    ' "$IDENTITY_FILE" 2>/dev/null \
      | sed -E 's/.*telegram_id:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/' \
      | grep -E '^[0-9]+$' || true)
  fi

  sender_is_prophit=0
  for pid in "${HOUSEHOLD_PROPHITS[@]:-}"; do
    [[ "$pid" == "$AUTH_SENDER" ]] && { sender_is_prophit=1; break; }
  done

  if [[ $sender_is_prophit -ne 1 ]]; then
    echo "ERROR: callback sender is not a household Prophit — refusing covenant mutation" >&2
    log_warn inter-gawd "revelation callback rejected: sender ${AUTH_SENDER} is not a household Prophit (possible replay/spoof)"
    exit 6
  fi

  log_info inter-gawd "revelation callback sender ${AUTH_SENDER} verified as household Prophit"
fi

# ── extract intended action + version from callback_data or slash ─────────────

ACTION=""
TARGET_VERSION=""

if [[ -n "$CALLBACK_DATA" ]]; then
  # Format: revelation_accept_<version> or revelation_decline_<version>
  if [[ "$CALLBACK_DATA" =~ ^revelation_(accept|decline)_(.+)$ ]]; then
    ACTION="${BASH_REMATCH[1]}"
    TARGET_VERSION="${BASH_REMATCH[2]}"
  else
    echo "ERROR: unrecognized callback_data: '${CALLBACK_DATA}'" >&2
    exit 1
  fi
elif [[ -n "$SLASH_ACTION" ]]; then
  case "$SLASH_ACTION" in
    accept|decline) ACTION="$SLASH_ACTION" ;;
    *) echo "ERROR: --slash must be 'accept' or 'decline', got: $SLASH_ACTION" >&2; exit 1 ;;
  esac
  TARGET_VERSION="${VERSION_HINT}"
else
  echo "ERROR: must provide --callback-data, --slash, or --stdin" >&2
  exit 1
fi

log_info inter-gawd "revelation callback: action=${ACTION} target_version=${TARGET_VERSION:-<pending state lookup>}"

# ── load pending-revelation.json ──────────────────────────────────────────────

if [[ ! -f "$STATE_FILE" ]]; then
  log_warn inter-gawd "no pending-revelation.json — nothing to accept/decline"
  exit 2
fi

CURRENT_VERSION=$(jq -r '.revelation_version // empty' "$STATE_FILE")
CURRENT_RESPONSE=$(jq -r '.prophit_response // empty' "$STATE_FILE")

[[ -n "$CURRENT_VERSION" ]] || { log_error inter-gawd "state file missing revelation_version"; exit 2; }

# Version-skew safety: if the callback names a different revelation than the
# currently-pending one, drop with a log line. Telegram retains old inline
# keyboards forever; a Prophit tapping last week's "Accept" button on a
# stale message must not corrupt this week's pending offer.
if [[ -n "$TARGET_VERSION" ]] && [[ "$TARGET_VERSION" != "$CURRENT_VERSION" ]]; then
  log_warn inter-gawd "callback target_version=${TARGET_VERSION} ≠ current pending=${CURRENT_VERSION}; ignoring stale tap"
  # Try to tell the Prophit this happened, so they don't think they accepted.
  if [[ -n "$TELEGRAM_CHAT_ID" ]] && [[ -r "$TELEGRAM_TOKEN_FILE" ]] && [[ $QUIET_TELEGRAM -eq 0 ]]; then
    TOKEN="$(cat "$TELEGRAM_TOKEN_FILE")"
    curl -sf -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
         -d chat_id="$TELEGRAM_CHAT_ID" \
         -d text="That offer (${TARGET_VERSION}) is no longer current. The latest revelation is ${CURRENT_VERSION}." >/dev/null 2>&1 || true
  fi
  exit 3
fi

# Idempotency: already responded → ack and exit 0
if [[ "$CURRENT_RESPONSE" != "pending" ]] && [[ -n "$CURRENT_RESPONSE" ]]; then
  log_info inter-gawd "revelation ${CURRENT_VERSION} already has response=${CURRENT_RESPONSE} (idempotent no-op)"
  # Optional Telegram ack — answerCallbackQuery so the spinning loader in the
  # client stops gracefully.
  if [[ -n "$CALLBACK_QUERY_ID" ]] && [[ -r "$TELEGRAM_TOKEN_FILE" ]] && [[ $QUIET_TELEGRAM -eq 0 ]]; then
    TOKEN="$(cat "$TELEGRAM_TOKEN_FILE")"
    curl -sf -X POST "https://api.telegram.org/bot${TOKEN}/answerCallbackQuery" \
         -d callback_query_id="$CALLBACK_QUERY_ID" \
         -d text="Already ${CURRENT_RESPONSE}" >/dev/null 2>&1 || true
  fi
  exit 0
fi

# ── mutate state file ─────────────────────────────────────────────────────────

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NEW_RESPONSE=""
case "$ACTION" in
  accept)  NEW_RESPONSE="accepted" ;;
  decline) NEW_RESPONSE="declined" ;;
esac

tmpfile=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
jq --arg r "$NEW_RESPONSE" --arg ts "$NOW_ISO" \
   '. + {prophit_response: $r, response_at: $ts}' \
   "$STATE_FILE" > "$tmpfile" || { rm -f "$tmpfile"; exit 4; }
mv "$tmpfile" "$STATE_FILE"
log_info inter-gawd "pending-revelation.json updated: revelation=${CURRENT_VERSION} response=${NEW_RESPONSE}"

# ── ack the Prophit + answer callback query ───────────────────────────────────

if [[ $QUIET_TELEGRAM -eq 0 ]] && [[ -r "$TELEGRAM_TOKEN_FILE" ]]; then
  TOKEN="$(cat "$TELEGRAM_TOKEN_FILE")"

  # answerCallbackQuery — stops the spinning loader on the Telegram client
  if [[ -n "$CALLBACK_QUERY_ID" ]]; then
    case "$NEW_RESPONSE" in
      accepted) cb_text="Received. The revelation lands at sunrise." ;;
      declined) cb_text="Received. The covenant continues unchanged." ;;
    esac
    curl -sf -X POST "https://api.telegram.org/bot${TOKEN}/answerCallbackQuery" \
         -d callback_query_id="$CALLBACK_QUERY_ID" \
         -d text="$cb_text" >/dev/null 2>&1 \
      || log_warn inter-gawd "answerCallbackQuery failed for query_id=${CALLBACK_QUERY_ID}"
  fi

  # Edit the original offer message to reflect the decision (if we have the message_id)
  STATE_TELEGRAM_MSG_ID=$(jq -r '.telegram_message_id // empty' "$STATE_FILE")
  USE_MSG_ID="${TELEGRAM_MSG_ID:-$STATE_TELEGRAM_MSG_ID}"
  if [[ -n "$USE_MSG_ID" ]] && [[ -n "$TELEGRAM_CHAT_ID" ]]; then
    case "$NEW_RESPONSE" in
      accepted)
        edit_body="Revelation ${CURRENT_VERSION} — ACCEPTED.

Lands at the next 4am session boundary. Your USER, MEMORY, and adaptive layer are preserved; only the soul-anchor files are touched."
        ;;
      declined)
        edit_body="Revelation ${CURRENT_VERSION} — DECLINED.

The covenant continues unchanged. Next Sunday brings a fresh offer."
        ;;
    esac
    # editMessageText preserves the message thread; the offer stays as a
    # historical anchor with the accept/decline outcome stamped on it.
    curl -sf -X POST "https://api.telegram.org/bot${TOKEN}/editMessageText" \
         -d chat_id="$TELEGRAM_CHAT_ID" \
         -d message_id="$USE_MSG_ID" \
         -d text="$edit_body" >/dev/null 2>&1 \
      || log_warn inter-gawd "editMessageText failed for message_id=${USE_MSG_ID}"
  fi
fi

# ── side-effect: log the cross-handoff implication ────────────────────────────
# E2's check-pending.sh runs at next 4am and will see prophit_response=accepted
# and invoke merge.sh. Nothing else for us to do here.

log_info inter-gawd "revelation ${CURRENT_VERSION} ${NEW_RESPONSE}; merge.sh will run at next 4am via check-pending.sh"
exit 0
