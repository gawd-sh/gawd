#!/usr/bin/env bash
# dream-verify.sh — Day-narrative fail-loud guard.
#
# Checks whether the current day (or GAWD_VERIFY_FORCE_TODAY) produced at
# least one non-empty dream-*.md note in GAWD_DREAM_DAY_NOTE_DIR. If the
# day had messages in lcm.db but zero non-empty notes, emits a structured
# ERROR via observability/logger.sh and raises an operator alert via the
# generic silence-avoidance engine.
#
# Design contracts (per Metatron handoff 2026-06-02):
#   - NEVER exit non-zero: the cron must never be broken by this guard.
#   - NEVER read/echo token files: engine.sh handles last-resort curl itself.
#   - One alert per failed day: once-per-day marker suppresses repeats.
#   - Idle-day silent: if lcm.db has zero messages for the day, no alert.
#   - Append-not-clobber: this script writes markers only; never touches notes.
#
# Env vars:
#   GAWD_LCM_DB               — path to lcm.db (default: /home/gawd/.openclaw/lcm.db)
#   GAWD_DREAM_DAY_NOTE_DIR   — dir containing dream-*.md notes (T3 archive)
#   GAWD_VERIFY_STATE_DIR     — dir for once-per-day alert markers and missing-narrative markers
#   GAWD_PROPHIT_ID           — Prophit identifier passed to engine.sh (default: "prophit")
#   GAWD_PRIMARY_CHANNEL      — channel passed to engine.sh (default: "telegram")
#   GAWD_VERIFY_ENGINE        — path to engine.sh (default: baked image path)
#   GAWD_VERIFY_MIN_BODY      — minimum non-whitespace chars for a note to count (default: 40)
#   GAWD_VERIFY_FORCE_TODAY   — override today's date (YYYY-MM-DD) — for backstop calls
#   GAWD_VERIFY_DRY_RUN       — if 1: render alert path but do not deliver; for tests
#
# Test hooks:
#   GAWD_VERIFY_ENGINE        — point at a mock script
#   GAWD_VERIFY_FORCE_TODAY   — override date
#   GAWD_VERIFY_DRY_RUN=1    — dry-run

# NOTE: intentionally NOT set -e. Must never crash the cron.
set -uo pipefail

# ── Source structured logger ─────────────────────────────────────────────────
# Locate logger.sh relative to this script's position (works both at the baked
# path /usr/local/lib/gawd/memory/ and at the staged workspace scripts/ path).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOGGER_CANDIDATES=(
    "${_SCRIPT_DIR}/../observability/logger.sh"
    "/usr/local/lib/gawd/observability/logger.sh"
    "/usr/local/lib/gawd/observability/logger.sh"
)
_logger_loaded=0
for _c in "${_LOGGER_CANDIDATES[@]}"; do
    if [[ -f "$_c" ]]; then
        # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
        source "$_c" && _logger_loaded=1 && break
    fi
done
if [[ "$_logger_loaded" -eq 0 ]]; then
    # Fallback plain-text logger so this script never fails to run.
    log_info()  { printf '[%s info  dream-verify] %s\n'  "$(date -u +%FT%TZ)" "$*" >&2; }
    log_warn()  { printf '[%s warn  dream-verify] %s\n'  "$(date -u +%FT%TZ)" "$*" >&2; }
    log_error() { printf '[%s error dream-verify] %s\n'  "$(date -u +%FT%TZ)" "$*" >&2; }
fi

