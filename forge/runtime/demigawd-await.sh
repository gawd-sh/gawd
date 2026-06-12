#!/usr/bin/env bash
# demigawd-await.sh — Poll for a DemiGawd result file with exponential backoff.
#
# Usage:
#   demigawd-await.sh <TASK_ID> [--timeout=<sec>] [--quiet]
#
# Output (stdout):
#   The full JSON result file content on success.
#   A synthesized JSON error envelope on timeout (does NOT kill the child).
#
# Exit codes:
#   0  result file present, JSON valid, status == "complete"
#   1  result file present, JSON valid, status == "failed"
#   2  usage error
#   3  TASK_ID unknown (no marker, no result — never spawned or already cleaned)
#   4  timeout reached
#   5  result file present but JSON invalid
#
# Backoff schedule:
#   100ms, 200ms, 400ms, 800ms, 1600ms, 3200ms, 5000ms, 5000ms, …
#   Capped at 5000ms (per handoff acceptance criteria).
#
# Reference: <install-root>/docs/architecture/demigawd-runtime.md

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

: "${GAWD_WORKSPACE_ROOT:=${HOME}/.gawd/workspace}"
: "${GAWD_STATE_ROOT:=${GAWD_WORKSPACE_ROOT}/state}"

# Default per-await timeout (seconds). Spec allows per-skill override via flag.
: "${GAWD_DEMIGAWD_AWAIT_TIMEOUT:=30}"

QUIET=0
TIMEOUT_SEC=""

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------

die() {
    printf 'demigawd-await: %s\n' "$*" >&2
    exit "${EXIT_CODE:-1}"
}

usage() {
    cat >&2 <<'EOF'
Usage: demigawd-await.sh <TASK_ID> [--timeout=<sec>] [--quiet]

  <TASK_ID>          the id returned by spawn_demigawd
  --timeout=<sec>    override timeout (default: 30s, env GAWD_DEMIGAWD_AWAIT_TIMEOUT)
  --quiet            suppress non-essential stderr (timeout warning is silenced)

Exit codes:
  0  complete
  1  failed (status:"failed" in result file)
  2  usage error
  3  TASK_ID unknown
  4  timeout
  5  malformed result JSON
EOF
    EXIT_CODE=2 die "usage error"
}

[[ $# -ge 1 ]] || usage
TASK_ID="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout=*) TIMEOUT_SEC="${1#--timeout=}"; shift ;;
        --quiet)     QUIET=1; shift ;;
        --help|-h)   usage ;;
        *)           EXIT_CODE=2 die "unknown arg: $1" ;;
    esac
done

# Validate TASK_ID shape — match what spawn_demigawd produces.
if ! [[ "$TASK_ID" =~ ^[a-z][a-z0-9-]+-[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]]; then
    EXIT_CODE=2 die "TASK_ID does not match expected shape: $TASK_ID"
fi

TIMEOUT_SEC="${TIMEOUT_SEC:-$GAWD_DEMIGAWD_AWAIT_TIMEOUT}"
[[ "$TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || {
    EXIT_CODE=2 die "timeout must be a positive integer (sec), got: $TIMEOUT_SEC"
}

RESULT_FILE="${GAWD_STATE_ROOT}/${TASK_ID}.result"
MARKER_FILE="${GAWD_STATE_ROOT}/${TASK_ID}.marker"

# If neither marker nor result exists, the TASK_ID is unknown.
if [[ ! -f "$MARKER_FILE" && ! -f "$RESULT_FILE" ]]; then
    EXIT_CODE=3 die "no marker or result for TASK_ID: $TASK_ID"
fi

# ---------------------------------------------------------------------------
# Backoff loop
# ---------------------------------------------------------------------------

# Use ms-precision integer math. sleep takes fractional seconds on Linux.
delay_ms=100
cap_ms=5000
deadline_epoch_ms=$(( $(date +%s%3N) + TIMEOUT_SEC * 1000 ))

while :; do
    if [[ -f "$RESULT_FILE" ]]; then
        # Read once, validate, classify.
        if ! body="$(cat -- "$RESULT_FILE")"; then
            EXIT_CODE=5 die "could not read result file: $RESULT_FILE"
        fi

        # JSON validity check via jq (already a hard dep elsewhere in <install-root>/bin).
        if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
            EXIT_CODE=5 die "result JSON malformed at: $RESULT_FILE"
        fi

        # Output the result content verbatim.
        printf '%s\n' "$body"

        status="$(printf '%s' "$body" | jq -r '.status // empty')"
        case "$status" in
            complete) exit 0 ;;
            failed)   exit 1 ;;
            *)
                # Spec contract: status must be complete|failed.
                # If we see another value, treat as malformed.
                [[ $QUIET -eq 1 ]] || printf 'demigawd-await: result status not in {complete,failed}: "%s"\n' "$status" >&2
                exit 5
                ;;
        esac
    fi

    now_ms=$(date +%s%3N)
    if (( now_ms >= deadline_epoch_ms )); then
        # Timeout — synthesize a structured error envelope so callers can branch.
        # Do NOT kill the background process; cleanup will collect it later.
        printf '{"status":"timeout","task_id":"%s","error":"await timeout after %ds; child still running","output":null}\n' \
            "$TASK_ID" "$TIMEOUT_SEC"
        [[ $QUIET -eq 1 ]] || printf 'demigawd-await: timeout for %s after %ds\n' "$TASK_ID" "$TIMEOUT_SEC" >&2
        exit 4
    fi

    # Sleep delay_ms ms, then double (capped).
    sleep_sec=$(awk -v d="$delay_ms" 'BEGIN{ printf "%.3f", d/1000 }')
    sleep "$sleep_sec"
    delay_ms=$(( delay_ms * 2 ))
    if (( delay_ms > cap_ms )); then
        delay_ms=$cap_ms
    fi
done
