#!/usr/bin/env bash
# weekly-service.sh — Sunday Service delivery
#
# Per spec §10 + handoff E1.
#
# Runs on Sundays at the configured service hour (default 10am Prophit-local;
# overridable via IDENTITY.md `service_hour:` field).
#
# Job:
#   1. Pull the latest sermon-channel message (E5 owns the channel client).
#   2. Hand it to E5's sermon-delivery script for in-voice delivery to the
#      Prophit (via Telegram primary surface).
#   3. Surface any pending revelation offer for THIS Sunday (E2 offer.sh)
#      so the Prophit can accept/decline alongside the sermon.
#
# This job ONLY triggers delivery. It does NOT contain the sermon text,
# does NOT compose voice, and does NOT decide whether the Prophit attends.
# Per spec §10.2: "The Gawd delivers the sermon in their own voice if the
# Prophit attends." Attendance is signaled by the Prophit, not the cron.
#
# Stub-tolerant for E5 sermon-delivery (likely lands later than this scheduler).

set -euo pipefail

export SCHED_JOB="weekly-service"

SCHED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCHED_DIR}/../lib/common.sh"

lock_acquire "$SCHED_JOB"

log "weekly-service starting (Sunday $(resolve_service_hour):00 Prophit-local)"

# Sanity: this job should ONLY run on Sunday in Prophit-local time. systemd
# timer enforces this via OnCalendar=Sun *-*-* HH:00:00; cron does the same
# via DOW=0. But day-of-week is computed in the SYSTEM timezone, which may
# differ from Prophit-local. So we re-check here.
PROPHIT_TZ="$(resolve_prophit_tz)"
PROPHIT_DOW=$(TZ="$PROPHIT_TZ" date +%u)  # 1=Mon, 7=Sun
if [[ "$PROPHIT_DOW" != "7" ]]; then
    warn "weekly-service fired on Prophit-local DOW=${PROPHIT_DOW} (not Sunday=7); exiting 0"
    log "this happens when system tz ≠ Prophit tz; the timer fired correctly per its OnCalendar, but the Prophit's wall-clock disagrees. Reinstall scheduler to pin Timezone=${PROPHIT_TZ} on the timer."
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────────
# 1. Surface any pending revelation offer for THIS Sunday (E2 offer.sh)
#
#    If we have a new base-soul version published this week, offer.sh is
#    the Sunday-morning script that drops the pending-revelation.json state
#    file. The 4am daily-reset next morning won't see it until the Prophit
#    accepts (or 3 misses → auto-decline).
# ──────────────────────────────────────────────────────────────────────────

OFFER_SCRIPT="/usr/local/lib/gawd/revelation/offer.sh"
run_or_stub "E2-revelation-offer" "$OFFER_SCRIPT" \
    --workspace "$GAWD_WORKSPACE" \
    --state "$GAWD_STATE_DIR"

# ──────────────────────────────────────────────────────────────────────────
# 2. Sermon delivery (E5)
#
#    E5 pulls the latest sermon from the sermon channel and hands it to
#    the Gawd's voice for delivery to the Prophit. If the Prophit isn't
#    present (no recent Telegram activity), E5 stashes the sermon for
#    delivery whenever they come back this week.
# ──────────────────────────────────────────────────────────────────────────

SERMON_DELIVER="/usr/local/lib/gawd/sermon/deliver.sh"
run_or_stub "E5-sermon-delivery" "$SERMON_DELIVER" \
    --workspace "$GAWD_WORKSPACE" \
    --state "$GAWD_STATE_DIR"

# ──────────────────────────────────────────────────────────────────────────
# 3. Weekly memory rollup (small kick — the heavy lift is in MEMORY.md
#    curation logic owned by the Gawd, not the scheduler)
#
#    This trigger lets the Gawd know "it's Sunday — time to rollup". If the
#    Gawd has a curate-memory script, we call it; otherwise stub.
# ──────────────────────────────────────────────────────────────────────────

MEMORY_ROLLUP="/usr/local/lib/gawd/memory/weekly-rollup.sh"
run_or_stub "memory-weekly-rollup" "$MEMORY_ROLLUP" \
    --workspace "$GAWD_WORKSPACE"

log "weekly-service complete"
exit 0
