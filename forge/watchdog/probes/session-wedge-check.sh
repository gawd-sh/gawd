#!/usr/bin/env bash
# probes/session-wedge-check.sh — Probe 2: session wedge detection.
#
# Delegates to G4 session-recovery's detect.sh (via sweep.sh) for the real
# wedge logic. When G4 is not yet installed, falls back to a direct index scan
# using the same detection rules (sr_is_session_wedged_by_key logic from
# session-recovery/lib/common.sh).
#
# Exits:
#   0  probe passed   (no wedged sessions found)
#   1  probe failed   (one or more wedged sessions detected)
#   2  probe inconclusive (index not found / jq unavailable)
#
# Stdout: one JSON result line per probe call:
#   {"probe":"session-wedge","status":"ok|fail|warn","wedged_sessions":[],"detail":"..."}
#
# Spec: §19.2 Layer 7, §19.6 "Session wedged after terminal error"
# Coordinates with G4 (Layer 4) per README.md:
#   L7 watchdog's session-wedge-check.sh probe calls G4's detect.sh.
#   When wedged, L7 calls G4's recover.sh <session-id>.

set -euo pipefail

PROBE_NAME="session-wedge"

# G4 paths — overridable via env for testing.
: "${GAWD_HOME:=${HOME}/.gawd}"
: "${SR_OPENCLAW_HOME:=${HOME}/.openclaw}"
: "${SR_AGENT_ID:=main}"
SR_SESSIONS_DIR="${SR_OPENCLAW_HOME}/agents/${SR_AGENT_ID}/sessions"
SR_INDEX_FILE="${SR_SESSIONS_DIR}/sessions.json"
SR_STATE_DIR="${GAWD_HOME}/state/session-recovery"
SR_RECOVERY_LOG="${SR_STATE_DIR}/recovery-log.jsonl"

# Threshold: don't flag sessions whose last interaction is within this many ms.
: "${SR_WEDGE_GRACE_MS:=10000}"
# Terminal-error regex (matches non_deliverable_terminal_turn and siblings).
: "${SR_TERMINAL_ERROR_REGEX:=^non_d}"

# G4 sweep.sh path — used when G4 is installed.
G4_SWEEP="${GAWD_HOME}/engine/session-recovery/sweep.sh"
# Alternative: the forge source (not production-installed).
G4_SWEEP_FORGE="/usr/local/lib/gawd/silence-avoidance/session-recovery/sweep.sh"

_result() {
    local status="$1" wedged_json="$2" detail="$3"
    printf '{"probe":"%s","status":"%s","wedged_sessions":%s,"detail":"%s"}\n' \
        "$PROBE_NAME" "$status" "$wedged_json" "$detail"
}

require_jq() {
    command -v jq >/dev/null 2>&1 || {
        _result "warn" "[]" "jq not available; probe inconclusive"
        exit 2
    }
}

# ── Try delegating to G4 first ──────────────────────────────────────────────

# G4 sweep.sh invocation (with SR_DRY_RUN=1 so no mutations from this probe).
# Output format from G4 sweep: one JSON line per wedged session found, or empty.
if [[ -x "$G4_SWEEP" ]]; then
    wedged_output="$(SR_DRY_RUN=1 timeout 5 "$G4_SWEEP" 2>/dev/null || true)"
    wedged_count="$(printf '%s' "$wedged_output" | grep -c '"action":"detected"' 2>/dev/null || echo 0)"
    if [[ "$wedged_count" -gt 0 ]]; then
        session_ids="$(printf '%s' "$wedged_output" \
            | jq -r 'select(.action=="detected") | .session_id // empty' 2>/dev/null \
            | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")"
        _result "fail" "$session_ids" "${wedged_count} wedged session(s) detected via G4"
        exit 1
    fi
    _result "ok" "[]" "G4 sweep: no wedged sessions"
    exit 0
fi

# ── Fallback: direct index scan (same rules as G4 common.sh) ─────────────────

require_jq

if [[ ! -f "$SR_INDEX_FILE" ]]; then
    _result "ok" "[]" "no sessions index at ${SR_INDEX_FILE}"
    exit 0
fi

now_ms=$(( $(date +%s) * 1000 ))
grace_floor=$(( now_ms - SR_WEDGE_GRACE_MS ))

wedged=()

# Read every session key from the index.
while IFS= read -r key; do
    [[ -z "$key" ]] && continue

    entry="$(jq -c --arg k "$key" '.[$k] // empty' "$SR_INDEX_FILE" 2>/dev/null)"
    [[ -z "$entry" || "$entry" == "null" ]] && continue

    status="$(printf '%s' "$entry"   | jq -r '.status // empty')"
    term_err="$(printf '%s' "$entry" | jq -r '.terminalError // empty')"
    aborted="$(printf '%s' "$entry"  | jq -r '.abortedLastRun // false')"
    last_at="$(printf '%s' "$entry"  | jq -r '.lastInteractionAt // 0')"
    sid="$(printf '%s' "$entry"      | jq -r '.sessionId // empty')"

    # Rule 1: terminal-error family present.
    has_terminal=0
    if [[ -n "$term_err" ]] && printf '%s' "$term_err" | grep -qE "$SR_TERMINAL_ERROR_REGEX"; then
        has_terminal=1
    fi
    # Secondary check: trajectory file if status is failed/error.
    if [[ $has_terminal -eq 0 ]] && [[ "$status" == "failed" || "$status" == "error" ]]; then
        jsonl_path="${SR_SESSIONS_DIR}/${sid}.jsonl"
        if [[ -f "$jsonl_path" ]]; then
            if tail -n 50 "$jsonl_path" 2>/dev/null \
                | grep -qE '"terminalError"[[:space:]]*:[[:space:]]*"non_d[a-zA-Z_]*"'; then
                has_terminal=1
            fi
        fi
    fi
    [[ $has_terminal -eq 0 ]] && continue

    # Rule 2: aborted flag.
    [[ "$aborted" != "true" ]] && continue

    # Rule 3: grace window.
    if [[ "$last_at" =~ ^[0-9]+$ ]] && (( last_at > grace_floor )); then
        continue
    fi

    # Rule 4: idempotence — already recovered?
    if [[ -f "$SR_RECOVERY_LOG" && -n "$sid" ]]; then
        already="$(grep -F "\"$sid\"" "$SR_RECOVERY_LOG" 2>/dev/null \
            | jq -c --arg sid "$sid" --argjson floor "$last_at" \
                'select(.session_id == $sid)
                 | select(.action == "recovered")
                 | select((.last_interaction_at_ms // 0) >= $floor)' 2>/dev/null \
            | head -n 1)"
        [[ -n "$already" ]] && continue
    fi

    wedged+=("$sid")
done < <(jq -r 'keys[]' "$SR_INDEX_FILE" 2>/dev/null)

if [[ ${#wedged[@]} -gt 0 ]]; then
    wedged_json="$(printf '%s\n' "${wedged[@]}" \
        | jq -Rs 'split("\n") | map(select(length > 0))')"
    _result "fail" "$wedged_json" "${#wedged[@]} wedged session(s) detected (fallback scan)"
    exit 1
fi

_result "ok" "[]" "no wedged sessions"
exit 0
