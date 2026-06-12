#!/usr/bin/env bash
# check-pending.sh — Apply a pending accepted revelation at the daily 4am boundary
#
# Per spec §10.3 + handoff E2. Called by E1's daily-reset.sh at the
# Prophit-local 4am daily session boundary. Reads the pending-revelation
# state file. If response=accepted and applied=false, invokes merge.sh.
# Also handles the missed-offer auto-decline transition (3 consecutive
# silent misses → that revelation auto-declines).
#
# Mid-conversation upgrade forbidden (spec §10.3): this script runs ONLY at
# the daily-reset boundary, NEVER inside an active session. The daily-reset
# scheduler (E1) is responsible for enforcing the boundary.
#
# Usage:
#   check-pending.sh [--state <dir>] [--workspace <dir>] [--dry-run]
#
# Exit codes:
#   0  no pending action, or merge succeeded, or auto-decline applied
#   1  args/env error
#   2  state file malformed
#   3  merge invocation failed (live workspace state per merge.sh's atomicity)

set -euo pipefail

STATE_DIR="${HOME}/.gawd/state"
WORKSPACE_DIR="${HOME}/.gawd/workspace"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE_DIR="$2"; shift 2 ;;
    --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

STATE_FILE="${STATE_DIR}/pending-revelation.json"
LAST_APPLIED_DIR="${STATE_DIR}/last-applied-base"
MERGE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge.sh"

log() { echo "[check-pending $(date -Iseconds)] $*"; }

# No pending state file = nothing to do
if [[ ! -f "$STATE_FILE" ]]; then
  log "No pending-revelation.json — nothing to apply"
  exit 0
fi

# Require jq for state mutation (graceful python fallback below)
HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=1
fi

read_field() {
  local key="$1"
  if [[ $HAS_JQ -eq 1 ]]; then
    jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE"
  else
    python3 -c "
import json, sys
with open('$STATE_FILE') as f: d = json.load(f)
v = d.get('$key', '')
print('' if v is None else v)
"
  fi
}

write_state() {
  # write_state <jq-filter> — applies a jq filter (or python equivalent) to the state file
  local filter="$1"
  local tmpfile
  tmpfile=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
  if [[ $HAS_JQ -eq 1 ]]; then
    jq --arg ts "$(date -Iseconds)" "$filter" "$STATE_FILE" > "$tmpfile"
  else
    log "WARN: jq not present; using python fallback (filter param treated as python expression)"
    python3 -c "
import json, sys, datetime
with open('$STATE_FILE') as f: d = json.load(f)
ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
$2  # the python-form mutation passed as arg 2
with open('$tmpfile', 'w') as f: json.dump(d, f, indent=2)
"
  fi
  mv "$tmpfile" "$STATE_FILE"
}

REVELATION_VERSION=$(read_field revelation_version)
PROPHIT_RESPONSE=$(read_field prophit_response)
APPLIED=$(read_field applied)
OFFERED_AT=$(read_field offered_at)
MISSED_COUNT=$(read_field missed_offers_count)
BUNDLE_PATH=$(read_field revelation_bundle_path)

[[ -n "$REVELATION_VERSION" ]] || { echo "ERROR: state file missing revelation_version" >&2; exit 2; }
[[ -n "$PROPHIT_RESPONSE" ]]   || { echo "ERROR: state file missing prophit_response"   >&2; exit 2; }

log "Pending revelation: ${REVELATION_VERSION}"
log "  prophit_response: ${PROPHIT_RESPONSE}"
log "  applied:          ${APPLIED}"
log "  offered_at:       ${OFFERED_AT}"
log "  missed_count:     ${MISSED_COUNT}"

