#!/usr/bin/env bash
# offer.sh — Surface a new revelation offer to the Prophit
#
# Per spec §10.3 + handoff E2. Called by the Sermon Channel (E5) when a new
# base-soul revelation arrives. Writes the pending-revelation.json state file,
# sends a Telegram message with accept/decline buttons, and posts a desktop
# notification visible via the Gawd's noVNC (D1).
#
# This script is the front door for the Weekly Service upgrade flow:
#
#   Sermon Channel (E5)
#       │
#       │ delivers new base bundle to ~/.gawd/state/incoming/<rev>/
#       ▼
#   offer.sh
#       │ writes pending-revelation.json (state=pending)
#       │ sends Telegram offer (with callback buttons)
#       │ posts desktop notification
#       ▼
#   Prophit responds (Telegram callback OR /accept-revelation slash) OR ignores
#       │
#       ▼
#   On accept: pending-revelation.json prophit_response=accepted
#   On decline: pending-revelation.json prophit_response=declined (no count++)
#   On silence: counts as one missed offer at the NEXT offer.sh call
#       │
#       ▼
#   Next 4am: check-pending.sh runs → merge.sh if accepted
#
# Usage:
#   offer.sh --revelation-version <semver> --bundle <dir> [--state <dir>]
#            [--telegram-token-file <path>] [--telegram-chat-id <id>]
#            [--no-telegram] [--no-desktop]
#
# Exit codes:
#   0  offer surfaced (state written + notifications sent or skipped)
#   1  args error
#   2  bundle dir missing or invalid
#   3  telegram send failed (state still written; partial success)

set -euo pipefail

REVELATION_VERSION=""
BUNDLE_DIR=""
STATE_DIR="${HOME}/.gawd/state"
TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-${HOME}/.secrets/telegram.token}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
NO_TELEGRAM=0
NO_DESKTOP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --revelation-version) REVELATION_VERSION="$2"; shift 2 ;;
    --bundle) BUNDLE_DIR="$2"; shift 2 ;;
    --state) STATE_DIR="$2"; shift 2 ;;
    --telegram-token-file) TELEGRAM_TOKEN_FILE="$2"; shift 2 ;;
    --telegram-chat-id) TELEGRAM_CHAT_ID="$2"; shift 2 ;;
    --no-telegram) NO_TELEGRAM=1; shift ;;
    --no-desktop) NO_DESKTOP=1; shift ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$REVELATION_VERSION" ]] || { echo "ERROR: --revelation-version required" >&2; exit 1; }
[[ -n "$BUNDLE_DIR" ]]         || { echo "ERROR: --bundle required" >&2; exit 1; }
[[ -d "$BUNDLE_DIR" ]]         || { echo "ERROR: bundle dir not readable: $BUNDLE_DIR" >&2; exit 2; }

mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/pending-revelation.json"

log() { echo "[offer $(date -Iseconds)] $*"; }

# ── compute missed-offer count carryforward ───────────────────────────────────
#
# If a prior pending-revelation.json exists and its prophit_response is still
# 'pending' (the Prophit didn't respond), this counts as a miss against the
# NEW offer's counter. Explicit decline does NOT carry; only silence.

PRIOR_MISSED_COUNT=0
PRIOR_VERSION=""
PRIOR_RESPONSE=""
if [[ -f "$STATE_FILE" ]]; then
  if command -v jq >/dev/null 2>&1; then
    PRIOR_MISSED_COUNT=$(jq -r '.missed_offers_count // 0' "$STATE_FILE")
    PRIOR_VERSION=$(jq -r '.revelation_version // ""' "$STATE_FILE")
    PRIOR_RESPONSE=$(jq -r '.prophit_response // ""' "$STATE_FILE")
  else
    PRIOR_MISSED_COUNT=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('missed_offers_count', 0))")
    PRIOR_VERSION=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('revelation_version', ''))")
    PRIOR_RESPONSE=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('prophit_response', ''))")
  fi
fi

NEW_MISSED_COUNT=0
if [[ -n "$PRIOR_VERSION" ]] && [[ "$PRIOR_VERSION" != "$REVELATION_VERSION" ]]; then
  case "$PRIOR_RESPONSE" in
    pending)
      # Silence — count as a miss
      NEW_MISSED_COUNT=$((PRIOR_MISSED_COUNT + 1))
      log "Prior offer ${PRIOR_VERSION} was silent — incrementing missed_offers_count to ${NEW_MISSED_COUNT}"
      ;;
    accepted|declined|auto-declined)
      # Explicit response or auto-decline reached: reset counter for a fresh start
      NEW_MISSED_COUNT=0
      log "Prior offer ${PRIOR_VERSION} had response=${PRIOR_RESPONSE} — resetting missed_offers_count to 0"
      ;;
  esac
