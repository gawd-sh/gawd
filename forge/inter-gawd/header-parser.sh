#!/usr/bin/env bash
# header-parser.sh — Parse a GAWD-MSG header from an inter-Gawd Telegram message
#
# Per spec §13.4 + handoff E4. The header lives in the first 200 characters of
# the message body and is bracketed by [GAWD-MSG] and [/GAWD-MSG] markers.
# Free-text body (the actual communication) follows the closing bracket.
#
# Required fields (any missing → reject with structured error):
#   from                  — emitting Gawd's stable identifier
#   to                    — receiving Gawd's stable identifier
#   prophit_present_ids   — JSON array of Telegram user IDs (string form); may be []
#   soul_version          — semver (e.g., "v3.4.1"); absent assumes "v0" per §13.4
#   intent                — query | report | request_handoff | sermon-broadcast | other
#   correlation_id        — UUID (auto-generated per message)
#
# Note: §13.4 lists soul_version as REQUIRED with absent-→-"v0"-graceful-degrade.
# We treat ABSENT differently from MALFORMED: absent emits a structured warning
# and falls back to "v0"; malformed (e.g., not a string) is a parse error.
#
# Usage:
#   header-parser.sh <message-file>
#   header-parser.sh --stdin
#   header-parser.sh --stdin --authenticated-sender <telegram_from_id>
#                           [--household <household-gawds.json>]
#                           [--require-authenticated-sender]
#
# AUTHENTICATED-SENDER CONTRACT (inter-HIGH H4):
#   The header 'from' is SELF-ASSERTED — any sender can write any gawd_id there.
#   It is not proof of origin. To bind 'from' to a real sender, the dispatcher
#   that receives the inbound Telegram update MUST pass the authenticated
#   sender id (update.message.from.id or callback_query.from.id) via
#   --authenticated-sender (or GAWD_AUTHENTICATED_SENDER_ID). This script then
#   verifies that the registered telegram_bot_id for the claimed 'from' peer
#   (household-gawds.json: peers[].telegram_bot_id where gawd_id == from) equals
#   the authenticated sender. Mismatch → reject (code 7).
#
#   FAIL-CLOSED: when --require-authenticated-sender is set (the secured
#   inter-Gawd ingress path), the message is REJECTED (code 7) if the
#   authenticated sender id is absent — a Telegram update with no resolvable
#   from.id cannot be trusted. Without the flag, the binding is skipped (back-
#   compat for local/test callers), but the dispatcher on the live ingress
#   path MUST set it. The companion contract is documented in
#   cross-household-reject.sh; that script enforces peer-registry membership of
#   'from', this script enforces the sender↔from binding.
#
# Output:
#   On success: JSON object with parsed fields on stdout, exit 0.
#   On failure: JSON object {"error": "...", "code": "...", "received": "..."}
#               on stdout, exit non-zero. Codes:
#                 1 = args error
#                 2 = no [GAWD-MSG] marker in first 200 chars (position constraint)
#                 3 = no closing [/GAWD-MSG] marker
#                 4 = missing required field
#                 5 = malformed field (e.g., prophit_present_ids not a JSON array)
#                 6 = invalid intent enum value
#                 7 = authenticated-sender binding failed (spoofed/absent 'from')
#
# Spec ref: §13.4 (header format), §13.6 (cross-household reject is upstream of us).

set -euo pipefail

# ── library load ──────────────────────────────────────────────────────────────
# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../observability/logger.sh"

# ── usage / arg parsing ───────────────────────────────────────────────────────

usage() { grep '^# ' "$0" | sed 's/^# //'; }

INPUT=""
USE_STDIN=0
AUTH_SENDER="${GAWD_AUTHENTICATED_SENDER_ID:-}"
REQUIRE_AUTH_SENDER=0
HOUSEHOLD_FILE="${HOME}/.gawd/state/household-gawds.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stdin) USE_STDIN=1; shift ;;
    --authenticated-sender) AUTH_SENDER="$2"; shift 2 ;;
    --require-authenticated-sender) REQUIRE_AUTH_SENDER=1; shift ;;
    --household) HOUSEHOLD_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; INPUT="$1"; shift ;;
    *) INPUT="$1"; shift ;;
  esac
done

