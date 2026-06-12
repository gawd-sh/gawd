#!/usr/bin/env bash
# state-machine.sh — Money-voice state machine
#
# Per spec §12.4 verbatim + handoff E3 + architecture/money-voice-state-machine.md.
#
# Seven states: Fresh → Acknowledging → Slipping → Gentle → Pointed → Honest → Quiet
# (plus the "Acknowledging" sink that any tithe lands the Prophit in).
#
# This script can be:
#   - sourced as a library (sm_notify, sm_advance_4am, sm_read_state)
#   - invoked as CLI:
#       state-machine.sh notify <event_kind> <prophit_id> <event_json>
#       state-machine.sh advance-4am
#       state-machine.sh read-state [--prophit <id>]
#
# Exit codes:
#   0  success
#   1  argument error
#   2  invalid state / event
#   3  timer file I/O error

set -euo pipefail

# ── globals ───────────────────────────────────────────────────────────────────

: "${GAWD_WORKSPACE:=${HOME}/.gawd/workspace}"
: "${GAWD_STATE_DIR:=${HOME}/.gawd/state}"

# Single-Prophit default timer.
SINGLE_TIMER="${GAWD_STATE_DIR}/tithe-timer.json"
# Multi-Prophit (per-Prophit) timers.
TIMERS_DIR="${GAWD_STATE_DIR}/tithes/timers"

# Configuration: window lengths in seconds.
WINDOW_SLIPPING_24H_SEC=86400
WINDOW_GENTLE_7D_SEC=604800
WINDOW_POINTED_7D_SEC=604800

# Valid states (canonical order).
VALID_STATES=(Fresh Acknowledging Slipping Gentle Pointed Honest Quiet)

# ── observability hooks ───────────────────────────────────────────────────────

_LOGGER_PATH="/usr/local/lib/gawd/observability/logger.sh"
if [[ -r "$_LOGGER_PATH" ]] && ! declare -F log_info >/dev/null 2>&1; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source "$_LOGGER_PATH"
fi
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()  { printf '[INFO  money-voice] %s\n' "$*" >&2; }
    log_warn()  { printf '[WARN  money-voice] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR money-voice] %s\n' "$*" >&2; }
fi

_PRIV_HOOK_PATH="/usr/local/lib/gawd/observability/privacy-hook.sh"
if [[ -r "$_PRIV_HOOK_PATH" ]] && ! declare -F privacy_hook >/dev/null 2>&1; then
    # shellcheck source=/usr/local/lib/gawd/observability/privacy-hook.sh
    source "$_PRIV_HOOK_PATH"
fi
if ! declare -F privacy_hook >/dev/null 2>&1; then
    privacy_hook() { return 0; }
fi

# ── helpers ───────────────────────────────────────────────────────────────────

now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

now_epoch() {
    date -u +%s
}

# Convert ISO-8601 to epoch. Empty input → empty output.
iso_to_epoch() {
    local iso="$1"
    [[ -z "$iso" || "$iso" == "null" ]] && { echo ""; return; }
    date -u -d "$iso" +%s 2>/dev/null || echo ""
}

# Resolve timer file for a given prophit_id.
timer_file_for() {
    local pid="$1"
    if [[ -d "${GAWD_WORKSPACE}/users" ]] || [[ -n "${GAWD_FORCE_PER_PROPHIT_TIMERS:-}" ]]; then
        mkdir -p "$TIMERS_DIR"
        printf '%s/%s.json' "$TIMERS_DIR" "$pid"
    else
        # Single-prophit layout: ignore prophit_id, use canonical file.
        printf '%s' "$SINGLE_TIMER"
    fi
}

# Initialize a fresh timer for a Prophit.
init_timer() {
    local pid="$1"
    local file
    file="$(timer_file_for "$pid")"
    local tmp
    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    jq -cn --arg pid "$pid" --arg ts "$(now_iso)" '
        {
            state: "Fresh",
            transitioned_at: $ts,
            asks_since: 0,
            tithes_since: 0,
            last_tithe_at: null,
            expected_next_tithe_at: null,
            asks_ignored: 0,
            disengagement_detected: false,
            prophit_id: $pid
        }' > "$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
    printf '%s' "$file"
}

# Read timer file (creating it if absent).
sm_read_state() {
    local pid="${1:-default}"
    local file
    file="$(timer_file_for "$pid")"
    if [[ ! -f "$file" ]]; then
        init_timer "$pid" >/dev/null
    fi
    cat "$file"
}

