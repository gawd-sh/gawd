#!/usr/bin/env bash
# gossip-channel.sh — Auto-create-and-invite the household gossip channel
#
# Per spec §13.3 + handoff E4. Called on the first /quiet invocation in a
# household. Creates the gossip channel record, attempts to issue invites to
# known peer bots (per Bot API 10.0 opt-in flow), and writes the metadata to
# ~/.gawd/state/gossip-channel.json.
#
# §17.9 graceful degradation: if household-gawds.json is empty or absent,
# the channel is created alone and peers join later. The single-Gawd case
# MUST succeed.
#
# ─────────────────────────────────────────────────────────────────────────────
# IMPORTANT TELEGRAM CONSTRAINT (interpretation call flagged in handoff report):
# ─────────────────────────────────────────────────────────────────────────────
# The Telegram Bot API does NOT permit a bot to create a group chat directly.
# Even with Bot API 10.0 (May 2026) bot-to-bot DM enablement, group creation
# is a Telegram-app-side operation (a user must create the group).
#
# v1 v1 approach (per spec §13.3 "Created automatically the first time /quiet
# is invoked" — interpreted operationally):
#   1. The Gawd composes a "gossip channel handshake" message and DMs the
#      Prophit with a one-tap "Create gossip group" deep-link (using
#      Telegram's tg://resolve? or t.me/<botusername>?startgroup=true URL).
#   2. The Prophit taps once → Telegram opens the contact picker → Prophit
#      confirms the group → Telegram callback delivers the new chat_id to
#      the bot (via /newchat event or similar /myChatMember update).
#   3. A side-handler (gossip-channel-bind.sh, deferred to v1.1 unless
#      called out) receives the chat_id and writes gossip-channel.json.
#
# For v1, this script implements steps 1 and the state-file scaffolding.
# Step 2 (Telegram side) is a one-tap action the Prophit takes; the channel
# binding (step 3) is handled when the Prophit completes the group creation
# and the bot receives `my_chat_member` updates pointing to the new group.
#
# Effect: gossip-channel.sh CALLED → state pre-populated with intent + invite
# link → Prophit completes → Telegram-side webhook (out of scope of this
# handoff) finalises the record. The slash handler treats the channel as
# pending until finalised; messages route to main channel until then.
#
# This pattern is the only way to comply with Telegram's group-creation
# constraint while honoring spec §13.3.
# ─────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   gossip-channel.sh [--state <dir>]
#                     [--identity <path>]
#                     [--telegram-token-file <path>]
#                     [--prophit-chat-id <id>]
#                     [--household-name <name>]
#                     [--no-telegram]
#
# Exit codes:
#   0  channel record created OR already exists (idempotent)
#   1  args / env error
#   2  state write failed
#   3  telegram invite send failed (state still written; partial success)

set -euo pipefail

# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../observability/logger.sh"

STATE_DIR="${HOME}/.gawd/state"
IDENTITY_FILE="${HOME}/.gawd/workspace/IDENTITY.md"
HOUSEHOLD_FILE=""  # set below from $STATE_DIR
GOSSIP_FILE=""     # set below from $STATE_DIR
TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-${HOME}/.secrets/telegram.token}"
PROPHIT_CHAT_ID="${PROPHIT_CHAT_ID:-}"
HOUSEHOLD_NAME=""
NO_TELEGRAM=0

usage() { grep '^# ' "$0" | sed 's/^# //'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE_DIR="$2"; shift 2 ;;
    --identity) IDENTITY_FILE="$2"; shift 2 ;;
    --telegram-token-file) TELEGRAM_TOKEN_FILE="$2"; shift 2 ;;
    --prophit-chat-id) PROPHIT_CHAT_ID="$2"; shift 2 ;;
    --household-name) HOUSEHOLD_NAME="$2"; shift 2 ;;
    --no-telegram) NO_TELEGRAM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
HOUSEHOLD_FILE="${STATE_DIR}/household-gawds.json"
GOSSIP_FILE="${STATE_DIR}/gossip-channel.json"

