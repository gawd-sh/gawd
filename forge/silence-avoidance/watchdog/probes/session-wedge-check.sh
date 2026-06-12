#!/usr/bin/env bash
# probes/session-wedge-check.sh — Probe 2: Session wedge detection.
#
# Scans the active OpenClaw sessions directory for trajectory.jsonl files
# whose most-recent event indicates a terminal/stuck state without a
# subsequent successful model.completed event.
#
# Wedge signatures (from the 2026-05-27 Dasra incident):
#   - type == "terminalError" with data.reason containing "non_deliverable"
#   - type == "prompt.submitted" with NO subsequent "model.completed" within
#     the stale-session threshold (default 10 minutes)
#   - sessions.json entry where .status == "failed" and updatedAt is recent
#
# Outputs JSON array of wedged session IDs to stdout (may be empty array).
# Exits 0 if no wedge detected; exits 1 if any wedge found.
# Exits 2 on probe infrastructure error (missing jq, missing sessions dir).
#
# Spec: §19.2 Layer 7, §19.6 "Watchdog finds stuck gateway"
# No LLM calls. Pure bash + jq + date.

set -euo pipefail
trap 'printf "[]\n"; exit 2' ERR

SESSIONS_DIR="${GAWD_SESSIONS_DIR:-${HOME}/.openclaw/agents/main/sessions}"
STALE_THRESHOLD_S="${STALE_THRESHOLD_S:-600}"   # 10 minutes: no model.completed = suspect wedge
MAX_TRAJECTORY_LINES="${MAX_TRAJECTORY_LINES:-200}"  # only read tail of large files

command -v jq >/dev/null 2>&1 || { printf '[]\n'; exit 2; }

[[ -d "$SESSIONS_DIR" ]] || { printf '[]\n'; exit 2; }

now_epoch="$(date +%s)"
wedged=()

# ── Method 1: sessions.json status=failed ─────────────────────────────────────
sessions_json="${SESSIONS_DIR}/sessions.json"
if [[ -f "$sessions_json" ]]; then
    while IFS= read -r session_id; do
        [[ -n "$session_id" ]] && wedged+=("$session_id")
    done < <(
        jq -r --arg now "$now_epoch" --arg thresh "$STALE_THRESHOLD_S" '
            to_entries[]
            | select(
                .value.status == "failed"
                and .value.updatedAt != null
                and (($now | tonumber) - (.value.updatedAt / 1000 | floor)) < ($thresh | tonumber) * 10
              )
            | .value.sessionId // empty
        ' "$sessions_json" 2>/dev/null || true
    )
fi

# ── Method 2: trajectory.jsonl scan for non_deliverable terminalError ─────────
for traj in "${SESSIONS_DIR}"/*.trajectory.jsonl; do
    [[ -f "$traj" ]] || continue
    session_id="$(basename "$traj" .trajectory.jsonl)"

    # Read last N lines only — keep probe fast
    recent="$(tail -n "$MAX_TRAJECTORY_LINES" "$traj" 2>/dev/null || true)"
    [[ -z "$recent" ]] && continue

    # Check for terminalError type with non_deliverable reason
    if printf '%s\n' "$recent" | jq -e '
        select(
            .type == "terminalError"
            and (
                (.data.reason // "") | test("non_deliverable|terminal_turn"; "i")
            )
        )
    ' >/dev/null 2>&1; then
        # Verify no successful model.completed AFTER the terminalError
        last_completed="$(printf '%s\n' "$recent" | jq -r 'select(.type == "model.completed") | .seq' 2>/dev/null | tail -1 || true)"
        last_terminal="$(printf '%s\n' "$recent" | jq -r '
            select(
                .type == "terminalError"
                and ((.data.reason // "") | test("non_deliverable|terminal_turn"; "i"))
            ) | .seq
        ' 2>/dev/null | tail -1 || true)"
        if [[ -n "$last_terminal" ]] && { [[ -z "$last_completed" ]] || (( last_completed < last_terminal )); }; then
            # Deduplicate
            already=0
            for w in "${wedged[@]}"; do
                [[ "$w" == "$session_id" ]] && { already=1; break; }
            done
            [[ "$already" == "0" ]] && wedged+=("$session_id")
        fi
    fi
done

# ── Method 3: prompt.submitted with no model.completed within threshold ────────
for traj in "${SESSIONS_DIR}"/*.trajectory.jsonl; do
    [[ -f "$traj" ]] || continue
    session_id="$(basename "$traj" .trajectory.jsonl)"

    # Skip if already flagged
    already=0
    for w in "${wedged[@]}"; do
        [[ "$w" == "$session_id" ]] && { already=1; break; }
    done
    [[ "$already" == "1" ]] && continue

    recent="$(tail -n "$MAX_TRAJECTORY_LINES" "$traj" 2>/dev/null || true)"
    [[ -z "$recent" ]] && continue

    last_submitted_ts="$(printf '%s\n' "$recent" | jq -r 'select(.type == "prompt.submitted") | .ts' 2>/dev/null | tail -1 || true)"
    last_completed_ts="$(printf '%s\n' "$recent" | jq -r 'select(.type == "model.completed") | .ts' 2>/dev/null | tail -1 || true)"

    [[ -z "$last_submitted_ts" ]] && continue

    submitted_epoch="$(date -d "$last_submitted_ts" +%s 2>/dev/null || true)"
    [[ -z "$submitted_epoch" ]] && continue

    age=$(( now_epoch - submitted_epoch ))
    if (( age > STALE_THRESHOLD_S )); then
        # A prompt was submitted >threshold ago and no completed after it
        if [[ -z "$last_completed_ts" ]]; then
            wedged+=("$session_id")
        else
            completed_epoch="$(date -d "$last_completed_ts" +%s 2>/dev/null || true)"
            if [[ -n "$completed_epoch" ]] && (( submitted_epoch > completed_epoch )); then
                wedged+=("$session_id")
            fi
        fi
    fi
done

# ── Output ─────────────────────────────────────────────────────────────────────
if [[ "${#wedged[@]}" -eq 0 ]]; then
    printf '[]\n'
    exit 0
else
    # Emit JSON array of unique session IDs
    printf '['
    first=1
    for w in "${wedged[@]}"; do
        [[ "$first" == "1" ]] && first=0 || printf ','
        printf '"%s"' "$w"
    done
    printf ']\n'
    exit 1
fi
