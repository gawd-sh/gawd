#!/usr/bin/env bash
# probes/auth-staleness-check.sh — Probe 4 (v1.1): auth token staleness.
#
# STATUS: v1.1 STUB — deferred per handoff spec.
# This probe WARNS (non-blocking) if the auth-refresh timestamp for any
# provider is stale (> STALE_THRESHOLD_SEC). It does NOT perform the refresh
# itself (that's Layer 3 / G3b auth-health-monitor). It surfaces the signal
# so the watchdog can report stale auth in last-sweep.json before it causes
# an actual incident.
#
# v1.0 behaviour: always exits 0 with status "warn-stub" so the sweep
# continues and the dashboard shows a visible "not yet implemented" probe.
# Wire in real logic when the auth-health-monitor (L3) lands and exports
# its timestamp file.
#
# Exits:
#   0  probe passed (or stub)
#   1  probe failed (stale auth detected — blocking in v1.1+)
#
# Stdout: {"probe":"auth-staleness","status":"ok|warn|warn-stub","detail":"...","providers":[]}
#
# Spec: §19.2 Layer 7, §19.6 "Auth cascade exhaustion"
# Depends on: L3 auth-health-monitor (not yet shipped as of 2026-05-27)

set -euo pipefail

PROBE_NAME="auth-staleness"

# L3 will export a file like:
#   $GAWD_HOME/state/auth-health/<provider>-last-refresh.json
#   { "provider": "anthropic", "last_refresh_at": "2026-05-27T14:03:00Z", "ok": true }
: "${GAWD_HOME:=${HOME}/.gawd}"
AUTH_STATE_DIR="${GAWD_HOME}/state/auth-health"

# Threshold: warn if any provider's last-refresh is older than this.
: "${AUTH_STALE_THRESHOLD_SEC:=7200}"   # 2 hours

_result() {
    local status="$1" detail="$2" providers_json="$3"
    printf '{"probe":"%s","status":"%s","detail":"%s","providers":%s}\n' \
        "$PROBE_NAME" "$status" "$detail" "$providers_json"
}

# ── v1.0 stub — L3 not yet landed ────────────────────────────────────────────

if [[ ! -d "$AUTH_STATE_DIR" ]]; then
    _result "warn-stub" \
        "L3 auth-health-monitor not installed; probe deferred to v1.1 (no $AUTH_STATE_DIR)" \
        "[]"
    exit 0
fi

# ── v1.1 real logic (activates once L3 writes its state files) ───────────────

now_epoch=$(date +%s)
stale=()
all=()

while IFS= read -r state_file; do
    [[ -f "$state_file" ]] || continue
    if ! command -v jq >/dev/null 2>&1; then
        _result "warn" "jq unavailable; cannot parse auth state" "[]"
        exit 0
    fi

    provider="$(jq -r '.provider // "unknown"' "$state_file" 2>/dev/null)"
    last_refresh_iso="$(jq -r '.last_refresh_at // empty' "$state_file" 2>/dev/null)"
    ok="$(jq -r '.ok // true' "$state_file" 2>/dev/null)"

    if [[ -z "$last_refresh_iso" ]]; then
        stale+=("${provider}:no-timestamp")
        all+=("{\"provider\":\"${provider}\",\"status\":\"unknown\"}")
        continue
    fi

    # Convert ISO8601 to epoch.
    last_epoch="$(date -d "$last_refresh_iso" +%s 2>/dev/null || echo 0)"
    age=$(( now_epoch - last_epoch ))

    if [[ "$ok" != "true" ]] || (( age > AUTH_STALE_THRESHOLD_SEC )); then
        stale+=("${provider}:age=${age}s")
        all+=("{\"provider\":\"${provider}\",\"status\":\"stale\",\"age_s\":${age},\"ok\":${ok}}")
    else
        all+=("{\"provider\":\"${provider}\",\"status\":\"ok\",\"age_s\":${age}}")
    fi
done < <(find "$AUTH_STATE_DIR" -name "*-last-refresh.json" -maxdepth 1 2>/dev/null)

# Build providers JSON array.
providers_json="[$(IFS=','; printf '%s' "${all[*]}")]"

if [[ ${#stale[@]} -gt 0 ]]; then
    stale_str="$(IFS=','; printf '%s' "${stale[*]}")"
    _result "warn" "stale auth for: ${stale_str}" "$providers_json"
    # v1.1: warn, not fail — auth staleness is not yet a blocking condition.
    # Upgrade to exit 1 once proactive refresh is in place.
    exit 0
fi

_result "ok" "all provider auth tokens fresh" "$providers_json"
exit 0