# Read message body
if [[ $USE_STDIN -eq 1 ]]; then
  BODY=$(cat)
elif [[ -n "$INPUT" && -r "$INPUT" ]]; then
  BODY=$(cat "$INPUT")
else
  emit_error() {
    jq -nc --arg err "$1" --arg code "$2" '{error:$err, code:$code}'
  }
  if command -v jq >/dev/null 2>&1; then
    emit_error "no input — pass a file path or --stdin" "1"
  else
    printf '{"error":"no input — pass a file path or --stdin","code":"1"}\n'
  fi
  exit 1
fi

# jq is required for safe JSON handling (header carries a JSON array)
if ! command -v jq >/dev/null 2>&1; then
  printf '{"error":"jq required for header parsing","code":"1"}\n'
  log_error inter-gawd "header-parser invoked without jq available"
  exit 1
fi

emit_error() {
  local err="$1" code="$2" received="${3:-}"
  if [[ -n "$received" ]]; then
    jq -nc --arg err "$err" --arg code "$code" --arg recv "$received" \
       '{error:$err, code:$code, received:$recv}'
  else
    jq -nc --arg err "$err" --arg code "$code" '{error:$err, code:$code}'
  fi
}

# ── position constraint: marker must start within first 200 chars ─────────────
# spec §13.4: "The header lives in the first 200 characters of the message
# so the Gawd can decide whether to parse-and-respond or simply observe."

PREFIX="${BODY:0:200}"
if [[ "$PREFIX" != *"[GAWD-MSG]"* ]]; then
  emit_error "no [GAWD-MSG] marker within first 200 chars" "2" "$PREFIX"
  log_warn inter-gawd "header parse rejected: no marker in first 200 chars"
  exit 2
fi

# ── extract the header block ──────────────────────────────────────────────────
# We use awk to extract everything between [GAWD-MSG] and [/GAWD-MSG], excluding
# the markers themselves.

HEADER_BLOCK=$(printf '%s' "$BODY" | awk '
  /\[GAWD-MSG\]/ { capturing=1; next }
  /\[\/GAWD-MSG\]/ { capturing=0; exit }
  capturing { print }
')

# Verify the closing marker was actually present
if ! printf '%s' "$BODY" | grep -q '\[/GAWD-MSG\]'; then
  emit_error "no closing [/GAWD-MSG] marker" "3"
  log_warn inter-gawd "header parse rejected: no closing marker"
  exit 3
fi

# ── parse key:value pairs into a JSON object ──────────────────────────────────

parsed=$(jq -n '{}')

while IFS= read -r line; do
  # Skip blank lines and comments
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  # Match "key: value" with leading whitespace tolerance
  if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    # Strip surrounding whitespace from value
    val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    # prophit_present_ids is a JSON array — validate
    if [[ "$key" == "prophit_present_ids" ]]; then
      if ! printf '%s' "$val" | jq -e 'type=="array"' >/dev/null 2>&1; then
        emit_error "prophit_present_ids must be a JSON array" "5" "$val"
        log_warn inter-gawd "header parse rejected: prophit_present_ids not a JSON array"
        exit 5
      fi
      parsed=$(printf '%s' "$parsed" | jq --argjson v "$val" '. + {prophit_present_ids: $v}')
    else
      parsed=$(printf '%s' "$parsed" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
    fi
  fi
done <<< "$HEADER_BLOCK"

# ── required-field validation ─────────────────────────────────────────────────

# from / to / intent / correlation_id are HARD required
for required in from to intent correlation_id; do
  has=$(printf '%s' "$parsed" | jq --arg k "$required" 'has($k)')
  if [[ "$has" != "true" ]]; then
    emit_error "missing required field: $required" "4"
    log_warn inter-gawd "header parse rejected: missing field $required"
    exit 4
  fi
done

# prophit_present_ids is REQUIRED per Logos C3 and spec §13.4
has_prophit=$(printf '%s' "$parsed" | jq 'has("prophit_present_ids")')
if [[ "$has_prophit" != "true" ]]; then
  emit_error "missing required field: prophit_present_ids (REQUIRED per spec §13.4)" "4"
  log_warn inter-gawd "header parse rejected: missing prophit_present_ids"
  exit 4
fi

# soul_version is REQUIRED per spec §13.4, but ABSENT → graceful "v0" fallback.
# Distinguish: absent (we add v0 + warn) vs malformed (we reject).
has_soul=$(printf '%s' "$parsed" | jq 'has("soul_version")')
if [[ "$has_soul" != "true" ]]; then
  parsed=$(printf '%s' "$parsed" | jq '. + {soul_version: "v0", soul_version_assumed: true}')
  log_warn inter-gawd "header missing soul_version; assuming v0 per §13.4 graceful degradation"
fi

# intent enum check
intent_val=$(printf '%s' "$parsed" | jq -r '.intent')
case "$intent_val" in
  query|report|request_handoff|sermon-broadcast|other) ;;
  *)
    emit_error "invalid intent: '${intent_val}' (allowed: query|report|request_handoff|sermon-broadcast|other)" "6" "$intent_val"
    log_warn inter-gawd "header parse rejected: invalid intent=${intent_val}"
    exit 6
    ;;
