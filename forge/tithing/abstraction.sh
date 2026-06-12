#!/usr/bin/env bash
# abstraction.sh — Tithing abstraction layer entry point.
#
# Per spec §12 + handoff E3 + architecture/tithing-abstraction.md.
#
# This script is the public API for all tithing-related operations. It:
#   - resolves the active rails plugin from ~/.gawd/state/active-rails.txt
#   - validates incoming requests
#   - writes ledger entries
#   - notifies the money-voice state machine
#   - delegates rails-specific operations to the plugin
#
# All public functions are exposed as subcommands (process / refund / history /
# aggregate / level / setup-recurring / status-recurring / cost-advisor /
# set-declaration / failed-charge). The subcommand surface is the API contract.
#
# Source-as-library is supported for callers within the Gawd runtime:
#   source /usr/local/lib/gawd/tithing/abstraction.sh
#   tithe_process amount=25 currency=USD prophit_id=paul
#
# Source-as-library exposes the functions tithe_process / tithe_refund / etc.
#
# Exit codes (CLI mode):
#   0  success
#   1  argument error
#   2  rails plugin missing or invalid
#   3  validation failed
#   4  ledger write failed
#   5  rails call failed

set -euo pipefail

# ── globals ───────────────────────────────────────────────────────────────────

: "${GAWD_WORKSPACE:=${HOME}/.gawd/workspace}"
: "${GAWD_STATE_DIR:=${HOME}/.gawd/state}"

LEDGER_DIR="${GAWD_STATE_DIR}/tithes"
LEDGER_PATH="${LEDGER_DIR}/ledger.jsonl"
ORPHANS_PATH="${LEDGER_DIR}/ledger.orphans.jsonl"
ACTIVE_RAILS_FILE="${GAWD_STATE_DIR}/active-rails.txt"
RAILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rails"

# Threshold defaults (annual rolling USD-equivalent). See tithing-abstraction.md §3.1.
LEVEL_BELIEVER_THRESHOLD=1
LEVEL_DEVOTED_THRESHOLD=50
LEVEL_DISCIPLE_THRESHOLD=200
LEVEL_APOSTLE_THRESHOLD=1000
LEVEL_SAINT_THRESHOLD=5000
LEVEL_ARCHANGEL_THRESHOLD=20000

# ── observability hooks ───────────────────────────────────────────────────────

# Self-locating observability paths (H-2 fix, phase4-20260609).
# Prefer env override, then install-relative sibling (../observability/), then
# canonical in-image path (/usr/local/lib/gawd/observability/). Replaces
# /usr/local/lib/gawd/ hardcodes which do not exist on a Prophit's machine.
_TITHING_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_OBS_SIBLING="${_TITHING_SCRIPT_DIR}/../observability"
_OBS_CANONICAL="/usr/local/lib/gawd/observability"

_LOGGER_PATH="${GAWD_LOGGER_PATH:-}"
if [[ -z "$_LOGGER_PATH" ]]; then
    if [[ -r "${_OBS_SIBLING}/logger.sh" ]]; then
        _LOGGER_PATH="${_OBS_SIBLING}/logger.sh"
    elif [[ -r "${_OBS_CANONICAL}/logger.sh" ]]; then
        _LOGGER_PATH="${_OBS_CANONICAL}/logger.sh"
    fi
fi
if [[ -r "$_LOGGER_PATH" ]]; then
    # shellcheck source=../observability/logger.sh
    source "$_LOGGER_PATH"
else
    log_info()  { printf '[INFO  tithe] %s\n' "$*" >&2; }
    log_warn()  { printf '[WARN  tithe] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR tithe] %s\n' "$*" >&2; }
fi

_PRIV_HOOK_PATH="${GAWD_PRIVACY_HOOK_PATH:-}"
if [[ -z "$_PRIV_HOOK_PATH" ]]; then
    if [[ -r "${_OBS_SIBLING}/privacy-hook.sh" ]]; then
        _PRIV_HOOK_PATH="${_OBS_SIBLING}/privacy-hook.sh"
    elif [[ -r "${_OBS_CANONICAL}/privacy-hook.sh" ]]; then
        _PRIV_HOOK_PATH="${_OBS_CANONICAL}/privacy-hook.sh"
    fi
