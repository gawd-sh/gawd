#!/usr/bin/env bash
# sharpen.sh — Nightly SIL sharpen cycle
#
# Per spec §15 + handoff E1.
#
# Runs nightly at 2am Prophit-local (per Lilith's existing pattern).
#
# Job:
#   - Trigger E3's SIL sharpen cycle.
#   - SIL reviews the day's interactions, may produce proposals for
#     soul-touching changes (gated) or adaptive writes (silent).
#   - Result: zero or more sharpen artifacts in workspace/sil/.
#
# The job MUST NEVER BLOCK. SIL is exploratory; if it hangs or fails, the
# Gawd keeps operating. We enforce this with a timeout wrapper (default
# 30 minutes; configurable via SHARPEN_TIMEOUT_SEC env var).
#
# Stub-tolerant: E3 SIL may not be wired up at first ship.

set -euo pipefail

export SCHED_JOB="sharpen"

SCHED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCHED_DIR}/../lib/common.sh"

lock_acquire "$SCHED_JOB"

: "${SHARPEN_TIMEOUT_SEC:=1800}"  # 30 minutes default

log "sharpen starting (timeout=${SHARPEN_TIMEOUT_SEC}s)"

SIL_SHARPEN="/usr/local/lib/gawd/sil/sharpen.sh"

if [[ -x "$SIL_SHARPEN" ]]; then
    started=$(date +%s)
    set +e
    timeout --preserve-status "$SHARPEN_TIMEOUT_SEC" \
        "$SIL_SHARPEN" \
        --workspace "$GAWD_WORKSPACE" \
        --state "$GAWD_STATE_DIR"
    rc=$?
    set -e
    elapsed=$(( $(date +%s) - started ))
    if [[ $rc -eq 124 ]]; then
        warn "SIL sharpen TIMED OUT after ${elapsed}s (rc=124); cron continues — investigate SIL"
    elif [[ $rc -ne 0 ]]; then
        warn "SIL sharpen exited non-zero (rc=${rc} duration=${elapsed}s); cron continues"
    else
        log "SIL sharpen complete (duration=${elapsed}s)"
    fi
else
    log "stub: would have called E3-sil-sharpen → ${SIL_SHARPEN} (not present yet)"
fi

log "sharpen job complete"
exit 0
