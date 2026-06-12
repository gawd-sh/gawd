#!/usr/bin/env bash
# lib/common.sh — shared helpers for scheduler scripts
#
# Sourced by every job script. Provides:
#   - log() / warn() / fatal() with structured prefix
#   - run_or_stub <label> <path-to-script> [args...]
#       Executes the downstream script if it exists and is executable;
#       otherwise emits a structured "stub" line and returns 0.
#       This is the load-bearing pattern that lets E1 ship before E2/E3/E5
#       without disabling cron firings (per handoff explicit guidance).
#   - lock_acquire / lock_release — flock-based mutual exclusion per job
#   - resolve_workspace / resolve_state — workspace + state dir resolution
#
# All scripts source this file via:
#   SCHED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCHED_DIR}/../lib/common.sh"

# Defensive: do not 'set -e' here. The caller chooses error policy. We use
# explicit return codes from helpers; callers decide whether non-zero is fatal.

: "${GAWD_WORKSPACE:=${HOME}/.gawd}"
: "${GAWD_STATE_DIR:=${GAWD_WORKSPACE}/state}"
: "${GAWD_LOG_DIR:=${GAWD_WORKSPACE}/logs/scheduler}"
: "${GAWD_RUN_DIR:=${GAWD_WORKSPACE}/run/scheduler}"

mkdir -p "$GAWD_LOG_DIR" "$GAWD_RUN_DIR" 2>/dev/null || true

# Structured log line. Goes to stderr (so it appears in journald when called
# under a systemd unit) AND appends to a per-job log file for offline review.
log() {
    local msg="$*"
    local job="${SCHED_JOB:-scheduler}"
    local line
    line="$(printf '[%s %s job=%s] %s' \
        "$(date -Iseconds)" "INFO" "$job" "$msg")"
    printf '%s\n' "$line" >&2
    if [[ -n "${SCHED_JOB:-}" ]]; then
        printf '%s\n' "$line" >> "${GAWD_LOG_DIR}/${SCHED_JOB}.log" 2>/dev/null || true
    fi
}

warn() {
    local msg="$*"
    local job="${SCHED_JOB:-scheduler}"
    local line
    line="$(printf '[%s %s job=%s] %s' \
        "$(date -Iseconds)" "WARN" "$job" "$msg")"
    printf '%s\n' "$line" >&2
    if [[ -n "${SCHED_JOB:-}" ]]; then
        printf '%s\n' "$line" >> "${GAWD_LOG_DIR}/${SCHED_JOB}.log" 2>/dev/null || true
    fi
}

fatal() {
    local code="${1:-1}"; shift || true
    local msg="$*"
    local job="${SCHED_JOB:-scheduler}"
    local line
    line="$(printf '[%s %s job=%s exit=%d] %s' \
        "$(date -Iseconds)" "FATAL" "$job" "$code" "$msg")"
    printf '%s\n' "$line" >&2
    if [[ -n "${SCHED_JOB:-}" ]]; then
        printf '%s\n' "$line" >> "${GAWD_LOG_DIR}/${SCHED_JOB}.log" 2>/dev/null || true
    fi
    exit "$code"
}

# run_or_stub <label> <path-to-script> [args...]
#
# If the script exists and is executable, run it with the supplied args.
# Log start + duration + exit code; never propagate a non-zero from the
# downstream script as a fatal (per handoff: "avoid hard failures that
# disable the cron").
#
# If the script does NOT exist or is not executable, emit a "stub" log line
# and return 0. This keeps the cron firing across stub-state weeks while
# E2/E3/E5 are still landing.
#
# Returns 0 always (the cron job stays alive). Internal exit code is logged
# for observability; callers that need it can use $LAST_RUN_EXIT.
run_or_stub() {
    local label="$1"; shift
    local script="$1"; shift
    LAST_RUN_EXIT=0

    if [[ ! -e "$script" ]]; then
        log "stub: would have called ${label} → ${script} (not present yet)"
        return 0
    fi
    if [[ ! -x "$script" ]]; then
        warn "stub: ${label} script not executable: ${script} (chmod +x missing?)"
        return 0
    fi

    local started elapsed rc
    started=$(date +%s)
    log "calling ${label}: ${script} $*"

    set +e
    "$script" "$@"
    rc=$?
    set -e
    LAST_RUN_EXIT=$rc

    elapsed=$(( $(date +%s) - started ))

    if [[ $rc -eq 0 ]]; then
        log "${label} completed ok (duration=${elapsed}s)"
    else
        warn "${label} exited non-zero (rc=${rc} duration=${elapsed}s) — cron continues"
    fi
    return 0
}

# flock-based per-job lock. Prevents re-entrancy if a manual run and a timer
# fire fall on the same minute. Lock is non-blocking: if a prior invocation
# is still running, the new one exits 0 with a log line.
lock_acquire() {
    local job="$1"
    local lockfile="${GAWD_RUN_DIR}/${job}.lock"

    # Use file descriptor 9 for the lock; tied to the script's lifetime.
    exec 9>"$lockfile" || {
        warn "could not open lockfile: ${lockfile} — proceeding without lock"
        return 0
    }
    if ! flock -n 9; then
        log "lock held by prior invocation (pid lock=${lockfile}) — exit 0"
        exit 0
    fi
    # On exit, the FD closes and the lock releases automatically.
}

# Resolve Prophit-local timezone from IDENTITY.md.
# Returns the IANA tz string on stdout. Defaults to UTC with a WARN log if
# IDENTITY.md is absent or malformed.
resolve_prophit_tz() {
    local identity_md="${GAWD_WORKSPACE}/IDENTITY.md"
    if [[ ! -f "$identity_md" ]]; then
        warn "IDENTITY.md not present at ${identity_md} — defaulting to UTC"
        echo "UTC"
        return 0
    fi
    # Extract the first `timezone:` value from the Prophits list block.
    # The IDENTITY.md template puts the field as:   timezone: America/Chicago
    local tz
    tz=$(grep -m1 -E '^\s*timezone:\s*' "$identity_md" 2>/dev/null \
        | sed -E 's/^\s*timezone:\s*//' \
        | tr -d '"' | tr -d "'" \
        | awk '{print $1}')

    if [[ -z "$tz" || "$tz" == "{IANA" ]]; then
        warn "IDENTITY.md has no concrete timezone field — defaulting to UTC"
        echo "UTC"
        return 0
    fi

    # Sanity-check: does this tz exist on this box?
    if [[ ! -e "/usr/share/zoneinfo/$tz" ]]; then
        warn "IDENTITY.md timezone '${tz}' not found in zoneinfo — defaulting to UTC"
        echo "UTC"
        return 0
    fi

    echo "$tz"
}

# Resolve a configured slot from IDENTITY.md or sensible default.
# Currently used for Sunday service hour. Default 10 (10am Prophit-local).
resolve_service_hour() {
    local identity_md="${GAWD_WORKSPACE}/IDENTITY.md"
    if [[ -f "$identity_md" ]]; then
        local hour
        hour=$(grep -m1 -E '^\s*service_hour:\s*' "$identity_md" 2>/dev/null \
            | sed -E 's/^\s*service_hour:\s*//' \
            | awk '{print $1}')
        if [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 )); then
            echo "$hour"
            return 0
        fi
    fi
    echo "10"
}
