#!/usr/bin/env bash
# cross-household-reject.sh — Enforce v1 §13.6 cross-household rejection
#
# Per spec §13.6 + handoff E4. v1 daemons reject any inter-Gawd message whose
# from/to Prophit pair does not match the receiving Gawd's known household
# (i.e., a Prophit ID that does not appear in IDENTITY.md). The message is
# dropped with a structured warning log entry; NO Prophit-facing error is
# surfaced (per spec: "no error is surfaced to the Prophit").
#
# Design note: the rejection is replaceable. Future v2 cross-household routing
# will replace the "reject" outcome with "route through trust layer" without
# rearchitecting. This script encapsulates the decision so future swaps touch
# this file only.
#
# Usage:
#   cross-household-reject.sh --header-json <file-or-stdin>
#                             [--identity <path>]
#
# Input:
#   The parsed header JSON from header-parser.sh (object with fields:
#   from, to, prophit_present_ids, intent, ...).
#
# Behavior:
#   - Load household Prophit IDs from IDENTITY.md (Prophits section).
#   - Load known peer Gawd IDs from household-gawds.json (peers[].gawd_id).
#   - Reject if NONE of prophit_present_ids overlap with the household set.
#     This catches the "foreign Prophit" case.
#   - SECURITY (BLOCKER 3 / inter-HIGH H4): the header 'from' is self-asserted
#     and HARVESTABLE — a Prophit's Telegram ID is not a secret, so an UNKNOWN
#     Gawd can trivially claim a household Prophit ID to satisfy the overlap
#     check. Prophit overlap ALONE must NEVER authorize accept. On BOTH paths
#     'from' MUST additionally be a known peer in household-gawds.json. The
#     stronger claim (Prophit present) cannot be guarded by the weaker check.
#   - SPECIAL CASE: prophit_present_ids = []  → background coordination
#     between in-household Gawds. Permitted only if the 'from' Gawd is in
#     household-gawds.json. Otherwise rejected.
#
# AUTHENTICATED-SENDER CONTRACT (inter-HIGH H4): 'from' is the self-asserted
# header identifier. It is NOT proof of origin on its own. The dispatcher that
# receives the inbound Telegram update MUST bind 'from' to the authenticated
# Telegram sender (update.message.from.id / callback_query.from.id) BEFORE this
# script runs: i.e. the peer claiming gawd_id=X in 'from' must have sent the
# update from the telegram_bot_id registered for X in household-gawds.json.
# This script enforces the peer-registry membership of 'from'; the
# sender↔from binding is enforced upstream (header-parser.sh documents the
# same contract and fails closed if the authenticated sender is unavailable).
#
# Exit codes:
#   0  accepted — message belongs to this household, pass through
#   1  args error
#   2  rejected — cross-household (no Prophit overlap)
#   3  rejected — unknown peer ('from' not in household-gawds.json)
#
# Spec ref: §13.6 (cross-household reject), §13.4 (prophit_present_ids semantics).

set -euo pipefail

# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../observability/logger.sh"

HEADER_INPUT=""
IDENTITY_FILE="${HOME}/.gawd/workspace/IDENTITY.md"
HOUSEHOLD_FILE="${HOME}/.gawd/state/household-gawds.json"

usage() { grep '^# ' "$0" | sed 's/^# //'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --header-json) HEADER_INPUT="$2"; shift 2 ;;
    --identity) IDENTITY_FILE="$2"; shift 2 ;;
    --household) HOUSEHOLD_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 1
fi

# Read header JSON
if [[ -z "$HEADER_INPUT" || "$HEADER_INPUT" == "-" ]]; then
  HEADER=$(cat)
elif [[ -r "$HEADER_INPUT" ]]; then
  HEADER=$(cat "$HEADER_INPUT")
else
  echo "ERROR: header input unreadable: $HEADER_INPUT" >&2
  exit 1
fi

if ! printf '%s' "$HEADER" | jq -e 'type=="object"' >/dev/null 2>&1; then
  echo "ERROR: header JSON malformed" >&2
  exit 1
fi

