#!/usr/bin/env bash
# gawd-health-gate.sh — block until a dependency's /health is ok, or timeout.
# Usage: gawd-health-gate.sh <url> [timeout_sec] [label]
#   Polls <url> every 1s until it returns HTTP 200 with body containing
#   '"ok":true', or until timeout. Exit 0 on ready, 1 on timeout.
#   Used as ExecStartPre= (systemd) and inline (docker entrypoint).
#
# Hardening 4 (health-gated startup ordering): `After=` orders start; this gate
# makes "started" mean "actually ready", closing the start-before-dependency-ready
# race. ALWAYS used with a leading `-` (systemd) or `|| echo WARN` (docker) so a
# timeout WARNS but never fail-stops the caller — silence-is-worst-outcome: a
# gateway up without embed beats no gateway.
set -uo pipefail
URL="${1:?usage: gawd-health-gate.sh <url> [timeout] [label]}"
TIMEOUT="${2:-60}"
LABEL="${3:-$URL}"
i=0
while [[ $i -lt $TIMEOUT ]]; do
  if curl -fsS --max-time 2 "$URL" 2>/dev/null | grep -q '"ok":true'; then
    printf '[health-gate] %s ready after %ss\n' "$LABEL" "$i"
    exit 0
  fi
  sleep 1; i=$((i+1))
done
printf '[health-gate] TIMEOUT: %s not ready after %ss — proceeding anyway (fail-loud, not fail-stop)\n' "$LABEL" "$TIMEOUT" >&2
exit 1