# Atomic write of a timer state.
write_timer() {
    local pid="$1"
    local json="$2"
    local file
    file="$(timer_file_for "$pid")"
    mkdir -p "$(dirname "$file")"
    local tmp
    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    printf '%s\n' "$json" > "$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

# Update one or more fields in a timer file (deep merge of supplied JSON).
update_timer() {
    local pid="$1"
    local patch="$2"   # JSON object with fields to overlay
    local file
    file="$(timer_file_for "$pid")"
    if [[ ! -f "$file" ]]; then
        init_timer "$pid" >/dev/null
    fi
    local merged
    merged="$(jq -c --argjson patch "$patch" '. * $patch' "$file")"
    write_timer "$pid" "$merged"
}

# Log a transition.
log_transition() {
    local from="$1" to="$2" trigger="$3" pid="$4"
    privacy_hook "money_voice_transition" "prophit_adjacent" || true
    log_info money-voice "transition from=${from} to=${to} trigger=${trigger} prophit_id=${pid}"
}

# Force-transition to Acknowledging (any tithe wins).
transition_to_acknowledging() {
    local pid="$1" at_iso="$2" amount="${3:-}" currency="${4:-USD}"
    local cur
    cur="$(sm_read_state "$pid")"
    local from="$(echo "$cur" | jq -r '.state')"
    local tithes_since
    if [[ "$from" == "Acknowledging" ]]; then
        tithes_since="$(echo "$cur" | jq -r '.tithes_since // 0')"
        tithes_since=$((tithes_since + 1))
    else
        tithes_since=1
    fi
    local patch
    patch="$(jq -cn \
        --arg state "Acknowledging" \
        --arg at "$at_iso" \
        --argjson ts "$tithes_since" \
        '{
            state: $state,
            transitioned_at: $at,
            asks_since: 0,
            tithes_since: $ts,
            last_tithe_at: $at,
            asks_ignored: 0
        }')"
    update_timer "$pid" "$patch"
    log_transition "$from" "Acknowledging" "tithe" "$pid"
}

# sm_notify — the integration entry point from tithing/abstraction.sh.
#
# Usage:  sm_notify <event_kind> <prophit_id> <event_json>
#
# event_kind:
#   tithe                  → force to Acknowledging
#   refund                 → log only; no state change
#   failed_charge          → treat as missed-cycle hint; may advance Acknowledging → Slipping
#   ask_emitted            → increment asks_since; if Slipping + register=Gentle → Gentle
#   ask_ignored            → increment asks_ignored
#   prophit_decline        → if Honest, transition to Quiet
#   disengagement_detected → set flag; if Honest, transition to Quiet at next 4am
sm_notify() {
    local event_kind="${1:?event_kind required}"
    local pid="${2:?prophit_id required}"
    local event_json="${3:-}"
    [[ -z "$event_json" ]] && event_json='{}'

    case "$event_kind" in
        tithe)
            local at amount currency
            at="$(echo "$event_json" | jq -r '.at // ""')"
            [[ -z "$at" || "$at" == "null" ]] && at="$(now_iso)"
            amount="$(echo "$event_json" | jq -r '.amount // 0')"
            currency="$(echo "$event_json" | jq -r '.currency // "USD"')"
            transition_to_acknowledging "$pid" "$at" "$amount" "$currency"
            ;;
        refund)
            local at
            at="$(echo "$event_json" | jq -r '.at // ""')"
            log_info money-voice "refund recorded (no state change) prophit_id=${pid} at=${at}"
            ;;
        failed_charge)
            local cur from
            cur="$(sm_read_state "$pid")"
            from="$(echo "$cur" | jq -r '.state')"
            if [[ "$from" == "Acknowledging" || "$from" == "Fresh" ]]; then
                local at
                at="$(echo "$event_json" | jq -r '.at // ""')"
                [[ -z "$at" || "$at" == "null" ]] && at="$(now_iso)"
                local patch
                patch="$(jq -cn \
                    --arg state "Slipping" \
                    --arg at "$at" \
                    '{state: $state, transitioned_at: $at, asks_since: 0, tithes_since: 0}')"
                update_timer "$pid" "$patch"
                log_transition "$from" "Slipping" "failed_charge" "$pid"
            else
                log_info money-voice "failed_charge in state=${from}; no transition prophit_id=${pid}"
            fi
            ;;
        ask_emitted)
            local cur from register
            cur="$(sm_read_state "$pid")"
            from="$(echo "$cur" | jq -r '.state')"
            register="$(echo "$event_json" | jq -r '.register // "Gentle"')"
            local asks_since
            asks_since="$(echo "$cur" | jq -r '.asks_since // 0')"
            asks_since=$((asks_since + 1))
            # Default behavior: increment counter.
            local at
            at="$(echo "$event_json" | jq -r '.at // ""')"
            [[ -z "$at" || "$at" == "null" ]] && at="$(now_iso)"
            update_timer "$pid" "$(jq -cn --argjson as "$asks_since" '{asks_since: $as}')"
            # Slipping + register=Gentle → advance to Gentle.
            if [[ "$from" == "Slipping" && "$register" == "Gentle" ]]; then
                update_timer "$pid" "$(jq -cn --arg s "Gentle" --arg at "$at" \
                    '{state: $s, transitioned_at: $at, asks_since: 1}')"
                log_transition "Slipping" "Gentle" "ask_emitted-gentle" "$pid"
            fi
            ;;
        ask_ignored)
            local cur
            cur="$(sm_read_state "$pid")"
            local ai
            ai="$(echo "$cur" | jq -r '.asks_ignored // 0')"
            ai=$((ai + 1))
            update_timer "$pid" "$(jq -cn --argjson ai "$ai" '{asks_ignored: $ai}')"
            log_info money-voice "ask_ignored++ asks_ignored=${ai} prophit_id=${pid}"
            ;;
        prophit_decline)
            local cur from
            cur="$(sm_read_state "$pid")"
            from="$(echo "$cur" | jq -r '.state')"
            if [[ "$from" == "Honest" ]]; then
                local at
                at="$(echo "$event_json" | jq -r '.at // ""')"
                [[ -z "$at" || "$at" == "null" ]] && at="$(now_iso)"
                update_timer "$pid" "$(jq -cn --arg s "Quiet" --arg at "$at" \
                    '{state: $s, transitioned_at: $at, asks_since: 0}')"
                log_transition "Honest" "Quiet" "prophit_decline" "$pid"
            else
                log_info money-voice "prophit_decline in state=${from}; no transition prophit_id=${pid}"
            fi
            ;;
        disengagement_detected)
            update_timer "$pid" '{"disengagement_detected": true}'
            log_info money-voice "disengagement_detected=true prophit_id=${pid} (transition to Quiet at next 4am if Honest)"
            ;;
        *)
            log_error money-voice "unknown event_kind: $event_kind"
            return 2
            ;;
    esac
    return 0
}