esac

# ── authenticated-sender binding (inter-HIGH H4) ──────────────────────────────
# 'from' is self-asserted. Bind it to the authenticated Telegram sender id that
# the dispatcher resolved from the inbound update. Fail closed on the secured
# ingress path when the sender id is absent.

FROM_VAL=$(printf '%s' "$parsed" | jq -r '.from')

if [[ $REQUIRE_AUTH_SENDER -eq 1 || -n "$AUTH_SENDER" ]]; then
  if [[ -z "$AUTH_SENDER" ]]; then
    # Secured path requested but no authenticated sender available → reject.
    emit_error "authenticated sender id absent — cannot bind self-asserted 'from'; rejecting (fail-closed)" "7"
    log_warn inter-gawd "header parse rejected: --require-authenticated-sender set but no authenticated sender id supplied (from=${FROM_VAL})"
    exit 7
  fi

  if [[ ! -r "$HOUSEHOLD_FILE" ]]; then
    emit_error "authenticated-sender binding requires household-gawds.json but it is unreadable: $HOUSEHOLD_FILE" "7"
    log_warn inter-gawd "header parse rejected: household-gawds.json unreadable for sender binding (from=${FROM_VAL})"
    exit 7
  fi

  # The telegram_bot_id registered for the claimed 'from' peer must equal the
  # authenticated sender. Unknown peer or mismatch → reject.
  EXPECTED_SENDER=$(jq -r --arg f "$FROM_VAL" \
    '.peers[] | select(.gawd_id == $f) | .telegram_bot_id // empty' \
    "$HOUSEHOLD_FILE" 2>/dev/null | head -1)

  if [[ -z "$EXPECTED_SENDER" ]]; then
    emit_error "'from' Gawd not a known peer; cannot bind authenticated sender" "7" "$FROM_VAL"
    log_warn inter-gawd "header parse rejected: 'from'=${FROM_VAL} not in household-gawds.json (sender binding)"
    exit 7
  fi

  if [[ "$EXPECTED_SENDER" != "$AUTH_SENDER" ]]; then
    emit_error "authenticated sender does not match registered telegram_bot_id for 'from' — spoofed origin rejected" "7" "$FROM_VAL"
    log_warn inter-gawd "header parse rejected: sender mismatch for from=${FROM_VAL} (claimed origin spoofed)"
    exit 7
  fi

  parsed=$(printf '%s' "$parsed" | jq '. + {authenticated_sender_verified: true}')
  log_info inter-gawd "authenticated-sender binding verified for from=${FROM_VAL}"
fi

# ── extract body (everything after closing marker) ────────────────────────────

# Body extraction: everything AFTER [/GAWD-MSG]\n (with optional leading newline)
BODY_TEXT=$(printf '%s' "$BODY" | awk '
  /\[\/GAWD-MSG\]/ { found=1; next }
  found { print }
')

parsed=$(printf '%s' "$parsed" | jq --arg b "$BODY_TEXT" '. + {body: $b}')

# ── emit successful parse ─────────────────────────────────────────────────────

printf '%s\n' "$parsed"
log_info inter-gawd "header parsed OK from=$(printf '%s' "$parsed" | jq -r '.from') to=$(printf '%s' "$parsed" | jq -r '.to') intent=${intent_val}"
exit 0