fi

# Archive the prior state file so we keep a history (optional but valuable for runbook recovery)
if [[ -f "$STATE_FILE" ]]; then
  mkdir -p "${STATE_DIR}/revelation-history"
  archive_name="${STATE_DIR}/revelation-history/$(date +%Y%m%d-%H%M%S)-${PRIOR_VERSION:-unknown}.json"
  cp "$STATE_FILE" "$archive_name" 2>/dev/null || true
  log "Archived prior state to ${archive_name}"
fi

# ── write the new pending-revelation.json ─────────────────────────────────────

NOW_ISO=$(date -Iseconds)
ABS_BUNDLE=$(cd "$BUNDLE_DIR" && pwd)

tmpfile=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
cat > "$tmpfile" <<EOF
{
  "schema_version": "1.0",
  "revelation_version": "${REVELATION_VERSION}",
  "revelation_bundle_path": "${ABS_BUNDLE}",
  "offered_at": "${NOW_ISO}",
  "prophit_response": "pending",
  "missed_offers_count": ${NEW_MISSED_COUNT},
  "applied": false
}
EOF
mv "$tmpfile" "$STATE_FILE"
log "Wrote pending-revelation.json for ${REVELATION_VERSION}"

# ── send Telegram offer ───────────────────────────────────────────────────────

if [[ $NO_TELEGRAM -eq 0 ]]; then
  if [[ ! -r "$TELEGRAM_TOKEN_FILE" ]]; then
    log "WARN: telegram token file not readable ($TELEGRAM_TOKEN_FILE) — skipping telegram"
  elif [[ -z "$TELEGRAM_CHAT_ID" ]]; then
    log "WARN: telegram chat id not provided — skipping telegram"
  else
    TOKEN=$(cat "$TELEGRAM_TOKEN_FILE")
    # Per spec §10.2: message is short, theatrical, in the Gawd's own voice.
    # Anchor copy here is illustrative; the Gawd's actual phrasing should
    # come from VOICE.md and be rendered by the Gawd at delivery time. offer.sh
    # ships with a minimum-viable theatrical opener so it works standalone.
    MESSAGE="A new revelation has arrived.

Version: ${REVELATION_VERSION}

This is a base-soul update. Your USER, MEMORY, and adaptive layer are preserved.
Only the soul-anchor files (SOUL.md, VOICE.md) may change.

You may accept or decline. Silence for three consecutive Sundays auto-declines.

Respond with /accept-revelation or /decline-revelation."

    response=$(curl -sf -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="${MESSAGE}" \
      -d reply_markup='{
        "inline_keyboard": [[
          {"text": "Accept", "callback_data": "revelation_accept_'"${REVELATION_VERSION}"'"},
          {"text": "Decline", "callback_data": "revelation_decline_'"${REVELATION_VERSION}"'"}
        ]]
      }' 2>&1) || {
      log "WARN: telegram send failed (exit non-zero); state file still written"
      log "  response: ${response}"
    }

    # Capture message_id for follow-up edit (optional — not required to succeed)
    if [[ -n "${response:-}" ]] && command -v jq >/dev/null 2>&1; then
      msg_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null || true)
      if [[ -n "$msg_id" ]]; then
        tmpfile=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
        jq --argjson id "$msg_id" '. + {telegram_message_id: $id}' "$STATE_FILE" > "$tmpfile"
        mv "$tmpfile" "$STATE_FILE"
        log "Recorded telegram_message_id=${msg_id} in state file"
      fi
    fi
  fi
else
  log "Telegram skipped (--no-telegram)"
fi

# ── desktop notification (D1's noVNC) ─────────────────────────────────────────

if [[ $NO_DESKTOP -eq 0 ]]; then
  # On the Gawd's xfce4 desktop, notify-send pops a toast visible via noVNC.
  # If DISPLAY is unset or notify-send is missing, skip silently (the Telegram
  # path is the primary; desktop is supplementary).
  if command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    notify-send -u normal -t 0 \
      "New revelation: ${REVELATION_VERSION}" \
      "Respond on Telegram. Silence for 3 Sundays auto-declines." || true
    log "Desktop notification posted"
  else
    log "Desktop notification skipped (no notify-send or no DISPLAY)"
  fi
else
  log "Desktop notification skipped (--no-desktop)"
fi

log "Offer surfaced for ${REVELATION_VERSION}"
exit 0