# ── Config defaults ──────────────────────────────────────────────────────────
GAWD_LCM_DB="${GAWD_LCM_DB:-/home/gawd/.openclaw/lcm.db}"
GAWD_DREAM_DAY_NOTE_DIR="${GAWD_DREAM_DAY_NOTE_DIR:-/home/gawd/.openclaw/workspace/memory}"
# State dir for markers: sibling of memory dir (never inside ingest scope).
GAWD_VERIFY_STATE_DIR="${GAWD_VERIFY_STATE_DIR:-${GAWD_DREAM_DAY_NOTE_DIR%/memory}/state}"
GAWD_PROPHIT_ID="${GAWD_PROPHIT_ID:-prophit}"
GAWD_PRIMARY_CHANNEL="${GAWD_PRIMARY_CHANNEL:-telegram}"
# Default engine path is the baked image path confirmed from forge/build/Dockerfile:
#   COPY forge/silence-avoidance/ /usr/local/lib/gawd/silence-avoidance/
# Fallback to the forge source path for bare-metal and test runs.
GAWD_VERIFY_ENGINE="${GAWD_VERIFY_ENGINE:-/usr/local/lib/gawd/silence-avoidance/engine.sh}"
if [[ ! -x "$GAWD_VERIFY_ENGINE" ]]; then
    _ENGINE_FALLBACK="${_SCRIPT_DIR}/../silence-avoidance/engine.sh"
    if [[ -x "$_ENGINE_FALLBACK" ]]; then
        GAWD_VERIFY_ENGINE="$_ENGINE_FALLBACK"
    fi
fi
GAWD_VERIFY_MIN_BODY="${GAWD_VERIFY_MIN_BODY:-40}"
GAWD_VERIFY_DRY_RUN="${GAWD_VERIFY_DRY_RUN:-0}"

# ── Resolve today ─────────────────────────────────────────────────────────────
# Use GAWD_VERIFY_FORCE_TODAY if set (test hook + backstop calls from daily-reset).
# GAWD_PROPHIT_TZ may be set as a test hook to supply the Prophit timezone
# when GAWD_VERIFY_FORCE_TODAY is used (bypassing the common.sh resolve path).
_tz="${GAWD_PROPHIT_TZ:-}"
if [[ -n "${GAWD_VERIFY_FORCE_TODAY:-}" ]]; then
    TODAY="$GAWD_VERIFY_FORCE_TODAY"
    # _tz is already set from GAWD_PROPHIT_TZ above (may be empty — that's fine;
    # the UTC-range block will fall back to date() if _tz is unset).
else
    # Try resolve_prophit_tz from scheduler common.sh for Prophit-local date.
    _COMMON_CANDIDATES=(
        "${_SCRIPT_DIR}/../scheduler/lib/common.sh"
        "/usr/local/lib/gawd/scheduler/lib/common.sh"
    )
    _tz_resolved=""
    for _c in "${_COMMON_CANDIDATES[@]}"; do
        if [[ -f "$_c" ]]; then
            # shellcheck source=/usr/local/lib/gawd/scheduler/lib/common.sh
            # Source with error suppression — we only want resolve_prophit_tz
            # and do not want set -euo in common.sh to affect us.
            _tz_resolved="$(bash -c "
                GAWD_WORKSPACE=\"\${GAWD_WORKSPACE:-\${HOME}/.gawd}\"
                GAWD_STATE_DIR=\"\${GAWD_STATE_DIR:-\${GAWD_WORKSPACE}/state}\"
                GAWD_LOG_DIR=\"\${GAWD_LOG_DIR:-\${GAWD_WORKSPACE}/logs/scheduler}\"
                GAWD_RUN_DIR=\"\${GAWD_RUN_DIR:-\${GAWD_WORKSPACE}/run/scheduler}\"
                source '$_c' 2>/dev/null || true
                tz=\"\$(resolve_prophit_tz 2>/dev/null)\" && printf '%s' \"\$tz\" || true
            " 2>/dev/null)" && break
        fi
    done
    # Prefer GAWD_PROPHIT_TZ if explicitly set (test hook), otherwise use resolved TZ.
    if [[ -z "$_tz" && -n "$_tz_resolved" ]]; then
        _tz="$_tz_resolved"
    fi
    if [[ -n "$_tz" ]]; then
        TODAY="$(TZ="$_tz" date +%Y-%m-%d 2>/dev/null)" || TODAY="$(date -u +%Y-%m-%d)"
    else
        log_warn "dream-verify" "could not resolve Prophit timezone; using UTC for date"
        TODAY="$(date -u +%Y-%m-%d)"
    fi
