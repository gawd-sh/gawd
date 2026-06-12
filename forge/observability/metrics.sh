#!/usr/bin/env bash
# metrics.sh — Prometheus-style metrics emitter for the Gawd daemon.
#
# Writes a metrics snapshot to $GAWD_METRICS_FILE on each invocation.
# Format: Prometheus text exposition (https://prometheus.io/docs/instrumenting/exposition_formats/).
#
# Why text exposition + a file (not a live HTTP endpoint):
#   - The Gawd daemon does not run a long-lived HTTP server for metrics in v1.
#     A periodic file write is sufficient — hosted-rung scrapers can read the
#     file (or be replaced with node_exporter textfile collector). Prophit-VM
#     and bare-metal rungs still produce the file, but nothing scrapes by
#     default on those rungs.
#   - No new listening ports = no new attack surface.
#
# Source-as-library contract:
#   source /usr/local/lib/gawd/observability/metrics.sh
#   metrics_snapshot              # writes a full point-in-time snapshot
#   metrics_record_spawn <skill>  # increments the spawn counter for this skill
#   metrics_record_cleanup <n>    # adds n to the cumulative cleanup counter
#   metrics_record_dispatch <tier_class>
#   metrics_record_telegram_message <direction>  # in|out
#   metrics_record_chain_latency <step> <seconds>
#
# Counter state lives in $GAWD_METRICS_STATE_DIR (one file per counter).
# A point-in-time snapshot reads counters + samples gauges + writes the file.
#
# Cardinality discipline: only LOW-cardinality labels are accepted (see
# envelope.json cardinality_rules). Per-DemiGawd-instance labels are NOT
# emitted as labels — they live in logs (high-cardinality), not metrics.

if [[ -n "${__GAWD_METRICS_LOADED:-}" ]]; then
    return 0
fi
__GAWD_METRICS_LOADED=1

# Dependencies
if ! declare -F log_info >/dev/null; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
fi

: "${GAWD_WORKSPACE_ROOT:=${HOME}/.gawd/workspace}"
: "${GAWD_STATE_ROOT:=${GAWD_WORKSPACE_ROOT}/state}"
: "${GAWD_OBS_ROOT:=${GAWD_WORKSPACE_ROOT}/obs}"
: "${GAWD_METRICS_FILE:=${GAWD_OBS_ROOT}/metrics.prom}"
: "${GAWD_METRICS_STATE_DIR:=${GAWD_OBS_ROOT}/state}"
: "${GAWD_ID:=${HOSTNAME:-unknown}}"
: "${GAWD_RUNG:=unknown}"

# Resolved envelope.json path (the budget table).
: "${GAWD_ENVELOPE_FILE:=$(dirname "${BASH_SOURCE[0]}")/envelope.json}"

_metrics_ensure_dirs() {
    mkdir -p "$GAWD_OBS_ROOT" "$GAWD_METRICS_STATE_DIR" 2>/dev/null || true
    chmod 0700 "$GAWD_OBS_ROOT" "$GAWD_METRICS_STATE_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Counter primitives
# ---------------------------------------------------------------------------

# _counter_path <name> [label_pairs...] -> file path
# Pairs are passed as 'key=value'. Sorted to produce a stable path.
_counter_path() {
    local name="$1"; shift
    local key="${name}"
    if (( $# > 0 )); then
        # Stable label ordering: sort the key=value pairs alphabetically.
        local sorted
        sorted="$(printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' '|')"
        # Strip illegal filename characters; collapse to a hash-like key.
        local slug
        slug="$(printf '%s' "$sorted" | tr '/= ' '___' | tr -dc 'a-zA-Z0-9_|.-' )"
        key="${name}__${slug}"
    fi
    printf '%s/%s.count' "$GAWD_METRICS_STATE_DIR" "$key"
}

# _counter_inc <name> <by> [label_pairs...]
_counter_inc() {
    local name="$1"; shift
    local by="$1"; shift
    [[ "$by" =~ ^-?[0-9]+$ ]] || { log_warn metrics "non-integer counter increment ignored: $by"; return 0; }

    _metrics_ensure_dirs
    local path
    path="$(_counter_path "$name" "$@")"

    # Use flock if available for concurrency safety; otherwise best-effort.
    if command -v flock >/dev/null 2>&1; then
        (
            flock -w 5 9 || {
                log_warn metrics "counter lock contention: $name"
                exit 0
            }
            local cur=0
            [[ -r "$path" ]] && cur="$(cat "$path" 2>/dev/null || echo 0)"
            [[ "$cur" =~ ^-?[0-9]+$ ]] || cur=0
            printf '%d\n' "$(( cur + by ))" >"$path"
        ) 9>"${path}.lock"
    else
        local cur=0
        [[ -r "$path" ]] && cur="$(cat "$path" 2>/dev/null || echo 0)"
        [[ "$cur" =~ ^-?[0-9]+$ ]] || cur=0
        printf '%d\n' "$(( cur + by ))" >"$path"
    fi
}

# _counter_get <name> [label_pairs...]
_counter_get() {
    local path
    path="$(_counter_path "$@")"
    if [[ -r "$path" ]]; then
        cat "$path"
    else
        echo 0
    fi
}

# ---------------------------------------------------------------------------
# Public: record events
# ---------------------------------------------------------------------------

# Valid skill name pattern matches demigawd-spawn.sh.
_metrics_valid_skill() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{1,63}$ ]]
}

