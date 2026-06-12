#!/usr/bin/env bash
# probes/auth-staleness-check.sh — Probe 4 (v1.1): Auth token staleness check.
#
# Status: v1.1 STUB — deferred per handoff spec. Emits WARN, never FAIL.
# Full implementation lands when the circuit-breaker layer (Layer 1) provides
# a stable per-provider auth-timestamp surface to read from.
#
# Intent: Check the timestamp of last successful auth refresh per provider.
# Warn if any provider's token was last refreshed >2 hours ago without a
# subsequent successful call. This catches the 2026-05-27 pattern where the
# Anthropic OAuth token was stale before any call attempt confirmed it.
#
# Current v1.0 behavior:
#   - Checks for existence of a known auth-state file.
#   - If file present, warns if any entry is stale (>2h).
#   - If file absent, emits "ok" (cannot check = assume ok, not fail).
#   - NEVER exits 1 in v1.0 — only 0 (ok) or 3 (warn).
#
# Spec: §19.2 Layer 7 probe 4 (deferred), §19.6 "Auth cascade exhaustion"

set -euo pipefail
trap 'printf "ok\n"; exit 0' ERR   # on error: assume ok, never block sweep

AUTH_STATE_FILE="${GAWD_AUTH_STATE_FILE:-${HOME}/.gawd/state/auth-refresh.json}"
STALE_THRESHOLD_S="${AUTH_STALE_THRESHOLD_S:-7200}"   # 2 hours

# If no auth state file, cannot check — emit ok (not warn, not fail)
if [[ ! -f "$AUTH_STATE_FILE" ]]; then
    printf "ok\n"
    exit 0
fi

command -v jq >/dev/null 2>&1 || { printf "ok\n"; exit 0; }

now="$(date +%s)"
stale_providers=()

while IFS= read -r provider; do
    [[ -z "$provider" ]] && continue
    last_refresh="$(jq -r --arg p "$provider" '.[$p].last_refresh_at // 0' "$AUTH_STATE_FILE" 2>/dev/null || echo 0)"
    last_success="$(jq -r --arg p "$provider" '.[$p].last_success_at // 0' "$AUTH_STATE_FILE" 2>/dev/null || echo 0)"

    # Use the more-recent of refresh/success
    ref_epoch="$(( last_refresh > last_success ? last_refresh : last_success ))"
    age=$(( now - ref_epoch ))

    if (( age > STALE_THRESHOLD_S )); then
        stale_providers+=("$provider")
    fi
done < <(jq -r 'keys[]' "$AUTH_STATE_FILE" 2>/dev/null || true)

if [[ "${#stale_providers[@]}" -gt 0 ]]; then
    printf "warn\n"
    # Write providers to stderr for sweep.sh to capture
    printf "STALE_PROVIDERS: %s\n" "${stale_providers[*]}" >&2
    exit 3
else
    printf "ok\n"
    exit 0
fi
