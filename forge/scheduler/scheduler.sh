#!/usr/bin/env bash
# scheduler.sh — Generate per-Gawd systemd-timer unit files (or crontab
# fallback) from IDENTITY.md's timezone field.
#
# This script DOES NOT install anything. It emits unit/timer/crontab text to
# stdout (or to --output-dir if provided). install-crons.sh consumes the
# output and writes the actual files into ~/.config/systemd/user/ (or runs
# `crontab -`).
#
# Why split generation from install:
#   - Generation is pure: same IDENTITY.md → same files. Testable.
#   - Install requires privileges / DBus / linger setup. Side-effectful.
#   - Operators can dry-run with `scheduler.sh --print` to inspect what
#     install-crons.sh would write, without touching the system.
#
# Per handoff E1 acceptance criterion 1:
#   "generates a valid crontab from IDENTITY.md timezone field (default to
#    UTC if missing, with WARNING log)"
#
# Stagger plan (per gospel §8.1 "no simultaneous fire"):
#   02:00 Prophit-local   — sharpen   (longest-running; gets quiet hours)
#   04:00 Prophit-local   — daily-reset (primary anchor; revelation apply)
#   10:00 Prophit-local   — weekly-service (Sundays only)
#   :17 every 6 hours     — cleanup (offset from common :00 boundaries to
#                                    avoid collision with backups/etc.)
#
# All timer-fired jobs include RandomizedDelaySec=60 in the unit file so
# many Gawds on the same host don't fire at the literal same second.
#
# Usage:
#   scheduler.sh --print                  # write all unit/timer text to stdout
#   scheduler.sh --output-dir <dir>       # write each file into <dir>
#   scheduler.sh --mode systemd|cron      # explicit (default: auto-detect)
#   scheduler.sh --workspace <dir>        # override IDENTITY.md location

set -euo pipefail

SCHED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCHED_DIR}/lib/common.sh"
export SCHED_JOB="scheduler-gen"

MODE="auto"
OUTPUT_DIR=""
PRINT_STDOUT=0
WORKSPACE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --print)           PRINT_STDOUT=1; shift ;;
        --output-dir)      OUTPUT_DIR="$2"; shift 2 ;;
        --mode)            MODE="$2"; shift 2 ;;
        --workspace)       WORKSPACE_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            grep '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) fatal 1 "unknown arg: $1" ;;
    esac
done

if [[ -n "$WORKSPACE_OVERRIDE" ]]; then
    export GAWD_WORKSPACE="$WORKSPACE_OVERRIDE"
fi

# Mode resolution: prefer systemd user services if available; else cron.
if [[ "$MODE" == "auto" ]]; then
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl --user --no-pager show-environment >/dev/null 2>&1; then
        MODE="systemd"
    else
        MODE="cron"
        warn "systemctl --user not usable (no session DBus or no linger) — falling back to cron"
    fi
fi

PROPHIT_TZ="$(resolve_prophit_tz)"
SERVICE_HOUR="$(resolve_service_hour)"

log "Generating scheduler config: mode=${MODE} tz=${PROPHIT_TZ} service_hour=${SERVICE_HOUR}"

if [[ "$PROPHIT_TZ" == "UTC" ]] && [[ ! -f "${GAWD_WORKSPACE}/IDENTITY.md" ]]; then
    warn "No IDENTITY.md found; scheduler will run in UTC. Re-run after onboarding to pin Prophit-local times."
fi

# ──────────────────────────────────────────────────────────────────────────
# systemd unit / timer text emitters
# ──────────────────────────────────────────────────────────────────────────

emit_service_unit() {
    # $1 job name (matches script in jobs/, no .sh)
    # $2 short description
    local job="$1"
    local desc="$2"
    cat <<EOF
[Unit]
Description=${desc}
Documentation=file://<install-root>/docs/runbooks/scheduler.md
# StartLimit prevents infinite restart loop if downstream is broken.
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Type=oneshot
# Pass through the workspace location so the job knows where to look.
Environment=GAWD_WORKSPACE=${GAWD_WORKSPACE}
ExecStart=${SCHED_DIR}/jobs/${job}.sh
# Per gospel: idempotent jobs, structured logs; we use journald by default.
# StandardOutput/Error inherit (= journald) — explicit declaration here for
# operator clarity.
StandardOutput=journal
StandardError=journal
# Soft limits to keep a runaway job from eating the box.
MemoryHigh=512M
MemoryMax=1G
# CPUWeight low to keep scheduling out of the Prophit's way.
CPUWeight=20
EOF
}

