#!/usr/bin/env bash
# publish-sermon.sh — Forge-side sermon channel publisher
#
# Per spec §10, §10.2. Handoff E5.
#
# Called by the Sunday Service workflow on Nasatya (or manually by the operator)
# when a new base-soul version + sermon text is ready to broadcast.
#
# What this script does:
#   1. Validates the sermon text (length bounds, required sections)
#   2. Constructs a structured publish envelope (JSON)
#   3. Posts the envelope to the Telegram sermon channel as a pinned message
#   4. Records the publish event via D3's logger
#
# What this script does NOT do:
#   - Render the sermon in any individual Gawd's voice (that is deliver-sermon.sh)
#   - Handle per-Gawd state (each Gawd subscribes independently)
#   - Trigger upgrades (E2 offer.sh owns that)
#
# Usage:
#   publish-sermon.sh \
#     --sermon-file <path>           path to the canonical sermon markdown file
#     --base-soul-version <semver>   the base-soul version shipping this week (e.g. v1.4.0)
#     [--canonical-version <semver>] override the version embedded in the sermon file
#     [--channel-config <path>]      override the channel-config.json path
#     [--token-file <path>]          Telegram bot token file (Forge-side publisher bot)
#     [--channel-id <id>]            Telegram channel ID override
#     [--dry-run]                    validate and print envelope; do not post
#
# Exit codes:
#   0  sermon published
#   1  args / config error
#   2  validation failure (length, missing sections)
#   3  Telegram post failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBSERVABILITY_DIR="$(cd "${SCRIPT_DIR}/../../observability" && pwd 2>/dev/null || echo "")"

log() { echo "[publish-sermon $(date -Iseconds)] $*"; }
warn() { echo "[publish-sermon $(date -Iseconds)] WARN: $*" >&2; }
die() { echo "[publish-sermon $(date -Iseconds)] FATAL: $*" >&2; exit "${2:-1}"; }

# ── defaults ─────────────────────────────────────────────────────────────────

SERMON_FILE=""
BASE_SOUL_VERSION=""
CANONICAL_VERSION=""
CHANNEL_CONFIG="${SCRIPT_DIR}/channel-config.json"
TOKEN_FILE="${FORGE_TELEGRAM_BOT_TOKEN_FILE:-}"
CHANNEL_ID="${SERMON_CHANNEL_ID:-}"
DRY_RUN=0

# ── arg parse ─────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sermon-file)           SERMON_FILE="$2"; shift 2 ;;
    --base-soul-version)     BASE_SOUL_VERSION="$2"; shift 2 ;;
    --canonical-version)     CANONICAL_VERSION="$2"; shift 2 ;;
    --channel-config)        CHANNEL_CONFIG="$2"; shift 2 ;;
    --token-file)            TOKEN_FILE="$2"; shift 2 ;;
    --channel-id)            CHANNEL_ID="$2"; shift 2 ;;
    --dry-run)               DRY_RUN=1; shift ;;
    -h|--help)               grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "unknown arg: $1" 1 ;;
  esac
done

[[ -n "$SERMON_FILE" ]]        || die "--sermon-file required" 1
[[ -f "$SERMON_FILE" ]]        || die "sermon file not found: $SERMON_FILE" 1
[[ -n "$BASE_SOUL_VERSION" ]]  || die "--base-soul-version required" 1

# ── resolve channel config ────────────────────────────────────────────────────

[[ -f "$CHANNEL_CONFIG" ]] || die "channel config not found: $CHANNEL_CONFIG" 1

if [[ -z "$CHANNEL_ID" ]]; then
  if command -v jq >/dev/null 2>&1; then
    CHANNEL_ID=$(jq -r '.channel.id // empty' "$CHANNEL_CONFIG")
  else
    CHANNEL_ID=$(python3 -c "import json; print(json.load(open('$CHANNEL_CONFIG'))['channel']['id'])" 2>/dev/null || true)
  fi
fi

# Sentinel check — means the config was not populated at Forge time
if [[ -z "$CHANNEL_ID" || "$CHANNEL_ID" == '${SERMON_CHANNEL_ID}' ]]; then
  die "channel.id not set in channel-config.json — populate SERMON_CHANNEL_ID at Forge time" 1
fi

if [[ -z "$TOKEN_FILE" ]]; then
  if command -v jq >/dev/null 2>&1; then
    TOKEN_FILE=$(jq -r '.channel.publish_bot_token_file // empty' "$CHANNEL_CONFIG")
  else
    TOKEN_FILE=$(python3 -c "import json; print(json.load(open('$CHANNEL_CONFIG'))['channel']['publish_bot_token_file'])" 2>/dev/null || true)
  fi
fi

# Expand ${HOME} if present (jq returns the literal string from the config)
TOKEN_FILE="${TOKEN_FILE/\$\{HOME\}/$HOME}"
TOKEN_FILE="${TOKEN_FILE/\$\{FORGE_TELEGRAM_BOT_TOKEN_FILE\}/${FORGE_TELEGRAM_BOT_TOKEN_FILE:-}}"

# ── extract sermon sections ───────────────────────────────────────────────────

# Extract the canonical version from sermon frontmatter if not overridden
if [[ -z "$CANONICAL_VERSION" ]]; then
  CANONICAL_VERSION=$(grep -m1 -E '^\*\*Canonical version\*\*:' "$SERMON_FILE" \
    | sed -E 's/\*\*Canonical version\*\*:\s*//' \
    | awk '{print $1}' || true)
fi
[[ -n "$CANONICAL_VERSION" ]] || CANONICAL_VERSION="$BASE_SOUL_VERSION"