metrics_record_spawn() {
    local skill="${1:-unknown}"
    if ! _metrics_valid_skill "$skill"; then
        skill="invalid"
    fi
    _counter_inc gawd_demigawd_spawn_total 1 "skill=${skill}"
}

metrics_record_cleanup() {
    local n="${1:-0}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    _counter_inc gawd_demigawd_cleanup_deleted_total "$n"
}

# Allowed tier classes match dispatch.sh tier names; we collapse cloud/local
# at a coarser granularity to keep cardinality low. Acceptable values:
#   cloud-divine, cloud-exalted, cloud-blessed,
#   local-sanctified, local-ordained, local-faithful, other
_metrics_normalise_tier() {
    case "$1" in
        divine|exalted|blessed) printf 'cloud-%s' "$1" ;;
        sanctified|ordained|faithful) printf 'local-%s' "$1" ;;
        *) printf 'other' ;;
    esac
}

metrics_record_dispatch() {
    local tier_in="${1:-other}"
    local cls
    cls="$(_metrics_normalise_tier "$tier_in")"
    _counter_inc gawd_dispatch_total 1 "tier_class=${cls}"
}

metrics_record_telegram_message() {
    local dir="${1:-unknown}"
    case "$dir" in in|out) ;; *) dir="unknown" ;; esac
    _counter_inc gawd_telegram_messages_total 1 "direction=${dir}"
}

# Histograms are tricky in shell; v1 uses a coarse fixed-bucket counter.
# Buckets in seconds: 0.5, 1, 2, 5, 10, +Inf
metrics_record_chain_latency() {
    local step="${1:-primary}"
    local secs="${2:-0}"
    # Sanitise step label.
    case "$step" in primary|fallback_1|fallback_2|fallback_3|fallback_4|fallback_5) ;; *) step="other" ;; esac
    # Float comparison via awk (POSIX bash has no float).
    local bucket
    bucket="$(awk -v v="$secs" 'BEGIN{
        if (v+0 <= 0.5) print "0.5";
        else if (v+0 <= 1)  print "1";
        else if (v+0 <= 2)  print "2";
        else if (v+0 <= 5)  print "5";
        else if (v+0 <= 10) print "10";
        else print "+Inf";
    }' 2>/dev/null)"
    [[ -z "$bucket" ]] && bucket="+Inf"
    _counter_inc gawd_chain_step_latency_seconds_bucket 1 "step=${step}" "le=${bucket}"
    # Track a coarse sum + count for crude rate calcs (no need for exact percentile).
    _counter_inc gawd_chain_step_latency_seconds_count 1 "step=${step}"
}

# ---------------------------------------------------------------------------
# Gauges sampled at snapshot time
# ---------------------------------------------------------------------------

