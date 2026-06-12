#!/usr/bin/env bash
# skills/smoke-noop/skill.sh — reference no-op DemiGawd for the smoke test.
#
# Demonstrates the full skill author contract:
#   - Args: $1 TASK_ID, $2 TASK_DESCRIPTION, $3 INJECTED_CONTEXT
#   - Writes JSON to ${GAWD_STATE_ROOT}/${TASK_ID}.result via write_result_*
#   - Exits 0 (the result file's status field communicates success/failure,
#     not the exit code — the parent has already detached at this point).
#
# This skill exists so the runtime smoke test can prove the spawn→await→
# cleanup loop without depending on any external service (LLM, browser, …).

set -euo pipefail

TASK_ID="${1:?TASK_ID required}"
TASK_DESCRIPTION="${2:-}"
INJECTED_CONTEXT="${3:-}"

# shellcheck source=../../lib/json-result.sh
source "$(cd "$(dirname "$0")" && pwd)/../../lib/json-result.sh"

# The "work" is a one-line echo. Real DemiGawds do model calls, browser
# automation, etc. The contract surface is identical.
OUTPUT="hello from smoke-noop: $TASK_DESCRIPTION"

write_result_complete "$TASK_ID" "$OUTPUT"
exit 0
