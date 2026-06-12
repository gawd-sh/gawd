#!/usr/bin/env bash
# cleanup.sh — Hourly maintenance
#
# Per spec + handoff E1.
#
# Runs every 6 hours (matches C1's recommended cadence for demigawd-cleanup;
# E1 takes ownership of triggering it).
#
# Job:
#   1. C1 demigawd-cleanup.sh — sweep DemiGawd state files older than 24h
#      whose tasks are complete/failed.
#   2. D3 envelope-monitor.sh — check memory/disk envelope vs per-rung budget,
#      warn if exceeded (stub until D3 lands).
#
# Cheap, idempotent. Safe to fire concurrently with sessions; the cleanup
# script explicitly preserves incomplete tasks and tasks younger than the
# age threshold.

set -euo pipefail

export SCHED_JOB="cleanup"

SCHED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCHED_DIR}/../lib/common.sh"

lock_acquire "$SCHED_JOB"

log "cleanup starting"

# ──────────────────────────────────────────────────────────────────────────
# 1. C1 — DemiGawd state cleanup (mandatory; this is the C1 deliverable)
# ──────────────────────────────────────────────────────────────────────────

DEMIGAWD_CLEANUP="/usr/local/lib/gawd/runtime/demigawd-cleanup.sh"
# Force GAWD_WORKSPACE_ROOT to match our workspace convention.
GAWD_WORKSPACE_ROOT="${GAWD_WORKSPACE}/workspace" \
    run_or_stub "C1-demigawd-cleanup" "$DEMIGAWD_CLEANUP"

# Also handle the case where workspace lives at $GAWD_WORKSPACE root, no
# "workspace" subdir (Lilith's pattern). Try both — C1 is a no-op when the
# state dir is absent, so this is safe.
GAWD_WORKSPACE_ROOT="$GAWD_WORKSPACE" \
    run_or_stub "C1-demigawd-cleanup-alt" "$DEMIGAWD_CLEANUP"

# ──────────────────────────────────────────────────────────────────────────
# 2. D3 — Envelope monitor (stub-tolerant)
# ──────────────────────────────────────────────────────────────────────────

ENVELOPE_MONITOR="/usr/local/lib/gawd/runtime/envelope-monitor.sh"
run_or_stub "D3-envelope-monitor" "$ENVELOPE_MONITOR" \
    --workspace "$GAWD_WORKSPACE"

# ──────────────────────────────────────────────────────────────────────────
# 3. Self-rotation of scheduler logs (keep last 14 days)
# ──────────────────────────────────────────────────────────────────────────

if [[ -d "$GAWD_LOG_DIR" ]]; then
    # Delete log files older than 14 days
    find "$GAWD_LOG_DIR" -maxdepth 1 -type f -name '*.log' -mtime +14 -delete 2>/dev/null || true
fi

log "cleanup complete"
exit 0