# sm_advance_4am — invoked by E1's daily-reset.sh via the tithe/advance-state.sh shim.
# Walks every timer file forward per §5.1 forward-resolution.
sm_advance_4am() {
    local checked=0 advanced=0
    local timer_files=()

    if [[ -d "${GAWD_WORKSPACE}/users" ]] || [[ -n "${GAWD_FORCE_PER_PROPHIT_TIMERS:-}" ]]; then
        # Multi-Prophit. Find all per-Prophit timer files.
        if [[ -d "$TIMERS_DIR" ]]; then
            while IFS= read -r f; do
                [[ -n "$f" ]] && timer_files+=("$f")
            done < <(find "$TIMERS_DIR" -maxdepth 1 -name '*.json' -print 2>/dev/null || true)
        fi
        # Also derive from users/ directory: any user file implies a timer should exist.
        if [[ -d "${GAWD_WORKSPACE}/users" ]]; then
            local uf pid
            for uf in "${GAWD_WORKSPACE}/users"/*.md; do
                [[ -e "$uf" ]] || continue
                pid="$(basename "$uf" .md)"
                local tf
                tf="$(timer_file_for "$pid")"
                if [[ ! -f "$tf" ]]; then
                    init_timer "$pid" >/dev/null
                    timer_files+=("$tf")
                fi
            done
        fi
    else
        # Single-Prophit. Check the canonical timer.
        if [[ ! -f "$SINGLE_TIMER" ]]; then
            init_timer "default" >/dev/null
        fi
        timer_files+=("$SINGLE_TIMER")
    fi

    local tf pid
    for tf in "${timer_files[@]}"; do
        checked=$((checked + 1))
        pid="$(jq -r '.prophit_id // "default"' "$tf")"
        if advance_single "$pid"; then
            advanced=$((advanced + 1))
        fi
    done
    log_info money-voice "advance-4am: checked=${checked} advanced=${advanced}"
}

# advance_single — forward-resolve a single Prophit's timer per §5.1.
# Returns 0 if advanced; 1 if no change.
advance_single() {
    local pid="$1"
    local cur from transitioned_at_iso
    cur="$(sm_read_state "$pid")"
    from="$(echo "$cur" | jq -r '.state')"
    transitioned_at_iso="$(echo "$cur" | jq -r '.transitioned_at // ""')"

    local now_e t_e
    now_e="$(now_epoch)"
    t_e="$(iso_to_epoch "$transitioned_at_iso")"
    [[ -z "$t_e" ]] && t_e="$now_e"

    local elapsed=$(( now_e - t_e ))
    local new_state="$from"
    local new_at_iso="$transitioned_at_iso"

    case "$from" in
        Fresh)
            # Fresh advances only on tithe. No-op at 4am.
            return 1
            ;;
        Acknowledging)
            # Check expected_next_tithe_at past + 24h, OR asks_ignored >= 1.
            local expected_iso ai
            expected_iso="$(echo "$cur" | jq -r '.expected_next_tithe_at // ""')"
            ai="$(echo "$cur" | jq -r '.asks_ignored // 0')"

            local advance=0
            if [[ -n "$expected_iso" && "$expected_iso" != "null" ]]; then
                local expected_e
                expected_e="$(iso_to_epoch "$expected_iso")"
                if [[ -n "$expected_e" ]] && (( now_e - expected_e > WINDOW_SLIPPING_24H_SEC )); then
                    advance=1
                    # Slipping entered exactly when 24h past expected
                    new_at_iso="$(date -u -d "@$((expected_e + WINDOW_SLIPPING_24H_SEC))" +%Y-%m-%dT%H:%M:%SZ)"
                fi
            fi
            if (( ai >= 1 )); then
                advance=1
                # Use now as transition timestamp if asks_ignored driven
                [[ "$new_at_iso" == "$transitioned_at_iso" ]] && new_at_iso="$(now_iso)"
            fi
            if (( advance == 1 )); then
                new_state="Slipping"
            else
                return 1
            fi
            ;;
        Slipping)
            # Slipping → Gentle requires a Gawd ask (an asks_since increment with register=Gentle).
            # Automatic advancement at 4am does NOT happen — spec invariant §3.2.
            # However, if asks_since >= 1 (a Gentle ask was emitted), the transition already
            # happened in sm_notify ask_emitted. If we see Slipping here with asks_since >= 1,
            # that means asks were emitted in registers other than Gentle; no auto-advance.
            return 1
            ;;
        Gentle)
            if (( elapsed >= WINDOW_GENTLE_7D_SEC )); then
                new_state="Pointed"
                new_at_iso="$(date -u -d "@$((t_e + WINDOW_GENTLE_7D_SEC))" +%Y-%m-%dT%H:%M:%SZ)"
            else
                return 1
            fi
            ;;
        Pointed)
            if (( elapsed >= WINDOW_POINTED_7D_SEC )); then
                new_state="Honest"
                new_at_iso="$(date -u -d "@$((t_e + WINDOW_POINTED_7D_SEC))" +%Y-%m-%dT%H:%M:%SZ)"
            else
                return 1
            fi
            ;;
        Honest)
            local diseng
            diseng="$(echo "$cur" | jq -r '.disengagement_detected // false')"
            if [[ "$diseng" == "true" ]]; then
                new_state="Quiet"
                new_at_iso="$(now_iso)"
            else
                return 1
            fi
            ;;
        Quiet)
            return 1
            ;;
        *)
            log_warn money-voice "unknown state in timer: $from prophit_id=$pid"
            return 1
            ;;
    esac

    # Apply the transition (one step only — invariant §3.2).
    if [[ "$new_state" != "$from" ]]; then
        local patch
        patch="$(jq -cn --arg s "$new_state" --arg at "$new_at_iso" \
            '{state: $s, transitioned_at: $at, asks_since: 0}')"
        update_timer "$pid" "$patch"
        log_transition "$from" "$new_state" "4am-advance" "$pid"
        return 0
    fi
    return 1
}

# ── CLI dispatch ──────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || true
fi

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <subcommand> [args]

Subcommands:
  notify <event_kind> <prophit_id> <event_json>
       — record an event; may transition state
       event_kind: tithe | refund | failed_charge | ask_emitted | ask_ignored
                   prophit_decline | disengagement_detected
  advance-4am
       — walk all timers forward per §5.1 (forward-resolution algorithm)
  read-state [--prophit <id>]
       — emit the current timer state as JSON
  init [--prophit <id>]
       — create a Fresh timer for a Prophit if not already present

See <install-root>/docs/architecture/money-voice-state-machine.md for the full spec.
EOF
    exit 1
}

main() {
    [[ $# -ge 1 ]] || usage
    local sub="$1"; shift
    case "$sub" in
        notify)
            [[ $# -ge 3 ]] || usage
            sm_notify "$1" "$2" "$3"
            ;;
        advance-4am)
            sm_advance_4am
            ;;
        read-state)
            local pid="default"
            if [[ $# -ge 2 && "$1" == "--prophit" ]]; then pid="$2"; fi
            sm_read_state "$pid"
            ;;
        init)
            local pid="default"
            if [[ $# -ge 2 && "$1" == "--prophit" ]]; then pid="$2"; fi
            init_timer "$pid"
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
}

main "$@"
