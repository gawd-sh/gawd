#!/usr/bin/env bash
# stub rails plugin — refund.sh (optional but implemented for stub)
#
# Accepts a refund request and emits a success response with a synthetic refund id.

set -euo pipefail

payload="$(cat)"
txn_id="$(echo "$payload" | jq -r '.rails_txn_id // ""')"
reason="$(echo "$payload" | jq -r '.reason // ""')"

if [[ -z "$txn_id" ]]; then
    jq -cn '{ok: false, error_kind: "invalid_args", detail: "stub: missing rails_txn_id", retryable: false}'
    exit 1
fi

refund_id="stub-refund-$(date +%s)-${RANDOM}"
jq -cn --arg rid "$refund_id" --arg status "succeeded" \
    '{ok: true, refund_id: $rid, status: $status}'
exit 0
