#!/usr/bin/env bash
# watchdog/sweep.sh — Layer 7 healing watchdog sweep.
#
# Runs all 5 probes sequentially. On failure, invokes the appropriate recovery:
#   gateway-health FAIL     → systemd restart of openclaw-gateway.service
#   session-wedge FAIL      → G4 recover.sh per wedged session; G2 stuck-state fallback
#   mcp-plugin FAIL         → set disconnect flag; G2 stuck-state; direct-curl alert
#   auth-staleness WARN     → log only (non-blocking in v1.1)
#   last-activity FAIL      → G4 + G2 (suspected wedge; same path as session-wedge)
#
# Writes last-sweep.json atomically after every sweep.
# Logs every sweep via D3 structured logger (or stderr fallback).
# Never calls an LLM. Never echoes secrets.
#
# Invocation: sweep.sh [--dry-run] [--probe <name>]
#   --dry-run          Run all probes, log actions that would be taken, take none.
#   --probe <name>     Run only the named probe (for diagnostics).
#
# Exit: 0 always (sweep result captured in last-sweep.json and logs).
#
# Install: registered as a systemd user timer (see install.sh).
# Interval: 60 seconds (OnUnitActiveSec in the timer).
#
# Spec: §19.2 Layer 7 (entire row), §19.6 failure-mode taxonomy

set -euo pipefail

SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBES_DIR="${SWEEP_DIR}/probes"

: "${GAWD_HOME:=${HOME}/.gawd}"
STATE_DIR="${SWEEP_DIR}/state"
LAST_SWEEP_FILE="${STATE_DIR}/last-sweep.json"

# ── hardening 6d: concurrency guard ────────────────────────────────────────────
# The */5 belt-and-suspenders cron AND the 60s entrypoint loop both call sweep.sh.
# A flock makes overlapping cron+loop+manual invocations safe so no two sweeps
# race a gateway restart. Non-blocking: a second concurrent sweep simply skips.
mkdir -p "${GAWD_HOME}/watchdog" 2>/dev/null || true
exec 9>"${GAWD_HOME}/watchdog/sweep.lock" 2>/dev/null || true
flock -n 9 || { echo "[sweep] another sweep is running — skipping"; exit 0; }

# ── hardening 6 (D2): canonical gateway unit name resolution ───────────────────
# The shipped daemon standardizes on gawd.service (per maintainer decision D2, forge-wide). Live
# boxes (Dasra/Lilith) still run openclaw-gateway.service and are NOT renamed.
# Resolve whichever unit actually exists so sweep.sh works on both the shipped
# template and the live boxes. gawd.service wins when both are present.
# M1 (2026-05-28): verify BOTH candidate units with the same `cat` guard. Never
# return a phantom unit name when neither exists — that makes systemctl restart
# target a non-existent unit and look like a no-op. If neither is present we are
# on the nohup rung; say so LOUDLY and let _restart_gateway's nohup path handle it.
_gateway_unit() {
  if systemctl --user list-unit-files gawd.service >/dev/null 2>&1 \
     && systemctl --user cat gawd.service >/dev/null 2>&1; then
    echo "gawd.service"; return 0
  fi
  if systemctl --user list-unit-files openclaw-gateway.service >/dev/null 2>&1 \
     && systemctl --user cat openclaw-gateway.service >/dev/null 2>&1; then
    echo "openclaw-gateway.service"; return 0
  fi
  _log_warn "no gateway systemd unit (neither gawd.service nor openclaw-gateway.service) — using nohup rung for gateway recovery"
  echo ""   # empty = no systemd unit; _restart_gateway falls to the nohup path
}
GATEWAY_UNIT="$(_gateway_unit)"

# G2 engine (Layer 6 — static fallback delivery).
G2_ENGINE="${GAWD_HOME}/engine/silence-avoidance/engine.sh"
G2_ENGINE_FORGE="${SWEEP_DIR}/../silence-avoidance/engine.sh"

