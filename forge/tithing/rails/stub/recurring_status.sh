#!/usr/bin/env bash
# stub rails plugin — recurring_status.sh
#
# Reads back from the local recurring-state file.

set -euo pipefail

: "${GAWD_STATE_DIR:=${HOME}/.gawd/state}"
RECUR_FILE="${GAWD_STATE_DIR}/stub-recurring.jsonl"

payload="$(cat)"
prophit_id="$(echo "$payload" | jq -r '.prophit_id // ""')"

if [[ -z "$prophit_id" ]]; then
    jq -cn '{ok: false, error_kind: "invalid_args", detail: "stub: missing prophit_id", retryable: false}'
    exit 1
fi

if [[ ! -f "$RECUR_FILE" ]]; then
    jq -cn '{ok: true, recurring: []}'
    exit 0
fi

jq -s --arg pid "$prophit_id" '
    map(select(.prophit_id == $pid))
    | { ok: true, recurring: . }
' "$RECUR_FILE"
exit 0
