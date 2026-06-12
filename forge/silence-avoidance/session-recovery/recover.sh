#!/usr/bin/env bash
# recover.sh — Composite: detect → clear → emit `recovered` signal → log.
#
# This is the script that L7 (watchdog) and the sweep cron call when they
# spot a wedged session. It wraps detect + clear and adds the post-recovery
# signal emission for the L6 engine (which will send the "I'm back"
# template on next message arrival or on its next poll).
#
# Idempotency:
#   - If the session is not wedged, recover.sh returns 0 with a no-op log.
#   - If the session was already cleared, recover.sh returns 0 with a no-op
#     log (the index entry won't exist; clear.sh handles that path).
#   - Running recover.sh twice on the same session is safe.
#
# Usage:
#   recover.sh --session-key <key> [--force] [--dry-run]
#   recover.sh --session-id  <uuid> [--force] [--dry-run]
#
# Exit codes:
#   0   recovered (or already-recovered noop)
#   1   not-wedged refusal (no recovery action needed)
#   2   infra error
#
# Spec: §19.2 Layer 4, §19.6, §19.7 Phase 11 test #2.

set -uo pipefail

SR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SR_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
recover.sh — detect + clear + signal L6 engine.

USAGE:
  recover.sh --session-key <key> [--force] [--dry-run]
  recover.sh --session-id  <uuid> [--force] [--dry-run]

EXIT CODES:
  0  recovered (or already-recovered noop)
  1  refused (not wedged; --force overrides via clear.sh)
  2  infra error
EOF
}

mode=""
arg=""
force=0
dry=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-key) mode="by-key"; arg="${2:-}"; shift 2 ;;
        --session-id)  mode="by-id";  arg="${2:-}"; shift 2 ;;
        --force)       force=1; shift ;;
        --dry-run)     dry=1; export SR_DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ -z "$mode" || -z "$arg" ]]; then
    usage >&2
    exit 2
fi

# Resolve both key and sid up front; we need them for signal emission.
key=""
sid=""
if [[ "$mode" == "by-id" ]]; then
    sid="$arg"
    key="$(sr_index_key_for_session_id "$sid")"
    if [[ -z "$key" ]]; then
        sr_log_info "recover noop: session-id ${sid} not in index (already cleared?)"
        sr_log_recovery "$sid" "" "recovered" "noop" '{"reason":"id-absent"}'
        exit 0
    fi
else
    key="$arg"
    sid="$(sr_index_session_id_for_key "$key")"
    if [[ -z "$sid" ]]; then
        sr_log_info "recover noop: key ${key} not in index (already cleared?)"
        sr_log_recovery "" "$key" "recovered" "noop" '{"reason":"key-absent"}'
        exit 0
    fi
fi

# Idempotency guard (#2): if recovery-log already has a `recovered` entry
# for this sid whose `last_interaction_at_ms` matches or exceeds the
# current index entry's lastInteractionAt, the session has already been
# recovered for THIS wedge. Skip.
if [[ -f "$SR_RECOVERY_LOG" ]]; then
    cur_last_at="$(sr_index_field "$key" "lastInteractionAt")"
    cur_last_at="${cur_last_at:-0}"
    if grep -F "\"$sid\"" "$SR_RECOVERY_LOG" 2>/dev/null \
        | jq -e --arg sid "$sid" --argjson floor "${cur_last_at:-0}" \
            'select(.session_id == $sid)
             | select(.action == "recovered")
             | select(.outcome == "ok" or .outcome == "noop")
             | select((.last_interaction_at_ms // 0) >= $floor)' >/dev/null 2>&1; then
        sr_log_info "recover noop: already-recovered sid=${sid}"
        # Do not append another entry — the previous one is authoritative.
        exit 0
    fi
fi

# Re-check wedge state (unless --force).
if [[ $force -eq 0 ]]; then
    sr_is_session_wedged_by_key "$key"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        case $rc in
            1) sr_log_info "recover noop: session healthy/in-flight key=${key}"
               sr_log_recovery "$sid" "$key" "recovered" "noop" '{"reason":"not-wedged"}'
               exit 1 ;;
            *) sr_log_error "recover refused: wedge status unknown key=${key}"
               sr_log_recovery "$sid" "$key" "recovered" "error" '{"reason":"wedge-unknown"}'
               exit 2 ;;
        esac
    fi
fi

# Capture diagnostic for the signal payload (taken pre-clear).
diag="$(sr_diagnostic_for_key "$key")"

# Delegate the destructive mutation to clear.sh. We pass --force because we
# already re-verified the wedge above.
clear_flags=("--session-key" "$key" "--force")
if [[ $dry -eq 1 ]]; then
    clear_flags+=("--dry-run")
fi
if ! "${SR_DIR}/clear.sh" "${clear_flags[@]}"; then
    rc=$?
    sr_log_error "recover: clear.sh failed rc=${rc} key=${key} sid=${sid}"
    sr_log_recovery "$sid" "$key" "recovered" "error" '{"phase":"clear","child_rc":'"$rc"'}'
    exit 2
fi

# Emit the `recovered` signal for L6. We do this AFTER clear succeeds —
# we never tell L6 "I'm back" if the wedge wasn't actually cleared.
if ! sr_emit_signal "recovered" "$sid" "$key" "$diag"; then
    sr_log_error "recover: signal emission failed for recovered sid=${sid}"
    sr_log_recovery "$sid" "$key" "recovered" "error" '{"phase":"signal-recovered"}'
    exit 2
fi

# Final success log. Include last_interaction_at_ms so the idempotency
# check above can short-circuit subsequent calls.
last_at="$(printf '%s' "$diag" | jq -r '.last_interaction_at_ms // 0' 2>/dev/null || echo 0)"
extras="$(jq -nc \
    --argjson diag "$diag" \
    --argjson lia "${last_at:-0}" \
    '{diagnostic: $diag, last_interaction_at_ms: $lia}')"
sr_log_recovery "$sid" "$key" "recovered" "ok" "$extras"

sr_log_info "recovered: key=${key} sid=${sid}"
exit 0