# G4 session-recovery (Layer 4).
G4_RECOVER="${GAWD_HOME}/engine/session-recovery/recover.sh"
G4_RECOVER_FORGE="${SWEEP_DIR}/../silence-avoidance/session-recovery/recover.sh"

# Prophit config (for G2 invocations — who to send the fallback to).
: "${GAWD_PROPHIT_ID:=default}"
: "${GAWD_PRIMARY_CHANNEL:=telegram}"

# Gateway URL used for the post-restart health verification (BLOCKER 11).
: "${GATEWAY_URL:=${GAWD_GATEWAY_URL:-http://127.0.0.1:18789}}"
WATCHDOG_LOG="${WATCHDOG_LOG:-${HOME}/.gawd/watchdog/logs/sweep.log}"

# Logger.
LOGGER_SH="/usr/local/lib/gawd/observability/logger.sh"
if [[ -r "$LOGGER_SH" ]]; then
    source "$LOGGER_SH"
    _log_info()  { log_info  "watchdog-sweep" "$@"; }
    _log_warn()  { log_warn  "watchdog-sweep" "$@"; }
    _log_error() { log_error "watchdog-sweep" "$@"; }
else
    _log_info()  { printf '{"severity":"info","source":"watchdog-sweep","ts":"%s","message":"%s"}\n' \
                       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
    _log_warn()  { printf '{"severity":"warn","source":"watchdog-sweep","ts":"%s","message":"%s"}\n' \
                       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
    _log_error() { printf '{"severity":"error","source":"watchdog-sweep","ts":"%s","message":"%s"}\n' \
                       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fi

# ── Parse args ────────────────────────────────────────────────────────────────

DRY_RUN=0
ONLY_PROBE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --probe)   shift; ONLY_PROBE="${1:-}" ;;
        *) _log_warn "unknown arg: $1" ;;
    esac
    shift || true
done

# ── Helpers ───────────────────────────────────────────────────────────────────

# _g2_call <event> [channel] [prophit]
# Invokes the L6 silence-avoidance engine. §19-HIGH H3: the engine's exit code
# is captured and appended to actions_taken (never masked with `|| true`), so
# last-sweep.json reflects delivery failures truthfully. stderr is routed to
# the watchdog log, not /dev/null.
# Engine exit codes: 0 delivered, 10 suppressed (in-window), 20 template missing,
#                    30 delivery failed, 40 invalid invocation.
_g2_call() {
    local event="$1" channel="${2:-${GAWD_PRIMARY_CHANNEL}}" pid="${3:-${GAWD_PROPHIT_ID}}"
    local engine=""
    [[ -x "$G2_ENGINE"       ]] && engine="$G2_ENGINE"
    [[ -z "$engine" && -x "$G2_ENGINE_FORGE" ]] && engine="$G2_ENGINE_FORGE"

    if [[ -z "$engine" ]]; then
        _log_error "G2 engine not found at ${G2_ENGINE} or ${G2_ENGINE_FORGE}; fallback SUPPRESSED — silence-net DEPLOY BUG"
        actions_taken+=("g2-call:ENGINE-MISSING")
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _log_info "DRY_RUN: would call G2 engine.sh ${event} --channel ${channel} --prophit ${pid}"
        return 0
    fi

    mkdir -p "$(dirname "$WATCHDOG_LOG")" 2>/dev/null || true
    local rc=0
    "$engine" "$event" --channel "$channel" --prophit "$pid" >>"$WATCHDOG_LOG" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        _log_info "g2 engine delivered event=${event} channel=${channel} prophit=${pid}"
        actions_taken+=("g2-call:OK")
    elif [[ $rc -eq 10 ]]; then
        _log_info "g2 engine suppressed (in silence-window) event=${event} channel=${channel}"
        actions_taken+=("g2-call:SUPPRESSED")
    else
        _log_error "g2 engine call FAILED rc=${rc} event=${event} channel=${channel} prophit=${pid}"
        actions_taken+=("g2-call:FAILED:${rc}")
    fi
    return $rc
}

# _g4_recover_session <session-id>
# §19-HIGH H3: capture recover.sh exit code; on failure log + record in
# actions_taken rather than swallowing with `|| true`.
_g4_recover_session() {
    local sid="$1"
    local recover=""
    [[ -x "$G4_RECOVER"       ]] && recover="$G4_RECOVER"
    [[ -z "$recover" && -x "$G4_RECOVER_FORGE" ]] && recover="$G4_RECOVER_FORGE"

    if [[ -z "$recover" ]]; then
        _log_warn "G4 recover.sh not found at ${G4_RECOVER}; calling G2 stuck-state as fallback for session ${sid}"
        actions_taken+=("g4-recover:RECOVER-MISSING:${sid}")
        _g2_call "stuck-state" || true
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _log_info "DRY_RUN: would call G4 recover.sh ${sid}"
        return 0
    fi

    mkdir -p "$(dirname "$WATCHDOG_LOG")" 2>/dev/null || true
    local rc=0
    "$recover" "$sid" >>"$WATCHDOG_LOG" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        _log_error "g4 recover.sh FAILED rc=${rc} session=${sid}"
        actions_taken+=("g4-recover:FAILED:${rc}:${sid}")
    fi
    return $rc
}

# _verify_gateway_up
# BLOCKER 11: `systemctl --user restart` was observed live (2026-05-28) to
# return {"deferred":true} — exit 0 WITHOUT actually cycling the process. So we
# NEVER trust the systemctl exit code. We poll /health for a real "ok":true.
# Returns 0 if the gateway answers ok:true within ~10s, 1 otherwise.
_verify_gateway_up() {
    local i
    for i in $(seq 1 10); do
        if curl -fsS --max-time 2 "${GATEWAY_URL}/health" 2>/dev/null | grep -q '"ok":true'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ── hardening 6c: docker-rung gateway circuit-breaker (sliding window) ──────────
# The §2 docker counterpart to systemd's StartLimit. Gives the docker rung the
# same "give up + alert, no storm" property: ≥5 gateway restarts in the last
# 300s → stop restarting that window, alert the Prophit, record circuit-open.
_breaker_open() {  # returns 0 (open=stop) if >=5 restarts in last 300s
    local f="${GAWD_HOME}/watchdog/state/gateway-restarts"; mkdir -p "$(dirname "$f")"
    local now cutoff; now=$(date +%s); cutoff=$((now-300))
    if [[ -f "$f" ]]; then awk -v c="$cutoff" '$1>=c' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; fi
    local n; n=$(wc -l < "$f" 2>/dev/null || echo 0)
    [[ "$n" -ge 5 ]]
}
_breaker_record() { mkdir -p "${GAWD_HOME}/watchdog/state"; echo "$(date +%s)" >> "${GAWD_HOME}/watchdog/state/gateway-restarts"; }

# ── §19-HIGH H1: pending-alerts retry ────────────────────────────────────────
# gawd-failure-alert.sh queues alerts it could not deliver (after 3 curl tries)
# to ${GAWD_HOME}/state/pending-alerts, one per line: "<ts>\t<chat_id>\t<msg>".
# It NEVER stores the bot token. On each sweep we re-resolve the token from the
# live channels.telegram config (same source as the daemon) and retry every
# queued alert; delivered lines are dropped, undelivered lines are kept for the
# next cadence. NEVER echoes the token.
_retry_pending_alerts() {
    local pending="${GAWD_HOME}/state/pending-alerts"
    [[ -s "$pending" ]] || return 0
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _log_info "DRY_RUN: would retry $(wc -l <"$pending" 2>/dev/null || echo '?') pending Telegram alert(s)"
        return 0
    fi

    # Re-resolve token once (no echo) from the daemon's own channels.telegram.
    local oc="${OPENCLAW_CONFIG:-${HOME}/.openclaw/openclaw.json}"
    local sj="${HOME}/.openclaw/secrets/secrets.json"
    local tok=""
    if [[ -f "$oc" ]]; then
        tok="$(python3 - "$oc" "$sj" <<'PY' 2>/dev/null || true
import json,sys,os
cfg=json.load(open(sys.argv[1])); fb=sys.argv[2]
tg=(cfg.get("channels") or {}).get("telegram") or {}
bt=tg.get("botToken"); tok=""
if isinstance(bt,str): tok=bt
elif isinstance(bt,dict):
    src=bt.get("source"); prov=bt.get("provider"); key=(bt.get("id") or "").lstrip("/")
    if src=="env": tok=os.environ.get(key,"") or os.environ.get(bt.get("id",""),"")
    elif src=="file":
        pdef=(((cfg.get("secrets") or {}).get("providers")) or {}).get(prov) or {}
        path=pdef.get("path") or fb; mode=pdef.get("mode","json")
        try:
            tok=str(json.load(open(path)).get(key,"") or "") if mode=="json" else open(path).read().strip()
        except Exception: tok=""
print(tok)
PY
)"
    fi
    if [[ -z "$tok" ]] && command -v secrets >/dev/null 2>&1; then
        tok="$(secrets get TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
    fi
    if [[ -z "$tok" ]]; then
        _log_warn "pending-alerts retry skipped — no bot token resolvable this cadence"
        actions_taken+=("pending-alerts:NO-TOKEN")
        return 0
    fi

    local kept="${pending}.tmp.$$"; : > "$kept"
    local delivered=0 still=0 line ts cid msg
    while IFS=$'\t' read -r ts cid msg; do
        [[ -z "$cid" || -z "$msg" ]] && continue
        if curl -sf -X POST "https://api.telegram.org/bot${tok}/sendMessage" \
             -d "chat_id=${cid}" --data-urlencode "text=${msg}" >/dev/null 2>&1; then
            delivered=$((delivered+1))
        else
            printf '%s\t%s\t%s\n' "$ts" "$cid" "$msg" >> "$kept"
            still=$((still+1))
        fi
    done < "$pending"
    if [[ "$still" -gt 0 ]]; then mv "$kept" "$pending"; else rm -f "$kept" "$pending"; fi
    if [[ "$delivered" -gt 0 || "$still" -gt 0 ]]; then
        _log_info "pending-alerts retry: delivered=${delivered} still_pending=${still}"
        actions_taken+=("pending-alerts:delivered=${delivered}:pending=${still}")
    fi
}

# _restart_gateway
# Issues a restart, then VERIFIES via /health (never via the systemctl rc).
# Escalation ladder:
#   0. circuit-breaker (hardening 6c): if ≥5 restarts in 300s, STOP + alert.
#   1. systemctl --user restart of the resolved gateway unit → verify
#   2. nohup node workaround (gospel §4.5) → verify — ONLY when the gateway is
#      NOT systemd-managed (hardening 6b: never spawn a competing nohup gateway
#      while systemd owns the port — that is the dual-owner crashloop cause).
#   3. on continued failure: fire a distinct `extended`-degraded engine event
#      AND record gateway-restart-FAILED in actions_taken (never bare success).
_restart_gateway() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _log_info "DRY_RUN: would restart ${GATEWAY_UNIT} (systemd user) and verify /health"
        return 0
    fi

    # Step 0: circuit-breaker. Stop storming a genuinely broken gateway.
    if _breaker_open; then
        _log_error "gateway-circuit-open — ≥5 restarts in 300s; NOT restarting this window, alerting Prophit"
        actions_taken+=("gateway-circuit-open")
        if [[ -x "${GAWD_HOME}/scripts/gawd-failure-alert.sh" ]]; then
            bash "${GAWD_HOME}/scripts/gawd-failure-alert.sh" "${GATEWAY_UNIT}(circuit-open)" || true
        fi
        _g2_call "extended" || true
        return 1
    fi
    _breaker_record

    # M1: if no systemd gateway unit was resolved, skip the systemd path entirely
    # and go straight to the nohup rung — never `systemctl restart ""`.
    if [[ -z "$GATEWAY_UNIT" ]]; then
        _log_warn "no systemd gateway unit resolved — skipping systemctl path, escalating directly to nohup node startup"
    else
        # Step 1: ask systemd to restart, but do NOT trust its exit code.
        systemctl --user restart "${GATEWAY_UNIT}" >>"$WATCHDOG_LOG" 2>&1 \
            || _log_warn "systemctl restart returned non-zero (may be deferred/no-op); will verify via /health regardless"

        if _verify_gateway_up; then
            _log_info "gateway-restart-verified (systemd path) — /health returned ok:true"
            actions_taken+=("gateway-restart-verified")
            return 0
        fi
    fi

    # hardening 6b: if the gateway is systemd-managed, do NOT fall to nohup — a
    # second process competing for :18789 is exactly the dual-owner failure.
    # Leave recovery to systemd + the circuit-breaker.
    if [[ -n "$GATEWAY_UNIT" ]] && systemctl --user is-enabled "${GATEWAY_UNIT}" >/dev/null 2>&1; then
        _log_warn "gateway is systemd-managed (${GATEWAY_UNIT}); NOT spawning a competing nohup gateway — leaving recovery to systemd + circuit-breaker"
        actions_taken+=("gateway-restart-deferred-to-systemd")
        _g2_call "extended" || true
        return 1
    fi

    # Step 2: docker/nohup rung only — systemd does NOT manage the gateway here.
    # Escalate to the nohup node workaround.
    _log_warn "gateway still down after systemctl restart (nohup rung); escalating to nohup node startup"
    mkdir -p "$(dirname "$WATCHDOG_LOG")" 2>/dev/null || true
    nohup /usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js \
        gateway --port 18789 \
        >>"${HOME}/gateway.log" 2>&1 &
    _log_info "started gateway via nohup node (pid $!) — verifying"

    if _verify_gateway_up; then
        _log_info "gateway-restart-verified (nohup path) — /health returned ok:true"
        actions_taken+=("gateway-restart-verified-nohup")
        return 0
    fi

    # Step 3: both paths failed. This is an EXTENDED degradation — surface it
    # distinctly and record the FAILURE truthfully (never the success line).
    _log_error "gateway-restart-FAILED — /health did not return ok:true after systemd + nohup; firing extended-degraded"
    actions_taken+=("gateway-restart-FAILED")
    _g2_call "extended" || true
    return 1
}

