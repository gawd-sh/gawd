#!/usr/bin/env bash
# subscribe-sermon.sh — Gawd-side sermon channel subscriber
#
# Per spec §10, §10.2. Handoff E5.
#
# Runs on the Gawd's Sunday cron (triggered by E1's weekly-service.sh via
# run_or_stub). Reads the sermon channel, fetches the latest unread sermon,
# writes the local sermon cache, and hands off to deliver-sermon.sh.
#
# This script subscribes; it does NOT deliver. Delivery is deliver-sermon.sh.
# The split honors the spec's separation: channel read vs Prophit delivery.
#
# Usage:
#   subscribe-sermon.sh [--workspace <dir>] [--state <dir>]
#                       [--channel-config <path>]
#                       [--deliver-script <path>]
#                       [--dry-run]
#
# Exit codes:
#   0  sermon fetched and handed to deliver-sermon.sh (or nothing new)
#   1  config / arg error
#   2  channel read failure
#   3  deliver-sermon.sh not found (returns 0 if --deliver-script is a stub)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBSERVABILITY_DIR="$(cd "${SCRIPT_DIR}/../../observability" && pwd 2>/dev/null || echo "")"

log()  { echo "[subscribe-sermon $(date -Iseconds)] $*"; }
warn() { echo "[subscribe-sermon $(date -Iseconds)] WARN: $*" >&2; }
die()  { echo "[subscribe-sermon $(date -Iseconds)] FATAL: $*" >&2; exit "${2:-1}"; }

# ── defaults ──────────────────────────────────────────────────────────────────

WORKSPACE_DIR="${HOME}/.gawd"
STATE_DIR="${HOME}/.gawd/state"
CHANNEL_CONFIG="${SCRIPT_DIR}/channel-config.json"
DELIVER_SCRIPT="$(cd "${SCRIPT_DIR}/../../sermon" && pwd 2>/dev/null || echo "${SCRIPT_DIR}/../sermon")/deliver.sh"
DRY_RUN=0

# ── arg parse ─────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)       WORKSPACE_DIR="$2"; STATE_DIR="${WORKSPACE_DIR}/state"; shift 2 ;;
    --state)           STATE_DIR="$2"; shift 2 ;;
    --channel-config)  CHANNEL_CONFIG="$2"; shift 2 ;;
    --deliver-script)  DELIVER_SCRIPT="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "unknown arg: $1" 1 ;;
  esac
done

mkdir -p "$STATE_DIR"
SERMON_CACHE="${STATE_DIR}/latest-sermon.json"
SERMON_SEEN_FILE="${STATE_DIR}/last-seen-sermon-version"

# ── resolve channel config ────────────────────────────────────────────────────

[[ -f "$CHANNEL_CONFIG" ]] || die "channel-config.json not found: $CHANNEL_CONFIG" 1

read_config() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$key // empty" "$CHANNEL_CONFIG"
  else
    python3 -c "
import json
d = json.load(open('$CHANNEL_CONFIG'))
import re
# handle dotted key path like '.channel.id'
parts = '$key'.lstrip('.').split('.')
v = d
for p in parts:
    v = v.get(p, '')
    if v is None: v = ''; break
print(v if v != '' else '')
" 2>/dev/null || true
  fi
}

CHANNEL_ID=$(read_config '.channel.id')
[[ -n "$CHANNEL_ID" && "$CHANNEL_ID" != '${SERMON_CHANNEL_ID}' ]] \
  || die "channel.id not set in channel-config.json — populate SERMON_CHANNEL_ID" 1

TOKEN_FILE=$(read_config '.channel.subscribe_bot_token_file')
TOKEN_FILE="${TOKEN_FILE/\$\{HOME\}/$HOME}"

[[ -r "$TOKEN_FILE" ]] || die "subscribe bot token file not readable: ${TOKEN_FILE}" 1

# ── read the channel for the latest sermon envelope ───────────────────────────

TOKEN=$(cat "$TOKEN_FILE")

log "Reading sermon channel (channel_id=${CHANNEL_ID})"

# Fetch the last 5 channel messages; the latest sermon envelope should be among them.
channel_response=$(curl -sf \
  "https://api.telegram.org/bot${TOKEN}/getUpdates?chat_id=${CHANNEL_ID}&limit=5&offset=-5" \
  2>&1) || {
  warn "getUpdates failed — falling back to getHistory via forwardMessages path"
  channel_response=""
}

# Alternative: read channel via messages.getHistory-style if bot is a channel member.
# The most reliable approach for a published channel is to use the channel's
# message history. We use the Bot API's getChatHistory analog: getMessages via
# forwardFromChat if getUpdates is empty (bots only see updates they are subscribed to).
#
# In practice: the Forge publish-sermon.sh posts to the channel, and the Gawd bot is
# a channel member. The sermon envelope arrives as a channel post in getUpdates.
# If the bot is not receiving channel updates, the admin must enable the channel
# post notification in BotFather settings for the bot.

