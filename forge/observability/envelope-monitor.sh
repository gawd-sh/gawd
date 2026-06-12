#!/usr/bin/env bash
# envelope-monitor.sh — Per-rung resource-envelope monitor.
#
# Runs every 5 minutes (cron registered by E1). Reads envelope.json, samples
# current RAM use, and emits warning/alarm signals per the rung's policy:
#
#   hosted     -> hard alerts at 80% AND 100% (Telegram to the operator via GawdFather
#                 inbox tripwire per gospel §12; we own the cost so pre-warn).
#   prophit-vm -> soft warning to Gawd journal only (Prophit owns substrate).
#   bare-metal -> log-only (Prophit's machine, Prophit's call).
#
# Per §14.2.5: "The daemon does not self-terminate; it warns and surfaces."
# This script MUST NOT kill processes, restart services, or alter system state.
#
# Usage:
#   envelope-monitor.sh [--once] [--dry-run]
#     --once     run a single check (default; the cron schedule provides the loop)
#     --dry-run  print would-emit actions, do not write artifacts
#
# Exit codes:
#   0  OK (within budget, or rung has no enforcement)
#   1  warning emitted (>= 80% on hosted/prophit-vm)
#   2  alarm emitted (>= 100% on hosted)
#   3  monitor self-error (envelope.json missing, etc.) — does NOT count as alarm

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/usr/local/lib/gawd/observability/logger.sh
source "$SCRIPT_DIR/logger.sh"
# shellcheck source=/usr/local/lib/gawd/observability/metrics.sh
source "$SCRIPT_DIR/metrics.sh"
# shellcheck source=/usr/local/lib/gawd/observability/privacy-hook.sh
source "$SCRIPT_DIR/privacy-hook.sh"
# shellcheck source=/usr/local/lib/gawd/observability/voice-status.sh
source "$SCRIPT_DIR/voice-status.sh"

: "${GAWD_ENVELOPE_FILE:=$SCRIPT_DIR/envelope.json}"
: "${GAWD_ID:=${HOSTNAME:-unknown}}"
: "${GAWD_RUNG:=unknown}"

# Inbox path for GawdFather alert delivery on hosted rung.
# Per gospel §12, dropping a file here fires the inbox tripwire which surfaces
# to the operator via Telegram. This is the ONLY alert surface for hosted rung.
: "${GAWDFATHER_INBOX:=<install-root>/.openclaw/workspace/inbox/}"

# Deduplication: don't fire the same warn/alarm again within this window.
# Stops the 5-minute cron from flooding the operator during a sustained breach.
: "${GAWD_ENVELOPE_ALARM_COOLDOWN_SEC:=3600}"   # 1 hour
: "${GAWD_ENVELOPE_WARN_COOLDOWN_SEC:=3600}"    # 1 hour
: "${GAWD_ENVELOPE_STATE_DIR:=${GAWD_WORKSPACE_ROOT:-${HOME}/.gawd/workspace}/obs/envelope}"

ONCE=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --once)    ONCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h)
            cat >&2 <<'EOF'
Usage: envelope-monitor.sh [--once] [--dry-run]
EOF
            exit 0 ;;
        *) log_warn envelope-monitor "unknown arg ignored: $1"; shift ;;
    esac
done

mkdir -p "$GAWD_ENVELOPE_STATE_DIR" 2>/dev/null || true

_now_epoch() { date -u +%s; }

# Cooldown check. Returns 0 if it's OK to fire (cooldown elapsed).
_cooldown_ok() {
    local label="$1" window="$2"
    local f="${GAWD_ENVELOPE_STATE_DIR}/last_${label}.epoch"
    [[ -r "$f" ]] || return 0
    local last now
    last="$(cat "$f" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || return 0
    now="$(_now_epoch)"
    (( now - last >= window ))
}

_cooldown_mark() {
    local label="$1"
    local f="${GAWD_ENVELOPE_STATE_DIR}/last_${label}.epoch"
    _now_epoch > "$f"
}