# Atomic write for last-sweep.json.
_write_state() {
    local content="$1"
    mkdir -p "$STATE_DIR"
    local tmp
    tmp="$(mktemp "${LAST_SWEEP_FILE}.XXXXXX")"
    printf '%s\n' "$content" > "$tmp"
    # Validate before committing.
    if command -v jq >/dev/null 2>&1; then
        if ! jq -e . "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"
            _log_error "state write produced invalid JSON; last-sweep.json not updated"
            return 1
        fi
    fi
    chmod 0644 "$tmp"
    mv "$tmp" "$LAST_SWEEP_FILE"
}

# Run a single probe with a 5-second enforced timeout.
_run_probe() {
    local probe_name="$1"
    local probe_script="${PROBES_DIR}/${probe_name}.sh"

    if [[ ! -x "$probe_script" ]]; then
        printf '{"probe":"%s","status":"missing","detail":"probe script not found at %s"}\n' \
            "$probe_name" "$probe_script"
        return 0
    fi

    local output exit_code
    output="$(timeout 5 bash "$probe_script" 2>/dev/null)" || exit_code=$?
    exit_code="${exit_code:-0}"

    # If probe produced no output, emit a placeholder.
    if [[ -z "$output" ]]; then
        output="$(printf '{"probe":"%s","status":"empty","detail":"probe produced no output (exit %d)"}' \
            "$probe_name" "$exit_code")"
    fi

    printf '%s\n' "$output"
}

