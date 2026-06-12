#!/usr/bin/env bash
# on-terminal-error.sh — Immediate hook fired the instant a terminal-error
# event lands. Invoked by the gateway hook (if OpenClaw supports one) OR by
# the L7 watchdog when it sees a fresh wedge.
#
# Two-step orchestration:
#   1. IMMEDIATELY emit the L6 `stuck-state` signal so the engine can send
#      the static fallback ("I am hiccuping...") within seconds.
#      Engine call may be done in-process via the L6 engine.sh CLI or
#      lazily by the engine's own poll — either way, the marker is on disk
#      well under the 30s silence threshold.
#   2. Defer the actual session-clear to recover.sh. We do NOT clear inline
#      because clear is a state mutation that should be the last word, and
#      because OpenClaw may still emit retry events for ~1s after the
#      terminal-error message. recover.sh runs ON THE NEXT MESSAGE or at
#      next sweep — either path gives the runtime a moment to settle.
#
# Optionally we ALSO call the L6 engine inline (when --invoke-engine is
# passed) so the static fallback is on the Prophit's screen before this
# script returns. That keeps latency-to-fallback at ~milliseconds rather
# than at the engine's next poll cycle. Default: don't invoke engine
# inline — engine reads the signal marker itself.
#
# Usage:
#   on-terminal-error.sh --session-id <uuid> [--channel <ch>] [--prophit <id>]
#                        [--reason <r>] [--invoke-engine] [--dry-run]
#
# When --channel + --prophit are provided AND --invoke-engine is set, this
# script calls L6 engine.sh stuck-state synchronously. Otherwise it only
# writes the signal marker; engine picks it up on its next read.
#
# Exit codes:
#   0  hook fired (marker emitted; engine invoked if requested)
#   1  hook fired with engine-invoke failure (marker still emitted)
#   2  infra error (signal emission failed)
#
# Spec: §19.1 silence-avoidance, §19.2 Layer 4 + Layer 6 integration.

set -uo pipefail

SR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SR_DIR}/lib/common.sh"

ENGINE_SH="${SR_DIR}/../engine.sh"

usage() {
    cat <<'EOF'
on-terminal-error.sh — fast terminal-error hook.

USAGE:
  on-terminal-error.sh --session-id <uuid> [--channel <ch>] [--prophit <id>]
                       [--reason <reason>] [--invoke-engine] [--dry-run]

EXIT CODES:
  0  marker emitted (engine invoked if requested)
  1  engine-invoke failed (marker still emitted)
  2  marker emission failed
EOF
}

sid=""
channel=""
prophit=""
reason=""
invoke_engine=0
dry=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id)    sid="${2:-}"; shift 2 ;;
        --channel)       channel="${2:-}"; shift 2 ;;
        --prophit)       prophit="${2:-}"; shift 2 ;;
        --reason)        reason="${2:-}"; shift 2 ;;
        --invoke-engine) invoke_engine=1; shift ;;
        --dry-run)       dry=1; export SR_DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ -z "$sid" ]]; then
    sr_log_error "on-terminal-error: --session-id required"
    exit 2
fi

# Best-effort key resolution; can be empty if the session is brand-new
# or already retired. The signal marker tolerates empty session_key.
key="$(sr_index_key_for_session_id "$sid" 2>/dev/null || true)"

# Build diagnostic. We try to pull from the index when possible (more
# accurate); fall back to the inline --reason flag.
diag="{}"
if [[ -n "$key" ]]; then
    diag="$(sr_diagnostic_for_key "$key")"
fi
if [[ -n "$reason" ]]; then
    diag="$(printf '%s' "$diag" | jq -c \
        --arg r "$reason" \
        '. + {terminal_error: $r}')"
fi

# Step 1: emit `stuck-state` signal. This is the durable record that L6
# reads on next poll or message-arrival.
if ! sr_emit_signal "stuck-state" "$sid" "$key" "$diag"; then
    sr_log_error "on-terminal-error: signal emission failed sid=${sid}"
    sr_log_recovery "$sid" "$key" "stuck-state-signaled" "error" '{"phase":"signal-stuck"}'
    exit 2
fi
sr_log_recovery "$sid" "$key" "stuck-state-signaled" "ok" "$diag"
sr_log_info "stuck-state signal emitted sid=${sid} reason=${reason:-unspecified}"

# Step 2: optionally invoke L6 engine inline for sub-second latency.
engine_rc=0
if [[ $invoke_engine -eq 1 ]]; then
    if [[ -z "$channel" || -z "$prophit" ]]; then
        sr_log_warn "on-terminal-error: --invoke-engine requires --channel and --prophit; skipping inline engine call"
        engine_rc=2
    elif [[ ! -x "$ENGINE_SH" ]]; then
        sr_log_warn "on-terminal-error: L6 engine.sh not present at ${ENGINE_SH}; relying on signal marker"
        engine_rc=2
    else
        engine_flags=("stuck-state" "--channel" "$channel" "--prophit" "$prophit")
        if [[ $dry -eq 1 ]]; then
            engine_flags+=("--dry-run")
        fi
        if "$ENGINE_SH" "${engine_flags[@]}" >/dev/null 2>&1; then
            sr_log_info "L6 engine called inline channel=${channel} prophit=${prophit}"
        else
            engine_rc=$?
            sr_log_warn "L6 engine inline call failed rc=${engine_rc} — marker still on disk"
        fi
    fi
fi

if [[ $engine_rc -ne 0 && $invoke_engine -eq 1 ]]; then
    exit 1
fi
exit 0
