#!/usr/bin/env bash
# capacity-check.sh — Hermes-style capacity-error helper.
#
# Per persona-file-architecture.md §10:
#   When a write to a budgeted adaptive file would exceed cap, the write tool
#   returns an error telling the agent:
#       "capacity reached — consolidate before adding."
#
# This library provides:
#   - capacity_check <file_path> <proposed_content> [token_cap_override]
#   - capacity_error_envelope <reason>      (writes a JSON error to stdout)
#
# Cap table (matches A1 §10):
#   USER.md           ~700 tokens
#   MEMORY.md         ~800 tokens
#   VOICE-ADAPTIVE.md ~400 tokens
#   tuning.md         ~400 tokens
#
# T0 anchors (SOUL.md, IDENTITY.md, VOICE.md) are NOT subject to capacity
# check at runtime — they are chmod 0444 and unwritable. SIL proposals have
# their own budget check at proposal time, not here.
#
# Token estimation: 4 chars per token is the Hermes-anchor heuristic
# (`_BRIEF.md` §3a, conservative average for English persona-file prose).
# Honest estimate; not exact. For an audit-grade count, hand the content to
# a tokenizer. This helper exists for in-write checks where speed matters.
#
# Source it:
#   source /usr/local/lib/gawd/runtime/lib/capacity-check.sh
#   if ! capacity_check "$persona_file" "$new_content"; then
#       capacity_error_envelope "USER.md at cap; consolidate before adding"
#       exit 1
#   fi

if [[ -n "${__CAPACITY_CHECK_LOADED:-}" ]]; then
    return 0
fi
__CAPACITY_CHECK_LOADED=1

# Chars per estimated token; conservative anchor.
: "${GAWD_CAPACITY_CHARS_PER_TOKEN:=4}"

# Default caps, in tokens. Keys must match basename of the persona file.
declare -gA __GAWD_CAPACITY_CAPS=(
    ["USER.md"]=700
    ["MEMORY.md"]=800
    ["VOICE-ADAPTIVE.md"]=400
    ["tuning.md"]=400
)

# Internal: estimate tokens given a body string.
_cap_estimate_tokens() {
    local body="$1"
    local chars=${#body}
    local cpt="$GAWD_CAPACITY_CHARS_PER_TOKEN"
    # Ceiling division.
    echo $(( (chars + cpt - 1) / cpt ))
}

# Internal: pick cap for a persona file. 0 means "no cap configured for this
# basename" (e.g., users/<name>.md goes through a different lookup).
_cap_lookup_cap() {
    local file="$1"
    local base
    base="$(basename -- "$file")"

    # Per-Prophit files (users/<name>.md) use USER.md's cap.
    if [[ "$file" == */users/* && "$base" == *.md ]]; then
        echo 700
        return 0
    fi

    # Daily notes (memory/YYYY-MM-DD.md) have no cap by design.
    if [[ "$file" == */memory/* && "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$ ]]; then
        echo 0
        return 0
    fi

    echo "${__GAWD_CAPACITY_CAPS[$base]:-0}"
}

# capacity_check <persona_file_path> <proposed_full_content> [cap_override]
#
# Returns 0 if the proposed content fits within the cap (or no cap applies).
# Returns 1 if it would exceed the cap (caller should emit a capacity_error
# envelope and refuse the write).
capacity_check() {
    local file="${1:?persona file path required}"
    local content="${2:-}"
    local override="${3:-}"

    local cap
    if [[ -n "$override" ]]; then
        cap="$override"
    else
        cap="$(_cap_lookup_cap "$file")"
    fi

    if (( cap == 0 )); then
        # No cap applies — pass.
        return 0
    fi

    local est
    est="$(_cap_estimate_tokens "$content")"

    if (( est > cap )); then
        return 1
    fi
    return 0
}

# capacity_error_envelope <reason> -- writes a JSON envelope to stdout.
# Use this in skill scripts that implement persona-write semantics, so the
# Gawd receives a machine-parseable signal that consolidation is required.
capacity_error_envelope() {
    local reason="${1:?reason required}"
    jq -nc \
        --arg msg "capacity reached — consolidate before adding" \
        --arg detail "$reason" \
        '{
            status: "failed",
            output: null,
            error: $msg,
            error_kind: "capacity_error",
            detail: $detail,
            remedy: "Read the persona file, distill/merge entries, rewrite a smaller version, then re-attempt the add."
        }'
}
