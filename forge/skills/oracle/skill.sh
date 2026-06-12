#!/usr/bin/env bash
# skills/oracle/skill.sh — The Oracle DemiGawd.
#
# Purpose: Synthesize across multiple sources into a verdict. Not a summary;
#          a synthesis — what the material says, what it implies, what the answer is.
#
# Contract (per demigawd-runtime.md §12):
#   $1 = TASK_ID           (required; assigned by spawn_demigawd)
#   $2 = TASK_DESCRIPTION  (required; describes what to synthesize and from where)
#   $3 = INJECTED_CONTEXT  (optional; the source material to synthesize across)
#
# Tier: exalted (cross-task synthesis; cloud mid-tier; see C1 §12 and dispatch.sh)
#
# Output: write_result_complete → TASK_ID.result with synthesized verdict string.
#
# Do NOT modify SOUL.md, IDENTITY.md, VOICE.md, or any T0 anchor.
# Do NOT call OpenClaw directly; use dispatch_demigawd_call.

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

# Build the prompt from the skill's template and the caller's inputs.
PROMPT_TEMPLATE="${SKILL_DIR}/prompt.md"

# Write an ephemeral prompt file for this task (cleaned up on exit).
PROMPT_FILE="$(mktemp "${GAWD_STATE_ROOT}/oracle-prompt-XXXXXX.txt")"
trap 'rm -f -- "$PROMPT_FILE"' EXIT

{
    cat "${PROMPT_TEMPLATE}"
    printf '\n\n---\n\n## Task\n\n%s\n' "${TASK_DESCRIPTION}"
    if [[ -n "${INJECTED_CONTEXT}" ]]; then
        printf '\n## Source Material\n\n%s\n' "${INJECTED_CONTEXT}"
    fi
} > "${PROMPT_FILE}"

# Dispatch to the exalted-tier model. On dispatch failure, write a failed result.
RESPONSE="$(dispatch_demigawd_call "${TIER}" "${PROMPT_FILE}" 1500)" || {
    write_result_failed "${TASK_ID}" "oracle: dispatch failed (tier=${TIER})"
    exit 0
}

if [[ -z "${RESPONSE}" ]]; then
    write_result_failed "${TASK_ID}" "oracle: model returned empty response"
    exit 0
fi

write_result_complete "${TASK_ID}" "${RESPONSE}"
exit 0