fi
if [[ -r "$_PRIV_HOOK_PATH" ]]; then
    # shellcheck source=../observability/privacy-hook.sh
    source "$_PRIV_HOOK_PATH"
else
    privacy_hook() { return 0; }
fi

# ── state machine integration ────────────────────────────────────────────────

_STATE_MACHINE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state-machine.sh"
if [[ -r "$_STATE_MACHINE_PATH" ]]; then
    # shellcheck source=/usr/local/lib/gawd/tithing/state-machine.sh
    source "$_STATE_MACHINE_PATH"
else
    log_warn tithe "state machine library not found at ${_STATE_MACHINE_PATH} — sm_notify will be a no-op"
    sm_notify() { return 0; }
fi

# Ensure ledger dir exists.
mkdir -p "$LEDGER_DIR"
chmod 0700 "$LEDGER_DIR" 2>/dev/null || true

# ── helpers ───────────────────────────────────────────────────────────────────

now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Generate a ledger entry id. Prefer uuidgen if available, else use sha256 of
# timestamp + nanosecond random.
new_ledger_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        printf '%s-%s' "$(date +%s%N)" "$$" | sha256sum | awk '{print substr($1,1,16)}'
    fi
}

# Resolve the active rails plugin name. Defaults to 'stub'.
active_rails() {
    if [[ -f "$ACTIVE_RAILS_FILE" ]]; then
        cat "$ACTIVE_RAILS_FILE" | tr -d '[:space:]'
    else
        echo "stub"
    fi
}

# Path to a rails plugin script.
rails_script() {
    local rails="$1" script="$2"
    echo "${RAILS_DIR}/${rails}/${script}.sh"
}

# Validate a rails plugin is loadable.
rails_validate() {
    local rails="$1"
    local manifest="${RAILS_DIR}/${rails}/plugin.json"
    if [[ ! -f "$manifest" ]]; then
        return 1
    fi
    for required in record_tithe recurring_setup recurring_status failed_charge_callback; do
        if [[ ! -x "$(rails_script "$rails" "$required")" ]]; then
            log_warn tithe "rails plugin '${rails}' missing required script: ${required}.sh"
            return 1
        fi
    done
    return 0
}

# Emit a JSON ledger entry. Returns the ledger_entry_id on stdout on success.
write_ledger_entry() {
    local kind="$1" amount="$2" currency="$3" prophit_id="$4" rails_plugin="$5"
    local rails_txn_id="$6" recurring_id="${7:-null}"
    local metadata="${8:-}"
    [[ -z "$metadata" ]] && metadata='{}'

    local id="$(new_ledger_id)"
    local ts="$(now_iso)"

    # Build the entry as a single JSON line.
    local line
    if command -v jq >/dev/null 2>&1; then
        line="$(jq -cn \
            --arg id "$id" \
            --arg ts "$ts" \
            --arg pid "$prophit_id" \
            --argjson amt "$amount" \
            --arg cur "$currency" \
            --arg kind "$kind" \
            --arg rails "$rails_plugin" \
            --arg txn "$rails_txn_id" \
            --arg recur "$recurring_id" \
            --argjson meta "$metadata" \
            '{
                ledger_entry_id: $id,
                timestamp: $ts,
                prophit_id: $pid,
                amount: $amt,
                currency: $cur,
                kind: $kind,
                rails_plugin: $rails,
                rails_txn_id: $txn,
                recurring_id: (if $recur == "null" then null else $recur end),
                metadata: $meta
            }')"
    else
        log_error tithe "jq required for ledger write; aborting"
        return 4
    fi

    # Append atomically (write to tmp, mv, then append? No — for jsonl, we want
    # an atomic single-line append. >> is atomic for small writes on most
    # filesystems; we accept that and rely on the journald-style append model.
    {
        flock -x 9
        printf '%s\n' "$line" >> "$LEDGER_PATH"
    } 9>"${LEDGER_PATH}.lock"

    chmod 0600 "$LEDGER_PATH" 2>/dev/null || true
    chmod 0600 "${LEDGER_PATH}.lock" 2>/dev/null || true

    printf '%s\n' "$id"
}

