#!/usr/bin/env bash
# logger.sh — Structured JSON-lines logger for the Gawd daemon.
#
# Source-as-library contract:
#   source /usr/local/lib/gawd/observability/logger.sh
#   log_info  observability "gawd booted"
#   log_warn  envelope-monitor "rss 2900 MB exceeds 80% of 3584 MB budget"
#   log_error dispatch "primary model returned 401; falling through chain"
#
# Each call emits one JSON object per line to stdout. The container runtime
# (Docker / journald / etc.) captures stdout, so we do NOT write log files
# ourselves. Hosted-rung deployments pipe to a central log aggregator
# (out of scope for D3 — flagged for ops).
#
# Spec ref: D3 (observability), gospel §1 principle 5 (no secrets), gospel §12.
#
# No-secrets discipline:
#   - The logger NEVER serialises arbitrary objects; it formats fixed fields.
#   - Callers must not pass token values, API keys, or any secret material
#     in the message string. We do basic stripping (see _logger_strip_secrets)
#     as belt-and-suspenders, but the contract is on the caller.

if [[ -n "${__GAWD_LOGGER_LOADED:-}" ]]; then
    return 0
fi
__GAWD_LOGGER_LOADED=1

# Identity fields populated at first log call; override via env if needed.
: "${GAWD_ID:=${HOSTNAME:-unknown}}"
: "${GAWD_RUNG:=unknown}"

# Patterns to redact if a caller accidentally leaks. Cheap belt-and-suspenders;
# do NOT rely on this — fix the caller.
__GAWD_LOGGER_REDACT_PATTERNS=(
    'sk-ant-[a-zA-Z0-9_-]{8,}'
    'sk-[a-zA-Z0-9]{20,}'
    'AKIA[0-9A-Z]{16}'
    'ghp_[a-zA-Z0-9]{20,}'
    'xox[baprs]-[a-zA-Z0-9-]{10,}'
    'bot[0-9]{8,}:[A-Za-z0-9_-]{30,}'
)

_logger_strip_secrets() {
    local msg="$1"
    local pat
    for pat in "${__GAWD_LOGGER_REDACT_PATTERNS[@]}"; do
        # sed -E with portable BRE-ish; this is best-effort, not crypto.
        msg="$(printf '%s' "$msg" | sed -E "s/${pat}/[REDACTED]/g")"
    done
    printf '%s' "$msg"
}

# ISO-8601 UTC timestamp with milliseconds when GNU date supports it.
_logger_ts() {
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ
}

# _log <severity> <source> <message...>
_log() {
    local sev="$1"; shift
    local src="$1"; shift
    local msg="$*"

    # Strip known secret patterns defensively.
    msg="$(_logger_strip_secrets "$msg")"

    # Emit JSON line. jq -c -n is the safe path — it handles quoting + control chars.
    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg ts "$(_logger_ts)" \
            --arg sev "$sev" \
            --arg src "$src" \
            --arg msg "$msg" \
            --arg gid "$GAWD_ID" \
            --arg rng "$GAWD_RUNG" \
            '{ts:$ts, severity:$sev, source:$src, gawd_id:$gid, rung:$rng, message:$msg}'
    else
        # Fallback: hand-built JSON if jq unavailable (rare on Linux). Manually
        # escape backslashes and quotes; do NOT support full JSON escape rules.
        local esc="$msg"
        esc="${esc//\\/\\\\}"
        esc="${esc//\"/\\\"}"
        printf '{"ts":"%s","severity":"%s","source":"%s","gawd_id":"%s","rung":"%s","message":"%s"}\n' \
            "$(_logger_ts)" "$sev" "$src" "$GAWD_ID" "$GAWD_RUNG" "$esc"
    fi
}

log_info()  { _log info  "${1:-unknown}" "${@:2}"; }
log_warn()  { _log warn  "${1:-unknown}" "${@:2}"; }
log_error() { _log error "${1:-unknown}" "${@:2}"; }
log_debug() {
    # Suppressed unless GAWD_LOG_DEBUG=1; debug stays out of prod log volume.
    [[ "${GAWD_LOG_DEBUG:-0}" == "1" ]] || return 0
    _log debug "${1:-unknown}" "${@:2}"
}

# If executed directly, emit a smoke line — handy in tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_info logger "logger.sh smoke test"
fi
