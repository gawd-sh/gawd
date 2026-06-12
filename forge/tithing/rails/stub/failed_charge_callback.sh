#!/usr/bin/env bash
# stub rails plugin — failed_charge_callback.sh
#
# Accepts a synthetic webhook payload and emits a success response. Used by F3
# tests to simulate the webhook path. Does NOT call the abstraction layer's
# failed_charge directly — that's the receiver's job (the webhook server),
# which extracts recurring_id + prophit_id and calls into abstraction.sh.

set -euo pipefail

payload="$(cat)"
recurring_id="$(echo "$payload" | jq -r '.recurring_id // .data.subscription.id // ""')"
prophit_id="$(echo "$payload" | jq -r '.prophit_id // .data.customer.metadata.prophit_id // ""')"

if [[ -z "$recurring_id" || -z "$prophit_id" ]]; then
    jq -cn '{ok: false, error_kind: "invalid_args", detail: "stub: could not extract recurring_id/prophit_id from payload", retryable: false}'
    exit 1
fi

jq -cn --arg rid "$recurring_id" --arg pid "$prophit_id" \
    '{ok: true, recurring_id: $rid, prophit_id: $pid, action: "notified"}'
exit 0
