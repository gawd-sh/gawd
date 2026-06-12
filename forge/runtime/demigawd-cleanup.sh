#!/usr/bin/env bash
# demigawd-cleanup.sh — Remove DemiGawd state files older than a threshold.
#
# Default behavior: delete result + log + marker triplets for tasks whose
# .result file is OLDER than 24 hours AND whose status is "complete" or
# "failed". NEVER delete a task with status:"incomplete" or with no result
# file (a slow spawn may still be writing).
#
# Usage:
#   demigawd-cleanup.sh [--age-hours=<h>] [--dry-run]
#
# Cron registration: handoff E1 wires this into the systemd-timer / cron
# layer. Suggested schedule: every 6 hours. Cheap idempotent op.
#
# Reference: <install-root>/docs/architecture/demigawd-runtime.md

set -euo pipefail

: "${GAWD_WORKSPACE_ROOT:=${HOME}/.gawd/workspace}"
: "${GAWD_STATE_ROOT:=${GAWD_WORKSPACE_ROOT}/state}"

AGE_HOURS=24
DRY_RUN=0

# Orphan threshold: how old (in hours) must a .marker with no .result be before
# we treat it as a crashed/stuck DemiGawd and reap it.  Default to max of
# the await timeout (30s is negligible) and 2 hours.  We deliberately set a
# generous default so a genuinely slow skill is not reaped prematurely.
# Override via --orphan-age-hours for tests that need a tiny threshold.
ORPHAN_AGE_HOURS=2

die() {
    printf 'demigawd-cleanup: %s\n' "$*" >&2
    exit "${EXIT_CODE:-1}"
}

usage() {
    cat >&2 <<'EOF'
Usage: demigawd-cleanup.sh [--age-hours=<h>] [--orphan-age-hours=<h>] [--dry-run]

  --age-hours=<h>         threshold; result files older than this are eligible. Default 24.
  --orphan-age-hours=<h>  threshold for marker-with-no-result reap. Default 2.
  --dry-run               list candidates; do not delete.
EOF
    EXIT_CODE=2 die "usage error"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --age-hours=*)        AGE_HOURS="${1#--age-hours=}"; shift ;;
        --orphan-age-hours=*) ORPHAN_AGE_HOURS="${1#--orphan-age-hours=}"; shift ;;
        --dry-run)            DRY_RUN=1; shift ;;
        --help|-h)            usage ;;
        *)                    EXIT_CODE=2 die "unknown arg: $1" ;;
    esac
done

[[ "$AGE_HOURS" =~ ^[1-9][0-9]*$ ]] || {
    EXIT_CODE=2 die "age-hours must be a positive integer, got: $AGE_HOURS"
}
[[ "$ORPHAN_AGE_HOURS" =~ ^[1-9][0-9]*$ ]] || {
    EXIT_CODE=2 die "orphan-age-hours must be a positive integer, got: $ORPHAN_AGE_HOURS"
}

# Convert hours -> minutes for find -mmin.
AGE_MIN=$(( AGE_HOURS * 60 ))

if [[ ! -d "$GAWD_STATE_ROOT" ]]; then
    # Nothing to do; state dir not provisioned yet.
    printf 'demigawd-cleanup: state root absent (%s) — nothing to do\n' "$GAWD_STATE_ROOT" >&2
    exit 0
fi

deleted=0
kept_incomplete=0
kept_too_young=0
kept_malformed=0
orphans_reaped=0
orphans_killed=0

