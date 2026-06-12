#!/usr/bin/env bash
# dispatch.sh — DemiGawd dispatch primitive (cloud-chain vs local-AROUND).
#
# Per spec §6.4 / §17.8 (verified 2026-05-26): v1 takes the AROUND-OpenClaw
# path for local LLM dispatch. The local wrapper (<install-root>/bin/
# gawdfather-local-dispatch) bypasses OpenClaw entirely — no header burden,
# no chain interception. Cloud-tier DemiGawds go through OpenClaw's chain;
# local-tier DemiGawds go through gawdfather-llm-call equivalents directly.
#
# This library does NOT add local models to the OpenClaw chain. It chooses
# the right caller based on the tier hint.
#
# Tiers (spec §6.5, Zoos's layered policy as routing hint):
#   divine    -> cloud, top-tier      (e.g., opus-class via OpenClaw chain)
#   exalted   -> cloud, mid-tier      (sonnet-class)
#   blessed   -> cloud, fast-tier     (haiku-class)
#   sanctified -> local, 30B          (qwen-coder-30b via local-dispatch)
#   ordained  -> local, 7B            (qwen3-7b via local-dispatch)
#   faithful  -> local, 0.5B          (smallest, near-instant)
#
# Default per-task tier hint: choose the smallest tier that can do the job.
# For narrow tasks (single-document extraction, log analysis, etc), prefer
# local tiers per spec §6.4 task-class routing rules.
#
# Use:
#   source /usr/local/lib/gawd/runtime/lib/dispatch.sh
#   response="$(dispatch_demigawd_call <tier> <prompt-file> [max-tokens])"
#
# Exit codes mirror gawdfather-llm-call / gawdfather-local-dispatch.

if [[ -n "${__DISPATCH_LOADED:-}" ]]; then
    return 0
fi
__DISPATCH_LOADED=1

# Tunable model mappings. Override via env if a different model is preferred
# per tier. Cloud tiers route via gawdfather-llm-call (which itself calls the
# cloud provider directly — NOT through OpenClaw, because OpenClaw is the
# Gawd's runtime, not its DemiGawd-call surface; v1 keeps these separate).
#
# Future evolution (D3+ observability): cloud tier dispatch may flip to
# routing through OpenClaw's chain to inherit fallback machinery. For v1,
# direct provider calls give us deterministic cost/latency telemetry per
# DemiGawd spawn. Flagged in spec §17.8 as the reversible decision.
: "${GAWD_TIER_DIVINE_MODEL:=minimax/MiniMax-M2.7}"     # placeholder top-tier
: "${GAWD_TIER_EXALTED_MODEL:=minimax/MiniMax-M2.7}"    # placeholder mid-tier
: "${GAWD_TIER_BLESSED_MODEL:=deepseek/deepseek-v4}"    # fast cloud
: "${GAWD_TIER_SANCTIFIED_MODEL:=llamacpp/qwen3-coder-30b}"
: "${GAWD_TIER_ORDAINED_MODEL:=llamacpp/qwen3-7b}"
: "${GAWD_TIER_FAITHFUL_MODEL:=llamacpp/qwen3-0.5b}"

# Self-locating binary paths: prefer install-relative bin/ sibling, then
# canonical container install path, then GAWD_*_BIN env override (highest priority).
# This replaces the previous hardcode (<install-root>/bin/) which does not
# exist on a Prophit's machine.
_DISPATCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DISPATCH_BIN_SIBLING="$(dirname "$(dirname "$_DISPATCH_LIB_DIR")")/bin"
: "${GAWD_LOCAL_DISPATCH_BIN:=${_DISPATCH_BIN_SIBLING}/gawdfather-local-dispatch}"
: "${GAWD_CLOUD_LLM_CALL_BIN:=${_DISPATCH_BIN_SIBLING}/gawdfather-llm-call}"

_dispatch_err() { printf 'dispatch: %s\n' "$*" >&2; }

# Map tier -> (caller_bin, model_id).
# Returns 0 with caller_bin and model_id printed on stdout (newline separated),
# returns non-zero on unknown tier.
_dispatch_resolve_tier() {
    local tier="${1:?tier required}"
    local bin model
    case "$tier" in
        divine)
            bin="$GAWD_CLOUD_LLM_CALL_BIN"
            model="$GAWD_TIER_DIVINE_MODEL"
            ;;
        exalted)
            bin="$GAWD_CLOUD_LLM_CALL_BIN"
            model="$GAWD_TIER_EXALTED_MODEL"
            ;;
        blessed)
            bin="$GAWD_CLOUD_LLM_CALL_BIN"
            model="$GAWD_TIER_BLESSED_MODEL"
            ;;
        sanctified)
            bin="$GAWD_LOCAL_DISPATCH_BIN"
            model="$GAWD_TIER_SANCTIFIED_MODEL"
            ;;
        ordained)
            bin="$GAWD_LOCAL_DISPATCH_BIN"
            model="$GAWD_TIER_ORDAINED_MODEL"
            ;;
        faithful)
            bin="$GAWD_LOCAL_DISPATCH_BIN"
            model="$GAWD_TIER_FAITHFUL_MODEL"
            ;;
        *)
            _dispatch_err "unknown tier: $tier (want one of: divine|exalted|blessed|sanctified|ordained|faithful)"
            return 64
            ;;
    esac
    printf '%s\n%s\n' "$bin" "$model"
}

# dispatch_demigawd_call <tier> <prompt-file> [max-tokens]
#
# Reads the prompt file, sends it to the model selected by tier, and prints
# the model's response on stdout. Errors propagate from the caller bin.
dispatch_demigawd_call() {
    local tier="${1:?tier required}"
    local prompt_file="${2:?prompt-file required}"
    local max_tokens="${3:-1024}"

    if [[ ! -r "$prompt_file" ]]; then
        _dispatch_err "prompt file not readable: $prompt_file"
        return 66
    fi

    local resolve
    if ! resolve="$(_dispatch_resolve_tier "$tier")"; then
        return 64
    fi
    local bin model
    bin="$(printf '%s\n' "$resolve" | sed -n '1p')"
    model="$(printf '%s\n' "$resolve" | sed -n '2p')"

    if [[ ! -x "$bin" ]]; then
        _dispatch_err "caller bin not executable: $bin"
        return 70
    fi

    # Each caller bin takes: <model> <prompt-file> [max-tokens]
    "$bin" "$model" "$prompt_file" "$max_tokens"
}

# dispatch_resolve_tier_pub <tier>
# Public alias for callers that want to inspect which bin/model would be used.
dispatch_resolve_tier_pub() {
    _dispatch_resolve_tier "$@"
}