fi

log_info "dream-verify" "checking day-narrative coverage for ${TODAY}"

# ── Guard: sqlite3 must be present (no crash if absent) ──────────────────────
if ! command -v sqlite3 >/dev/null 2>&1; then
    log_error "dream-verify" "sqlite3 not available; cannot verify day-narrative coverage — guard is disabled, memory loss may go undetected"
    exit 0
fi

# ── Was there anything to synthesize? ────────────────────────────────────────
# Count messages in lcm.db for today. If zero, quiet day — no alert.
if [[ ! -f "$GAWD_LCM_DB" ]]; then
    log_info "dream-verify" "lcm.db not found at ${GAWD_LCM_DB}; quiet day (no corpus) — OK"
    exit 0
fi

# Count messages in lcm.db whose created_at falls within the Prophit-local TODAY.
#
# CRITICAL: production lcm.db stores created_at via datetime('now') as UTC,
# space-separated "YYYY-MM-DD HH:MM:SS". TODAY is resolved in the Prophit's
# local timezone (via resolve_prophit_tz). For non-UTC Prophits (e.g.
# America/Chicago) date(created_at) = TODAY would diverge near midnight:
# UTC-stored timestamps for the late-evening hours of the Prophit's day
# fall on the NEXT UTC calendar date, causing false "quiet day" under-counts.
#
# Fix: compute the Prophit-local day as a UTC range and bound created_at on
# a half-open interval [START_UTC, END_UTC).
#
# Approach: date -d "TZ=\"tz\" YYYY-MM-DD 00:00:00" -u +format
# Interprets the local midnight in the named timezone (via inline TZ= in the
# -d string), then outputs in UTC with -u. This works on both UTC and non-UTC
# hosts and is DST-correct.
#
# _NEXT is computed WITHOUT an embedded TZ to avoid GNU date mis-parsing
# "+1 day" with an inline TZ= — compute it as a plain calendar offset.
#
# Distinguish query failure from "query succeeded, returned 0":
#   - On sqlite3 failure (locked, schema drift, corruption): _QUERY_FAILED=1
#     → do NOT treat as quiet day; fail loud toward alerting.
#   - On success with COUNT=0: true quiet day → silent exit.
_QUERY_FAILED=0

# Compute the UTC window for Prophit-local TODAY.
if [[ -n "${_tz:-}" ]]; then
    _NEXT="$(date -d "${TODAY} +1 day" +%Y-%m-%d 2>/dev/null)" || _NEXT=""
    if [[ -n "$_NEXT" ]]; then
        _START_UTC="$(date -d "TZ=\"${_tz}\" ${TODAY} 00:00:00" -u +"%Y-%m-%d %H:%M:%S" 2>/dev/null)" || _START_UTC=""
        _END_UTC="$(date -d "TZ=\"${_tz}\" ${_NEXT} 00:00:00" -u +"%Y-%m-%d %H:%M:%S" 2>/dev/null)" || _END_UTC=""
    fi
fi

if [[ -n "${_START_UTC:-}" && -n "${_END_UTC:-}" ]]; then
    # Timezone-correct UTC-range query.
    _MSG_COUNT_RAW="$(sqlite3 "$GAWD_LCM_DB" \
        "SELECT COUNT(*) FROM messages WHERE created_at >= '${_START_UTC}' AND created_at < '${_END_UTC}';" \
        2>/dev/null)" || _QUERY_FAILED=1
    log_info "dream-verify" "UTC window for ${TODAY} (${_tz:-UTC}): [${_START_UTC}, ${_END_UTC})"
else
    # Fallback: _tz unavailable or date math failed; use format-agnostic date()
    # comparison. UTC Prophits are not affected; non-UTC may have near-midnight drift.
    log_warn "dream-verify" "could not compute UTC window for ${TODAY} (tz=${_tz:-unset}); falling back to date(created_at) comparison"
    _MSG_COUNT_RAW="$(sqlite3 "$GAWD_LCM_DB" \
        "SELECT COUNT(*) FROM messages WHERE date(created_at) = '${TODAY}';" \
        2>/dev/null)" || _QUERY_FAILED=1
