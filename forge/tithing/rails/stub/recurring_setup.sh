#!/usr/bin/env bash
# stub rails plugin — recurring_setup.sh
#
# Persists recurring schedules to a local JSONL file so recurring_status can
# read them back. Not a real subscription.

set -euo pipefail

: "${GAWD_STATE_DIR:=${HOME}/.gawd/state}"
RECUR_FILE="${GAWD_STATE_DIR}/stub-recurring.jsonl"
mkdir -p "$(dirname "$RECUR_FILE")"

payload="$(cat)"
prophit_id="$(echo "$payload" | jq -r '.prophit_id // ""')"
amount="$(echo "$payload" | jq -r '.amount // 0')"
currency="$(echo "$payload" | jq -r '.currency // "USD"')"
cadence="$(echo "$payload" | jq -r '.cadence // "monthly"')"

if [[ -z "$prophit_id" || "$amount" == "0" || "$amount" == "null" ]]; then
    jq -cn '{ok: false, error_kind: "invalid_args", detail: "stub: missing prophit_id or amount", retryable: false}'
    exit 1
fi

case "$cadence" in
    weekly)  delta="+7 days" ;;
    monthly) delta="+30 days" ;;
    annual)  delta="+365 days" ;;
    *) jq -cn '{ok: false, error_kind: "invalid_args", detail: "stub: bad cadence", retryable: false}'; exit 1 ;;
esac

next_at="$(date -u -d "$delta" +%Y-%m-%dT%H:%M:%SZ)"
recur_id="stub-recur-$(date +%s)-${RANDOM}"

entry="$(jq -cn \
    --arg rid "$recur_id" \
    --arg pid "$prophit_id" \
    --argjson amt "$amount" \
    --arg cur "$currency" \
    --arg cad "$cadence" \
    --arg next "$next_at" \
    --arg status "active" \
    '{recurring_id: $rid, prophit_id: $pid, amount: $amt, currency: $cur, cadence: $cad, status: $status, next_charge_at: $next}')"

{
    flock -x 9
    printf '%s\n' "$entry" >> "$RECUR_FILE"
} 9>"${RECUR_FILE}.lock"

jq -cn --arg rid "$recur_id" --arg status "active" --arg next "$next_at" \
    '{ok: true, recurring_id: $rid, status: $status, next_charge_at: $next}'
exit 0