emit_timer_unit() {
    # $1 job name (matches .service)
    # $2 OnCalendar expression (no Timezone= suffix; we add it via Timezone= field)
    # $3 short description
    # $4 Persistent setting (true = catch up missed runs; false = forward-resolve)
    local job="$1"
    local oncalendar="$2"
    local desc="$3"
    local persistent="${4:-false}"
    cat <<EOF
[Unit]
Description=Timer for ${desc}
Documentation=file://<install-root>/docs/runbooks/scheduler.md

[Timer]
Unit=gawd-${job}.service
OnCalendar=${oncalendar}
# Timezone the OnCalendar expression evaluates in.
# Per handoff: Prophit-local time, computed from IDENTITY.md.
# (systemd >= 247 supports Timezone= on Timer units.)
Timezone=${PROPHIT_TZ}
# Random delay so many Gawds on one host don't fire at the literal same second.
RandomizedDelaySec=60
# Persistent=false: a missed firing while the daemon was down does NOT
# trigger a catch-up at next boot. Per handoff E1 acceptance:
#   "On daemon restart, missed cron firings are NOT replayed; the next
#    scheduled firing catches up"
# Per spec §12.4 timer-persistence pattern:
#   "missed transitions resolve forward to current state; does not replay
#    intermediate transitions"
Persistent=${persistent}
# Accuracy of 1 minute — these are not real-time jobs, no need for tighter.
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
}

# Each entry: <job> <description> <OnCalendar> <persistent>
#
# OnCalendar syntax (per systemd.time(7)):
#   "*-*-* 02:00:00"           = every day at 02:00 in the timer's Timezone
#   "Sun *-*-* 10:00:00"       = Sundays at 10:00 in the timer's Timezone
#   "*-*-* 00,06,12,18:17:00"  = every 6h at 17 past the hour
#
# Stagger choices (no two jobs share a minute):
#   02:00 sharpen          — quietest hours, longest job
#   04:00 daily-reset      — primary anchor, 2h after sharpen so SIL output is ready
#   10:00 Sunday service   — well after morning reset, Prophit's awake-window
#   :17 every 6h cleanup   — odd offset, no collision with hourly system jobs

declare -a JOB_TABLE=(
    "sharpen|Gawd nightly SIL sharpen cycle|*-*-* 02:00:00|false"
    "daily-reset|Gawd daily 4am Prophit-local reset (revelation+SIL+tithe+rotate)|*-*-* 04:00:00|false"
    "weekly-service|Gawd Sunday Service (sermon delivery + revelation offer)|Sun *-*-* ${SERVICE_HOUR}:00:00|false"
    "cleanup|Gawd DemiGawd cleanup + envelope monitor (every 6h)|*-*-* 00,06,12,18:17:00|false"
)

# ──────────────────────────────────────────────────────────────────────────
# Output dispatch
# ──────────────────────────────────────────────────────────────────────────

write_or_print() {
    local rel_path="$1"
    local body="$2"
    if [[ $PRINT_STDOUT -eq 1 ]]; then
        printf '\n──── %s ────\n' "$rel_path"
        printf '%s' "$body"
        printf '\n'
    fi
    if [[ -n "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
        local abs="${OUTPUT_DIR}/${rel_path}"
        mkdir -p "$(dirname "$abs")"
        printf '%s' "$body" > "$abs"
        log "wrote: $abs"
    fi
}

if [[ "$MODE" == "systemd" ]]; then
    for row in "${JOB_TABLE[@]}"; do
        IFS='|' read -r job desc oncalendar persistent <<< "$row"
        svc_text=$(emit_service_unit "$job" "$desc")
        tim_text=$(emit_timer_unit "$job" "$oncalendar" "$desc" "$persistent")
        write_or_print "gawd-${job}.service" "$svc_text"
        write_or_print "gawd-${job}.timer"   "$tim_text"
    done
elif [[ "$MODE" == "cron" ]]; then
    # Cron does NOT support per-line timezone in any portable way. We emit a
    # CRON_TZ block at the top, which Vixie cron + cronie + ISC cron all honor.
    crontab_text="# Gawd scheduler — generated by scheduler.sh
# Mode: cron (systemd user timers unavailable)
# Generated: $(date -Iseconds)
# Timezone: ${PROPHIT_TZ} (from IDENTITY.md)
#
# Each job script is idempotent and stub-tolerant. See:
#   <install-root>/docs/runbooks/scheduler.md
#
# Note: with CRON_TZ, ALL entries below evaluate in ${PROPHIT_TZ}.
# Do NOT add jobs in other timezones here without splitting the crontab.
CRON_TZ=${PROPHIT_TZ}
GAWD_WORKSPACE=${GAWD_WORKSPACE}
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Stagger map (no two jobs share a minute):
#   02:00 — sharpen        | nightly SIL cycle (quietest hours, longest job)
#   04:00 — daily-reset    | primary anchor: revelation + SIL apply + tithe + rotate
#   10:00 — weekly-service | Sundays only: sermon delivery + revelation offer
#   :17 q6h — cleanup      | DemiGawd cleanup + envelope monitor

0  2 * * *   ${SCHED_DIR}/jobs/sharpen.sh
0  4 * * *   ${SCHED_DIR}/jobs/daily-reset.sh
0 ${SERVICE_HOUR} * * 0   ${SCHED_DIR}/jobs/weekly-service.sh
17 0,6,12,18 * * *   ${SCHED_DIR}/jobs/cleanup.sh
"
    write_or_print "crontab.gawd" "$crontab_text"
else
    fatal 1 "unknown mode: $MODE (expected systemd|cron|auto)"
fi

log "scheduler config generation complete (mode=${MODE}, tz=${PROPHIT_TZ})"
