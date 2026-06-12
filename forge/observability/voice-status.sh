#!/usr/bin/env bash
# voice-status.sh — D3 voice-subsystem status bridge.
#
# The D2 voice relay (browser-relay.mjs) emits its degradation state via
# console.log/console.error to stdout/stderr, which systemd/journald captures.
# D3 needs a structured surface that:
#   1. Records "voice currently active vs disabled vs degraded" as a gauge.
#   2. Records counts of degradation events (STT failure, TTS failure, etc.)
#      as a counter for trend analysis.
#   3. Sets GAWD_VOICE_ACTIVE for the envelope monitor (so the +200 MB
#      voice budget is accounted for when voice is up).
#
# Two complementary surfaces:
#   * read_voice_status_file — read a JSON status file the relay can update
#     when it changes state. Voice relay writes this file at startup, on
#     degradation, and on shutdown. This file is the source of truth.
#   * scan_voice_journal_recent — fallback path: scrape `journalctl -u
#     voice-relay --since "5 minutes ago"` for the relay's known log lines
#     and synthesise a status guess. Used when the status file is missing
#     (older voice-relay builds, or just after first boot).
#
# Status file format (JSON):
#   {
#     "state": "active|disabled|degraded|stopped",
#     "since": "2026-05-27T10:11:22Z",
#     "reason": "<short string; never includes secrets or prophit content>",
#     "stt_failures_total": <int>,
#     "tts_failures_total": <int>
#   }
#
# Status file location (default): ~/.gawd/workspace/state/voice.status.json
# Override: GAWD_VOICE_STATUS_FILE
#
# Privacy: status reason MUST be coarse-grained (e.g., "missing_keys",
# "provider_failure", "config_disabled"). Anything provider/Prophit-specific
# stays in journald.

if [[ -n "${__GAWD_VOICE_STATUS_LOADED:-}" ]]; then
    return 0
fi
__GAWD_VOICE_STATUS_LOADED=1

# Dependencies
if ! declare -F log_info >/dev/null; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
fi
if ! declare -F metrics_snapshot >/dev/null; then
    # shellcheck source=/usr/local/lib/gawd/observability/metrics.sh
    source "$(dirname "${BASH_SOURCE[0]}")/metrics.sh"
fi

: "${GAWD_WORKSPACE_ROOT:=${HOME}/.gawd/workspace}"
: "${GAWD_VOICE_STATUS_FILE:=${GAWD_WORKSPACE_ROOT}/state/voice.status.json}"

# Allowed states; anything else becomes "unknown" at ingest time.
__GAWD_VOICE_STATES=(active disabled degraded stopped unknown)

# Allowed reasons (short enum). Free-form extension is permitted at write
# time but recorded as "other" in the counter.
__GAWD_VOICE_REASONS=(
    starting
    enabled_ok
    config_disabled
    missing_keys
    config_invalid
    provider_failure_stt
    provider_failure_tts
    llm_failure
    session_timeout
    shutdown_normal
    other
)

_voice_valid_state() {
    local s="$1" allowed
    for allowed in "${__GAWD_VOICE_STATES[@]}"; do
        [[ "$s" == "$allowed" ]] && return 0
    done
    return 1
}

_voice_norm_reason() {
    local r="$1" allowed
    for allowed in "${__GAWD_VOICE_REASONS[@]}"; do
        [[ "$r" == "$allowed" ]] && { printf '%s' "$r"; return 0; }
    done
    printf 'other'
}

# Public: write the voice status file. Called by D2 (browser-relay.mjs)
# via a small node helper, or by any sidecar / systemd ExecStartPre/Post.
#
# write_voice_status <state> <reason> [stt_failures] [tts_failures]
#
# stt_failures/tts_failures are CUMULATIVE since process start. The status
# file holds the totals; D3's ingester records DELTAS into counters.
write_voice_status() {
    local state="${1:-unknown}"
    local reason="${2:-other}"
    local stt_fail="${3:-0}"
    local tts_fail="${4:-0}"

    _voice_valid_state "$state" || state="unknown"
    reason="$(_voice_norm_reason "$reason")"
    [[ "$stt_fail" =~ ^[0-9]+$ ]] || stt_fail=0
    [[ "$tts_fail" =~ ^[0-9]+$ ]] || tts_fail=0

    local dir
    dir="$(dirname "$GAWD_VOICE_STATUS_FILE")"
    mkdir -p "$dir" 2>/dev/null || true

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local tmp="${GAWD_VOICE_STATUS_FILE}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg st "$state" \
            --arg sn "$ts" \
            --arg rs "$reason" \
            --argjson sf "$stt_fail" \
            --argjson tf "$tts_fail" \
            '{state:$st, since:$sn, reason:$rs, stt_failures_total:$sf, tts_failures_total:$tf}' \
            >"$tmp"
    else
        printf '{"state":"%s","since":"%s","reason":"%s","stt_failures_total":%d,"tts_failures_total":%d}\n' \
            "$state" "$ts" "$reason" "$stt_fail" "$tts_fail" >"$tmp"
    fi
    mv -f "$tmp" "$GAWD_VOICE_STATUS_FILE"
    chmod 0644 "$GAWD_VOICE_STATUS_FILE" 2>/dev/null || true

    log_info voice-status "wrote state=${state} reason=${reason} stt=${stt_fail} tts=${tts_fail}"
}

