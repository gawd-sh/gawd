#!/usr/bin/env bash
# privacy-hook.sh — Placeholder hook for §17.4 (data ownership / privacy policy).
#
# Why this file exists in v1:
#   Spec §17.4 is deferred — the privacy policy that governs what an ops
#   operator may read of a Prophit's data hasn't been written yet. But every
#   observability call site that touches Prophit-adjacent state (logs, metrics
#   labels, error envelopes) needs to call ONE hook today, so that when §17.4
#   lands we bind the policy in one place and enforce it everywhere.
#
# The architectural commitment is: "Bind once, enforce everywhere."
# When §17.4 ships, this file becomes the enforcement point. Until then,
# it is a no-op shim that records that the hook fired.
#
# Contract:
#   privacy_hook <event> <data_kind>
#
#   <event>     = string ID for the event (e.g., "log_emit", "metric_label",
#                 "ops_telegram_alert"). Free-form; consumed by policy when bound.
#   <data_kind> = coarse classification of what data is in scope. Allowed
#                 values (extend in §17.4):
#                   public           - non-sensitive (versions, counts)
#                   ops_only         - infra metadata (rung, gawd_id)
#                   prophit_adjacent - related to the Prophit but not their
#                                      message content (chat_id presence,
#                                      activity counters)
#                   prophit_content  - actual user content; v1 should
#                                      NEVER pass this kind to telemetry
#
# Return code is currently always 0 (allow). Future §17.4 implementations
# may return non-zero for "deny" — callers MUST check the return code and
# treat non-zero as "do not emit this data."
#
# Usage in caller:
#   if privacy_hook "ops_telegram_alert" "ops_only"; then
#       send_telegram_alert "..."
#   fi

if [[ -n "${__GAWD_PRIVACY_HOOK_LOADED:-}" ]]; then
    return 0
fi
__GAWD_PRIVACY_HOOK_LOADED=1

if ! declare -F log_info >/dev/null; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
fi

# Allowed data kinds. Caller MUST pass one of these; anything else is an
# architectural violation and we log a warning. We still return 0 to avoid
# breaking sites that haven't been updated, but the warning is the trip wire.
__GAWD_PRIVACY_ALLOWED_KINDS=(public ops_only prophit_adjacent prophit_content)

_privacy_kind_valid() {
    local k="$1" allowed
    for allowed in "${__GAWD_PRIVACY_ALLOWED_KINDS[@]}"; do
        [[ "$k" == "$allowed" ]] && return 0
    done
    return 1
}

# privacy_hook <event> <data_kind>
# v1 behavior: log that the hook fired; ALWAYS return 0.
# v2 behavior (when §17.4 lands): consult policy file; may return non-zero.
privacy_hook() {
    local event="${1:-unknown_event}"
    local kind="${2:-unknown_kind}"

    if ! _privacy_kind_valid "$kind"; then
        log_warn privacy-hook "invalid data_kind=${kind} for event=${event}; allowed: ${__GAWD_PRIVACY_ALLOWED_KINDS[*]}"
        # Still allow in v1; flag the violation for §17.4 design notes.
    fi

    # v1 belt-and-suspenders: refuse to emit prophit_content even with the
    # shim in no-op mode. This is the one rule v1 enforces — content of a
    # Prophit's message must never reach telemetry. Logs of "the Prophit
    # sent a message" are fine; the message text is not.
    if [[ "$kind" == "prophit_content" ]]; then
        log_warn privacy-hook "denied prophit_content emission for event=${event} (v1 default)"
        return 1
    fi

    if [[ "${GAWD_LOG_DEBUG:-0}" == "1" ]]; then
        log_debug privacy-hook "fired event=${event} kind=${kind} (v1 no-op)"
    fi

    return 0
}

# Smoke test when run directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    privacy_hook "smoke" "public" && echo "privacy_hook smoke: public OK"
    privacy_hook "smoke" "prophit_content" || echo "privacy_hook smoke: prophit_content denied (expected)"
    privacy_hook "smoke" "bogus" && echo "privacy_hook smoke: bogus kind allowed-with-warning (expected)"
fi