fi

if [[ "$_QUERY_FAILED" -eq 1 ]]; then
    log_error "dream-verify" "sqlite3 query failed on ${GAWD_LCM_DB} (db locked, schema drift, or corruption) — cannot confirm quiet day; proceeding to alert to avoid silent memory loss"
    # Do not exit; fall through to the note-count check and alert path.
    _MSG_COUNT="1"  # treat as non-quiet to fail loud
else
    # Normalize: strip whitespace
    _MSG_COUNT="$(printf '%s' "$_MSG_COUNT_RAW" | tr -d '[:space:]')"
    _MSG_COUNT="${_MSG_COUNT:-0}"
fi

if [[ "$_QUERY_FAILED" -eq 0 ]] && [[ "$_MSG_COUNT" -eq 0 ]] 2>/dev/null; then
    log_info "dream-verify" "quiet day for ${TODAY}: 0 messages in lcm.db — no alert needed"
    exit 0
fi

# ── Did the day produce real narrative? ──────────────────────────────────────
# Count non-empty dream-*.md notes whose mtime or created_at front-matter is today.
# "Non-empty" = body after front-matter has >= GAWD_VERIFY_MIN_BODY non-whitespace chars.
_NOTE_COUNT=0
if [[ -d "$GAWD_DREAM_DAY_NOTE_DIR" ]]; then
    while IFS= read -r -d '' _note; do
        # Check mtime: file modified today (quick first filter).
        _fdate="$(date -r "$_note" +%Y-%m-%d 2>/dev/null)" || _fdate=""
        # Also check created_at front-matter for accuracy.
        _fm_date="$(grep -m1 '^created_at:' "$_note" 2>/dev/null | sed 's/^created_at:[[:space:]]*//' | cut -c1-10)" || _fm_date=""
        if [[ "$_fdate" != "$TODAY" && "$_fm_date" != "$TODAY" ]]; then
            continue
        fi
        # Count non-whitespace chars in the body (after front-matter).
        _body="$(awk 'BEGIN{in_fm=0;past=0} /^---/{if(!past){in_fm=1-in_fm; if(!in_fm)past=1;next}} past{print}' "$_note" 2>/dev/null)"
        _body_nws="$(printf '%s' "$_body" | tr -d '[:space:]' | wc -c 2>/dev/null)" || _body_nws=0
        _body_nws="$(printf '%s' "$_body_nws" | tr -d '[:space:]')"
        if [[ "${_body_nws:-0}" -ge "${GAWD_VERIFY_MIN_BODY}" ]] 2>/dev/null; then
            _NOTE_COUNT=$(( _NOTE_COUNT + 1 ))
        fi
    done < <(find "$GAWD_DREAM_DAY_NOTE_DIR" -maxdepth 1 -name 'dream-*.md' -type f -print0 2>/dev/null)
fi

if [[ "$_NOTE_COUNT" -ge 1 ]]; then
    log_info "dream-verify" "day-narrative OK for ${TODAY}: ${_NOTE_COUNT} non-empty dream note(s) found"
    exit 0
fi

# ── FAIL CONDITION ────────────────────────────────────────────────────────────
# Messages existed today but zero non-empty dream-*.md notes cover the day.
log_error "dream-verify" "day-narrative synthesis produced NO non-empty note for ${TODAY} despite ${_MSG_COUNT} messages in lcm.db; raw corpus preserved at ${GAWD_LCM_DB} — backfill required"

# ── Idempotency: once-per-day alert marker ───────────────────────────────────
mkdir -p "$GAWD_VERIFY_STATE_DIR" 2>/dev/null || true
_MARKER="${GAWD_VERIFY_STATE_DIR}/dream-verify-alerted-${TODAY}"
if [[ -f "$_MARKER" ]]; then
    log_info "dream-verify" "already alerted for ${TODAY}; suppressing repeat alert"
    exit 0
fi