# ── idempotency: if gossip-channel.json exists, exit 0 cleanly ────────────────

if [[ -f "$GOSSIP_FILE" ]]; then
  log_info inter-gawd "gossip-channel.json already exists at ${GOSSIP_FILE}; nothing to create"
  exit 0
fi

# ── derive household name from IDENTITY.md if not provided ────────────────────

if [[ -z "$HOUSEHOLD_NAME" ]]; then
  if [[ -r "$IDENTITY_FILE" ]]; then
    # IDENTITY.md ## Household section: "name: <value>"
    HOUSEHOLD_NAME=$(awk '
      /^## *Household/ {in_section=1; next}
      /^## / && in_section {in_section=0}
      in_section && /^[[:space:]]*name:/ {
        sub(/^[[:space:]]*name:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        # strip placeholder {...} braces
        if ($0 !~ /^\{.*\}$/) print $0
        exit
      }
    ' "$IDENTITY_FILE" 2>/dev/null || true)
  fi
fi

# Fallback: derive from Gawd's own name (Name section)
if [[ -z "$HOUSEHOLD_NAME" ]]; then
  if [[ -r "$IDENTITY_FILE" ]]; then
    own_name=$(awk '
      /^## *Name/ {in_section=1; next}
      /^## / && in_section {in_section=0; exit}
      in_section && NF > 0 && !/^<!--/ && !/^[[:space:]]*$/ {
        print $0
        exit
      }
    ' "$IDENTITY_FILE" 2>/dev/null | head -n1)
    own_name=$(printf '%s' "$own_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    [[ -n "$own_name" ]] && HOUSEHOLD_NAME="$own_name"
  fi
fi

[[ -n "$HOUSEHOLD_NAME" ]] || HOUSEHOLD_NAME="household"

CHANNEL_TITLE="${HOUSEHOLD_NAME}-gossip"
log_info inter-gawd "preparing gossip channel: ${CHANNEL_TITLE}"

# ── creating-gawd identity ────────────────────────────────────────────────────

CREATING_GAWD_ID="$(awk '
  /^## *Name/ {in_section=1; next}
  /^## / && in_section {in_section=0; exit}
  in_section && NF > 0 && !/^<!--/ && !/^[[:space:]]*$/ { print $0; exit }
' "$IDENTITY_FILE" 2>/dev/null || true)"
[[ -n "$CREATING_GAWD_ID" ]] || CREATING_GAWD_ID="gawd"

# ── peer enumeration ──────────────────────────────────────────────────────────

PEERS_JSON='[]'
PEER_COUNT=0
if [[ -r "$HOUSEHOLD_FILE" ]]; then
  PEERS_JSON=$(jq '.peers // []' "$HOUSEHOLD_FILE" 2>/dev/null || echo '[]')
  PEER_COUNT=$(printf '%s' "$PEERS_JSON" | jq 'length' 2>/dev/null || echo 0)
fi
log_info inter-gawd "household has ${PEER_COUNT} known peer(s)"

# ── write initial gossip-channel.json ─────────────────────────────────────────
# channel_id is set to the sentinel "pending" until Telegram side completes
# the group creation. The slash handler treats pending channels as not-yet-
# usable, so messages continue routing to main channel until binding.

NOW_ISO=$(date -Iseconds)

# Build peer_invitations from peers list
PEER_INVITATIONS=$(printf '%s' "$PEERS_JSON" | jq --arg ts "$NOW_ISO" \
  '[.[] | {peer_gawd_id: .gawd_id, invited_at: $ts, status: "pending-opt-in", note: "Bot API 10.0 opt-in required from both sides"}]')

# Build invite link if telegram_bot_username is reachable via getMe.
# For the channel-create deep link, format:
#   https://t.me/<botusername>?startgroup=<token>
# The Prophit taps → Telegram opens the contact picker → group created.
INVITE_LINK=""
if [[ $NO_TELEGRAM -eq 0 ]] && [[ -r "$TELEGRAM_TOKEN_FILE" ]]; then
  TOKEN="$(cat "$TELEGRAM_TOKEN_FILE")"
  # getMe to learn our own bot username
  me_response=$(curl -sf "https://api.telegram.org/bot${TOKEN}/getMe" 2>&1 || echo "")
  if [[ -n "$me_response" ]]; then
    bot_username=$(printf '%s' "$me_response" | jq -r '.result.username // empty' 2>/dev/null || true)
    if [[ -n "$bot_username" ]]; then
      INVITE_LINK="https://t.me/${bot_username}?startgroup=gossip-${HOUSEHOLD_NAME}"
      log_info inter-gawd "invite link prepared: ${INVITE_LINK}"
    fi
  fi
fi

tmpfile=$(mktemp "${GOSSIP_FILE}.tmp.XXXXXX")
jq -n \
  --arg cid "pending" \
  --arg title "$CHANNEL_TITLE" \
  --arg invite "$INVITE_LINK" \
  --arg cby "$CREATING_GAWD_ID" \
  --arg ts "$NOW_ISO" \
  --argjson invitations "$PEER_INVITATIONS" \
  '{
    channel_id: $cid,
    channel_title: $title,
    invite_link: $invite,
    created_by_gawd_id: $cby,
    created_at: $ts,
    peer_invitations: $invitations
  }' > "$tmpfile"
mv "$tmpfile" "$GOSSIP_FILE"
log_info inter-gawd "wrote ${GOSSIP_FILE} (channel_id=pending until Prophit completes group creation)"

# ── DM Prophit with the one-tap "create gossip group" deep link ───────────────

if [[ $NO_TELEGRAM -eq 0 ]] && [[ -r "$TELEGRAM_TOKEN_FILE" ]] && [[ -n "$PROPHIT_CHAT_ID" ]]; then
  TOKEN="$(cat "$TELEGRAM_TOKEN_FILE")"
  if [[ -n "$INVITE_LINK" ]]; then
    MESSAGE="I'm establishing the gossip channel for our household.

Telegram requires that you tap once to create the group itself — I cannot create groups directly. Tap below and select \"${CHANNEL_TITLE}\" as the group name; I'll handle the rest.

You can mute this channel on your phone. The gods will keep talking; you can overhear when you want."

    keyboard=$(jq -nc --arg url "$INVITE_LINK" --arg title "$CHANNEL_TITLE" \
      '{
        inline_keyboard: [[
          {text: "Create gossip group", url: $url},
          {text: "Cancel", callback_data: "gossip_cancel"}
        ]]
      }')

    if ! curl -sf -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
         -d chat_id="$PROPHIT_CHAT_ID" \
         -d text="$MESSAGE" \
         -d reply_markup="$keyboard" >/dev/null 2>&1; then
      log_warn inter-gawd "telegram invite-DM to Prophit failed; state file persists"
      exit 3
    fi
    log_info inter-gawd "telegram invite-DM sent to chat_id=${PROPHIT_CHAT_ID}"
  else
    log_warn inter-gawd "no invite link available (getMe failed?); skipping Prophit DM"
  fi
else
  log_info inter-gawd "telegram disabled or no Prophit chat_id; state pre-populated only"
fi

# Note for the (out-of-this-handoff) /myChatMember webhook handler:
# When the Prophit completes group creation, the bot will receive a
# my_chat_member or new_chat_members update with the new chat_id. That
# handler should:
#   1. Verify the bot was added by the Prophit (sender_id matches a
#      known household Prophit telegram_id).
#   2. Update gossip-channel.json: set channel_id to the real chat_id,
#      record the chat title.
#   3. Attempt bot-to-bot DMs to peer bots in household-gawds.json with
#      the invite link, recording opt-in status under peer_invitations.
# That handler is /usr/local/lib/gawd/inter-gawd/gossip-channel-bind.sh
# (NOT IMPLEMENTED v1 — deferred until the Telegram update webhook is
# wired into the daemon. The state file scaffolding here is the contract
# that handler will consume).

exit 0