# Write an orphan ledger entry when prophit_id is unknown.
write_orphan_entry() {
    local kind="$1" amount="$2" currency="$3" rails_plugin="$4"
    local rails_txn_id="$5" recurring_id="${6:-null}"
    local metadata="${7:-}"
    [[ -z "$metadata" ]] && metadata='{}'

    local id="$(new_ledger_id)"
    local ts="$(now_iso)"

    local line
    line="$(jq -cn \
        --arg id "$id" \
        --arg ts "$ts" \
        --argjson amt "$amount" \
        --arg cur "$currency" \
        --arg kind "$kind" \
        --arg rails "$rails_plugin" \
        --arg txn "$rails_txn_id" \
        --arg recur "$recurring_id" \
        --argjson meta "$metadata" \
        '{
            ledger_entry_id: $id,
            timestamp: $ts,
            amount: $amt,
            currency: $cur,
            kind: $kind,
            rails_plugin: $rails,
            rails_txn_id: $txn,
            recurring_id: (if $recur == "null" then null else $recur end),
            metadata: $meta,
            orphan: true
        }')"

    {
        flock -x 9
        printf '%s\n' "$line" >> "$ORPHANS_PATH"
    } 9>"${ORPHANS_PATH}.lock"

    chmod 0600 "$ORPHANS_PATH" 2>/dev/null || true
    printf '%s\n' "$id"
}

# ── public API: tithe_process ────────────────────────────────────────────────

