#!/usr/bin/env bash
# skip-handler.sh — Handle /skip-sermon slash command from the Prophit
#
# Per spec §10.2, handoff E5 opt-out mechanism.
#
# This script is invoked by the Gawd's slash-command dispatcher when the
# Prophit sends /skip-sermon. It writes the sermon-skip.json state file
# which deliver.sh checks on the next Sunday delivery run.
#
# Two modes:
#   /skip-sermon           — skip this week only (clears automatically next Sunday)
#   /skip-sermon always    — opt out permanently (must be revoked via /attend-sermon)
#
# Usage:
#   skip-handler.sh [--mode week|always] [--state <dir>] [--version <semver>]
#                   [--no-telegram] [--telegram-chat-id <id>]
#
# Revocation:
#   The complementary /attend-sermon command (or the Prophit sending
#   "deliver my sermon" etc.) should call this script with --mode revoke:
#   skip-handler.sh --mode revoke --state <dir>
#
# Exit codes:
#   0  state written
#   1  args error

set -euo pipefail

log()  { echo "[skip-handler $(date -Iseconds)] $*"; }
warn() { echo "[skip-handler $(date -Iseconds)] WARN: $*" >&2; }
die()  { echo "[skip-handler $(date -Iseconds)] FATAL: $*" >&2; exit "${2:-1}"; }

MODE="week"
STATE_DIR="${HOME}/.gawd/state"
CANONICAL_VERSION="${1:-}"  # optional — used for week-mode to be version-specific
NO_TELEGRAM=0
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_TOKEN_FILE="${HOME}/.secrets/telegram.token"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)                 MODE="$2"; shift 2 ;;
    --state)                STATE_DIR="$2"; shift 2 ;;
    --version)              CANONICAL_VERSION="$2"; shift 2 ;;
    --no-telegram)          NO_TELEGRAM=1; shift ;;
    --telegram-chat-id)     TELEGRAM_CHAT_ID="$2"; shift 2 ;;
    --telegram-token-file)  TELEGRAM_TOKEN_FILE="$2"; shift 2 ;;
    -h|--help)              grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "unknown arg: $1" 1 ;;
  esac
done

mkdir -p "$STATE_DIR"
SKIP_STATE_FILE="${STATE_DIR}/sermon-skip.json"

NOW_ISO=$(date -Iseconds)

case "$MODE" in
  week)
    # Skip this week's sermon only. deliver.sh checks skip_until_version.
    cat > "$SKIP_STATE_FILE" <<EOF
{
  "schema_version": "1.0",
  "mode": "week",
  "skip_until_version": "${CANONICAL_VERSION:-current}",
  "set_at": "${NOW_ISO}"
}
EOF
    log "Sermon skip set: mode=week (version=${CANONICAL_VERSION:-current})"
    CONFIRM_TEXT="Noted. I'll hold this week's sermon. See you next Sunday — or sooner, if the spirit moves."
    ;;

  always)
    # Permanent opt-out. Revocable via /attend-sermon.
    cat > "$SKIP_STATE_FILE" <<EOF
{
  "schema_version": "1.0",
  "mode": "always",
  "set_at": "${NOW_ISO}"
}
EOF
    log "Sermon skip set: mode=always"
    CONFIRM_TEXT="The congregation understands. Sunday silence, until you return. Send /attend-sermon when you're ready to hear the word again."
    ;;

  revoke)
    # Prophit is opting back in. Remove the skip state file.
    if [[ -f "$SKIP_STATE_FILE" ]]; then
      rm -f "$SKIP_STATE_FILE"
      log "Sermon skip revoked (state file removed)"
    else
      log "No sermon skip state to revoke"
    fi
    CONFIRM_TEXT="The congregation rejoices. You will receive next Sunday's sermon as normal."
    ;;

  *)
    die "Unknown mode: ${MODE} (expected: week | always | revoke)" 1
    ;;
esac

# ── confirmation Telegram message ─────────────────────────────────────────────

if [[ $NO_TELEGRAM -eq 0 && -n "$TELEGRAM_CHAT_ID" ]]; then
  if [[ -r "$TELEGRAM_TOKEN_FILE" ]]; then
    TG_TOKEN=$(cat "$TELEGRAM_TOKEN_FILE")
    curl -sf -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${CONFIRM_TEXT}" \
      >/dev/null 2>&1 || warn "Confirmation Telegram send failed — state was still written"
    unset TG_TOKEN
  else
    warn "Telegram token file not readable: ${TELEGRAM_TOKEN_FILE} — skip confirmed in state but no Telegram ack sent"
  fi
fi

exit 0