# Read alarm policy fields for the current rung.
_envelope_policy() {
    local rung="$1"
    if [[ ! -r "$GAWD_ENVELOPE_FILE" ]]; then
        log_error envelope-monitor "envelope file not readable: $GAWD_ENVELOPE_FILE"
        echo "log_only"
        return
    fi
    jq -r --arg r "$rung" '.rungs[$r].alarm_policy // "log_only"' "$GAWD_ENVELOPE_FILE" 2>/dev/null \
        || echo "log_only"
}

_envelope_threshold_pct() {
    local rung="$1" level="$2"
    jq -r --arg r "$rung" --arg l "$level" '.rungs[$r][$l] // empty' "$GAWD_ENVELOPE_FILE" 2>/dev/null
}

# Drop a structured alert file into the GawdFather inbox.
# File name format follows the pattern in §4.7 of the gospel.
# Contents: a small markdown brief; no secrets.
_drop_inbox_alert() {
    local level="$1" rss_mb="$2" budget_mb="$3" ratio="$4"

    # Privacy gate: this is ops-only data (rung, budget, RSS).
    privacy_hook "ops_telegram_alert" "ops_only" || {
        log_warn envelope-monitor "privacy hook denied ops_telegram_alert; skipping inbox drop"
        return 0
    }

    if [[ ! -d "$GAWDFATHER_INBOX" ]]; then
        log_warn envelope-monitor "GawdFather inbox missing ($GAWDFATHER_INBOX); cannot drop $level alert"
        return 0
    fi

    local ts file
    ts="$(date -u +%Y%m%d-%H%M%S)"
    file="${GAWDFATHER_INBOX%/}/ALERT-${ts}-envelope-${level}-${GAWD_ID}.md"

    if (( DRY_RUN == 1 )); then
        printf 'DRY-RUN would drop inbox alert: %s\n' "$file"
        return 0
    fi

    cat > "$file" <<EOF
# Envelope Alert — ${level^^}

**From**: envelope-monitor (Gawd: ${GAWD_ID})
**To**: GAWDFATHER (delivers to operator via tripwire)
**Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Rung**: ${GAWD_RUNG}
**Level**: ${level}

## Observation

| Metric | Value |
|---|---|
| Gawd ID | ${GAWD_ID} |
| Rung | ${GAWD_RUNG} |
| Current RSS | ${rss_mb} MB |
| Budget | ${budget_mb} MB |
| Used | ${ratio} |

## Policy

Per §14.2.5: the daemon does NOT self-terminate. This is a surfacing alert,
not an automated remediation.

## Recommended Ops Action

- ${level} ≥80%: investigate within hours; check for memory leak or runaway DemiGawd
- ${level} ≥100%: investigate immediately; consider restarting the Gawd daemon if
  RSS does not drop after the next cleanup cycle. Verify no cascading effect
  on neighbor Gawds on the same host.

## Source

- Snapshot file: ${GAWD_METRICS_FILE:-${GAWD_WORKSPACE_ROOT:-${HOME}/.gawd/workspace}/obs/metrics.prom}
- Envelope config: ${GAWD_ENVELOPE_FILE}
- Spec: §14.2.5 Per-Rung Resource Envelope

EOF
    chmod 0644 "$file" 2>/dev/null || true
    log_info envelope-monitor "dropped inbox alert: $(basename "$file")"
}