FROM=$(printf '%s' "$HEADER" | jq -r '.from // empty')
TO=$(printf '%s' "$HEADER" | jq -r '.to // empty')
CORR=$(printf '%s' "$HEADER" | jq -r '.correlation_id // empty')

# Extract prophit_present_ids as a flat space-separated list for shell comparison
PROPHIT_IDS_JSON=$(printf '%s' "$HEADER" | jq -c '.prophit_present_ids // []')
PROPHIT_COUNT=$(printf '%s' "$PROPHIT_IDS_JSON" | jq 'length')

# ── load household Prophit IDs from IDENTITY.md ───────────────────────────────

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

# ── peer-registry check (shared by both cases) ────────────────────────────────
# The header 'from' is self-asserted. On EVERY path we require it to be a known
# peer in household-gawds.json. Returns 0 if 'from' is a registered peer,
# non-zero otherwise (fails closed when the registry is missing/empty/unreadable).
from_is_known_peer() {
  local from="$1"
  [[ -n "$from" ]] || return 1
  [[ "$from" != *$'\n'* ]] || return 1   # reject multi-line from outright
  [[ -r "$HOUSEHOLD_FILE" ]] || return 1
  jq -e --arg f "$from" 'any(.peers[]?; .gawd_id == $f)' \
     "$HOUSEHOLD_FILE" >/dev/null 2>&1
}

# ── decision tree ─────────────────────────────────────────────────────────────

# CASE A: prophit_present_ids non-empty — must overlap household AND 'from' must
# be a known peer. Prophit overlap ALONE is insufficient: Prophit Telegram IDs
# are harvestable, so an unknown Gawd can spoof one. The weaker (self-asserted
# overlap) check must NOT guard the stronger claim — bind to the peer registry,
# exactly as Case B does. (BLOCKER 3 / inter-HIGH H4.)
if [[ "$PROPHIT_COUNT" -gt 0 ]]; then
  # Compute intersection of header prophit_present_ids vs household_prophits.
  # Use jq for the intersection check.
  household_json=$(printf '%s\n' "${HOUSEHOLD_PROPHITS[@]:-}" | jq -R . | jq -s 'map(select(length>0))')
  intersection=$(printf '%s' "$PROPHIT_IDS_JSON" | jq --argjson hh "$household_json" '[.[] | select(. as $x | $hh | index($x))]')
  intersection_len=$(printf '%s' "$intersection" | jq 'length')

  if [[ "$intersection_len" -eq 0 ]]; then
    log_warn inter-gawd "cross-household reject: no Prophit overlap. from=${FROM} to=${TO} corr=${CORR} foreign_prophit_ids=$(printf '%s' "$PROPHIT_IDS_JSON" | tr -d '\n')"
    exit 2
  fi

  # Prophit overlap is necessary but NOT sufficient. 'from' must be a known peer.
  if ! from_is_known_peer "$FROM"; then
    log_warn inter-gawd "cross-household reject: Prophit overlap claimed but 'from' Gawd is NOT a known peer (possible spoof — harvestable Prophit ID). from=${FROM} to=${TO} corr=${CORR}"
    exit 3
  fi

  log_info inter-gawd "cross-household check passed (Prophit overlap + known peer). from=${FROM} to=${TO} corr=${CORR}"
  exit 0
fi

# CASE B: prophit_present_ids == [] (background coordination)
# Must verify 'from' is a known household Gawd.
log_debug inter-gawd "empty prophit_present_ids — checking peer registry"

if [[ ! -r "$HOUSEHOLD_FILE" ]]; then
  log_warn inter-gawd "cross-household reject: empty prophit list and no household-gawds.json. from=${FROM} to=${TO} corr=${CORR}"
  exit 3
fi

# We only verify the 'from' is a known peer (the 'to' SHOULD match our own
# gawd_id; that's the message dispatcher's job, not enforced here).
if ! from_is_known_peer "$FROM"; then
  log_warn inter-gawd "cross-household reject: 'from' Gawd not in household-gawds.json. from=${FROM} to=${TO} corr=${CORR}"
  exit 3
fi

log_info inter-gawd "background coordination accepted (known peer). from=${FROM} to=${TO} corr=${CORR}"
exit 0