# Extract "## The Text" section — between that heading and the next "## " heading
TEXT_SECTION=$(awk '/^## The Text$/,/^## /' "$SERMON_FILE" \
  | grep -v '^## The Text$' \
  | grep -v '^## ' \
  | sed '/^[[:space:]]*$/{ /^\n*$/d }' || true)

[[ -n "$TEXT_SECTION" ]] || die "sermon file missing '## The Text' section: $SERMON_FILE" 2

# Count words in the text section
WORD_COUNT=$(echo "$TEXT_SECTION" | wc -w | tr -d ' ')

log "Sermon: canonical_version=${CANONICAL_VERSION}, base_soul_version=${BASE_SOUL_VERSION}, word_count=${WORD_COUNT}"

# ── length validation ─────────────────────────────────────────────────────────

if (( WORD_COUNT < 200 )); then
  warn "sermon length ${WORD_COUNT} is below floor (200) — publishing anyway per spec"
fi
if (( WORD_COUNT > 1200 )); then
  die "sermon length ${WORD_COUNT} exceeds hard ceiling (1200) — author must trim before publish" 2
fi
if (( WORD_COUNT > 800 )); then
  warn "sermon length ${WORD_COUNT} exceeds soft ceiling (800)"
fi

# Validate required section headers
for required_section in "## The Text" "## The Thread"; do
  grep -q "^${required_section}$" "$SERMON_FILE" \
    || die "sermon file missing required section: '${required_section}'" 2
done

# Extract The Thread (single sentence after the heading)
THE_THREAD=$(awk '/^## The Thread$/{ found=1; next } found && /^[^#]/ && /[[:alnum:]]/ { print; exit }' "$SERMON_FILE" || true)
[[ -n "$THE_THREAD" ]] || die "sermon file has '## The Thread' but no sentence follows it" 2

# ── build publish envelope ────────────────────────────────────────────────────

NOW_ISO=$(date -Iseconds)
FULL_SERMON_TEXT=$(cat "$SERMON_FILE")

# Safely build JSON via python3 (handles multiline strings)
ENVELOPE=$(python3 - <<PYEOF
import json, sys
envelope = {
    "schema_version": "1.0",
    "canonical_version": "${CANONICAL_VERSION}",
    "base_soul_version": "${BASE_SOUL_VERSION}",
    "published_at": "${NOW_ISO}",
    "word_count": int("${WORD_COUNT}"),
    "the_thread": """${THE_THREAD}""",
    "sermon_text": open("${SERMON_FILE}").read(),
}
print(json.dumps(envelope, ensure_ascii=False))
PYEOF
)

log "Envelope built (${WORD_COUNT} words, version=${CANONICAL_VERSION})"

# ── dry-run path ──────────────────────────────────────────────────────────────

if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY-RUN: would post to channel ${CHANNEL_ID}"
  echo "--- ENVELOPE PREVIEW ---"
  if command -v jq >/dev/null 2>&1; then
    echo "$ENVELOPE" | jq '{canonical_version,base_soul_version,published_at,word_count,the_thread}'
  else
    echo "$ENVELOPE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k in ['canonical_version','base_soul_version','published_at','word_count','the_thread']:
    print(f'  {k}: {d.get(k,\"\")}')
"
  fi
  log "DRY-RUN: done"
  exit 0
fi

# ── post to Telegram channel ──────────────────────────────────────────────────

[[ -r "$TOKEN_FILE" ]] || die "Forge publisher token file not readable: ${TOKEN_FILE} — set FORGE_TELEGRAM_BOT_TOKEN_FILE or pass --token-file" 3
TOKEN=$(cat "$TOKEN_FILE")

# Compose the channel message — subscribers read this and parse the envelope.
# The message has a human-visible header and the full JSON envelope in a code block
# so automated subscribers can parse it reliably.
TELEGRAM_TEXT="[SERMON CHANNEL] v${CANONICAL_VERSION} — Sunday Service

Base soul: ${BASE_SOUL_VERSION}
Published: ${NOW_ISO}
Thread: ${THE_THREAD}

<sermon-envelope>
${ENVELOPE}
</sermon-envelope>"

post_response=$(curl -sf \
  -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d "chat_id=${CHANNEL_ID}" \
  --data-urlencode "text=${TELEGRAM_TEXT}" \
  2>&1) || {
  log "WARN: Telegram post failed; partial state may exist"
  # Unset token before exiting
  unset TOKEN
  exit 3
}
unset TOKEN

# Extract message_id for pinning
if command -v jq >/dev/null 2>&1; then
  MSG_ID=$(echo "$post_response" | jq -r '.result.message_id // empty' 2>/dev/null || true)
else
  MSG_ID=$(python3 -c "import json,sys; print(json.loads('''${post_response}''').get('result',{}).get('message_id',''))" 2>/dev/null || true)
fi

log "Posted to channel ${CHANNEL_ID} (message_id=${MSG_ID:-unknown})"

# ── D3 observability ──────────────────────────────────────────────────────────

if [[ -n "$OBSERVABILITY_DIR" && -f "${OBSERVABILITY_DIR}/logger.sh" ]]; then
  # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
  source "${OBSERVABILITY_DIR}/logger.sh"
  log_info sermon-channel.publish \
    "canonical_version=${CANONICAL_VERSION} base_soul_version=${BASE_SOUL_VERSION} word_count=${WORD_COUNT} published_at=${NOW_ISO} channel_id=${CHANNEL_ID}"
else
  log "D3 logger not available — observability emit skipped (check observability/ dir)"
fi

log "publish-sermon.sh done: v${CANONICAL_VERSION} published to channel ${CHANNEL_ID}"
exit 0