# Extract status from a probe's JSON output line.
_probe_status() {
    local json_line="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.status // "unknown"' <<<"$json_line" 2>/dev/null || echo "unknown"
    else
        # Text fallback.
        printf '%s' "$json_line" | grep -oE '"status":"[^"]*"' \
            | head -1 | cut -d'"' -f4 || echo "unknown"
    fi
}

# ── Main sweep ────────────────────────────────────────────────────────────────

sweep_start=$(date +%s%N 2>/dev/null || echo "$(( $(date +%s) * 1000000000 ))")
sweep_ts="$(date -u +%Y-%m-%dT%H:%M:%S%z)"

_log_info "sweep start dry_run=${DRY_RUN}"

PROBES=("gateway-health" "session-wedge-check" "mcp-plugin-check" "auth-staleness-check" "last-activity-check" "lock-wedge-check" "session-hygiene-check")
PROBE_KEYS=("gateway-health" "session-wedge" "mcp-plugin" "auth-staleness" "last-activity" "lock-wedge" "session-hygiene")

declare -A probe_results
declare -A probe_statuses
actions_taken=()

for i in "${!PROBES[@]}"; do
    probe_script_name="${PROBES[$i]}"
    probe_key="${PROBE_KEYS[$i]}"

    # Skip if --probe filter set.
    if [[ -n "$ONLY_PROBE" && "$ONLY_PROBE" != "$probe_key" ]]; then
        probe_results["$probe_key"]='{"probe":"'"$probe_key"'","status":"skipped","detail":"--probe filter"}'
        probe_statuses["$probe_key"]="skipped"
        continue
    fi

    result_line="$(_run_probe "$probe_script_name")"
    status="$(_probe_status "$result_line")"

    probe_results["$probe_key"]="$result_line"
    probe_statuses["$probe_key"]="$status"

    _log_info "probe=${probe_key} status=${status}"

    # ── Recovery dispatch ──────────────────────────────────────────────────────

    case "$probe_key" in

        "gateway-health")
            if [[ "$status" == "fail" ]]; then
                _log_warn "gateway health failed — restarting gateway (will verify via /health)"
                actions_taken+=("gateway-restart-attempt")
                # _restart_gateway records gateway-restart-verified|FAILED itself
                # (BLOCKER 11) based on a real /health poll, never on systemctl rc.
                # `|| true` only prevents set -e abort; the true rc is already in
                # actions_taken so state stays truthful and the sweep completes.
                _restart_gateway || true
                # G2 stuck-state (no reply for a while as gateway comes up).
                # _g2_call records its own g2-call:OK|SUPPRESSED|FAILED line (§19-H3).
                _g2_call "stuck-state" || true
            fi
            ;;

        "session-wedge")
            if [[ "$status" == "fail" ]]; then
                # Extract wedged session IDs from the result.
                if command -v jq >/dev/null 2>&1; then
                    wedged_ids="$(printf '%s' "$result_line" \
                        | jq -r '.wedged_sessions[]? // empty' 2>/dev/null || true)"
                else
                    wedged_ids=""
                fi

                if [[ -n "$wedged_ids" ]]; then
                    while IFS= read -r sid; do
                        [[ -z "$sid" ]] && continue
                        _log_warn "wedged session detected: ${sid} — invoking G4 recovery"
                        # _g4_recover_session records its own OK/FAILED line (§19-H3).
                        # `|| true` only prevents set -e abort; rc already recorded.
                        _g4_recover_session "$sid" || true
                    done <<< "$wedged_ids"
                else
                    # No individual IDs extracted — trigger G2 generically.
                    _log_warn "session wedge detected (no session IDs) — calling G2 stuck-state"
                    _g2_call "stuck-state" || true
                fi
            fi
            ;;

        "mcp-plugin")
            if [[ "$status" == "fail" ]]; then
                _log_warn "MCP plugin disconnect detected — flagging direct-curl path; calling G2 stuck-state"
                actions_taken+=("mcp-disconnect-flag")
                # _g2_call records its own g2-call:OK|FAILED line (§19-H3).
                _g2_call "stuck-state" || true
                # Note: the disconnect flag itself is set inside the probe.
            fi
            # "warn" status from the probe is logged above; no action needed.
            ;;

        "auth-staleness")
            # v1.1 stub: warn only, never block or restart.
            if [[ "$status" == "warn" || "$status" == "warn-stub" ]]; then
                _log_warn "auth-staleness: ${result_line}"
                # No action — observation only until L3 ships.
            fi
            ;;

        "last-activity")
            if [[ "$status" == "fail" ]]; then
                _log_warn "last-activity stale — treating as suspected wedge; invoking G4 + G2"
                # Run G4 sweep (detect + recover all wedged sessions).
                G4_SWEEP="${GAWD_HOME}/engine/session-recovery/sweep.sh"
                G4_SWEEP_FORGE="${SWEEP_DIR}/../silence-avoidance/session-recovery/sweep.sh"
                g4_sweep=""
                [[ -x "$G4_SWEEP"       ]] && g4_sweep="$G4_SWEEP"
                [[ -z "$g4_sweep" && -x "$G4_SWEEP_FORGE" ]] && g4_sweep="$G4_SWEEP_FORGE"
                if [[ -z "$g4_sweep" ]]; then
                    _log_error "G4 sweep.sh not found at ${G4_SWEEP} — suspected-wedge sweep skipped (DEPLOY BUG)"
                    actions_taken+=("g4-sweep:SWEEP-MISSING")
                elif [[ "$DRY_RUN" -eq 1 ]]; then
                    _log_info "DRY_RUN: would call G4 sweep.sh"
                    actions_taken+=("g4-sweep-suspected-wedge")
                else
                    # §19-H3: capture rc, keep stderr in the log, record truthfully.
                    mkdir -p "$(dirname "$WATCHDOG_LOG")" 2>/dev/null || true
                    g4sweep_rc=0
                    "$g4_sweep" >>"$WATCHDOG_LOG" 2>&1 || g4sweep_rc=$?
                    if [[ $g4sweep_rc -eq 0 ]]; then
                        actions_taken+=("g4-sweep-suspected-wedge")
                    else
                        _log_error "g4 sweep.sh FAILED rc=${g4sweep_rc}"
                        actions_taken+=("g4-sweep:FAILED:${g4sweep_rc}")
                    fi
                fi
                # _g2_call records its own g2-call:OK|FAILED line (§19-H3).
                _g2_call "stuck-state" || true
            fi
            ;;
        "lock-wedge")
            if [[ "$status" == "fail" ]]; then
                _log_warn "live lock-wedge detected — gateway holds a session .jsonl.lock while unhealthy; escalating to prophit-restart (the kill releases the lock)"
                actions_taken+=("lock-wedge-restart-attempt")
                RESTART_SH="${GAWD_HOME}/engine/scripts/gawd-prophit-restart.sh"
                RESTART_SH_FORGE="${SWEEP_DIR}/../scripts/gawd-prophit-restart.sh"
                restart=""
                [[ -x "$RESTART_SH"       ]] && restart="$RESTART_SH"
                [[ -z "$restart" && -x "$RESTART_SH_FORGE" ]] && restart="$RESTART_SH_FORGE"
                if [[ -z "$restart" ]]; then
                    _log_error "gawd-prophit-restart.sh not found — lock-wedge unrecoverable (DEPLOY BUG)"
                    actions_taken+=("lock-wedge:RESTART-MISSING")
                elif [[ "$DRY_RUN" -eq 1 ]]; then
                    _log_info "DRY_RUN: would call gawd-prophit-restart.sh for lock-wedge"
                    actions_taken+=("lock-wedge-restart")
                else
                    lwrc=0
                    bash "$restart" >>"$WATCHDOG_LOG" 2>&1 || lwrc=$?
                    if [[ $lwrc -eq 0 ]]; then actions_taken+=("lock-wedge-restart-verified")
                    else _log_error "prophit-restart FAILED rc=${lwrc} on lock-wedge"; actions_taken+=("lock-wedge-restart:FAILED:${lwrc}"); fi
                fi
            fi
            ;;
        "session-hygiene")
            if [[ "$status" == "fail" ]]; then
                worst="$(printf '%s' "$result_line" | jq -r '.worst // empty' 2>/dev/null || true)"
                _log_warn "session-hygiene breach (${result_line}) — archiving worst session: ${worst:-<unknown>}"
                actions_taken+=("session-hygiene-rotate-attempt")
                if [[ -n "$worst" && "$DRY_RUN" -eq 0 && -f "$worst" ]]; then
                    arch="${HOME}/.openclaw/archive/sessions"
                    mkdir -p "$arch"
                    if mv "$worst" "${arch}/$(basename "$worst").hygiene.$(date +%s)" 2>>"$WATCHDOG_LOG"; then
                        actions_taken+=("session-hygiene-rotated")
                    else
                        _log_error "session-hygiene: archive move FAILED for ${worst}"
                        actions_taken+=("session-hygiene-rotate:FAILED")
                    fi
                elif [[ "$DRY_RUN" -eq 1 ]]; then
                    _log_info "DRY_RUN: would archive ${worst:-<unknown>}"
                    actions_taken+=("session-hygiene-rotate")
                fi
            fi
            ;;
    esac
