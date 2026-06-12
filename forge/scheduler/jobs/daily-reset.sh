#!/usr/bin/env bash
# daily-reset.sh — Daily 4am Prophit-local boundary
#
# Per spec §11 + §10.4 + §12.4 + handoff E1.
#
# This is the PRIMARY anchor. At 4am Prophit-local:
#   1. Apply any accepted but un-applied revelation (calls E2 check-pending.sh,
#      which calls merge.sh on accepted+un-applied state).
#   2. Run SIL apply-or-archive (E3 — stub-tolerant).
#   3. Advance tithe state machine (E3 — stub-tolerant).
#   4. Rotate the daily memory file (this script owns this directly).
#   5. Clean up ~/.gawd.previous if older than ~24h (per spec §7.2 rollback window).
#
# Mid-conversation upgrade is forbidden (spec §10.3). This job is the ONLY
# place where soul-anchor mutations are committed; the scheduler firing the
# job IS the boundary.
#
# Missed-run policy: systemd timer has Persistent=false, so a missed 4am
# while the daemon was down does NOT trigger an immediate catch-up. The
# downstream check-pending.sh + state machine resolve forward (per spec §12.4).
#
# Exit codes:
#   0  job completed (any downstream stubs/non-zeros logged but non-fatal)
#   1  workspace missing or unreadable

set -euo pipefail

export SCHED_JOB="daily-reset"

SCHED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCHED_DIR}/../lib/common.sh"

lock_acquire "$SCHED_JOB"

log "daily-reset starting (4am Prophit-local boundary)"

if [[ ! -d "$GAWD_WORKSPACE" ]]; then
    fatal 1 "GAWD_WORKSPACE not present: ${GAWD_WORKSPACE}"
fi

mkdir -p "$GAWD_STATE_DIR"

# ──────────────────────────────────────────────────────────────────────────
# 1. Revelation apply (E2 check-pending.sh)
#
#    If state/pending-revelation.json says response=accepted and applied=false,
#    check-pending.sh invokes merge.sh which performs the three-way merge.
#    If there's no pending revelation, check-pending.sh exits 0 silently.
# ──────────────────────────────────────────────────────────────────────────

REVELATION_CHECK="/usr/local/lib/gawd/revelation/check-pending.sh"
run_or_stub "E2-revelation-check" "$REVELATION_CHECK" \
    --state "$GAWD_STATE_DIR" \
    --workspace "$GAWD_WORKSPACE"

# ──────────────────────────────────────────────────────────────────────────
# 2. SIL apply-or-archive (E3)
#
#    SIL sharpen ran overnight at 2am; if it produced soul-touching proposals
#    awaiting Prophit response, this step archives stale ones (>N days
#    unanswered) and applies any that the Prophit accepted via slash command
#    or button-press during the day.
#
#    E3 stub-tolerant: script may not exist yet. The cron stays alive.
# ──────────────────────────────────────────────────────────────────────────

SIL_APPLY="/usr/local/lib/gawd/sil/apply-or-archive.sh"
run_or_stub "E3-sil-apply-or-archive" "$SIL_APPLY" \
    --workspace "$GAWD_WORKSPACE" \
    --state "$GAWD_STATE_DIR"

# ──────────────────────────────────────────────────────────────────────────
# 3. Tithe state machine transition (E3)
#
#    Per spec §12.4: tithe state transitions evaluated at the daily 4am
#    reset, NOT in real time. State machine resolves forward to current
#    state — does not replay intermediate transitions.
# ──────────────────────────────────────────────────────────────────────────

TITHE_ADVANCE="/usr/local/lib/gawd/tithe/advance-state.sh"
run_or_stub "E3-tithe-advance" "$TITHE_ADVANCE" \
    --workspace "$GAWD_WORKSPACE" \
    --state "$GAWD_STATE_DIR"

# ──────────────────────────────────────────────────────────────────────────
# 4. Daily memory file rotation
#
#    The current day's memory file is memory/YYYY-MM-DD.md (no cap).
#    Today's new day starts NOW; this step ensures the file exists empty
#    and is owned by the Gawd process user. This is a no-op if the file
#    already exists from earlier session activity.
# ──────────────────────────────────────────────────────────────────────────

