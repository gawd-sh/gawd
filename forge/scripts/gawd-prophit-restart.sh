#!/usr/bin/env bash
# gawd-prophit-restart.sh — the ONE shared restart primitive.
# Phases: clean-state (sweep stale locks) → recover-wedged (clear any wedged
# session) → restart-gateway → verify-health. Reports success ONLY on a real
# /health ok:true poll (never on a systemctl exit code). Used by the dashboard
# restart button (B1) and the live-lock watchdog dispatch (B2).
#
# Exit: 0 = gateway verified ok:true after restart. non-zero = restart failed.
# Flags: --dry-run (log the phases, take no action)
set -uo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" || "${GAWD_PROPHIT_RESTART_DRY:-0}" == "1" ]] && DRY=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_DIR="$(cd "${SELF_DIR}/.." && pwd)"
: "${GAWD_HOME:=${HOME}/.gawd}"
: "${GATEWAY_URL:=${GAWD_GATEWAY_URL:-http://127.0.0.1:18789}}"
LOG="${GAWD_HOME}/logs/prophit-restart.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
say() { printf '[prophit-restart] %s\n' "$*"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true; }

# Resolve the staged helpers (per-Prophit install) then fall back to the forge tree.
_resolve() {  # _resolve <basename> <forge-relpath>
  local b="$1" rel="$2"
  for c in "${GAWD_HOME}/engine/${rel}" "/usr/local/lib/gawd/${rel}" "${FORGE_DIR}/${rel}"; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}
CLEAN_STATE="$(_resolve gawd-clean-state.sh scripts/gawd-clean-state.sh || true)"
G4_SWEEP="$(_resolve sweep.sh silence-avoidance/session-recovery/sweep.sh || true)"

# Verify /health returns ok:true within ~10s. Mirrors sweep.sh:_verify_gateway_up.
_verify_health() {
  local i
  for i in $(seq 1 10); do
    curl -fsS --max-time 2 "${GATEWAY_URL}/health" 2>/dev/null | grep -q '"ok":true' && return 0
    sleep 1
  done
  return 1
}

# Restart the gateway: systemd unit if present (verify via /health, never rc),
# else nohup node rung. Mirrors sweep.sh:_restart_gateway (288–353) minus the
# circuit-breaker (the button is rate-limited at the dashboard; the probe path
# is gated by the watchdog circuit-breaker before it ever calls us).
_restart() {
  local unit=""
  if systemctl --user cat gawd.service >/dev/null 2>&1; then unit="gawd.service"
  elif systemctl --user cat openclaw-gateway.service >/dev/null 2>&1; then unit="openclaw-gateway.service"
  fi
  if [[ -n "$unit" ]]; then
    systemctl --user restart "$unit" >>"$LOG" 2>&1 || say "systemctl restart returned non-zero (deferred?) — verifying via /health regardless"
    _verify_health && { say "restart-gateway: verified via /health (systemd: $unit)"; return 0; }
    if systemctl --user is-enabled "$unit" >/dev/null 2>&1; then
      say "gateway is systemd-managed ($unit); NOT spawning competing nohup — leaving to systemd"
      return 1
    fi
  fi
  say "restart-gateway: nohup node rung"
  nohup /usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789 >>"${HOME}/gateway.log" 2>&1 &
  _verify_health && { say "restart-gateway: verified via /health (nohup)"; return 0; }
  return 1
}

if [[ "$DRY" -eq 1 ]]; then
  say "DRY: phase clean-state (would run: ${CLEAN_STATE:-<none>})"
  say "DRY: phase recover-wedged (would run: ${G4_SWEEP:-<none>})"
  say "DRY: phase restart-gateway (would systemctl/nohup + verify /health)"
  say "DRY: phase verify-health (would poll ${GATEWAY_URL}/health for ok:true)"
  exit 0
fi

# Phase 1: clean-state — sweep stale flock locks (live holders left alone).
[[ -n "$CLEAN_STATE" ]] && { say "clean-state: $CLEAN_STATE"; bash "$CLEAN_STATE" >>"$LOG" 2>&1 || say "clean-state non-zero (continuing)"; } || say "clean-state: helper not found (skipping)"

# Phase 2: recover-wedged — clear any wedged session before the restart.
[[ -n "$G4_SWEEP" ]] && { say "recover-wedged: $G4_SWEEP"; bash "$G4_SWEEP" >>"$LOG" 2>&1 || say "recover-wedged non-zero (continuing)"; } || say "recover-wedged: sweep not found (skipping)"

# Phase 3+4: restart-gateway + verify-health.
if _restart; then
  say "verify-health: ok:true — restart succeeded"
  exit 0
fi
say "restart-gateway FAILED — /health did not return ok:true"
exit 1
