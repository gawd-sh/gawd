#!/usr/bin/env bash
# skills/refiner/skill.sh — The Refiner DemiGawd.
#
# Purpose: Polish output — tighten prose, sharpen structure, ensure voice consistency.
#          Preserves all substance; improves form. Returns the polished version + a
#          brief note on what changed.
#
# Contract (per demigawd-runtime.md §12):
#   $1 = TASK_ID           (required; assigned by spawn_demigawd)
#   $2 = TASK_DESCRIPTION  (required; what to polish and any voice/style guidance)
#   $3 = INJECTED_CONTEXT  (optional; the content to refine)
#
# Tier: blessed (bounded transform; single-document polish; cloud fast-tier)
#
# Output: write_result_complete → TASK_ID.result with polished content + change note.
#
# Do NOT modify T0 anchors. Do NOT call OpenClaw directly.

set -euo pipefail

TASK_ID="${1:?TASK_ID required}"
TASK_DESCRIPTION="${2:?TASK_DESCRIPTION required}"
INJECTED_CONTEXT="${3:-}"

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_LIB_DIR="${SKILL_DIR}/../../runtime/lib"

# shellcheck source=../../runtime/lib/json-result.sh
source "${RUNTIME_LIB_DIR}/json-result.sh"
# shellcheck source=../../runtime/lib/dispatch.sh
source "${RUNTIME_LIB_DIR}/dispatch.sh"

TIER="blessed"

PROMPT_TEMPLATE="${SKILL_DIR}/prompt.md"

PROMPT_FILE="$(mktemp "${GAWD_STATE_ROOT}/refiner-prompt-XXXXXX.txt")"
trap 'rm -f -- "$PROMPT_FILE"' EXIT

{
    cat "${PROMPT_TEMPLATE}"
    printf '\n\n---\n\n## Polish Instructions\n\n%s\n' "${TASK_DESCRIPTION}"
    if [[ -n "${INJECTED_CONTEXT}" ]]; then
        printf '\n## Content to Refine\n\n%s\n' "${INJECTED_CONTEXT}"
    fi
} > "${PROMPT_FILE}"

RESPONSE="$(dispatch_demigawd_call "${TIER}" "${PROMPT_FILE}" 2500)" || {
    write_result_failed "${TASK_ID}" "refiner: dispatch failed (tier=${TIER})"
    exit 0
}

if [[ -z "${RESPONSE}" ]]; then
    write_result_failed "${TASK_ID}" "refiner: model returned empty response"
    exit 0
}

write_result_complete "${TASK_ID}" "${RESPONSE}"
exit 0
