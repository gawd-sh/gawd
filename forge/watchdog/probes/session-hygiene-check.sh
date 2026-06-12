#!/usr/bin/env bash
# probes/session-hygiene-check.sh — Probe: mid-run session hygiene.
#
# Flags (status=fail) a session file exceeding ANY of:
#   - size       (> GAWD_HYGIENE_MAX_BYTES, default 50MB) — same vector as the
#                 boot trim but checked every sweep, not only at boot.
#   - msg-count  (> GAWD_HYGIENE_MAX_MSGS, default 2000)  — the n8n trim that
#                 does not ship; line count ≈ message count for .jsonl.
#   - poison     (>= GAWD_HYGIENE_POISON_MAX occurrences of a poison token,
#                 default token "headless", default max 500) — the 783x"headless"
#                 vector that is under 50MB and slips the size trim.
#
# On fail, sweep.sh archives the session (rotation). Exit 0 (ok) / 1 (fail).
# Contract: {"probe":"session-hygiene","status":"ok|fail","detail":"...","worst":"<path>"}
# Hard rules: no LLM; ≤5s (we scan at most N files, tail-bounded); read-only.
set -uo pipefail
PROBE_NAME="session-hygiene"
SESS_DIR="${GAWD_HYGIENE_SESSIONS_DIR:-${HOME}/.openclaw/agents/main/sessions}"
MAX_BYTES="${GAWD_HYGIENE_MAX_BYTES:-52428800}"   # 50 MB
MAX_MSGS="${GAWD_HYGIENE_MAX_MSGS:-2000}"
POISON_TOKEN="${GAWD_HYGIENE_POISON_TOKEN:-headless}"
POISON_MAX="${GAWD_HYGIENE_POISON_MAX:-500}"
_result() { printf '{"probe":"%s","status":"%s","detail":"%s","worst":"%s"}\n' "$PROBE_NAME" "$1" "$2" "${3:-}"; }

worst=""; reason=""
shopt -s nullglob
for f in "${SESS_DIR}"/*.jsonl; do
  [[ -f "$f" ]] || continue
  bytes=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
  if [[ "$bytes" -gt "$MAX_BYTES" ]]; then worst="$f"; reason="size=${bytes}>${MAX_BYTES}"; break; fi
  msgs=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  if [[ "${msgs:-0}" -gt "$MAX_MSGS" ]]; then worst="$f"; reason="msgs=${msgs}>${MAX_MSGS}"; break; fi
  poison=$(grep -c -- "$POISON_TOKEN" "$f" 2>/dev/null || echo 0)
  if [[ "${poison:-0}" -ge "$POISON_MAX" ]]; then worst="$f"; reason="poison=${poison}>=${POISON_MAX}"; break; fi
done
shopt -u nullglob

if [[ -z "$worst" ]]; then
  _result "ok" "all sessions within hygiene thresholds"
  exit 0
fi
_result "fail" "$reason" "$worst"
exit 1