# Read envelope.json and return the budget for the current rung, in bytes.
# Voice flag (GAWD_VOICE_ACTIVE=1) adds the voice extra.
_metrics_get_budget_bytes() {
    local rung="${GAWD_RUNG:-unknown}"
    local text_only="${GAWD_TEXT_ONLY:-0}"
    local voice="${GAWD_VOICE_ACTIVE:-0}"
    local base_mb=0
    local voice_mb=0

    if [[ ! -r "$GAWD_ENVELOPE_FILE" ]]; then
        printf '0'
        return 0
    fi

    case "$rung" in
        hosted)
            if [[ "$text_only" == "1" ]]; then
                base_mb="$(jq -r '.rungs.hosted.per_gawd.text_only_mb // 0' "$GAWD_ENVELOPE_FILE" 2>/dev/null)"
            else
                base_mb="$(jq -r '.rungs.hosted.per_gawd.with_desktop_mb // 0' "$GAWD_ENVELOPE_FILE" 2>/dev/null)"
            fi
            voice_mb="$(jq -r '.rungs.hosted.per_gawd.voice_relay_extra_mb // 0' "$GAWD_ENVELOPE_FILE" 2>/dev/null)"
            ;;
        prophit-vm)
            # Use recommended; the runtime may override via GAWD_BUDGET_OVERRIDE_MB.
            base_mb="$(jq -r '.rungs."prophit-vm".per_gawd.recommended_mb // 0' "$GAWD_ENVELOPE_FILE" 2>/dev/null)"
            voice_mb="$(jq -r '.rungs."prophit-vm".per_gawd.voice_relay_extra_mb // 0' "$GAWD_ENVELOPE_FILE" 2>/dev/null)"
            ;;
        bare-metal)
            # No enforcement; return 0 to signal "no budget".
            printf '0'
            return 0
            ;;
        *)
            printf '0'
            return 0
            ;;
    esac

    if [[ "$voice" == "1" ]]; then
        base_mb=$(( base_mb + voice_mb ))
    fi

    # GAWD_BUDGET_OVERRIDE_MB lets prophit-vm rung honour Docker --memory.
    if [[ -n "${GAWD_BUDGET_OVERRIDE_MB:-}" ]]; then
        base_mb="$GAWD_BUDGET_OVERRIDE_MB"
    fi

    printf '%d' "$(( base_mb * 1024 * 1024 ))"
}

# Total RSS for the Gawd's process tree.
# Heuristic: sum of RSS of all processes owned by $USER under the Gawd's
# session group. This is "good enough" for trend monitoring. For exact
# accounting, the hosted rung uses cgroup memory.current — see runbook.
#
# Test hook: GAWD_FAKE_RSS_BYTES short-circuits sampling. Only set this in
# tests; the test suite uses it to drive deterministic threshold scenarios.
_metrics_sample_rss_bytes() {
    if [[ -n "${GAWD_FAKE_RSS_BYTES:-}" ]]; then
        printf '%d' "$GAWD_FAKE_RSS_BYTES"
        return 0
    fi
    local pid_self=$$
    local group_pids
    # All processes in same session as this script — close enough for the daemon.
    group_pids="$(ps -o pid= -s "$(ps -o sid= -p "$pid_self" 2>/dev/null | tr -d ' ')" 2>/dev/null || echo "")"

    if [[ -z "$group_pids" ]]; then
        # Fallback: read cgroup memory.current if available.
        if [[ -r /sys/fs/cgroup/memory.current ]]; then
            cat /sys/fs/cgroup/memory.current 2>/dev/null
            return 0
        fi
        printf '0'
        return 0
    fi

    # ps -o rss= prints KB. Sum and convert to bytes.
    local sum_kb
    sum_kb="$(ps -o rss= -p "$(echo "$group_pids" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null \
        | awk '{s+=$1} END{print s+0}')"
    [[ "$sum_kb" =~ ^[0-9]+$ ]] || sum_kb=0
    printf '%d' "$(( sum_kb * 1024 ))"
}

# Voice state gauge (D2 integration). Reads the state_num sidecar file
# written by ingest_voice_status() in voice-status.sh. Missing file ->
# -1 (stopped) so a Gawd with no voice subsystem still reports cleanly.
_metrics_sample_voice_state() {
    local f="${GAWD_VOICE_DELTA_DIR:-${GAWD_OBS_ROOT}/voice}/state_num"
    if [[ -r "$f" ]]; then
        local v
        v="$(cat "$f" 2>/dev/null)"
        if [[ "$v" =~ ^-?[0-9]+$ ]]; then
            printf '%s' "$v"
            return 0
        fi
    fi
    # Voice subsystem absent / never reported -> "stopped".
    printf '%s' "-1"
}

