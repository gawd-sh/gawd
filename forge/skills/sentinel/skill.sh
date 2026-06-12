#!/usr/bin/env bash
# skills/sentinel/skill.sh — The Sentinel DemiGawd.
#
# Purpose: Scan content for a named condition; returns TRIGGERED or CLEAR plus
#          a brief explanation. Cheap, narrow, single-shot classifier.
#
# Contract (per demigawd-runtime.md §12):
#   $1 = TASK_ID           (required; assigned by spawn_demigawd)
#   $2 = TASK_DESCRIPTION  (required; the condition to scan for — precise definition)
#   $3 = INJECTED_CONTEXT  (optional; the content to scan)
#
# Tier: ordained (single-shot classifier; local 7B sufficient for this task class)
#
# Output: write_result_complete → TASK_ID.result with TRIGGERED/CLEAR + explanation.
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

TIER="ordained"

PROMPT_TEMPLATE="${SKILL_DIR}/prompt.md"

PROMPT_FILE="$(mktemp "${GAWD_STATE_ROOT}/sentinel-prompt-XXXXXX.txt")"
trap 'rm -f -- "$PROMPT_FILE"' EXIT

{
    cat "${PROMPT_TEMPLATE}"
    printf '\n\n---\n\n## Condition to Scan For\n\n%s\n' "${TASK_DESCRIPTION}"
    if [[ -n "${INJECTED_CONTEXT}" ]]; then
        printf '\n## Content to Scan\n\n%s\n' "${INJECTED_CONTEXT}"
    fi
} > "${PROMPT_FILE}"

RESPONSE="$(dispatch_demigawd_call "${TIER}" "${PROMPT_FILE}" 500)" || {
    # Ordained (local) failure — fall back to blessed (cloud fast-tier) before reporting failure.
    RESPONSE="$(dispatch_demigawd_call "blessed" "${PROMPT_FILE}" 500)" || {
        write_result_failed "${TASK_ID}" "sentinel: dispatch failed (ordained and blessed both failed)"
        exit 0
    }
}

if [[ -z "${RESPONSE}" ]]; then
    write_result_failed "${TASK_ID}" "sentinel: model returned empty response"
    exit 0
fi

write_result_complete "${TASK_ID}" "${RESPONSE}"
exit 0
