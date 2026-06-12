#!/usr/bin/env bash
# probes/gateway-health.sh — Probe 1: Gateway HTTP liveness check.
#
# Exits 0 if gateway responds {"ok":true} within PROBE_TIMEOUT_S seconds.
# Exits 1 on timeout, connection refusal, or non-ok response.
#
# Outputs one line to stdout: probe_result string for last-sweep.json.
# Caller interprets exit code; this script NEVER restarts the gateway —
# that belongs to sweep.sh's action layer.
#
# Spec: §19.2 Layer 7, §19.6 failure-mode "Daemon process down"
# Self-defending: set -euo pipefail with explicit trap; hangs impossible
#                 because curl has --max-time.

set -euo pipefail
trap 'printf "error\n"; exit 1' ERR

GATEWAY_URL="${GAWD_GATEWAY_URL:-http://127.0.0.1:18789}"
PROBE_TIMEOUT_S="${PROBE_TIMEOUT_S:-5}"

response="$(curl -sf --max-time "${PROBE_TIMEOUT_S}" \
    "${GATEWAY_URL}/health" 2>/dev/null || true)"

if [[ "$response" == '{"ok":true}' ]]; then
    printf "ok\n"
    exit 0
else
    printf "fail\n"
    exit 1
fi