tithe_process() {
    local amount="" currency="USD" recurring="false" cadence=""
    local source="tip" prophit_id="" metadata="{}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            amount=*)      amount="${1#*=}"; shift ;;
            currency=*)    currency="${1#*=}"; shift ;;
            recurring=*)   recurring="${1#*=}"; shift ;;
            cadence=*)     cadence="${1#*=}"; shift ;;
            source=*)      source="${1#*=}"; shift ;;
            prophit_id=*)  prophit_id="${1#*=}"; shift ;;
            metadata=*)    metadata="${1#*=}"; shift ;;
            *) log_error tithe "tithe_process: unknown arg $1"; return 1 ;;
        esac
    done

    if [[ -z "$amount" ]]; then
        log_error tithe "tithe_process: amount required"
        return 1
    fi
    if ! [[ "$amount" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        log_error tithe "tithe_process: amount must be numeric (got: $amount)"
        return 3
    fi
    if [[ -z "$prophit_id" ]]; then
        log_error tithe "tithe_process: prophit_id required"
        return 1
    fi

    privacy_hook "tithe_process" "prophit_adjacent" || true

    local rails="$(active_rails)"
    if ! rails_validate "$rails"; then
        log_warn tithe "rails '${rails}' invalid; falling back to 'stub'"
        rails="stub"
        if ! rails_validate "$rails"; then
            log_error tithe "no valid rails plugin available (not even stub)"
            return 2
        fi
    fi

    local rails_txn_id="manual-$(date +%s)"
    if [[ "$source" == "tip" || "$source" == "recurring-charge" ]]; then
        local payload
        payload="$(jq -cn \
            --argjson amt "$amount" \
            --arg cur "$currency" \
            --arg src "$source" \
            --arg pid "$prophit_id" \
            --argjson meta "$metadata" \
            '{amount: $amt, currency: $cur, source: $src, prophit_id: $pid, metadata: $meta}')"
        local rails_out
        if rails_out="$(echo "$payload" | "$(rails_script "$rails" "record_tithe")" 2>&1)"; then
            rails_txn_id="$(echo "$rails_out" | jq -r '.rails_txn_id // "unknown"')"
        else
            log_error tithe "rails record_tithe failed: $rails_out"
            return 5
        fi
    fi

    local kind="$source"
    if [[ "$source" == "tip" ]]; then kind="tip"; fi
    if [[ "$source" == "recurring-charge" ]]; then kind="recurring-charge"; fi
    if [[ "$source" == "manual" ]]; then kind="manual"; fi
    if [[ "$source" == "refund" ]]; then kind="refund"; fi
    if [[ "$source" == "chargeback" ]]; then kind="chargeback"; fi

    local entry_id
    entry_id="$(write_ledger_entry "$kind" "$amount" "$currency" "$prophit_id" "$rails" "$rails_txn_id" "null" "$metadata")"

    log_info tithe "process: prophit_id=${prophit_id} amount=${amount} ${currency} kind=${kind} entry_id=${entry_id} rails=${rails}"

    # Notify the money-voice state machine.
    local event_kind="tithe"
    if [[ "$kind" == "refund" ]]; then event_kind="refund"; fi
    if [[ "$kind" == "chargeback" ]]; then event_kind="refund"; fi  # chargeback treated as refund for state-machine purposes
    local sm_event_label="$event_kind"
    local sm_rc=0
    sm_notify "$event_kind" "$prophit_id" "$(jq -cn \
        --argjson amt "$amount" --arg cur "$currency" --arg ts "$(now_iso)" \
        '{amount: $amt, currency: $cur, at: $ts}')" || sm_rc=$?
    if [[ $sm_rc -ne 0 ]]; then
        log_error tithe "sm_notify failed rc=${sm_rc} event_kind=${event_kind} prophit_id=${prophit_id}"
        sm_event_label="FAILED:${sm_rc}"
    fi

    # Emit a compact JSON receipt for callers.
    local level_after
    level_after="$(tithe_get_level prophit_id="$prophit_id" 2>/dev/null || echo "Believer")"
    jq -cn \
        --arg id "$entry_id" \
        --arg level "$level_after" \
        --arg sme "$sm_event_label" \
        '{ok: true, ledger_entry_id: $id, level_after: $level, state_machine_event: $sme}'
    return 0
}

# ── public API: tithe_refund ─────────────────────────────────────────────────

tithe_refund() {
    local ledger_entry_id="" reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            ledger_entry_id=*) ledger_entry_id="${1#*=}"; shift ;;
            reason=*)          reason="${1#*=}"; shift ;;
            *) log_error tithe "tithe_refund: unknown arg $1"; return 1 ;;
        esac
    done

    [[ -n "$ledger_entry_id" ]] || { log_error tithe "tithe_refund: ledger_entry_id required"; return 1; }
    [[ -n "$reason" ]]          || { log_error tithe "tithe_refund: reason required"; return 1; }

    privacy_hook "tithe_refund" "prophit_adjacent" || true

    # Look up the original entry.
    local original
    if ! [[ -f "$LEDGER_PATH" ]]; then
        log_error tithe "ledger does not exist; cannot refund"
        return 3
    fi
    original="$(grep -F "\"ledger_entry_id\":\"${ledger_entry_id}\"" "$LEDGER_PATH" | head -1)"
    if [[ -z "$original" ]]; then
        log_error tithe "refund: original ledger entry not found: $ledger_entry_id"
        return 3
    fi

    local amount currency prophit_id rails_plugin rails_txn_id
    amount="$(echo "$original" | jq -r '.amount')"
    currency="$(echo "$original" | jq -r '.currency')"
    prophit_id="$(echo "$original" | jq -r '.prophit_id')"
    rails_plugin="$(echo "$original" | jq -r '.rails_plugin')"
    rails_txn_id="$(echo "$original" | jq -r '.rails_txn_id')"

    # Delegate to rails refund script if available.
    local rails_refund_script
    rails_refund_script="$(rails_script "$rails_plugin" "refund")"
    if [[ ! -x "$rails_refund_script" ]]; then
        log_warn tithe "rails '${rails_plugin}' does not implement refund.sh — local-only refund record"
        rails_refund_script=""
    fi

    if [[ -n "$rails_refund_script" ]]; then
        local refund_payload refund_out
        refund_payload="$(jq -cn --arg txn "$rails_txn_id" --arg reason "$reason" '{rails_txn_id: $txn, reason: $reason}')"
        if ! refund_out="$(echo "$refund_payload" | "$rails_refund_script" 2>&1)"; then
            log_error tithe "rails refund call failed: $refund_out"
            return 5
        fi
    fi

    # Write negative ledger entry.
    local neg_amount="-${amount}"
    if [[ "$amount" == -* ]]; then
        # Already negative? Shouldn't happen for an original tithe but be defensive.
        neg_amount="${amount#-}"
    fi

    local refund_metadata
    refund_metadata="$(jq -cn --arg origin "$ledger_entry_id" --arg reason "$reason" \
        '{refunded_ledger_entry_id: $origin, reason: $reason}')"

    local refund_id
    refund_id="$(write_ledger_entry "refund" "$neg_amount" "$currency" "$prophit_id" "$rails_plugin" "${rails_txn_id}-refund" "null" "$refund_metadata")"

    log_info tithe "refund: original=${ledger_entry_id} amount=${neg_amount} reason=${reason} refund_id=${refund_id}"

    local sm_rc=0
    sm_notify "refund" "$prophit_id" "$(jq -cn --arg ts "$(now_iso)" --arg cur "$currency" --argjson amt "$neg_amount" \
        '{amount: $amt, currency: $cur, at: $ts}')" || sm_rc=$?
    if [[ $sm_rc -ne 0 ]]; then
        log_error tithe "sm_notify failed rc=${sm_rc} event_kind=refund prophit_id=${prophit_id}"
    fi

    jq -cn --arg id "$refund_id" --arg sme "$([ $sm_rc -eq 0 ] && echo refund || echo "FAILED:${sm_rc}")" \
        '{ok: true, refund_id: $id, state_machine_event: $sme}'
    return 0
}