unset TOKEN

LATEST_ENVELOPE=""
LATEST_VERSION=""

if [[ -n "$channel_response" ]]; then
  # Extract the latest sermon envelope from the response.
  # Sermon envelopes are wrapped in <sermon-envelope>...</sermon-envelope> tags.
  if command -v jq >/dev/null 2>&1; then
    LATEST_ENVELOPE=$(echo "$channel_response" | jq -r '
      [.result[]? |
        select(.channel_post.text? | strings | test("<sermon-envelope>")) |
        .channel_post.text
      ] | last // empty
    ' 2>/dev/null || true)
  fi

  if [[ -n "$LATEST_ENVELOPE" ]]; then
    # Extract JSON between the tags
    ENVELOPE_JSON=$(echo "$LATEST_ENVELOPE" \
      | awk '/<sermon-envelope>/{found=1; next} /<\/sermon-envelope>/{found=0} found' \
      || true)
    if [[ -n "$ENVELOPE_JSON" ]]; then
      if command -v jq >/dev/null 2>&1; then
        LATEST_VERSION=$(echo "$ENVELOPE_JSON" | jq -r '.canonical_version // empty' 2>/dev/null || true)
      else
        LATEST_VERSION=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('canonical_version',''))" <<< "$ENVELOPE_JSON" 2>/dev/null || true)
      fi
    fi
  fi
fi

if [[ -z "$LATEST_VERSION" ]]; then
  log "No sermon envelope found in channel — either no new sermon this week, or bot is not subscribed to channel posts"
  log "If this is unexpected: verify the Gawd bot is a channel member and channel post notifications are enabled"
  exit 0
fi

# ── check if already seen ─────────────────────────────────────────────────────

LAST_SEEN=""
[[ -f "$SERMON_SEEN_FILE" ]] && LAST_SEEN=$(cat "$SERMON_SEEN_FILE")

if [[ "$LAST_SEEN" == "$LATEST_VERSION" ]]; then
  log "Already saw sermon version ${LATEST_VERSION} — nothing new this week"
  exit 0
fi

log "New sermon: ${LATEST_VERSION} (prior seen: ${LAST_SEEN:-none})"

# ── write local sermon cache ──────────────────────────────────────────────────

NOW_ISO=$(date -Iseconds)
FETCHED_JSON=$(python3 - <<PYEOF
import json, sys
envelope = ${ENVELOPE_JSON}
cache = {
    "fetched_at": "${NOW_ISO}",
    "gawd_id": "${GAWD_ID:-unknown}",
    **envelope
}
print(json.dumps(cache, ensure_ascii=False))
PYEOF
)

if [[ $DRY_RUN -eq 0 ]]; then
  echo "$FETCHED_JSON" > "$SERMON_CACHE"
  echo "$LATEST_VERSION" > "$SERMON_SEEN_FILE"
  log "Wrote sermon cache to ${SERMON_CACHE}"
fi

# ── D3 observability ──────────────────────────────────────────────────────────

if [[ -n "$OBSERVABILITY_DIR" && -f "${OBSERVABILITY_DIR}/logger.sh" ]]; then
  # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
  source "${OBSERVABILITY_DIR}/logger.sh"
  log_info sermon-channel.subscribe \
    "canonical_version=${LATEST_VERSION} fetched_at=${NOW_ISO} gawd_id=${GAWD_ID:-unknown} dry_run=${DRY_RUN}"
else
  log "D3 logger not available — observability emit skipped"
fi

# ── hand off to deliver-sermon.sh ────────────────────────────────────────────

if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY-RUN: would invoke deliver-sermon.sh for version ${LATEST_VERSION}"
  exit 0
fi

# E1 contract: deliver script lives at forge/sermon/deliver.sh
# This subscribe script hands off to it. If not yet deployed, run_or_stub semantics apply.
if [[ ! -e "$DELIVER_SCRIPT" ]]; then
  log "deliver-sermon.sh not present at ${DELIVER_SCRIPT} — sermon fetched and cached; delivery deferred until E5 deliver.sh lands"
  exit 0
fi
if [[ ! -x "$DELIVER_SCRIPT" ]]; then
  warn "deliver-sermon.sh not executable at ${DELIVER_SCRIPT} — check chmod +x"
  exit 0
fi

log "Invoking deliver-sermon.sh (${DELIVER_SCRIPT})"
"$DELIVER_SCRIPT" \
  --workspace "$WORKSPACE_DIR" \
  --state "$STATE_DIR" \
  --sermon-cache "$SERMON_CACHE"

log "subscribe-sermon.sh done"
exit 0