# State-dir signals (C1 cleanup integration).
_metrics_sample_state_dir_bytes() {
    [[ -d "$GAWD_STATE_ROOT" ]] || { printf '0'; return 0; }
    local sz
    sz="$(du -sb "$GAWD_STATE_ROOT" 2>/dev/null | awk '{print $1}')"
    [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
    printf '%d' "$sz"
}

_metrics_sample_marker_count() {
    [[ -d "$GAWD_STATE_ROOT" ]] || { printf '0'; return 0; }
    find "$GAWD_STATE_ROOT" -maxdepth 1 -type f -name '*.marker' 2>/dev/null | wc -l | awk '{print $1+0}'
}

# Max age, in seconds, of any incomplete marker. Reads each marker JSON.
_metrics_sample_stale_marker_age() {
    [[ -d "$GAWD_STATE_ROOT" ]] || { printf '0'; return 0; }
    local now max=0 f spawned_at status age
    now="$(date -u +%s)"
    while IFS= read -r -d '' f; do
        status="$(jq -r '.status // ""' "$f" 2>/dev/null)"
        [[ "$status" != "incomplete" ]] && continue
        spawned_at="$(jq -r '.spawned_at // ""' "$f" 2>/dev/null)"
        [[ -z "$spawned_at" ]] && continue
        # ISO-8601 to epoch
        local epoch
        epoch="$(date -d "$spawned_at" -u +%s 2>/dev/null || echo 0)"
        (( epoch > 0 )) || continue
        age=$(( now - epoch ))
        (( age > max )) && max="$age"
    done < <(find "$GAWD_STATE_ROOT" -maxdepth 1 -type f -name '*.marker' -print0 2>/dev/null)
    printf '%d' "$max"
}

# ---------------------------------------------------------------------------
# Snapshot: write all metrics to $GAWD_METRICS_FILE
# ---------------------------------------------------------------------------

# Emit one Prometheus-style metric line (handles labels safely).
# _emit <name> <type> <help> <value> [label_pairs...]
_emit_typed_header() {
    local name="$1" type="$2" help="$3"
    printf '# HELP %s %s\n' "$name" "$help"
    printf '# TYPE %s %s\n' "$name" "$type"
}

_emit_sample() {
    local name="$1"; shift
    local value="$1"; shift
    if (( $# > 0 )); then
        local labels="" pair k v
        for pair in "$@"; do
            k="${pair%%=*}"
            v="${pair#*=}"
            # Escape backslashes and double quotes per exposition spec.
            v="${v//\\/\\\\}"
            v="${v//\"/\\\"}"
            if [[ -z "$labels" ]]; then
                labels="${k}=\"${v}\""
            else
                labels="${labels},${k}=\"${v}\""
            fi
        done
        printf '%s{%s} %s\n' "$name" "$labels" "$value"
    else
        printf '%s %s\n' "$name" "$value"
    fi
}

metrics_snapshot() {
    _metrics_ensure_dirs

    local tmp="${GAWD_METRICS_FILE}.tmp.$$"
    {
        printf '# Gawd metrics snapshot\n'
        printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# gawd_id=%s rung=%s\n' "$GAWD_ID" "$GAWD_RUNG"
        printf '\n'

        # --- Gauges ---
        local rss bgt ratio sd_bytes marker_count stale_age
        rss="$(_metrics_sample_rss_bytes)"
        bgt="$(_metrics_get_budget_bytes)"
        sd_bytes="$(_metrics_sample_state_dir_bytes)"
        marker_count="$(_metrics_sample_marker_count)"
        stale_age="$(_metrics_sample_stale_marker_age)"

        if (( bgt > 0 )); then
            # awk for float division
            ratio="$(awk -v r="$rss" -v b="$bgt" 'BEGIN{ printf "%.4f", r/b }')"
        else
            ratio="0"
        fi

        _emit_typed_header gawd_rss_bytes gauge "Resident set size of Gawd process tree, in bytes."
        _emit_sample gawd_rss_bytes "$rss" "gawd_id=${GAWD_ID}" "rung=${GAWD_RUNG}"

        _emit_typed_header gawd_budget_bytes gauge "Per-Gawd RAM budget for current rung, in bytes (0 = no enforcement)."
        _emit_sample gawd_budget_bytes "$bgt" "gawd_id=${GAWD_ID}" "rung=${GAWD_RUNG}"

        _emit_typed_header gawd_budget_used_ratio gauge "Ratio of current RSS to rung budget (0.0-1.0+)."
        _emit_sample gawd_budget_used_ratio "$ratio" "gawd_id=${GAWD_ID}" "rung=${GAWD_RUNG}"

        _emit_typed_header gawd_state_dir_bytes gauge "Total size of DemiGawd state directory in bytes (C1 signal)."
        _emit_sample gawd_state_dir_bytes "$sd_bytes"

        _emit_typed_header gawd_state_marker_count gauge "Current count of .marker files in state dir (C1 signal)."
        _emit_sample gawd_state_marker_count "$marker_count"

        _emit_typed_header gawd_state_stale_marker_age_seconds_max gauge "Max age in seconds of any incomplete marker (C1 signal)."
        _emit_sample gawd_state_stale_marker_age_seconds_max "$stale_age"

        # Voice state gauge (D2 integration).
        local voice_state
        voice_state="$(_metrics_sample_voice_state)"
        _emit_typed_header gawd_voice_state gauge "Voice subsystem state: active=2, degraded=1, disabled=0, stopped=-1, unknown=-2 (D2 signal)."
        _emit_sample gawd_voice_state "$voice_state"

        # --- Counters (from $GAWD_METRICS_STATE_DIR) ---
        _metrics_emit_counter_family gawd_demigawd_spawn_total counter "Cumulative DemiGawd spawns by skill."
        _metrics_emit_counter_family gawd_demigawd_cleanup_deleted_total counter "Cumulative DemiGawd state files deleted by cleanup runs."
        _metrics_emit_counter_family gawd_dispatch_total counter "Cumulative dispatches by tier_class."
        _metrics_emit_counter_family gawd_telegram_messages_total counter "Cumulative Telegram messages by direction."
        _metrics_emit_counter_family gawd_chain_step_latency_seconds_bucket counter "Cumulative chain-step latency bucket counts."
        _metrics_emit_counter_family gawd_chain_step_latency_seconds_count counter "Cumulative chain-step latency sample counts."
        _metrics_emit_counter_family gawd_skill_fallback_total counter "Cumulative skill fallback events (C2 integration)."
        _metrics_emit_counter_family gawd_voice_degradation_total counter "Cumulative voice degradation events by kind (D2 integration)."

    } > "$tmp"

    mv -f "$tmp" "$GAWD_METRICS_FILE"
    chmod 0644 "$GAWD_METRICS_FILE" 2>/dev/null || true
}

# Walk $GAWD_METRICS_STATE_DIR for files matching <metric>__*.count and reconstruct
# label sets from the filename. Cardinality stays low because callers normalize.
_metrics_emit_counter_family() {
    local metric="$1" type="$2" help="$3"
    _emit_typed_header "$metric" "$type" "$help"

    local family_dir="$GAWD_METRICS_STATE_DIR"
    local f base body labels label_pairs value
    local emitted_any=0

    # First, the no-label case: <metric>.count
    if [[ -r "${family_dir}/${metric}.count" ]]; then
        value="$(cat "${family_dir}/${metric}.count" 2>/dev/null || echo 0)"
        [[ "$value" =~ ^-?[0-9]+$ ]] || value=0
        _emit_sample "$metric" "$value"
        emitted_any=1
    fi

    # Labeled variants: <metric>__<slug>.count where slug encodes k=v|k=v
    shopt -s nullglob
    for f in "${family_dir}/${metric}__"*.count; do
        base="$(basename "$f")"
        # Strip "<metric>__" prefix and ".count" suffix.
        body="${base#${metric}__}"
        body="${body%.count}"
        # body is k_v|k_v (we replaced '=' with '_'); we cannot perfectly
        # reverse without ambiguity. Workaround: callers always use
        # alphanumeric keys; we recover by splitting on '|' then on first '_'.
        label_pairs=()
        IFS='|' read -ra parts <<< "$body"
        local part k v
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            k="${part%%_*}"
            v="${part#*_}"
            label_pairs+=("${k}=${v}")
        done
        value="$(cat "$f" 2>/dev/null || echo 0)"
        [[ "$value" =~ ^-?[0-9]+$ ]] || value=0
        _emit_sample "$metric" "$value" "${label_pairs[@]}"
        emitted_any=1
    done
    shopt -u nullglob

    if (( emitted_any == 0 )); then
        # Emit a zero so scrapers always see the metric exists.
        _emit_sample "$metric" 0
    fi
    printf '\n'
}

# Smoke when executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    metrics_snapshot
    echo "metrics: wrote $GAWD_METRICS_FILE"
fi
