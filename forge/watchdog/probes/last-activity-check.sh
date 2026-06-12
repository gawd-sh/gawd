#!/usr/bin/env bash
# probes/last-activity-check.sh — Probe 5: last successful agent reply timestamp.
#
# If no successful agent reply has been delivered in STALE_REPLY_MIN minutes
# while messages ARE arriving (detected via inbound-message indicator), this
# probe flags a suspected wedge. This is the "slow detection" path: session-
# wedge-check (probe 2) catches explicit terminal-error state; this probe
# catches the broader "gateway alive, sessions look ok in index, but no actual
# reply has gone out in a while" case.
#
# Sources for "last reply" (tried in order):
#   1. $GAWD_HOME/state/last-reply-at        — written by deliver scripts on
#      every successful delivery. Authoritative.
#   2. $GAWD_HOME/state/session-recovery/recovery-log.jsonl — last "recovered"
#      or "cleared" action (implies prior wedge, now fixed; treat as activity).
#   3. sessions.json lastInteractionAt field across all non-wedged sessions.
#
# Sources for "messages are arriving":
#   1. $GAWD_HOME/state/last-inbound-at      — written by channel layer on
#      every received message. If this file exists and is recent, messages are
#      arriving.
#   2. If neither source is available, skip the arriving-messages check and
#      flag based on reply-age alone (conservative).
#
# Exits:
#   0  probe passed (reply is recent, or no inbound messages to worry about)
#   1  probe failed (stale reply while messages are arriving)
#
# Stdout: {"probe":"last-activity","status":"ok|fail|warn","last_reply_ago_s":N,"detail":"..."}
#
# Spec: §19.2 Layer 7, §19.6 "Last-activity stale"

set -euo pipefail

PROBE_NAME="last-activity"

: "${GAWD_HOME:=${HOME}/.gawd}"
: "${OPENCLAW_HOME:=${HOME}/.openclaw}"
: "${SR_AGENT_ID:=main}"
SR_INDEX_FILE="${OPENCLAW_HOME}/agents/${SR_AGENT_ID}/sessions/sessions.json"
SR_RECOVERY_LOG="${GAWD_HOME}/state/session-recovery/recovery-log.jsonl"

LAST_REPLY_FILE="${GAWD_HOME}/state/last-reply-at"
LAST_INBOUND_FILE="${GAWD_HOME}/state/last-inbound-at"

# Thresholds — overridable via env.
: "${STALE_REPLY_MIN:=15}"              # minutes without a reply before flagging
STALE_REPLY_SEC=$(( STALE_REPLY_MIN * 60 ))
: "${INBOUND_RECENT_MIN:=10}"           # inbound message must be within this to consider "messages arriving"
INBOUND_RECENT_SEC=$(( INBOUND_RECENT_MIN * 60 ))

_result() {
    local status="$1" ago_s="$2" detail="$3"
    printf '{"probe":"%s","status":"%s","last_reply_ago_s":%s,"detail":"%s"}\n' \
        "$PROBE_NAME" "$status" "$ago_s" "$detail"
}

now_epoch=$(date +%s)

# ── Find last reply epoch ──────────────────────────────────────────────────────

last_reply_epoch=0

# Source 1: explicit state file.
if [[ -f "$LAST_REPLY_FILE" ]]; then
    val="$(cat "$LAST_REPLY_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        last_reply_epoch="$val"
    fi
fi

# Source 2: recovery log (treat recovered/cleared as activity signal).
if [[ $last_reply_epoch -eq 0 && -f "$SR_RECOVERY_LOG" ]]; then
    if command -v jq >/dev/null 2>&1; then
        rec_ts="$(jq -r 'select(.action == "recovered" or .action == "cleared") | .ts' \
            "$SR_RECOVERY_LOG" 2>/dev/null | tail -n 1)"
        if [[ -n "$rec_ts" ]]; then
            rec_epoch="$(date -d "$rec_ts" +%s 2>/dev/null || echo 0)"
            if (( rec_epoch > last_reply_epoch )); then
                last_reply_epoch="$rec_epoch"
            fi
        fi
    fi
fi

# Source 3: sessions index lastInteractionAt (fallback; noisy if sessions are wedged).
if [[ $last_reply_epoch -eq 0 && -f "$SR_INDEX_FILE" ]] && command -v jq >/dev/null 2>&1; then
    # Find the maximum lastInteractionAt across all sessions where status is not failed/error.
    max_ms="$(jq -r '
        to_entries[]
        | select(.value.status != "failed" and .value.status != "error")
        | .value.lastInteractionAt // 0
    ' "$SR_INDEX_FILE" 2>/dev/null \
        | sort -n | tail -n 1)"
    if [[ -n "$max_ms" && "$max_ms" =~ ^[0-9]+$ ]] && (( max_ms > 0 )); then
        # Convert ms to s.
        last_reply_epoch=$(( max_ms / 1000 ))
    fi
fi

# ── Find last inbound epoch ────────────────────────────────────────────────────

last_inbound_epoch=0
if [[ -f "$LAST_INBOUND_FILE" ]]; then
    val="$(cat "$LAST_INBOUND_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        last_inbound_epoch="$val"
    fi
fi

# ── Decision logic ─────────────────────────────────────────────────────────────

if [[ $last_reply_epoch -eq 0 ]]; then
    # No reply data at all — no baseline to check against.
    _result "warn" "0" "no last-reply-at baseline; probe inconclusive (new deployment?)"
    exit 0
fi

reply_age=$(( now_epoch - last_reply_epoch ))

# Are messages arriving?
messages_arriving=0
if [[ $last_inbound_epoch -gt 0 ]]; then
    inbound_age=$(( now_epoch - last_inbound_epoch ))
    if (( inbound_age <= INBOUND_RECENT_SEC )); then
        messages_arriving=1
    fi
fi

if (( reply_age > STALE_REPLY_SEC )); then
    if [[ $messages_arriving -eq 1 ]]; then
        _result "fail" "$reply_age" \
            "no reply in ${reply_age}s while messages arriving (threshold: ${STALE_REPLY_SEC}s) — suspected wedge"
        exit 1
    else
        # Stale reply but no recent inbound messages — not alarming.
        _result "ok" "$reply_age" \
            "reply is ${reply_age}s old but no recent inbound messages; no action needed"
        exit 0
    fi
fi

_result "ok" "$reply_age" "last reply ${reply_age}s ago (within ${STALE_REPLY_SEC}s threshold)"
exit 0