DAILY_FILE="${GAWD_WORKSPACE}/memory/$(date +%Y-%m-%d).md"
if [[ ! -f "$DAILY_FILE" ]]; then
    mkdir -p "$(dirname "$DAILY_FILE")"
    : > "$DAILY_FILE"
    log "rotated daily memory file: ${DAILY_FILE} (created empty)"
else
    log "daily memory file already present: ${DAILY_FILE} (no-op)"
fi

# ──────────────────────────────────────────────────────────────────────────
# 4b. Yesterday-empty backstop — dream-verify for the prior day.
#
#    Belt-and-suspenders for the case where the 3am dreaming cron did NOT
#    run (daemon was down at 3am, came back up before 4am): daily-reset is
#    the always-fires anchor (per this script's own header). If yesterday's
#    dated memory file is empty/whitespace AND no dream-*.md covers it, fire
#    dream-verify for yesterday so the silence is surfaced.
#
#    Uses run_or_stub so a missing dream-verify.sh never breaks daily-reset.
#    GNU date -d 'yesterday' (Debian image): reliable. python3 fallback for
#    portability on all rungs (python3 is guaranteed present per safe-dream.sh).
#
#    IMPORTANT: resolve yesterday in Prophit-local TZ so this backstop path and
#    dream-verify's own resolve_prophit_tz call agree on the day boundary. Using
#    system/container TZ here while dream-verify uses Prophit-local TZ produces an
#    off-by-one near midnight for non-UTC Prophits. resolve_prophit_tz is sourced
#    from common.sh (already sourced above) so it is available directly here.
# ──────────────────────────────────────────────────────────────────────────

# Resolve yesterday's date in Prophit-local TZ.
# resolve_prophit_tz is available from common.sh (sourced at top of this script).
_YESTERDAY=""
_PROPHIT_TZ="$(resolve_prophit_tz 2>/dev/null)" || _PROPHIT_TZ=""
if [[ -n "$_PROPHIT_TZ" ]]; then
    # Compute yesterday in Prophit-local TZ using python3 (portable, avoids
    # GNU date TZ= syntax incompatibilities on some images).
    _YESTERDAY="$(TZ="$_PROPHIT_TZ" python3 -c "
import datetime, os
tz_name = os.environ.get('TZ', 'UTC')
try:
    import zoneinfo
    tz = zoneinfo.ZoneInfo(tz_name)
except Exception:
    tz = datetime.timezone.utc
today_local = datetime.datetime.now(tz=tz).date()
yesterday = today_local - datetime.timedelta(days=1)
print(yesterday.strftime('%Y-%m-%d'))
" 2>/dev/null)" || _YESTERDAY=""
fi

# Fallback: system TZ (best-effort; acceptable when Prophit TZ is unavailable)
if [[ -z "$_YESTERDAY" ]]; then
    if date -d 'yesterday' +%Y-%m-%d >/dev/null 2>&1; then
        _YESTERDAY="$(date -d 'yesterday' +%Y-%m-%d)"
    else
        _YESTERDAY="$(python3 -c "
import datetime
print((datetime.date.today() - datetime.timedelta(days=1)).strftime('%Y-%m-%d'))
" 2>/dev/null)" || _YESTERDAY=""
    fi
fi

