#!/usr/bin/env bash
# skills/scribe/skill.sh — The Scribe DemiGawd.
#
# Purpose: Write a complete document from a brief — finished, not draft.
#          Returns the full document text, ready to use.
#
# Contract (per demigawd-runtime.md §12):
#   $1 = TASK_ID           (required; assigned by spawn_demigawd)
#   $2 = TASK_DESCRIPTION  (required; the document brief: format, voice, subject)
#   $3 = INJECTED_CONTEXT  (optional; source material, outlines, reference docs)
#
# Tier: exalted (long-form writing requires full reasoning; cloud mid-tier)
#
# Output: write_result_complete → TASK_ID.result with completed document string.
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

TIER="exalted"

PROMPT_TEMPLATE="${SKILL_DIR}/prompt.md"

PROMPT_FILE="$(mktemp "${GAWD_STATE_ROOT}/scribe-prompt-XXXXXX.txt")"
trap 'rm -f -- "$PROMPT_FILE"' EXIT

{
    cat "${PROMPT_TEMPLATE}"
    printf '\n\n---\n\n## Brief\n\n%s\n' "${TASK_DESCRIPTION}"
    if [[ -n "${INJECTED_CONTEXT}" ]]; then
        printf '\n## Reference Material\n\n%s\n' "${INJECTED_CONTEXT}"
    fi
} > "${PROMPT_FILE}"

RESPONSE="$(dispatch_demigawd_call "${TIER}" "${PROMPT_FILE}" 3000)" || {
    write_result_failed "${TASK_ID}" "scribe: dispatch failed (tier=${TIER})"
    exit 0
}

if [[ -z "${RESPONSE}" ]]; then
    write_result_failed "${TASK_ID}" "scribe: model returned empty response"
    exit 0
fi

write_result_complete "${TASK_ID}" "${RESPONSE}"
exit 0
