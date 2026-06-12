#!/usr/bin/env bash
# skills/memory-recall/skill.sh — Memory Recall skill (deterministic, not LLM-dispatched).
#
# Purpose: Fan out to all memory tiers (T1 lossless-claw, T2 focus_briefs,
#          T3a memory-core, T3b wiki), rank, dedup, budget-fit, and return
#          ONE provenance-tagged block to the caller.
#
# Contract (per demigawd-runtime.md §12):
#   $1 = TASK_ID      (required; assigned by spawn_demigawd)
#   $2 = QUERY        (required — the recall query string)
#   $3 = BUDGET       (optional — approximate token budget, default 2000)
#
# Output:
#   - writes ${TASK_ID}.result via write_result_complete_obj (DemiGawd runtime path)
#   - ALSO prints the skill envelope JSON to stdout (direct/non-DemiGawd path)
#   Both paths are always taken so this skill works in both invocation contexts.
#
# Do NOT call OpenClaw, dispatch_demigawd_call, or any LLM.
# This skill is deterministic.

set -uo pipefail

TASK_ID="${1:?TASK_ID required}"
QUERY="${2:?QUERY required (arg 2)}"
BUDGET="${3:-2000}"

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_LIB_DIR="${SKILL_DIR}/../../runtime/lib"

# shellcheck source=../../runtime/lib/json-result.sh
source "${RUNTIME_LIB_DIR}/json-result.sh"

RECALL_BIN="/usr/local/lib/gawd/memory/memory_recall.sh"

if [[ ! -x "$RECALL_BIN" ]]; then
    FAIL='{"status":"failed","entries":[],"tokens_used":0,"error":"recall binary not found: '"$RECALL_BIN"'"}'
    echo "$FAIL"
    write_result_failed "${TASK_ID}" "recall binary not found: ${RECALL_BIN}"
    exit 0
fi

# Shell out to the deterministic recall executable.
RESULT="$(bash "$RECALL_BIN" "$QUERY" "$BUDGET" 2>/dev/null)" \
    || RESULT='{"entries":[],"tokens_used":0}'

# Build the skill output envelope.
ENVELOPE="$(python3 -c "
import sys, json
raw = sys.argv[1]
try:
    r = json.loads(raw)
    entries = r.get('entries', [])
    tokens_used = r.get('tokens_used', 0)
    note = r.get('note', None)
    out = {'status': 'complete', 'entries': entries, 'tokens_used': tokens_used}
    if note:
        out['note'] = note
    print(json.dumps(out))
except Exception as e:
    print(json.dumps({'status': 'failed', 'entries': [], 'tokens_used': 0, 'error': str(e)}))
" "$RESULT")"

# Print to stdout for direct (non-DemiGawd) callers.
echo "$ENVELOPE"

# Write result file for DemiGawd runtime (spawn_demigawd + demigawd-await).
# write_result_complete_obj wraps the envelope as {"status":"complete","output":<obj>,"error":null}
write_result_complete_obj "${TASK_ID}" "${ENVELOPE}"