# ── Write human-readable missing-narrative marker to state dir ───────────────
# Written to GAWD_VERIFY_STATE_DIR (NOT the day-note dir) so it can never be
# accidentally ingested by the wiki/memory pipeline which scans *.md in the
# day-note dir. The state dir is outside the ingest scope.
_MISSING_MARKER="${GAWD_VERIFY_STATE_DIR}/MISSING-NARRATIVE-${TODAY}.md"
{
    printf '# Missing Day Narrative — %s\n\n' "$TODAY"
    printf 'day: %s\n' "$TODAY"
    printf 'message_count: %s\n' "$_MSG_COUNT"
    printf 'lcm_db: %s\n' "$GAWD_LCM_DB"
    printf 'backfill_command: sqlite3 "%s" "SELECT content FROM messages WHERE created_at >= '"'"'%s'"'"' AND created_at < '"'"'%s'"'"';" | <synthesizer>\n' \
        "$GAWD_LCM_DB" "${_START_UTC:-${TODAY} 00:00:00}" "${_END_UTC:-${TODAY} 23:59:59}"
    printf 'generated_at: %s\n' "$(date -u +%FT%TZ)"
    printf '\nBackfill required: no dream note was produced for this day despite %s messages.\n' "$_MSG_COUNT"
    printf 'Raw corpus is intact at: %s\n' "$GAWD_LCM_DB"
} > "$_MISSING_MARKER" 2>/dev/null || true

# ── Alert via silence-avoidance engine ───────────────────────────────────────
# CRITICAL: capture the engine exit code and gate the once-per-day marker on
# confirmed delivery ONLY (exit 0). Known engine exit codes:
#   0   → delivered
#   10  → suppressed (silence window active)
#   30  → delivery failed (Telegram/channel error)
#   31  → script missing
# On any non-zero exit the alert was NOT delivered; do NOT write the marker so
# the next cron retry can attempt delivery again. Emit a log_error to surface
# the non-delivery in the logs.
_ENGINE_RC=0
if [[ -x "$GAWD_VERIFY_ENGINE" ]]; then
    if [[ "$GAWD_VERIFY_DRY_RUN" == "1" ]]; then
        log_info "dream-verify" "DRY_RUN: would invoke engine terminal-error --channel ${GAWD_PRIMARY_CHANNEL} --prophit ${GAWD_PROPHIT_ID}"
        _ENGINE_RC=0  # dry-run counts as "delivered" for marker purposes
    else
        "$GAWD_VERIFY_ENGINE" terminal-error \
            --channel "$GAWD_PRIMARY_CHANNEL" \
            --prophit "$GAWD_PROPHIT_ID" \
            2>/dev/null
        _ENGINE_RC=$?
    fi
else
    log_warn "dream-verify" "engine not executable at ${GAWD_VERIFY_ENGINE}; alert not delivered — check deployment"
    _ENGINE_RC=31
fi

# ── Write once-per-day alert marker ONLY on confirmed delivery ────────────────
if [[ "$_ENGINE_RC" -eq 0 ]]; then
    _MARKER_TMP="$(mktemp "${_MARKER}.XXXXXX" 2>/dev/null)" && {
        printf '%s\n' "$(date -u +%FT%TZ)" > "$_MARKER_TMP" 2>/dev/null || true
        mv -f "$_MARKER_TMP" "$_MARKER" 2>/dev/null || rm -f "$_MARKER_TMP" 2>/dev/null || true
    } || true
    if [[ -f "$_MARKER" ]]; then
        log_info "dream-verify" "alert issued for ${TODAY} (${_MSG_COUNT} messages, 0 dream notes); marker written at ${_MARKER}"
    else
        log_warn "dream-verify" "alert delivered (engine rc=0) for ${TODAY} but marker write failed; next run will re-alert"
    fi
else
    log_error "dream-verify" "engine returned non-zero (rc=${_ENGINE_RC}) for ${TODAY}; alert NOT confirmed delivered — marker NOT written; next cron will retry"
fi

# Always exit 0 — self-defending, never break the cron.
exit 0
