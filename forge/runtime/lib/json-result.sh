#!/usr/bin/env bash
# json-result.sh — helper for DemiGawd skill authors.
#
# Sources into a skill.sh and provides write_result() — an atomic, jq-safe
# JSON result writer that satisfies the runtime contract:
#
#   { "status": "complete"|"failed", "output": <any>, "error": <string|null>, ... }
#
# Use:
#   source /usr/local/lib/gawd/runtime/lib/json-result.sh
#   write_result_complete "$TASK_ID" "$output_string"
#   write_result_failed   "$TASK_ID" "reason"
#   write_result_raw      "$TASK_ID" '{"status":"complete","output":{"foo":"bar"}}'
#
# Atomicity: write to TASK_ID.result.tmp then `mv` over TASK_ID.result.
# Readers (demigawd-await.sh) see either no file or a complete file — never
# a half-written one.
#
# Marker cleanup: on every write_result_*, the .marker file (if present)
# is removed. The marker exists ONLY while status is incomplete; the
# presence of a .result is the new ground truth.

if [[ -n "${__JSON_RESULT_LOADED:-}" ]]; then
    return 0
fi
__JSON_RESULT_LOADED=1

: "${GAWD_WORKSPACE_ROOT:=${HOME}/.gawd/workspace}"
: "${GAWD_STATE_ROOT:=${GAWD_WORKSPACE_ROOT}/state}"

_jr_err() { printf 'json-result: %s\n' "$*" >&2; }

_jr_state_path() {
    local task_id="$1"
    printf '%s/%s.result' "$GAWD_STATE_ROOT" "$task_id"
}

_jr_marker_path() {
    local task_id="$1"
    printf '%s/%s.marker' "$GAWD_STATE_ROOT" "$task_id"
}

# Atomic write: tmp then rename. Caller passes the complete JSON envelope.
write_result_raw() {
    local task_id="${1:?task_id required}"
    local body="${2:?json body required}"

    # Quick sanity: must parse as JSON. We refuse to write malformed bodies.
    if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
        _jr_err "refusing to write malformed JSON for $task_id"
        return 65
    fi

    local final tmp
    final="$(_jr_state_path "$task_id")"
    tmp="${final}.tmp.$$"

    mkdir -p -- "$(dirname -- "$final")"
    printf '%s\n' "$body" >"$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$final"

    # Marker is no longer the ground truth; remove it.
    rm -f -- "$(_jr_marker_path "$task_id")" 2>/dev/null || true
}

# Convenience: status:"complete" with a string output payload.
write_result_complete() {
    local task_id="${1:?task_id required}"
    local output="${2:-}"
    local body
    body="$(
        jq -nc \
            --arg out "$output" \
            '{status:"complete", output:$out, error:null}'
    )"
    write_result_raw "$task_id" "$body"
}

# Convenience: status:"failed" with a string error reason.
write_result_failed() {
    local task_id="${1:?task_id required}"
    local err="${2:?error message required}"
    local body
    body="$(
        jq -nc \
            --arg err "$err" \
            '{status:"failed", output:null, error:$err}'
    )"
    write_result_raw "$task_id" "$body"
}

# Convenience: status:"complete" with a structured object output (pass JSON string).
write_result_complete_obj() {
    local task_id="${1:?task_id required}"
    local obj_json="${2:?obj json required}"
    if ! printf '%s' "$obj_json" | jq -e . >/dev/null 2>&1; then
        _jr_err "obj_json is not valid JSON"
        return 65
    fi
    local body
    body="$(
        jq -nc --argjson obj "$obj_json" \
            '{status:"complete", output:$obj, error:null}'
    )"
    write_result_raw "$task_id" "$body"
}