done

# ── §19-HIGH H1: retry any Telegram alerts that failed to send ─────────────────
_retry_pending_alerts || true

# ── Build last-sweep.json ─────────────────────────────────────────────────────

sweep_end=$(date +%s%N 2>/dev/null || echo "$(( $(date +%s) * 1000000000 ))")
duration_ms=$(( (sweep_end - sweep_start) / 1000000 ))

# Build probes object.
# H-2: iterate the canonical PROBE_KEYS array (not a hardcoded 5-key list) so new
# probes (lock-wedge, session-hygiene added by B2/B6) always appear in the state
# report and the list can't drift out of sync with the dispatch loop again.
probes_json="{"
first=1
for key in "${PROBE_KEYS[@]}"; do
    [[ "$first" -eq 0 ]] && probes_json+=","
    first=0
    status="${probe_statuses[$key]:-skipped}"
    probes_json+="\"${key}\":\"${status}\""
done
probes_json+="}"

# Build actions array.
if [[ ${#actions_taken[@]} -gt 0 ]]; then
    actions_json="[$(printf '"%s",' "${actions_taken[@]}" | sed 's/,$//')]"
else
    actions_json="[]"
fi

# Central time for human-readable timestamp (per gospel §8.8 / feedback_time_in_central).
local_ts="$(TZ='America/Chicago' date '+%Y-%m-%dT%H:%M:%S %Z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"

sweep_state="$(cat <<EOF
{
  "timestamp": "${sweep_ts}",
  "timestamp_central": "${local_ts}",
  "duration_ms": ${duration_ms},
  "dry_run": $([ "$DRY_RUN" -eq 1 ] && echo "true" || echo "false"),
  "probes": ${probes_json},
  "actions_taken": ${actions_json}
}
EOF
)"

_write_state "$sweep_state"

_log_info "sweep complete duration_ms=${duration_ms} actions=${#actions_taken[@]}"

exit 0
