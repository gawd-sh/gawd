#!/usr/bin/env bash
# local-dispatch-telemetry.sh — D3 observability surface for the
# AROUND-OpenClaw local-dispatch wrapper.
#
# This file is sourced by D3's metrics collectors. It exposes one function:
#
#   local_dispatch_call_with_telemetry <ndjson_log_path> [wrapper_args...]
#
# which wraps a call to /usr/local/bin/gawd-local-dispatch and appends the
# telemetry line emitted by the wrapper to the NDJSON log at $1. The
# wrapper's stdout (model response) is forwarded to this function's stdout
# unchanged; the wrapper's exit code is forwarded as our exit code.
#
# Why this exists: the wrapper emits exactly one telemetry JSON line to
# stderr (or to a chosen fd) per call. D3 wants a structured, append-only
# record of every local dispatch — model, latency, tokens, status, task_id.
# This helper is the canonical collection point; downstream metrics
# pipelines (Prometheus text-format scraper, Loki ingestion, etc.) tail
# the NDJSON file rather than each call needing to reach D3.
#
# Contract:
#   * stdout = exactly the model response (proxied from wrapper)
#   * stderr = human-readable wrapper messages (proxied), MINUS the
#              final telemetry line (which is redirected to the log)
#   * exit  = the wrapper's exit code
#
# Telemetry schema is documented in <install-root>/docs/runbooks/
# local-dispatch.md §"Telemetry schema".

if [[ -n "${__LOCAL_DISPATCH_TELE_LOADED:-}" ]]; then
    return 0
fi
__LOCAL_DISPATCH_TELE_LOADED=1

: "${GAWD_LOCAL_DISPATCH_BIN:=/usr/local/bin/gawd-local-dispatch}"

# Default NDJSON path if the caller passes "" or omits it.
: "${GAWD_LOCAL_DISPATCH_TELEMETRY_LOG:=${HOME}/.gawd/workspace/state/local-dispatch.ndjson}"

# Internal: ensure the log path exists and is appendable.
_ldt_prepare_log() {
    local log_path="$1"
    local dir
    dir="$(dirname -- "$log_path")"
    mkdir -p -- "$dir" 2>/dev/null || return 1
    : >>"$log_path" 2>/dev/null || return 1
    return 0
}

# Internal: split combined stderr stream into (human-prefix, telemetry-line).
# The wrapper's invariant is that the LAST line of its stderr is the
# telemetry JSON. Anything before is human-readable.
_ldt_split_stderr() {
    local stderr_path="$1"
    local human_path="$2"
    local tele_path="$3"

    if [[ ! -s "$stderr_path" ]]; then
        : >"$human_path"
        : >"$tele_path"
        return 0
    fi
    # Last line -> telemetry; everything else -> human.
    tail -n 1 "$stderr_path" >"$tele_path"
    if [[ "$(wc -l <"$stderr_path")" -gt 1 ]]; then
        head -n -1 "$stderr_path" >"$human_path"
    else
        : >"$human_path"
    fi
}

# Internal: verify the captured line is a JSON object with at minimum
# .status (string) and .exit_code (number). If not, treat the entire
# stderr as human-readable and emit a synthetic "malformed" record.
_ldt_validate_or_synthesize() {
    local tele_path="$1"
    local fallback_exit="$2"
    if jq -e 'type == "object" and (.status | type == "string") and (.exit_code | type == "number")' \
        <"$tele_path" >/dev/null 2>&1; then
        return 0
    fi
    # Synthesize a malformed-telemetry record so D3 still sees an event.
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    jq -nc \
        --arg ts "$ts" \
        --argjson exit_code "$fallback_exit" \
        '{ts:$ts, status:"wrapper_telemetry_malformed", exit_code:$exit_code}' \
        >"$tele_path"
    return 0
}

# Public: wrap one local-dispatch call with NDJSON telemetry capture.
#
# Usage:
#   local_dispatch_call_with_telemetry /var/log/gawd/local.ndjson \
#       --model qwen3-7b --prompt-file /tmp/p.txt
local_dispatch_call_with_telemetry() {
    local log_path="${1:-$GAWD_LOCAL_DISPATCH_TELEMETRY_LOG}"
    shift || true

    if ! _ldt_prepare_log "$log_path"; then
        printf 'local-dispatch-telemetry: cannot write to log: %s\n' "$log_path" >&2
        # Run the wrapper anyway — observability failure must NEVER block the call.
        "$GAWD_LOCAL_DISPATCH_BIN" "$@"
        return $?
    fi

    if [[ ! -x "$GAWD_LOCAL_DISPATCH_BIN" ]]; then
        printf 'local-dispatch-telemetry: wrapper not executable: %s\n' "$GAWD_LOCAL_DISPATCH_BIN" >&2
        return 2
    fi

    local tmpdir stderr_path human_path tele_path
    tmpdir="$(mktemp -d -t gawd-ldt.XXXXXX)"
    stderr_path="$tmpdir/stderr"
    human_path="$tmpdir/human"
    tele_path="$tmpdir/tele"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$tmpdir'" RETURN

    # Run wrapper. Forward stdout directly; capture stderr for split.
    set +e
    "$GAWD_LOCAL_DISPATCH_BIN" "$@" 2>"$stderr_path"
    local rc=$?
    set -e

    _ldt_split_stderr "$stderr_path" "$human_path" "$tele_path"
    _ldt_validate_or_synthesize "$tele_path" "$rc"

    # Append telemetry line to the NDJSON log (atomic per-line append).
    cat -- "$tele_path" >>"$log_path"

    # Replay human-readable stderr to our caller (sans telemetry line).
    if [[ -s "$human_path" ]]; then
        cat -- "$human_path" >&2
    fi

    return "$rc"
}

# Aggregate helper — emits per-tier / per-status rollup for the last N hours.
# Useful for ad-hoc D3 inspection or a scrape endpoint.
#
# Usage:
#   local_dispatch_summarize <ndjson_log> [hours]
#
# Output: JSON object — { total, ok, llm_error, wrapper_error, avg_latency_ms,
# fallback_to_cloud_count, by_tier: {...}, by_model: {...} }.
local_dispatch_summarize() {
    local log_path="${1:?log path required}"
    local hours="${2:-24}"

    if [[ ! -r "$log_path" ]]; then
        printf '{"error":"log not readable","path":"%s"}\n' "$log_path"
        return 1
    fi

    local cutoff
    cutoff="$(date -u -d "${hours} hours ago" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')"

    # NDJSON -> filter by ts >= cutoff -> aggregate.
    jq -s --arg cutoff "$cutoff" '
        map(select(.ts >= $cutoff)) |
        {
            cutoff: $cutoff,
            total: length,
            ok:            map(select(.status == "ok"))           | length,
            llm_error:     map(select(.status == "llm_error"))    | length,
            wrapper_error: map(select(.status == "wrapper_error"))| length,
            avg_latency_ms: (
                ( map(select(.latency_ms != null) | .latency_ms) ) as $l |
                if ($l | length) == 0 then null
                else (($l | add) / ($l | length) | floor)
                end
            ),
            by_tier:  ( group_by(.tier  // "unknown") | map({key: (.[0].tier  // "unknown"), value: length}) | from_entries ),
            by_model: ( group_by(.model // "unknown") | map({key: (.[0].model // "unknown"), value: length}) | from_entries ),
            sum_total_tokens: (
                ( map(select(.total_tokens != null) | .total_tokens) ) as $t |
                if ($t | length) == 0 then 0 else ($t | add) end
            )
        }
    ' <"$log_path"
}
