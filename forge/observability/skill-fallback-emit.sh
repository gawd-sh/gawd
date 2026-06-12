#!/usr/bin/env bash
# skill-fallback-emit.sh — D3 skill-fallback event emitter.
#
# Sourced by skills (Sentinel, Browser-Vision, future) that have BOTH a
# default_tier and a fallback_tier in their metadata.json. When the skill
# detects it had to step from default to fallback, it emits ONE structured
# JSON line to the per-task .log file. D3 ingests these later (see
# skill-fallback-ingest.sh) and records a low-cardinality counter.
#
# Why this exists rather than instrumenting dispatch.sh:
#   * dispatch.sh is the C1/C2 transport library; modifying it invalidates
#     those acceptance signatures. The fallback DECISION lives in the skill
#     (sentinel/browser-vision call dispatch twice with different tiers).
#     The skill is the right emission point.
#   * The .log file is already the per-task transcript; one extra line
#     adds no cardinality risk and is grep-friendly for ops debugging.
#   * Skills source this library cheaply; no daemon, no new runtime cost.
#
# Source-as-library contract:
#   source /usr/local/lib/gawd/observability/skill-fallback-emit.sh
#   emit_skill_fallback <skill_name> <from_tier> <to_tier> <reason>
#
# Output format (one JSON line, appended to stderr — which the spawn harness
# captures into ${GAWD_STATE_ROOT}/<task_id>.log):
#   {"ts":"2026-05-27T11:22:33Z","event":"skill_fallback","skill":"sentinel",
#    "from":"ordained","to":"blessed","reason":"primary_dispatch_failed"}
#
# Cardinality discipline: skill names are LOW cardinality (one per registered
# skill); from/to are tier names (six values). Reason is a SHORT enum:
#   primary_dispatch_failed | primary_timeout | primary_empty_response |
#   primary_invalid_json | other
# Anything not in that enum is rewritten to "other" at ingest time.
#
# Privacy: this event contains NO Prophit data. Skill identity + tier names
# only. Safe to emit without gating the privacy hook (still ops_only data_kind
# when consumed).

if [[ -n "${__GAWD_SKILL_FALLBACK_EMIT_LOADED:-}" ]]; then
    return 0
fi
__GAWD_SKILL_FALLBACK_EMIT_LOADED=1

_sfe_ts() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Allowed reasons; anything else is recorded but normalised on ingest.
__GAWD_SFE_REASONS=(
    primary_dispatch_failed
    primary_timeout
    primary_empty_response
    primary_invalid_json
    other
)

_sfe_valid_reason() {
    local r="$1" allowed
    for allowed in "${__GAWD_SFE_REASONS[@]}"; do
        [[ "$r" == "$allowed" ]] && return 0
    done
    return 1
}

# Skill name pattern matches spawn_demigawd validator.
_sfe_valid_skill() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{1,63}$ ]]
}

# Tier names match dispatch.sh.
_sfe_valid_tier() {
    case "$1" in
        divine|exalted|blessed|sanctified|ordained|faithful) return 0 ;;
        *) return 1 ;;
    esac
}

# emit_skill_fallback <skill> <from_tier> <to_tier> <reason>
# Always returns 0; we never let observability emission fail a skill.
emit_skill_fallback() {
    local skill="${1:-unknown}"
    local from="${2:-unknown}"
    local to="${3:-unknown}"
    local reason="${4:-other}"

    _sfe_valid_skill "$skill" || skill="invalid"
    _sfe_valid_tier  "$from"  || from="other"
    _sfe_valid_tier  "$to"    || to="other"
    _sfe_valid_reason "$reason" || reason="other"

    local ts
    ts="$(_sfe_ts)"

    # Emit to stderr — the skill spawn harness captures stderr into the
    # per-task .log. This avoids polluting stdout (which carries the model
    # response on dispatch helpers).
    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg ts "$ts" \
            --arg ev "skill_fallback" \
            --arg sk "$skill" \
            --arg fr "$from" \
            --arg to "$to" \
            --arg rs "$reason" \
            '{ts:$ts, event:$ev, skill:$sk, from:$fr, to:$to, reason:$rs}' >&2
    else
        printf '{"ts":"%s","event":"skill_fallback","skill":"%s","from":"%s","to":"%s","reason":"%s"}\n' \
            "$ts" "$skill" "$from" "$to" "$reason" >&2
    fi

    return 0
}

# Smoke test when executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    emit_skill_fallback "sentinel" "ordained" "blessed" "primary_dispatch_failed"
fi