if [[ -n "$_YESTERDAY" ]]; then
    _YESTERDAY_FILE="${GAWD_WORKSPACE}/memory/${_YESTERDAY}.md"
    # Check if yesterday's dated file exists and is empty/whitespace-only.
    _yesterday_empty=0
    if [[ ! -f "$_YESTERDAY_FILE" ]]; then
        _yesterday_empty=1
    elif [[ ! -s "$_YESTERDAY_FILE" ]]; then
        _yesterday_empty=1
    else
        # Non-empty: check if it contains only whitespace.
        _nws="$(tr -d '[:space:]' < "$_YESTERDAY_FILE" 2>/dev/null | wc -c)" || _nws=1
        _nws="$(printf '%s' "${_nws:-1}" | tr -d '[:space:]')"
        [[ "${_nws:-1}" -eq 0 ]] && _yesterday_empty=1
    fi

    if [[ "$_yesterday_empty" -eq 1 ]]; then
        # Check if any dream-*.md note covers yesterday (quick mtime glob).
        _DREAM_DIR="${GAWD_WORKSPACE}/memory"
        _dream_covers_yesterday=0
        if [[ -d "$_DREAM_DIR" ]]; then
            while IFS= read -r -d '' _df; do
                _df_date="$(date -r "$_df" +%Y-%m-%d 2>/dev/null)" || _df_date=""
                _df_fm="$(grep -m1 '^created_at:' "$_df" 2>/dev/null | sed 's/^created_at:[[:space:]]*//' | cut -c1-10)" || _df_fm=""
                if [[ "$_df_date" == "$_YESTERDAY" || "$_df_fm" == "$_YESTERDAY" ]]; then
                    _dream_covers_yesterday=1
                    break
                fi
            done < <(find "$_DREAM_DIR" -maxdepth 1 -name 'dream-*.md' -type f -print0 2>/dev/null)
        fi

        if [[ "$_dream_covers_yesterday" -eq 0 ]]; then
            log "yesterday (${_YESTERDAY}) has empty dated file and no dream note; invoking dream-verify backstop"
            # Locate dream-verify.sh (baked path first, then forge source for bare-metal).
            _VERIFY_SCRIPT=""
            for _vc in \
                "/usr/local/lib/gawd/memory/dream-verify.sh" \
                "${SCHED_DIR}/../../memory/dream-verify.sh" \
                "$(dirname "${BASH_SOURCE[0]}")/../../memory/dream-verify.sh"; do
                if [[ -x "$_vc" ]]; then
                    _VERIFY_SCRIPT="$_vc"
                    break
                fi
            done
            # Export the date override before calling via run_or_stub.
            export GAWD_VERIFY_FORCE_TODAY="$_YESTERDAY"
            run_or_stub "dream-verify-yesterday" "${_VERIFY_SCRIPT:-/nonexistent/dream-verify.sh}"
            unset GAWD_VERIFY_FORCE_TODAY
        else
            log "yesterday (${_YESTERDAY}) dated file empty but dream note present — OK"
        fi
    else
        log "yesterday (${_YESTERDAY}) dated file non-empty — no backstop needed"
    fi
else
    warn "could not resolve yesterday's date; skipping dream-verify backstop"
fi

# ──────────────────────────────────────────────────────────────────────────
# 5. F1 migration cleanup — sibling-of-workspace rollback dirs older than 24h
#
#    Per spec §7.2: "~/.gawd.previous is retained for one daily-reset cycle
#    (~24 hours) as a rollback escape hatch, then auto-deleted at the next
#    4am reset."
#
#    The cleanup targets are SIBLINGS of $GAWD_WORKSPACE (e.g., if workspace
#    is ~/.gawd, the sibling rollback dirs are ~/.gawd.previous,
#    ~/.gawd.workspace.previous, ~/.gawd.failed). Deriving from
#    $GAWD_WORKSPACE — not literal $HOME — keeps the scheduler testable in
#    isolated workspaces and respects operator overrides.
#
#    Naming convention (per F1 gawd-import.sh + revelation/merge.sh):
#      ${GAWD_WORKSPACE}.previous            ← gawd-import rollback dir
#      ${GAWD_WORKSPACE}.workspace.previous  ← merge.sh rollback dir variant
#      ${GAWD_WORKSPACE}.failed              ← gawd-import self-test failed
#
#    Older than 23h (slight buffer for clock skew): delete.
# ──────────────────────────────────────────────────────────────────────────

cleanup_stale_rollback_dir() {
    # $1 path, $2 max-age-minutes, $3 human label
    local path="$1" age_min="$2" label="$3"
    if [[ -d "$path" ]]; then
        if find "$path" -maxdepth 0 -mmin "+${age_min}" -print 2>/dev/null | grep -q .; then
            log "deleting stale ${label} at ${path} (older than threshold)"
            rm -rf "$path"
        else
            log "${label} present at ${path} but inside rollback window — keep"
        fi
    fi
}

cleanup_stale_rollback_dir "${GAWD_WORKSPACE}.previous"           1380 "~/.gawd.previous"
cleanup_stale_rollback_dir "${GAWD_WORKSPACE}.workspace.previous" 1380 "~/.gawd.workspace.previous"

# .failed retains a longer forensic window (7 days = 10080 minutes).
cleanup_stale_rollback_dir "${GAWD_WORKSPACE}.failed"             10080 "~/.gawd.failed"

log "daily-reset complete"
exit 0
