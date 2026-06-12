#!/usr/bin/env bash
# cleanup-metrics-emit.sh — Parse the output of demigawd-cleanup.sh and
# record the metrics. Bridges C1's existing metric LINE format into D3's
# Prometheus-style counters without modifying demigawd-cleanup.sh.
#
# Why this exists rather than editing demigawd-cleanup.sh:
#   C1 deliverables are signed off as-is. Modifying them invalidates that
#   acceptance. The cleanest seam is a sidecar that consumes C1's output
#   and feeds D3's metrics state. demigawd-cleanup.sh continues to print
#   its summary line for ops consumption; this wrapper records the counts.
#
# Usage:
#   /usr/local/lib/gawd/runtime/demigawd-cleanup.sh 2>&1 \
#       | /usr/local/lib/gawd/observability/cleanup-metrics-emit.sh
#
# Cron registration (handoff E1 should wire this combined form):
#   */6  *  *  *  *  /path/to/run-cleanup-with-metrics.sh
# where the helper script does the pipe above.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$SCRIPT_DIR/logger.sh"
# shellcheck source=/usr/local/lib/gawd/observability/metrics.sh
source "$SCRIPT_DIR/metrics.sh"

# Parse C1 summary line — deterministic format set in demigawd-cleanup.sh:
#   demigawd-cleanup: deleted=N kept_too_young=N kept_incomplete=N kept_malformed=N age_threshold_hours=N dry_run=N
deleted=0
saw_line=0
while IFS= read -r line; do
    # Echo everything through so the caller still sees the original output.
    printf '%s\n' "$line"
    if [[ "$line" =~ ^demigawd-cleanup:\ deleted=([0-9]+)\  ]]; then
        deleted="${BASH_REMATCH[1]}"
        saw_line=1
    fi
done

if (( saw_line == 1 )); then
    metrics_record_cleanup "$deleted"
    log_info cleanup-metrics-emit "recorded cleanup: deleted=$deleted"
    # Refresh the snapshot so the new counter shows up promptly.
    metrics_snapshot
else
    log_warn cleanup-metrics-emit "no cleanup summary line detected on stdin"
fi
