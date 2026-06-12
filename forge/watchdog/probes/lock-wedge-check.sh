#!/usr/bin/env bash
# probes/lock-wedge-check.sh — Probe: live self-deadlock on a session .jsonl.lock.
#
# Detects a *.jsonl.lock under the sessions dir held by a LIVE process while the
# gateway is failing to reply. This is the fault recover.sh/clean-state cannot
# touch (both are lock-blind / live-holder-safe). On fail, sweep.sh escalates to
# gawd-prophit-restart.sh — the kill releases the lock.
#
# Exits 0 (ok) / 1 (fail). One-line JSON contract:
#   {"probe":"lock-wedge","status":"ok|fail","detail":"..."}
# Hard rules: no LLM; ≤5s; read-only.
set -uo pipefail
PROBE_NAME="lock-wedge"
GATEWAY_URL="${GAWD_GATEWAY_URL:-http://127.0.0.1:18789}"
SESS_DIR="${GAWD_LOCK_SESSIONS_DIR:-${HOME}/.openclaw/agents/main/sessions}"
_result() { printf '{"probe":"%s","status":"%s","detail":"%s"}\n' "$PROBE_NAME" "$1" "$2"; }

# Find any *.jsonl.lock with a live holder (fuser preferred, lsof fallback).
held=""
shopt -s nullglob
for lk in "${SESS_DIR}"/*.jsonl.lock; do
  [[ -e "$lk" ]] || continue
  if command -v fuser >/dev/null 2>&1; then
    if fuser "$lk" >/dev/null 2>&1; then held="$lk"; break; fi
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -- "$lk" >/dev/null 2>&1; then held="$lk"; break; fi
  fi
done
shopt -u nullglob

if [[ -z "$held" ]]; then
  _result "ok" "no live-held session lock"
  exit 0
fi

# A live holder exists. Confirm the gateway is ALSO failing to reply — a live
# lock during healthy operation is normal in-flight write; only a live lock
# *while replies fail* is the deadlock. If /health is fine, treat as ok (benign).
if curl -fsS --max-time 2 "${GATEWAY_URL}/health" 2>/dev/null | grep -q '"ok":true'; then
  _result "ok" "live lock present but gateway healthy (in-flight write): $(basename "$held")"
  exit 0
fi

_result "fail" "live-held session lock while gateway unhealthy: $(basename "$held")"
exit 1
