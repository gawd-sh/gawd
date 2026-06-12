#!/usr/bin/env bash
# skills/chronicler/skill.sh — The Chronicler DemiGawd.
#
# Purpose: Reconstruct a timeline or recall what happened from provided context.
#          Sequences events, narrates what occurred, acknowledges gaps honestly.
#
# Contract (per demigawd-runtime.md §12):
#   $1 = TASK_ID           (required; assigned by spawn_demigawd)
#   $2 = TASK_DESCRIPTION  (required; what timeline to reconstruct and from what scope)
#   $3 = INJECTED_CONTEXT  (optional; source material: logs, notes, messages, records)
#
# Tier: blessed (single-source extraction; cloud fast-tier is sufficient)
#
# Output: write_result_complete → TASK_ID.result with timeline narrative string.
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

PROMPT_FILE="$(mktemp "${GAWD_STATE_ROOT}/chronicler-prompt-XXXXXX.txt")"
trap 'rm -f -- "$PROMPT_FILE"' EXIT

{
    cat "${PROMPT_TEMPLATE}"
    printf '\n\n---\n\n## Task\n\n%s\n' "${TASK_DESCRIPTION}"
    if [[ -n "${INJECTED_CONTEXT}" ]]; then
        printf '\n## Source Material\n\n%s\n' "${INJECTED_CONTEXT}"
    fi
} > "${PROMPT_FILE}"

RESPONSE="$(dispatch_demigawd_call "${TIER}" "${PROMPT_FILE}" 1500)" || {
    write_result_failed "${TASK_ID}" "chronicler: dispatch failed (tier=${TIER})"
    exit 0
}

if [[ -z "${RESPONSE}" ]]; then
    write_result_failed "${TASK_ID}" "chronicler: model returned empty response"
    exit 0
fi

write_result_complete "${TASK_ID}" "${RESPONSE}"
exit 0