# Main check.
main() {
    local rung="$GAWD_RUNG"
    local policy
    policy="$(_envelope_policy "$rung")"

    if [[ "$rung" == "unknown" || "$rung" == "" ]]; then
        log_warn envelope-monitor "GAWD_RUNG not set; falling back to log-only behavior"
        policy="log_only"
    fi

    if [[ ! -r "$GAWD_ENVELOPE_FILE" ]]; then
        log_warn envelope-monitor "envelope file not found at $GAWD_ENVELOPE_FILE; falling back to log-only (bare-metal default)"
        policy="log_only"
    fi

    # Ingest voice status BEFORE snapshot so the gauge + GAWD_VOICE_ACTIVE
    # reflect current state. ingest_voice_status writes the state_num sidecar
    # that _metrics_sample_voice_state reads, and records degradation deltas.
    ingest_voice_status || log_warn envelope-monitor "voice status ingest failed (continuing)"

    # If voice is active, surface that to the budget calc by exporting the
    # flag. envelope.json's voice_relay_extra_mb is then added to the budget.
    if [[ -r "${GAWD_VOICE_DELTA_DIR:-${GAWD_OBS_ROOT}/voice}/active" ]]; then
        local _voice_active
        _voice_active="$(cat "${GAWD_VOICE_DELTA_DIR:-${GAWD_OBS_ROOT}/voice}/active" 2>/dev/null || echo 0)"
        [[ "$_voice_active" == "1" ]] && export GAWD_VOICE_ACTIVE=1
    fi

    # Always take a metrics snapshot — observability is the primary deliverable.
    metrics_snapshot

    # Bare-metal short-circuit: no enforcement, no alerting.
    if [[ "$policy" == "log_only" ]]; then
        log_info envelope-monitor "rung=${rung} policy=log_only (no enforcement)"
        return 0
    fi

    # Sample current state.
    local rss_bytes budget_bytes ratio rss_mb budget_mb
    rss_bytes="$(_metrics_sample_rss_bytes)"
    budget_bytes="$(_metrics_get_budget_bytes)"

    if (( budget_bytes == 0 )); then
        log_info envelope-monitor "rung=${rung} has no budget; nothing to enforce"
        return 0
    fi

    rss_mb=$(( rss_bytes / 1024 / 1024 ))
    budget_mb=$(( budget_bytes / 1024 / 1024 ))
    ratio="$(awk -v r="$rss_bytes" -v b="$budget_bytes" 'BEGIN{ printf "%.1f%%", (r/b)*100 }')"

    local soft hard
    soft="$(_envelope_threshold_pct "$rung" soft_threshold_pct)"
    hard="$(_envelope_threshold_pct "$rung" hard_threshold_pct)"
    [[ -z "$soft" || "$soft" == "null" ]] && soft=80
    [[ -z "$hard" || "$hard" == "null" ]] && hard=100

    # Compute thresholds in bytes.
    local soft_bytes hard_bytes
    soft_bytes=$(( budget_bytes * soft / 100 ))
    hard_bytes=$(( budget_bytes * hard / 100 ))

    log_info envelope-monitor "rung=${rung} policy=${policy} rss=${rss_mb}MB budget=${budget_mb}MB used=${ratio} soft=${soft}% hard=${hard}%"

    # Decision tree.
    if (( rss_bytes >= hard_bytes )); then
        if [[ "$policy" == "hard" ]]; then
            if _cooldown_ok alarm "$GAWD_ENVELOPE_ALARM_COOLDOWN_SEC"; then
                log_error envelope-monitor "ALARM rung=${rung} rss=${rss_mb}MB exceeds hard budget=${budget_mb}MB"
                _drop_inbox_alert alarm "$rss_mb" "$budget_mb" "$ratio"
                (( DRY_RUN == 1 )) || _cooldown_mark alarm
            else
                log_info envelope-monitor "alarm condition active but cooldown not elapsed (rss=${rss_mb}MB)"
            fi
            return 2
        elif [[ "$policy" == "soft" ]]; then
            log_warn envelope-monitor "rung=${rung} rss=${rss_mb}MB at-or-above budget=${budget_mb}MB (soft policy: journal only)"
            return 1
        fi
    elif (( rss_bytes >= soft_bytes )); then
        if [[ "$policy" == "hard" ]]; then
            if _cooldown_ok warn "$GAWD_ENVELOPE_WARN_COOLDOWN_SEC"; then
                log_warn envelope-monitor "WARNING rung=${rung} rss=${rss_mb}MB exceeds soft threshold (${soft}% of ${budget_mb}MB)"
                _drop_inbox_alert warning "$rss_mb" "$budget_mb" "$ratio"
                (( DRY_RUN == 1 )) || _cooldown_mark warn
            else
                log_info envelope-monitor "warning condition active but cooldown not elapsed (rss=${rss_mb}MB)"
            fi
            return 1
        elif [[ "$policy" == "soft" ]]; then
            log_warn envelope-monitor "rung=${rung} rss=${rss_mb}MB exceeds ${soft}% of budget ${budget_mb}MB (soft policy: journal only)"
            return 1
        fi
    fi

    return 0
}

main