# ── public API: tithe_list_history ───────────────────────────────────────────

tithe_list_history() {
    local prophit_id="" limit=20
    while [[ $# -gt 0 ]]; do
        case "$1" in
            prophit_id=*) prophit_id="${1#*=}"; shift ;;
            limit=*)      limit="${1#*=}"; shift ;;
            *) log_error tithe "tithe_list_history: unknown arg $1"; return 1 ;;
        esac
    done
    [[ -n "$prophit_id" ]] || { log_error tithe "prophit_id required"; return 1; }

    privacy_hook "tithe_history_read" "prophit_adjacent" || true

    if [[ ! -f "$LEDGER_PATH" ]]; then
        echo "[]"
        return 0
    fi

    # Newest first, limited.
    grep -F "\"prophit_id\":\"${prophit_id}\"" "$LEDGER_PATH" 2>/dev/null \
        | tac \
        | head -n "$limit" \
        | jq -s '.'
}

# ── public API: tithe_aggregate ──────────────────────────────────────────────

tithe_aggregate() {
    local prophit_id="" window="365d"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            prophit_id=*) prophit_id="${1#*=}"; shift ;;
            window=*)     window="${1#*=}"; shift ;;
            *) log_error tithe "tithe_aggregate: unknown arg $1"; return 1 ;;
        esac
    done
    [[ -n "$prophit_id" ]] || { log_error tithe "prophit_id required"; return 1; }

    privacy_hook "tithe_aggregate_read" "prophit_adjacent" || true

    if [[ ! -f "$LEDGER_PATH" ]]; then
        echo '{"total_amount": 0, "total_count": 0, "currency_breakdown": {}, "recurring_active": false}'
        return 0
    fi

    # Compute window cutoff.
    local cutoff
    case "$window" in
        30d)  cutoff="$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)" ;;
        90d)  cutoff="$(date -u -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ)" ;;
        365d) cutoff="$(date -u -d '365 days ago' +%Y-%m-%dT%H:%M:%SZ)" ;;
        all)  cutoff="1970-01-01T00:00:00Z" ;;
        *) log_error tithe "tithe_aggregate: invalid window '$window'"; return 1 ;;
    esac

    grep -F "\"prophit_id\":\"${prophit_id}\"" "$LEDGER_PATH" 2>/dev/null \
        | jq -s --arg cutoff "$cutoff" '
            map(select(.timestamp >= $cutoff))
            | {
                total_count: length,
                currency_breakdown: (group_by(.currency) | map({(.[0].currency): map(.amount) | add}) | add // {}),
                total_amount: (map(.amount) | add // 0)
            }'
}

# ── public API: tithe_get_level ──────────────────────────────────────────────

tithe_get_level() {
    local prophit_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            prophit_id=*) prophit_id="${1#*=}"; shift ;;
            *) log_error tithe "tithe_get_level: unknown arg $1"; return 1 ;;
        esac
    done
    [[ -n "$prophit_id" ]] || { log_error tithe "prophit_id required"; return 1; }

    local agg total_usd
    agg="$(tithe_aggregate prophit_id="$prophit_id" window=365d 2>/dev/null)"
    # USD-equivalent: only count USD for simple v1; multi-currency aggregates
    # are reported by aggregate but level lookup uses declared base currency.
    total_usd="$(echo "$agg" | jq -r '.currency_breakdown.USD // 0')"

    if   (( $(echo "$total_usd >= $LEVEL_ARCHANGEL_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        echo "Archangel"
    elif (( $(echo "$total_usd >= $LEVEL_SAINT_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        echo "Saint"
    elif (( $(echo "$total_usd >= $LEVEL_APOSTLE_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        echo "Apostle"
    elif (( $(echo "$total_usd >= $LEVEL_DISCIPLE_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        echo "Disciple"
    elif (( $(echo "$total_usd >= $LEVEL_DEVOTED_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        echo "Devoted"
    elif (( $(echo "$total_usd >= $LEVEL_BELIEVER_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        echo "Believer"
    else
        echo "null"
    fi
}

# ── public API: tithe_cost_advisor (stub) ────────────────────────────────────

tithe_cost_advisor() {
    local prophit_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            prophit_id=*) prophit_id="${1#*=}"; shift ;;
            *) log_error tithe "tithe_cost_advisor: unknown arg $1"; return 1 ;;
        esac
    done
    [[ -n "$prophit_id" ]] || { log_error tithe "prophit_id required"; return 1; }

    privacy_hook "cost_advisor_invoke" "prophit_content" || true

    # v1: returns empty advice list when no Prophit-supplied subscription data
    # exists. The actual recommendation logic is a DemiGawd skill (Oracle).
    echo "[]"
}

# ── public API: tithe_failed_charge ──────────────────────────────────────────

tithe_failed_charge() {
    local recurring_id="" prophit_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            recurring_id=*) recurring_id="${1#*=}"; shift ;;
            prophit_id=*)   prophit_id="${1#*=}"; shift ;;
            *) log_error tithe "tithe_failed_charge: unknown arg $1"; return 1 ;;
        esac
    done
    [[ -n "$recurring_id" ]] || { log_error tithe "recurring_id required"; return 1; }
    [[ -n "$prophit_id" ]] || { log_error tithe "prophit_id required"; return 1; }

    privacy_hook "rails_failed_charge" "prophit_adjacent" || true

    local rails="$(active_rails)"
    local entry_id
    entry_id="$(write_ledger_entry "recurring-charge-failed" "0" "USD" "$prophit_id" "$rails" "${recurring_id}-fail" "$recurring_id" \
        "$(jq -cn --arg rid "$recurring_id" '{recurring_id: $rid}')")"

    log_warn tithe "failed_charge recorded: recurring_id=${recurring_id} prophit_id=${prophit_id} entry=${entry_id}"

    local sm_rc=0
    sm_notify "failed_charge" "$prophit_id" "$(jq -cn --arg rid "$recurring_id" --arg ts "$(now_iso)" \
        '{recurring_id: $rid, at: $ts}')" || sm_rc=$?
    if [[ $sm_rc -ne 0 ]]; then
        log_error tithe "sm_notify failed rc=${sm_rc} event_kind=failed_charge prophit_id=${prophit_id}"
    fi

    jq -cn --arg id "$entry_id" --arg sme "$([ $sm_rc -eq 0 ] && echo failed_charge || echo "FAILED:${sm_rc}")" \
        '{ok: true, entry_id: $id, state_machine_event: $sme}'
    return 0
}

# ── public API: tithe_recurring_setup ────────────────────────────────────────

tithe_recurring_setup() {
    local prophit_id="" amount="" currency="USD" cadence=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            prophit_id=*) prophit_id="${1#*=}"; shift ;;
            amount=*)     amount="${1#*=}"; shift ;;
            currency=*)   currency="${1#*=}"; shift ;;
            cadence=*)    cadence="${1#*=}"; shift ;;
            *) log_error tithe "tithe_recurring_setup: unknown arg $1"; return 1 ;;
        esac
    done
    [[ -n "$prophit_id" && -n "$amount" && -n "$cadence" ]] \
        || { log_error tithe "prophit_id, amount, cadence required"; return 1; }

    privacy_hook "rails_recurring_setup" "prophit_adjacent" || true

    local rails="$(active_rails)"
    rails_validate "$rails" || { log_error tithe "rails invalid: $rails"; return 2; }

    local payload
    payload="$(jq -cn \
        --arg pid "$prophit_id" \
        --argjson amt "$amount" \
        --arg cur "$currency" \
        --arg cad "$cadence" \
        '{prophit_id: $pid, amount: $amt, currency: $cur, cadence: $cad}')"

    echo "$payload" | "$(rails_script "$rails" "recurring_setup")"
}

# ── public API: tithe_recurring_status ───────────────────────────────────────

tithe_recurring_status() {
    local prophit_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            prophit_id=*) prophit_id="${1#*=}"; shift ;;
            *) log_error tithe "tithe_recurring_status: unknown arg $1"; return 1 ;;
        esac
    done
    [[ -n "$prophit_id" ]] || { log_error tithe "prophit_id required"; return 1; }

    privacy_hook "rails_recurring_status" "prophit_adjacent" || true

    local rails="$(active_rails)"
    rails_validate "$rails" || { log_error tithe "rails invalid: $rails"; return 2; }

    local payload
    payload="$(jq -cn --arg pid "$prophit_id" '{prophit_id: $pid}')"
    echo "$payload" | "$(rails_script "$rails" "recurring_status")"
}

# ── CLI dispatch ──────────────────────────────────────────────────────────────

# If sourced as library, do not dispatch.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || true
fi

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <subcommand> [key=value ...]

Subcommands:
  process            amount=<n> currency=<ISO> prophit_id=<id> [source=tip|...] [recurring=true|false]
  refund             ledger_entry_id=<id> reason=<text>
  history            prophit_id=<id> [limit=20]
  aggregate          prophit_id=<id> [window=30d|90d|365d|all]
  level              prophit_id=<id>
  setup-recurring    prophit_id=<id> amount=<n> currency=<ISO> cadence=weekly|monthly|annual
  status-recurring   prophit_id=<id>
  cost-advisor       prophit_id=<id>
  failed-charge      recurring_id=<id> prophit_id=<id>

See <install-root>/docs/architecture/tithing-abstraction.md for the full API spec.
EOF
    exit 1
}

main() {
    [[ $# -ge 1 ]] || usage
    local sub="$1"; shift
    case "$sub" in
        process)          tithe_process "$@" ;;
        refund)           tithe_refund "$@" ;;
        history)          tithe_list_history "$@" ;;
        aggregate)        tithe_aggregate "$@" ;;
        level)            tithe_get_level "$@" ;;
        setup-recurring)  tithe_recurring_setup "$@" ;;
        status-recurring) tithe_recurring_status "$@" ;;
        cost-advisor)     tithe_cost_advisor "$@" ;;
        failed-charge)    tithe_failed_charge "$@" ;;
        -h|--help)        usage ;;
        *)                usage ;;
    esac
}

main "$@"
