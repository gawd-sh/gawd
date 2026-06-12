#!/usr/bin/env bash
# stub rails plugin — record_tithe.sh
#
# Synthetic no-op rails implementation. Used by F3 validation and offline dev.
# NOT a production rails. Stubs always return success with a synthetic txn id.

set -euo pipefail

payload="$(cat)"
amount="$(echo "$payload" | jq -r '.amount // 0')"
currency="$(echo "$payload" | jq -r '.currency // "USD"')"
prophit_id="$(echo "$payload" | jq -r '.prophit_id // "unknown"')"

if [[ "$amount" == "0" ]] || [[ "$amount" == "null" ]]; then
    jq -cn '{ok: false, error_kind: "invalid_amount", detail: "stub: amount missing or zero", retryable: false}'
    exit 1
fi

txn_id="stub-txn-$(date +%s)-${RANDOM}"

jq -cn --arg t "$txn_id" '{ok: true, rails_txn_id: $t, rails_status: "succeeded"}'
exit 0
