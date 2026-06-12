#!/usr/bin/env bash
# skill-fallback-ingest.sh — Scan per-task .log files in $GAWD_STATE_ROOT
# for skill_fallback events emitted by emit_skill_fallback, dedupe against
# previously-ingested marker, and record into D3 counters.
#
# Why this is a separate ingester (not inline in skill.sh):
#   * Skills must stay fast and narrow; observability bookkeeping belongs
#     in a sidecar that runs out-of-band.
#   * One ingest pass per cleanup cycle (E1 cron, every 6 minutes) is
#     sufficient — fallback events are rare, low-volume, and don't need
#     real-time aggregation.
#   * Keeps the ingest tolerant: a malformed .log entry never breaks the
#     skill that wrote it.
#
# Usage:
#   /usr/local/lib/gawd/observability/skill-fallback-ingest.sh
#     [--state-root <dir>]   default: $GAWD_STATE_ROOT
#     [--dry-run]            print would-record actions, do not increment
#
# Exit codes:
#   0  ingest succeeded (may have processed 0 events)
#   2  invalid args
#   3  state root missing
#
# Idempotency: each .log file is tracked via a per-log "<task_id>.ingested"
# sidecar in $GAWD_STATE_ROOT/_ingested/. Skipping previously-seen files
# means re-runs are cheap. Cleanup of these sidecars happens implicitly
# when the original .log is deleted by C1 cleanup (the sidecar can be
# orphan-cleaned during the same C1 pass; see runbook §10).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$SCRIPT_DIR/logger.sh"
# shellcheck source=/usr/local/lib/gawd/observability/metrics.sh
source "$SCRIPT_DIR/metrics.sh"

: "${GAWD_WORKSPACE_ROOT:=${HOME}/.gawd/workspace}"
: "${GAWD_STATE_ROOT:=${GAWD_WORKSPACE_ROOT}/state}"

DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-root) GAWD_STATE_ROOT="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)
            cat >&2 <<'EOF'
Usage: skill-fallback-ingest.sh [--state-root <dir>] [--dry-run]
EOF
            exit 0 ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ ! -d "$GAWD_STATE_ROOT" ]]; then
    log_warn skill-fallback-ingest "state root missing: $GAWD_STATE_ROOT"
    exit 3
fi

INGESTED_DIR="${GAWD_STATE_ROOT}/_ingested"
mkdir -p "$INGESTED_DIR" 2>/dev/null || true

total_events=0
processed_logs=0

# Allowed tiers + reasons for normalisation (must match emit_skill_fallback).
_norm_tier() {
    case "$1" in
        divine|exalted|blessed|sanctified|ordained|faithful) printf '%s' "$1" ;;
        *) printf 'other' ;;
    esac
}

_norm_reason() {
    case "$1" in
        primary_dispatch_failed|primary_timeout|primary_empty_response|primary_invalid_json) printf '%s' "$1" ;;
        *) printf 'other' ;;
    esac
}

# Skill name validator — anything malformed becomes "invalid" for the counter.
_norm_skill() {
    if [[ "$1" =~ ^[a-z][a-z0-9-]{1,63}$ ]]; then
        printf '%s' "$1"
    else
        printf 'invalid'
    fi
}

# Process one log file. Idempotent — sidecar marker prevents re-counting.
_process_log() {
    local log="$1"
    local task_id base sidecar
    base="$(basename "$log")"
    task_id="${base%.log}"
    sidecar="${INGESTED_DIR}/${task_id}.ingested"

    [[ -r "$log" ]] || return 0
    # Already ingested? Skip.
    [[ -e "$sidecar" ]] && return 0

    local events_here=0
    while IFS= read -r line; do
        # Cheap pre-filter — only JSON-looking lines with our event signature.
        [[ "$line" == *'"event":"skill_fallback"'* ]] || continue
        # Validate + extract via jq. If jq parsing fails, skip silently.
        local skill from to reason
        if command -v jq >/dev/null 2>&1; then
            local parsed
            parsed="$(jq -r '
                if type=="object" and .event=="skill_fallback"
                then "\(.skill // "invalid")\t\(.from // "other")\t\(.to // "other")\t\(.reason // "other")"
                else empty end' <<<"$line" 2>/dev/null)" || continue
            [[ -z "$parsed" ]] && continue
            IFS=$'\t' read -r skill from to reason <<<"$parsed"
        else
            # No jq — best-effort sed extraction.
            skill="$(printf '%s' "$line" | sed -nE 's/.*"skill":"([^"]*)".*/\1/p')"
            from="$(printf '%s'  "$line" | sed -nE 's/.*"from":"([^"]*)".*/\1/p')"
            to="$(printf '%s'    "$line" | sed -nE 's/.*"to":"([^"]*)".*/\1/p')"
            reason="$(printf '%s' "$line" | sed -nE 's/.*"reason":"([^"]*)".*/\1/p')"
        fi

        skill="$(_norm_skill "${skill:-invalid}")"
        from="$(_norm_tier  "${from:-other}")"
        to="$(_norm_tier    "${to:-other}")"
        reason="$(_norm_reason "${reason:-other}")"

        if (( DRY_RUN == 1 )); then
            printf 'DRY-RUN would record: skill=%s from=%s to=%s reason=%s\n' "$skill" "$from" "$to" "$reason"
        else
            # Single labeled counter — cardinality bounded by skill x tier x tier x reason.
            # In practice: <skill-count> * 6 * 6 * 5 — tiny.
            _counter_inc gawd_skill_fallback_total 1 \
                "skill=${skill}" "from=${from}" "to=${to}" "reason=${reason}"
        fi
        events_here=$(( events_here + 1 ))
    done <"$log"

    # Mark this log as ingested.
    if (( DRY_RUN == 0 )); then
        date -u +%s >"$sidecar"
    fi

    total_events=$(( total_events + events_here ))
    processed_logs=$(( processed_logs + 1 ))
}

# Walk *.log files. Skip files in _ingested/ (in case state root layout
# changes in the future to include subdirs).
shopt -s nullglob
for f in "${GAWD_STATE_ROOT}"/*.log; do
    [[ -f "$f" ]] || continue
    _process_log "$f"
done
shopt -u nullglob

log_info skill-fallback-ingest "scanned=${processed_logs} events_recorded=${total_events} dry_run=${DRY_RUN}"

# Refresh snapshot so the new counter values are visible to scrapers.
if (( DRY_RUN == 0 )) && (( total_events > 0 )); then
    metrics_snapshot
fi

exit 0