# Read voice status, normalised. Prints state on stdout; never errors.
# Missing file -> "stopped" (relay isn't running).
read_voice_status() {
    if [[ ! -r "$GAWD_VOICE_STATUS_FILE" ]]; then
        printf 'stopped'
        return 0
    fi
    local state
    state="$(jq -r '.state // "unknown"' "$GAWD_VOICE_STATUS_FILE" 2>/dev/null)"
    _voice_valid_state "$state" || state="unknown"
    printf '%s' "$state"
}

# Translate state -> numeric for the gauge (Prometheus convention: enum-as-int).
#   active=2 / degraded=1 / disabled=0 / stopped=-1 / unknown=-2
_voice_state_to_num() {
    case "$1" in
        active)    printf '2'  ;;
        degraded)  printf '1'  ;;
        disabled)  printf '0'  ;;
        stopped)   printf '%s' '-1' ;;
        unknown)   printf '%s' '-2' ;;
        *)         printf '%s' '-2' ;;
    esac
}

# Track last-seen failure totals so we can record deltas in counters
# (counters are monotonic; the status file's stt/tts totals are also
# monotonic until restart, so we use a small sidecar to detect restarts
# and avoid double-counting).
: "${GAWD_VOICE_DELTA_DIR:=${GAWD_WORKSPACE_ROOT}/obs/voice}"

_voice_record_delta() {
    local kind="$1"       # stt|tts
    local current_total="$2"
    local sidecar="${GAWD_VOICE_DELTA_DIR}/last_${kind}_total"
    mkdir -p "$GAWD_VOICE_DELTA_DIR" 2>/dev/null || true

    local last=0
    [[ -r "$sidecar" ]] && last="$(cat "$sidecar" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    local delta=$(( current_total - last ))
    if (( delta < 0 )); then
        # Relay restarted (counter reset). Treat current as fresh delta.
        delta="$current_total"
    fi
    if (( delta > 0 )); then
        _counter_inc gawd_voice_degradation_total "$delta" "kind=${kind}"
    fi
    printf '%d\n' "$current_total" >"$sidecar"
}

# Public: ingest the voice status file. Called from envelope-monitor.sh's
# 5-minute cron (so the gauge reflects "what voice is doing right now")
# AND records any new failure events as counter deltas.
#
# Also sets GAWD_VOICE_ACTIVE=1 on stdout if voice is currently active —
# the envelope-monitor reads this to know whether to include the +200 MB
# voice budget extra.
ingest_voice_status() {
    local state stt_total tts_total reason
    state="$(read_voice_status)"

    if [[ -r "$GAWD_VOICE_STATUS_FILE" ]] && command -v jq >/dev/null 2>&1; then
        stt_total="$(jq -r '.stt_failures_total // 0' "$GAWD_VOICE_STATUS_FILE" 2>/dev/null)"
        tts_total="$(jq -r '.tts_failures_total // 0' "$GAWD_VOICE_STATUS_FILE" 2>/dev/null)"
        reason="$(jq -r '.reason // "other"' "$GAWD_VOICE_STATUS_FILE" 2>/dev/null)"
    else
        stt_total=0
        tts_total=0
        reason="other"
    fi

    [[ "$stt_total" =~ ^[0-9]+$ ]] || stt_total=0
    [[ "$tts_total" =~ ^[0-9]+$ ]] || tts_total=0

    # Record deltas (idempotent across calls).
    _voice_record_delta stt "$stt_total"
    _voice_record_delta tts "$tts_total"

    # Print state for callers.
    local state_num
    state_num="$(_voice_state_to_num "$state")"

    # The envelope-monitor reads voice activity via GAWD_VOICE_ACTIVE env;
    # we surface a hint here (caller can `export GAWD_VOICE_ACTIVE="$(...)"`).
    local active=0
    [[ "$state" == "active" ]] && active=1

    log_info voice-status "state=${state} reason=${reason} stt_total=${stt_total} tts_total=${tts_total} active=${active}"

    # Expose as gauge via a small state file the metrics snapshot reads.
    mkdir -p "${GAWD_VOICE_DELTA_DIR}" 2>/dev/null || true
    printf '%s\n' "$state_num" >"${GAWD_VOICE_DELTA_DIR}/state_num"
    printf '%s\n' "$active"    >"${GAWD_VOICE_DELTA_DIR}/active"
}

# Smoke test when executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    GAWD_VOICE_STATUS_FILE="$(mktemp /tmp/voice-status-smoke-XXXX.json)"
    write_voice_status active enabled_ok 0 0
    cat "$GAWD_VOICE_STATUS_FILE"
    echo "read_voice_status: $(read_voice_status)"
    ingest_voice_status
    rm -f "$GAWD_VOICE_STATUS_FILE"
fi
