#!/usr/bin/env bash
# header-emitter.sh — Emit a well-formed GAWD-MSG header for outgoing inter-Gawd
# messages.
#
# Per spec §13.4 + handoff E4. Produces a multi-line block bracketed by
# [GAWD-MSG] / [/GAWD-MSG], followed by the free-text body. The full message
# is written to stdout, ready to send through the Telegram bot API.
#
# Required inputs:
#   --from <gawd-id>                — this Gawd's stable identifier
#   --to <gawd-id>                  — receiving Gawd's stable identifier
#   --intent <enum>                 — query|report|request_handoff|sermon-broadcast|other
#   --body <text>                   — free-text body (or --body-file <path>)
#
# Optional inputs (sourced from IDENTITY.md if unset):
#   --prophit-present-ids <json>    — JSON array of Telegram user IDs (string form)
#                                     If absent: read IDENTITY.md Prophits list;
#                                     if no Prophits there, defaults to [].
#   --soul-version <semver>         — defaults to value in IDENTITY.md or 'v0'
#   --correlation-id <uuid>         — auto-generated if absent (the only field
#                                     that is auto-generated per-message per
#                                     handoff context note)
#   --identity <path>               — IDENTITY.md path (default ~/.gawd/workspace/IDENTITY.md)
#
# Spec ref: §13.4 (header format).
#
# Exit codes:
#   0  emitted OK
#   1  args error
#   2  intent enum invalid
#   3  prophit_present_ids JSON malformed

set -euo pipefail

# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../observability/logger.sh"

FROM=""
TO=""
INTENT=""
BODY=""
BODY_FILE=""
PROPHIT_IDS=""
SOUL_VERSION=""
CORRELATION_ID=""
IDENTITY_FILE="${HOME}/.gawd/workspace/IDENTITY.md"

usage() { grep '^# ' "$0" | sed 's/^# //'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --intent) INTENT="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --prophit-present-ids) PROPHIT_IDS="$2"; shift 2 ;;
    --soul-version) SOUL_VERSION="$2"; shift 2 ;;
    --correlation-id) CORRELATION_ID="$2"; shift 2 ;;
    --identity) IDENTITY_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$FROM" ]]   || { echo "ERROR: --from required" >&2; exit 1; }
[[ -n "$TO" ]]     || { echo "ERROR: --to required" >&2; exit 1; }
[[ -n "$INTENT" ]] || { echo "ERROR: --intent required" >&2; exit 1; }

# Intent enum check
case "$INTENT" in
  query|report|request_handoff|sermon-broadcast|other) ;;
  *) echo "ERROR: invalid --intent '${INTENT}' (allowed: query|report|request_handoff|sermon-broadcast|other)" >&2; exit 2 ;;
esac

# Body resolution
if [[ -n "$BODY_FILE" ]]; then
  [[ -r "$BODY_FILE" ]] || { echo "ERROR: body file unreadable: $BODY_FILE" >&2; exit 1; }
  BODY="$(cat "$BODY_FILE")"
fi

# Auto-generate correlation_id if absent. UUID via /proc/sys/kernel/random/uuid (Linux)
# or uuidgen; fallback to a date+random concoction.
if [[ -z "$CORRELATION_ID" ]]; then
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    CORRELATION_ID=$(cat /proc/sys/kernel/random/uuid)
  elif command -v uuidgen >/dev/null 2>&1; then
    CORRELATION_ID=$(uuidgen)
  else
    CORRELATION_ID="cid-$(date +%s%N)-$RANDOM"
    log_warn inter-gawd "no UUID source; using degenerate correlation_id"
  fi
fi

# Source prophit_present_ids from IDENTITY.md if not provided
if [[ -z "$PROPHIT_IDS" ]]; then
  if [[ -r "$IDENTITY_FILE" ]]; then
    # Extract telegram_id values from "telegram_id:" lines under "## Prophits".
    # IDENTITY.md format per /usr/local/lib/gawd/persona-templates/IDENTITY.md:
    #   telegram_id: "<PROPHIT_TELEGRAM_ID>"
    # Portable: awk locates the section, sed extracts the value (no gawk-only
    # 3-arg match() needed).
    ids_csv=$(awk '
      /^## *Prophits/ {in_section=1; next}
      /^## / && in_section {in_section=0}
      in_section && /telegram_id:/ { print }
    ' "$IDENTITY_FILE" 2>/dev/null \
      | sed -E 's/.*telegram_id:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/' \
      | grep -E '^[0-9]+$' \
      | paste -sd, -)
    if [[ -n "$ids_csv" ]]; then
      # Convert csv "1,2,3" → JSON array ["1","2","3"]
      if command -v jq >/dev/null 2>&1; then
        PROPHIT_IDS=$(printf '%s' "$ids_csv" | jq -R 'split(",")')
      else
        # Hand-build JSON
        PROPHIT_IDS="[\"${ids_csv//,/\",\"}\"]"
      fi
    else
      PROPHIT_IDS="[]"
    fi
  else
    PROPHIT_IDS="[]"
    log_warn inter-gawd "IDENTITY.md not readable at ${IDENTITY_FILE}; emitting empty prophit_present_ids"
  fi
fi

# Validate prophit_present_ids is a JSON array
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$PROPHIT_IDS" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "ERROR: --prophit-present-ids must be a JSON array, got: $PROPHIT_IDS" >&2
    exit 3
  fi
fi

# Source soul_version from IDENTITY.md if not provided (looking for soul_version:
# or model_primary fallback). Default 'v0' for graceful degrade per spec §13.4.
if [[ -z "$SOUL_VERSION" ]]; then
  if [[ -r "$IDENTITY_FILE" ]] && grep -q 'soul_version:' "$IDENTITY_FILE"; then
    SOUL_VERSION=$(grep -m1 'soul_version:' "$IDENTITY_FILE" | sed -E 's/^[[:space:]]*soul_version:[[:space:]]*//; s/^"//; s/"$//')
  fi
  [[ -n "$SOUL_VERSION" ]] || SOUL_VERSION="v0"
fi

# ── emit ──────────────────────────────────────────────────────────────────────
# Header must start within first 200 chars (spec §13.4). Since we put the
# header at position 0, this is trivially satisfied.

cat <<EOF
[GAWD-MSG]
from: ${FROM}
to: ${TO}
prophit_present_ids: ${PROPHIT_IDS}
soul_version: ${SOUL_VERSION}
intent: ${INTENT}
correlation_id: ${CORRELATION_ID}
[/GAWD-MSG]
${BODY}
EOF

log_info inter-gawd "header emitted from=${FROM} to=${TO} intent=${INTENT} correlation_id=${CORRELATION_ID}"
exit 0