# Enumerate .result files older than AGE_MIN.
# -mmin uses modification time; the result file is written once on completion,
# so its mtime is effectively the completion time.
while IFS= read -r -d '' result; do
    task_id="$(basename -- "$result" .result)"

    # Read status defensively. Any parse failure -> KEEP (do not delete a file
    # we cannot interpret; might be a slow writer mid-flush).
    if ! body="$(cat -- "$result" 2>/dev/null)"; then
        kept_malformed=$(( kept_malformed + 1 ))
        continue
    fi
    if ! status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null)"; then
        kept_malformed=$(( kept_malformed + 1 ))
        continue
    fi

    case "$status" in
        complete|failed)
            : # eligible for delete
            ;;
        incomplete|"")
            # Spec: NEVER delete an incomplete/no-status file.
            kept_incomplete=$(( kept_incomplete + 1 ))
            continue
            ;;
        *)
            # Unknown status — preserve.
            kept_malformed=$(( kept_malformed + 1 ))
            continue
            ;;
    esac

    marker="${GAWD_STATE_ROOT}/${task_id}.marker"
    log="${GAWD_STATE_ROOT}/${task_id}.log"

    if [[ $DRY_RUN -eq 1 ]]; then
        printf 'would delete: %s (+ marker + log) status=%s\n' "$result" "$status"
    else
        rm -f -- "$result" "$marker" "$log"
        deleted=$(( deleted + 1 ))
    fi
done < <(find "$GAWD_STATE_ROOT" -maxdepth 1 -type f -name '*.result' -mmin "+${AGE_MIN}" -print0 2>/dev/null)

# Count too-young as those .result files younger than threshold (informational).
while IFS= read -r -d '' _; do
    kept_too_young=$(( kept_too_young + 1 ))
done < <(find "$GAWD_STATE_ROOT" -maxdepth 1 -type f -name '*.result' -mmin "-${AGE_MIN}" -print0 2>/dev/null)

printf 'demigawd-cleanup: deleted=%d kept_too_young=%d kept_incomplete=%d kept_malformed=%d age_threshold_hours=%d dry_run=%d\n' \
    "$deleted" "$kept_too_young" "$kept_incomplete" "$kept_malformed" "$AGE_HOURS" "$DRY_RUN"

# ---------------------------------------------------------------------------
# dem-H1: Orphan-marker reap pass
#
# Enumerate *.marker files with NO matching *.result that are older than
# ORPHAN_AGE_HOURS. These are DemiGawds that crashed or were killed before
# writing a result, leaking marker+log forever.
#
# For each orphan:
#   1. Read the PID from the marker JSON (set by dem-H2 in spawn).
#   2. If the process is still alive, kill -- -$pid (process group via setsid).
#   3. Delete marker + log.
# Guard: age threshold prevents reaping a genuinely slow (but live) skill.
# ---------------------------------------------------------------------------

ORPHAN_AGE_MIN=$(( ORPHAN_AGE_HOURS * 60 ))

while IFS= read -r -d '' marker; do
    task_id="$(basename -- "$marker" .marker)"
    result="${GAWD_STATE_ROOT}/${task_id}.result"
    log="${GAWD_STATE_ROOT}/${task_id}.log"

    # Only reap if NO result file exists.
    [[ -f "$result" ]] && continue

    # Read PID from marker (may be null if marker was written before dem-H2 fix).
    local_pid="$(jq -r '.pid // empty' -- "$marker" 2>/dev/null || true)"

    if [[ -n "$local_pid" && "$local_pid" != "null" && "$local_pid" =~ ^[0-9]+$ ]]; then
        if kill -0 "$local_pid" 2>/dev/null; then
            if [[ $DRY_RUN -eq 1 ]]; then
                printf 'would kill pgid -%s for orphan: %s\n' "$local_pid" "$marker"
            else
                kill -- "-${local_pid}" 2>/dev/null || true
                orphans_killed=$(( orphans_killed + 1 ))
            fi
        fi
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf 'would reap orphan: %s (+ log)\n' "$marker"
    else
        rm -f -- "$marker" "$log"
        orphans_reaped=$(( orphans_reaped + 1 ))
    fi
done < <(find "$GAWD_STATE_ROOT" -maxdepth 1 -type f -name '*.marker' -mmin "+${ORPHAN_AGE_MIN}" -print0 2>/dev/null)

printf 'demigawd-cleanup: orphans_reaped=%d orphans_killed=%d orphan_age_threshold_hours=%d dry_run=%d\n' \
    "$orphans_reaped" "$orphans_killed" "$ORPHAN_AGE_HOURS" "$DRY_RUN"
