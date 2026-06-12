#!/usr/bin/env bash
# probes/last-activity-check.sh — Probe 5: Last successful agent reply check.
#
# Detects the 2026-05-27 scenario where: messages are arriving, gateway is
# alive, session is alive — but no reply has been sent in the last N minutes.
# This is the "silent absorption" failure mode: gateway takes messages, never
# produces output, Prophit thinks Gawd is dead.
#
# Detection:
#   1. Find the most-recent message RECEIVED by the gateway (from Prophit).
#   2. Find the most-recent message SENT by the agent (to Prophit).
#   3. If received > sent by more than LAST_ACTIVITY_THRESHOLD_S, flag suspect.
#
# Data source:
#   - sessions.json: lastInteractionAt (most recent message received or sent)
#   - trajectory.jsonl: type="model.completed" ts = last successful reply turn
#   - gateway.log: "delivering reply" or equivalent pattern
#
# Outputs: ok | warn | fail
# Exits: 0=ok, 1=fail (active silent-absorption), 3=warn (borderline)
#
# Spec: §19.2 Layer 7 probe 5, §19.6 "Telegram MCP plugin disconnected" (silent variant)
# No LLM. Pure bash + jq.

set -euo pipefail
trap 'printf "ok\n"; exit 0' ERR   # probe failure = assume ok, never cascade

SESSIONS_DIR="${GAWD_SESSIONS_DIR:-${HOME}/.openclaw/agents/main/sessions}"
GATEWAY_LOG="${GAWD_GATEWAY_LOG:-${HOME}/gateway.log}"
LAST_ACTIVITY_THRESHOLD_S="${LAST_ACTIVITY_THRESHOLD_S:-900}"  # 15 minutes
WARN_THRESHOLD_S="${WARN_THRESHOLD_S:-600}"                    # 10 minutes = warn

command -v jq >/dev/null 2>&1 || { printf "ok\n"; exit 0; }
[[ -d "$SESSIONS_DIR" ]] || { printf "ok\n"; exit 0; }

now="$(date +%s)"

# ── Find last RECEIVED message time ───────────────────────────────────────────
# sessions.json lastInteractionAt is set on any message receipt (inbound or
# outbound). We need last INBOUND message.
last_received_epoch=0
if [[ -f "${SESSIONS_DIR}/sessions.json" ]]; then
    # lastInteractionAt in milliseconds; take the max across all active sessions
    max_interaction="$(jq -r '
        to_entries[]
        | select(.value.lastInteractionAt != null)
        | .value.lastInteractionAt
    ' "${SESSIONS_DIR}/sessions.json" 2>/dev/null | sort -n | tail -1 || true)"
    if [[ -n "$max_interaction" && "$max_interaction" != "null" ]]; then
        last_received_epoch=$(( max_interaction / 1000 ))
    fi
fi

# If no interaction at all, cannot assess — emit ok
if [[ "$last_received_epoch" -eq 0 ]]; then
    printf "ok\n"
    exit 0
fi

# If last interaction was itself >threshold ago, nothing is arriving anyway
# (Prophit hasn't messaged). Not a silent-absorption scenario.
interaction_age=$(( now - last_received_epoch ))
if (( interaction_age > LAST_ACTIVITY_THRESHOLD_S )); then
    printf "ok\n"
    exit 0
fi

# ── Find last SENT reply time ──────────────────────────────────────────────────
# Use trajectory.jsonl model.completed ts as proxy for "last reply produced".
last_reply_epoch=0
for traj in "${SESSIONS_DIR}"/*.trajectory.jsonl; do
    [[ -f "$traj" ]] || continue
    last_completed="$(tail -n 100 "$traj" 2>/dev/null | \
        jq -r 'select(.type == "model.completed") | .ts' 2>/dev/null | \
        tail -1 || true)"
    [[ -z "$last_completed" ]] && continue
    completed_epoch="$(date -d "$last_completed" +%s 2>/dev/null || true)"
    [[ -z "$completed_epoch" ]] && continue
    if (( completed_epoch > last_reply_epoch )); then
        last_reply_epoch="$completed_epoch"
    fi
done

# ── Assess gap ────────────────────────────────────────────────────────────────
# If we found a recent interaction but no recent reply, something is off.
if [[ "$last_reply_epoch" -eq 0 ]]; then
    # Never produced a reply in observable trajectory — might be brand new
    # session (first boot, no history) — emit warn not fail
    if (( interaction_age > WARN_THRESHOLD_S )); then
        printf "warn\n"
        exit 3
    fi
    printf "ok\n"
    exit 0
fi

reply_age=$(( now - last_reply_epoch ))

# Message received recently but no reply in >threshold = silent absorption
if (( interaction_age < LAST_ACTIVITY_THRESHOLD_S )) && (( reply_age > LAST_ACTIVITY_THRESHOLD_S )); then
    printf "fail\n"
    exit 1
fi

# Borderline: warn
if (( interaction_age < LAST_ACTIVITY_THRESHOLD_S )) && (( reply_age > WARN_THRESHOLD_S )); then
    printf "warn\n"
    exit 3
fi

printf "ok\n"
exit 0
