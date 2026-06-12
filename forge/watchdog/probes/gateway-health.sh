#!/usr/bin/env bash
# probes/gateway-health.sh — Probe 1: gateway HTTP health check.
#
# Exits:
#   0  probe passed   (gateway responded {"ok":true,...} within timeout)
#   1  probe failed   (no response, wrong status, or unexpected JSON)
#
# Outputs one-line JSON result to stdout:
#   {"probe":"gateway-health","status":"ok|fail","detail":"..."}
#
# Hard rules:
#   - No LLM dependency
#   - Completes in ≤5s (enforced via curl --max-time)
#   - Idempotent / read-only — no mutations
#
# Spec: §19.2 Layer 7, §19.6 "Daemon process down" and "Watchdog finds stuck gateway"

set -euo pipefail

PROBE_NAME="gateway-health"
GATEWAY_URL="${GAWD_GATEWAY_URL:-http://127.0.0.1:18789}"
CURL_TIMEOUT="${GAWD_PROBE_CURL_TIMEOUT:-5}"

_result() {
    local status="$1" detail="$2"
    printf '{"probe":"%s","status":"%s","detail":"%s"}\n' \
        "$PROBE_NAME" "$status" "$detail"
}

# Attempt the health call.
http_body=""
http_code=""
if ! http_body="$(curl -sf \
        --max-time "$CURL_TIMEOUT" \
        --connect-timeout 3 \
        -w '\n__HTTP_CODE__:%{http_code}' \
        "${GATEWAY_URL}/health" 2>/dev/null)"; then
    _result "fail" "curl failed or timed out after ${CURL_TIMEOUT}s"
    exit 1
fi

# Split body and status code.
http_code="$(printf '%s' "$http_body" | grep '^__HTTP_CODE__:' | cut -d: -f2)"
http_body="$(printf '%s' "$http_body" | grep -v '^__HTTP_CODE__:')"

if [[ "$http_code" != "200" ]]; then
    _result "fail" "non-200 response: http_code=${http_code}"
    exit 1
fi

# Validate JSON shape: must have "ok":true.
if ! command -v jq >/dev/null 2>&1; then
    # Fallback: text check.
    if printf '%s' "$http_body" | grep -q '"ok":true'; then
        _result "ok" "health=live (jq unavailable, text check)"
        exit 0
    else
        _result "fail" "response lacks ok:true (jq unavailable)"
        exit 1
    fi
fi

ok_val="$(printf '%s' "$http_body" | jq -r '.ok // "missing"' 2>/dev/null || echo "parse-error")"
if [[ "$ok_val" != "true" ]]; then
    _result "fail" "ok=${ok_val} (expected true)"
    exit 1
fi

_result "ok" "gateway responsive"
exit 0