# Case 1: accepted, not yet applied → run merge.sh
if [[ "$PROPHIT_RESPONSE" == "accepted" ]] && [[ "$APPLIED" != "true" ]]; then
  log "Action: apply revelation ${REVELATION_VERSION}"
  [[ -n "$BUNDLE_PATH" ]] || { echo "ERROR: accepted revelation has no revelation_bundle_path" >&2; exit 2; }
  [[ -d "$BUNDLE_PATH" ]] || { echo "ERROR: revelation_bundle_path not readable: $BUNDLE_PATH" >&2; exit 2; }

  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: would invoke merge.sh"
    exit 0
  fi

  # Invoke merge.sh with A = current workspace, B = bundle, C = last-applied
  if "$MERGE_SH" \
      --A "$WORKSPACE_DIR" \
      --B "$BUNDLE_PATH" \
      --C "$LAST_APPLIED_DIR" \
      --revelation-version "$REVELATION_VERSION" \
      --workspace "$WORKSPACE_DIR" \
      --state "$STATE_DIR"; then
    log "merge.sh succeeded — revelation applied"
    # merge.sh already marks applied=true; nothing more to do here

    # Surface to A2's perm enforcement script if present (per E2 acceptance note).
    # Self-locating: prefer install-relative path (sibling scripts/ dir), fall back to
    # the canonical container install location (/usr/local/lib/gawd/scripts/).
    _REVELATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local_perm_script="${_REVELATION_SCRIPT_DIR}/../scripts/gawd-persona-perms.sh"
    if [[ ! -x "$local_perm_script" ]]; then
        local_perm_script="/usr/local/lib/gawd/scripts/gawd-persona-perms.sh"
    fi
    if [[ -x "$local_perm_script" ]]; then
      log "Invoking A2 perm enforcement: $local_perm_script"
      "$local_perm_script" "$WORKSPACE_DIR" || log "WARN: perm script returned non-zero"
    else
      log "NOTE: A2 perm enforcement script not found ($local_perm_script) — T0 anchors are at 0644 until A2 lands"
    fi
    exit 0
  else
    rc=$?
    log "merge.sh FAILED with exit $rc — live workspace state per merge.sh atomicity contract"
    exit 3
  fi
fi

# Case 2: pending response — check for missed-offer auto-decline transition
if [[ "$PROPHIT_RESPONSE" == "pending" ]]; then
  # Has 7 days elapsed since offered_at? If so, this Sunday's offer was missed.
  # Note: this is "did the Prophit not respond within 7d"; the missed-count
  # increment itself is recorded by offer.sh when the NEXT offer arrives and
  # finds a pending unresponded prior offer. check-pending.sh does NOT
  # increment counters here — that's offer.sh's job. We only do the
  # auto-decline transition when count reaches 3.

  # However: if we see pending + missed_count >= 3, auto-decline now.
  if [[ "${MISSED_COUNT:-0}" -ge 3 ]]; then
    log "Action: auto-decline ${REVELATION_VERSION} (missed_offers_count=${MISSED_COUNT} >= 3)"
    if [[ $DRY_RUN -eq 1 ]]; then
      log "DRY-RUN: would mark prophit_response=auto-declined"
      exit 0
    fi
    if [[ $HAS_JQ -eq 1 ]]; then
      tmpfile=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
      jq --arg ts "$(date -Iseconds)" \
        '. + {prophit_response: "auto-declined", response_at: $ts}' \
        "$STATE_FILE" > "$tmpfile"
      mv "$tmpfile" "$STATE_FILE"
    else
      python3 - <<PYEOF
import json, datetime
with open("$STATE_FILE") as f: d = json.load(f)
d["prophit_response"] = "auto-declined"
d["response_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open("$STATE_FILE", "w") as f: json.dump(d, f, indent=2)
PYEOF
    fi
    log "Auto-decline recorded — next Sunday will bring a fresh offer"
    exit 0
  fi
  log "Response pending; missed_count=${MISSED_COUNT:-0} (auto-decline at 3) — no action"
  exit 0
fi

# Case 3: declined / auto-declined / already applied — nothing to do
log "No action: response=${PROPHIT_RESPONSE}, applied=${APPLIED}"
exit 0
