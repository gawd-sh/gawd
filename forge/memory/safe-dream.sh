#!/usr/bin/env bash
# safe-dream.sh — the single dreaming write-spine (Q2/Q3).
#
# Design:
#   Q2 — dedicated dream model via GAWD_DREAM_MODEL env (never the main gateway
#        chain; never rate-limited the way the 2026-05-27 failure was).
#   Q3 — this OS-cron script is the SINGLE owner of dreaming. The built-in
#        memory-core dreaming.enabled is set to false in openclaw.json to
#        prevent double-fire.
#
# Invariants (non-negotiable, each tested by test-safe-dream.sh):
#
#   SINGLE-FLIGHT — flock a lockfile so two concurrent invocations can never
#     overlap. The second runner exits 0 immediately (no error, no hang).
#
#   CURSOR-BOUNDED — queries lcm.db only for messages AFTER the cursor
#     (message_id > last_committed). Never re-processes history.
#
#   CHUNKED — processes at most GAWD_DREAM_CHUNK messages at once. Cursor
#     advances by chunk, only after that chunk is fully committed to T2.
#
#   BACK-PRESSURE — pace_gate (inter-call spacing) + retry_with_backoff
#     prevent the unbounded burst that killed dreaming on 2026-05-27.
#
#   SAFE-ABORT — on synthesis failure (retry exhaustion, signal, any error):
#     * checkpoint the cursor at the LAST FULLY-COMMITTED chunk
#     * log a WARN line
#     * exit 0 (never non-zero; never corrupt; never block)
#     A partially-written T2 row is impossible because the T2 write is inside
#     a transaction that only commits if synthesize_chunk returns 0.
#
# T2 write path (focus_briefs per frozen contract at
# forge/memory/docs/focus-briefs-contract.md):
#   The contract document establishes that lossless-claw uses an app-layer
#   state machine (supersede + insert in a transaction) keyed by conversation_id.
#   For dreaming, where no live lossless-claw session is running, we replicate
#   the state-machine directly in SQL using a SQLite transaction:
#     1. UPDATE SET status='superseded' WHERE conversation_id=? AND status IN (...)
#     2. INSERT the new brief with status='active' and a fresh brief_id (UUID).
#   Both steps in one BEGIN ... COMMIT, so the table is never half-written.
#
# T3 write path (day-note for memory-core indexing):
#   synthesize_chunk writes a day-note .md file to GAWD_DREAM_DAY_NOTE_DIR with
#   generation:0 front-matter (so wiki-gen-guard lets it through). memory-core
#   picks these up for vector indexing on its next scheduled pass.
#
# Synthesis call:
#   REAL DISPATCH — cloud model via OpenClaw gateway (Option A, locked 2026-05-29).
#   Model is configurable via GAWD_DREAM_MODEL (default: empty = stub mode).
#   Set GAWD_DREAM_MODEL to a cheap cloud model to activate real dreaming, e.g.:
#     GAWD_DREAM_MODEL="minimax/MiniMax-M2.7"
#   The dispatch uses openclaw agent --json with jq extraction of reply text.
#   On empty GAWD_DREAM_MODEL: stub mode — cursor advances, no T2/T3 writes.
#   Test hooks GAWD_DREAM_FORCE_FAIL and GAWD_DREAM_FAIL_AFTER_N remain active.
#
# Env vars:
#   GAWD_DREAM_MODEL         — target model (empty = stub mode; set to activate real dispatch)
#   GAWD_DREAM_OPENCLAW_CMD  — openclaw CLI invocation (default: "openclaw"; override
#                              for containers with broken binary:
#                              "node /usr/local/lib/node_modules/openclaw/dist/index.js")
#   GAWD_LCM_DB              — path to lcm.db (default: /home/gawd/.openclaw/lcm.db)
#   GAWD_DREAM_FOCUS_DB      — path to db holding focus_briefs (default: GAWD_LCM_DB)
#   GAWD_DREAM_DAY_NOTE_DIR  — dir for day-note .md files (T3 archive feed)
#   GAWD_DREAM_CURSOR        — cursor file path
#   GAWD_DREAM_LOCK          — flock lockfile path
#   GAWD_DREAM_LOG           — log file path
#   GAWD_DREAM_CHUNK         — messages per chunk (default: 200)
#   GAWD_DREAM_RETRY_MAX     — max retry attempts (default via dream-pace.sh: 5)
#   GAWD_DREAM_BACKOFF_BASE  — backoff base seconds (default: 2)
#   GAWD_DREAM_MAX_CALLS_PER_MIN — pacing (default: 20; 0 = disabled)
#   GAWD_DREAM_FORCE_FAIL    — test hook: set to 1 to force every synthesis fail
#   GAWD_DREAM_FAIL_AFTER_N  — test hook: fail synthesis after N successful calls

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Source helpers (Task 2.1 cursor + Task 2.2 pace/retry)
# ──────────────────────────────────────────────────────────────────────────────
LIB="$(cd "$(dirname "$0")/lib" && pwd)"
source "${LIB}/dream-cursor.sh"
source "${LIB}/dream-pace.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Config defaults
# ──────────────────────────────────────────────────────────────────────────────
GAWD_LCM_DB="${GAWD_LCM_DB:-/home/gawd/.openclaw/lcm.db}"
# T2 focus_briefs live in the same db as messages by default.
GAWD_DREAM_FOCUS_DB="${GAWD_DREAM_FOCUS_DB:-$GAWD_LCM_DB}"
# T3 day-notes go here (memory-core indexes this directory).
GAWD_DREAM_DAY_NOTE_DIR="${GAWD_DREAM_DAY_NOTE_DIR:-/home/gawd/.openclaw/workspace/memory}"
GAWD_DREAM_LOCK="${GAWD_DREAM_LOCK:-/home/gawd/.openclaw/state/dream.lock}"
GAWD_DREAM_LOG="${GAWD_DREAM_LOG:-/home/gawd/.openclaw/logs/gawd-dreaming.log}"
GAWD_DREAM_CHUNK="${GAWD_DREAM_CHUNK:-200}"
# Q2: dedicated dream model — empty means stub mode (no model call).
# Default: empty so operators must explicitly set before real dreaming is active.
# Operators should set this to a cheap cloud model, e.g. "minimax/MiniMax-M2.7".
GAWD_DREAM_MODEL="${GAWD_DREAM_MODEL:-}"
# The openclaw CLI invocation. Default: "openclaw" (works on live Lilith).
# Override for sandbox/container testing where the openclaw binary is broken:
#   GAWD_DREAM_OPENCLAW_CMD="node /usr/local/lib/node_modules/openclaw/dist/index.js"
GAWD_DREAM_OPENCLAW_CMD="${GAWD_DREAM_OPENCLAW_CMD:-openclaw}"

# ──────────────────────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    # Suppress mkdir stderr: if the log dir is inside a path we don't own
    # (e.g. the default /home/gawd/... when running outside a Gawd container),
    # the failure is benign — the log line is silently dropped rather than
    # emitting a spurious "Permission denied" to the test harness stderr.
    mkdir -p "$(dirname "$GAWD_DREAM_LOG")" 2>/dev/null || true
    printf '%s [%s] safe-dream: %s\n' "$(date -u +%FT%TZ)" "$level" "$*" \
        >> "$GAWD_DREAM_LOG" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# SINGLE-FLIGHT: acquire an exclusive flock on GAWD_DREAM_LOCK.
# A second concurrent invocation finds the lock held and exits 0 immediately.
# The lock is released automatically when this process exits (fd 9 closes).
# ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$GAWD_DREAM_LOCK")"
exec 9>"$GAWD_DREAM_LOCK"
if ! flock -n 9; then
    log "INFO" "another dream run holds the lock; skipping this invocation"
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────────────
# Early exit: no lcm.db yet (gateway hasn't run).
# ──────────────────────────────────────────────────────────────────────────────
if [ ! -f "$GAWD_LCM_DB" ]; then
    log "INFO" "lcm.db not found at $GAWD_LCM_DB; nothing to consolidate"
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────────────
# Read cursor: the last message_id that was fully consolidated.
# ──────────────────────────────────────────────────────────────────────────────
last_id="$(cursor_read)"

# ──────────────────────────────────────────────────────────────────────────────
# Check the frontier: max message_id in the db.
# ──────────────────────────────────────────────────────────────────────────────
max_id="$(sqlite3 "$GAWD_LCM_DB" \
    "SELECT COALESCE(MAX(message_id),0) FROM messages;" 2>/dev/null || echo "$last_id")"

if [ "$max_id" -le "$last_id" ]; then
    log "INFO" "no new messages since message_id=$last_id; nothing to do"
    exit 0
fi

log "INFO" "dream start: cursor=$last_id frontier=$max_id chunk=$GAWD_DREAM_CHUNK"

# ──────────────────────────────────────────────────────────────────────────────
# Internal counter for GAWD_DREAM_FAIL_AFTER_N test hook.
# ──────────────────────────────────────────────────────────────────────────────
_synthesis_call_count=0

# ──────────────────────────────────────────────────────────────────────────────
# synthesize_chunk — the integration point.
#
# $1 = from_id (first message_id in this chunk, inclusive)
# $2 = to_id   (last message_id in this chunk, inclusive)
#
# Responsibilities:
#   1. Fetch message rows from lcm.db for the id range [from_id, to_id].
#   2. Build a synthesis prompt from the messages.
#   3. Dispatch to GAWD_DREAM_MODEL (or stub if not set).
#   4. On success:
#      a. Upsert a focus_brief row in GAWD_DREAM_FOCUS_DB (T2 write).
#      b. Write a day-note .md to GAWD_DREAM_DAY_NOTE_DIR (T3 archive feed).
#      c. Return 0.
#   5. On failure: return non-zero so retry_with_backoff + safe-abort activates.
#
# SAFETY INVARIANT: T2 and T3 writes happen inside the function. If this
# function returns non-zero, the caller (the chunk loop below) does NOT call
# cursor_checkpoint — so the cursor stays at the last fully-committed chunk.
# Partial progress within this function is the ONLY corruption risk; it is
# eliminated by using a SQLite transaction for T2 and an atomic tmp+mv for T3.
# ──────────────────────────────────────────────────────────────────────────────
synthesize_chunk() {
    local from_id="$1" to_id="$2"
    _synthesis_call_count=$(( _synthesis_call_count + 1 ))

    # ── TEST HOOKS ──────────────────────────────────────────────────────────
    # GAWD_DREAM_FORCE_FAIL: always fail (safe-abort test).
    if [ "${GAWD_DREAM_FORCE_FAIL:-0}" = "1" ]; then
        return 7
    fi
    # GAWD_DREAM_FAIL_AFTER_N: succeed first N calls, fail thereafter.
    if [ -n "${GAWD_DREAM_FAIL_AFTER_N:-}" ]; then
        if [ "$_synthesis_call_count" -gt "${GAWD_DREAM_FAIL_AFTER_N}" ]; then
            return 7
        fi
    fi
    # ── END TEST HOOKS ───────────────────────────────────────────────────────

    # ── EMPTY-WINDOW GUARD (LOW fix) ─────────────────────────────────────────
    # With sparse message_ids (e.g. after lcm-watchdog trims sessions), a chunk
    # window [from_id, to_id] can cover zero actual rows. Skip such windows
    # entirely: no model call, no T2 write, no T3 note. The cursor still
    # advances past the empty range at the call site.
    local row_count
    row_count="$(sqlite3 "$GAWD_LCM_DB" \
        "SELECT COUNT(*) FROM messages WHERE message_id BETWEEN ${from_id} AND ${to_id};" \
        2>/dev/null || echo 1)"
    if [ "$row_count" -eq 0 ]; then
        log "INFO" "chunk ${from_id}-${to_id}: 0 messages in range; skipping (sparse ids)"
        return 0
    fi

    # ── STUB CHECK ───────────────────────────────────────────────────────────
    # If GAWD_DREAM_MODEL is empty (not set in env), use the stub path.
    #
    # BLOCKER-2 FIX: stub mode must NOT write status='active' rows to T2.
    # Recall's active-only query would serve a stub placeholder as a genuine
    # brief — data-integrity violation. In stub mode we advance the cursor so
    # all spine mechanics (flock, cursor, chunking, pace, safe-abort) remain
    # fully testable, but we write NOTHING to T2 or T3. A single INFO log line
    # records the stub pass so tests can verify the call happened.
    #
    # Likewise when GAWD_DREAM_MODEL is set but real dispatch is not yet wired:
    # the unimplemented branch also returns early without touching T2/T3 — same
    # safety guarantee. The real dispatch integration point below is where that
    # wiring happens when ready.
    #
    # GAWD_DREAM_TEST_T2_WRITE=1 is a TEST-ONLY hook that bypasses the early
    # stub-return so regression tests can exercise the full T2 write path and
    # verify BLOCKER-1 atomicity. Never set this in production.
    # ────────────────────────────────────────────────────────────────────────
    local model_out
    if [ -z "$GAWD_DREAM_MODEL" ] && [ "${GAWD_DREAM_TEST_T2_WRITE:-0}" != "1" ]; then
        # STUB: no T2/T3 write. Cursor advances via the call site.
        log "INFO" "stub mode: chunk ${from_id}-${to_id} synthesized (no T2/T3 write; GAWD_DREAM_MODEL unset)"
        return 0
    fi

    if [ -z "$GAWD_DREAM_MODEL" ]; then
        # GAWD_DREAM_TEST_T2_WRITE=1 active: use a test model_out so T2 path executes.
        # GAWD_DREAM_TEST_FORCE_MODEL_OUT overrides the static stub text (for guard-a test).
        if [ -n "${GAWD_DREAM_TEST_FORCE_MODEL_OUT:-}" ]; then
            model_out="${GAWD_DREAM_TEST_FORCE_MODEL_OUT}"
        else
            model_out="[test-t2-write] Consolidated messages ${from_id}-${to_id} (test hook)"
        fi
    else
        # ── REAL DISPATCH (Option A: cloud model via OpenClaw gateway) ───────
        #
        # Decision locked 2026-05-29: dreaming synthesis uses a cheap cloud
        # model via the gateway (never local — RAM hazard, proven unreliable
        # in production). Configurable via GAWD_DREAM_MODEL. Default: empty
        # (stub mode) so operators must explicitly set before live dreaming.
        # Recommended value: "minimax/MiniMax-M2.7".
        #
        # Steps:
        #   1. Fetch message rows [from_id, to_id] using
        #      COALESCE(large_content, content) — the live schema has
        #      large_content for overflow text in long messages.
        #   2. Build a narrow synthesis prompt (DemiGawd pattern: minimum
        #      context, bounded task, no personality injection).
        #   3. Dispatch via $GAWD_DREAM_OPENCLAW_CMD agent --json.
        #      --json gives parseable output; jq extracts the text.
        #      --session-key "dreaming:from-to" isolates from main history.
        #      timeout 120s: dreaming is once-daily; latency is not a concern.
        #   4. Return non-zero on: command failure, empty response, jq error.
        #      retry_with_backoff handles retries; safe-abort on exhaustion.
        #
        # GAWD_DREAM_OPENCLAW_CMD default: "openclaw" (works on live Lilith).
        # Sandbox override (rc5 container has broken openclaw binary):
        #   GAWD_DREAM_OPENCLAW_CMD="node /usr/local/lib/node_modules/openclaw/dist/index.js"
        # ────────────────────────────────────────────────────────────────────────

        # 1. Fetch message rows (truncate at 500 chars each to bound prompt size).
        local raw_rows
        raw_rows="$(sqlite3 "$GAWD_LCM_DB" \
            "SELECT role || ': ' || SUBSTR(COALESCE(large_content, content), 1, 500)
             FROM messages
             WHERE message_id BETWEEN ${from_id} AND ${to_id}
             ORDER BY message_id;" \
            2>/dev/null)" || {
            log "WARN" "chunk ${from_id}-${to_id}: failed to fetch message rows from lcm.db"
            return 1
        }

        if [ -z "$raw_rows" ]; then
            # Defensive: empty-window guard above should catch this, but guard here too.
            log "INFO" "chunk ${from_id}-${to_id}: no rows from message fetch; skipping"
            return 0
        fi

        # 2. Build synthesis prompt.
        local prompt_msg
        prompt_msg="$(printf 'You are a memory consolidation assistant. Synthesize the following conversation segment (messages %s to %s) into a concise focus brief of 3-6 sentences. Capture: key topics discussed, decisions made, and any important context for future reference. Be specific and factual — no filler, no preamble.\n\nConversation segment:\n---\n%s\n---\n\nFocus brief:' \
            "${from_id}" "${to_id}" "${raw_rows}")"

        # 3. Dispatch via gateway.
        # GAWD_DREAM_OPENCLAW_CMD may contain spaces (e.g. "node /path/to/index.js")
        # so it is intentionally unquoted to allow word-splitting by bash.
        # shellcheck disable=SC2086
        local raw_json
        raw_json="$(timeout 120 \
            ${GAWD_DREAM_OPENCLAW_CMD} agent \
                --agent main \
                --model "${GAWD_DREAM_MODEL}" \
                --session-key "dreaming:${from_id}-${to_id}" \
                --json \
                -m "${prompt_msg}" \
            2>/dev/null)"
        local dispatch_rc=$?

        if [ "$dispatch_rc" != "0" ]; then
            log "WARN" "chunk ${from_id}-${to_id}: gateway dispatch failed (rc=${dispatch_rc}, model=${GAWD_DREAM_MODEL})"
            return "$dispatch_rc"
        fi

        # 4. Extract reply text via jq.
        model_out="$(printf '%s' "$raw_json" | \
            jq -r '.result.payloads[0].text // empty' 2>/dev/null)"
        local jq_rc=$?

        if [ "$jq_rc" != "0" ] || [ -z "$model_out" ]; then
            log "WARN" "chunk ${from_id}-${to_id}: empty or unparseable gateway response (jq_rc=${jq_rc})"
            return 1
        fi

        log "INFO" "chunk ${from_id}-${to_id}: synthesis complete via ${GAWD_DREAM_MODEL}; $(printf '%s' "$model_out" | wc -c) chars"
    fi

    # ── SHORT-OUTPUT GUARD (guard a) ─────────────────────────────────────────
    # A real focus brief is 3-6 sentences (~40+ chars). If model_out is empty or
    # shorter than GAWD_DREAM_MIN_BRIEF_LEN chars, treat the response as a refusal
    # or junk output and abort this chunk — NO brief written to T2. The caller
    # (retry_with_backoff + safe-abort loop) handles the non-zero return: it will
    # retry, then safe-abort at cursor=committed if retries exhaust. This ensures
    # a one-line "I can't help with that" or similar refusal never lands as an
    # active brief in recall. Min-length check only; not designed to detect every
    # refusal pattern — just a simple sanity floor.
    local _brief_min_len="${GAWD_DREAM_MIN_BRIEF_LEN:-40}"
    local _brief_len
    _brief_len="$(printf '%s' "$model_out" | wc -c || echo 0)"
    if [ "$_brief_len" -lt "$_brief_min_len" ]; then
        log "WARN" "chunk ${from_id}-${to_id}: model output too short (${_brief_len} chars < ${_brief_min_len} min); treating as failed synthesis — no brief written"
        return 7
    fi

    # ── T2 WRITE: focus_briefs upsert (per frozen contract) ─────────────────
    # The state machine: supersede all active/draft briefs for this conversation,
    # then insert the new brief as 'active'. Both in one transaction.
    # We use the default conversation_id=1 (the first/only conversation in the
    # container test db). In production, resolve the active conversation_id from
    # conversations WHERE active=1 ORDER BY updated_at DESC LIMIT 1.
    local conv_id
    conv_id="$(sqlite3 "$GAWD_DREAM_FOCUS_DB" \
        "SELECT COALESCE(
            (SELECT conversation_id FROM conversations
             WHERE active=1 ORDER BY updated_at DESC LIMIT 1),
            1
         );" 2>/dev/null || echo 1)"

    # Generate a simple UUID-like brief_id (no uuidgen required; python3 is in image).
    # GAWD_DREAM_TEST_FORCE_BRIEF_ID overrides the generated ID for atomicity tests.
    local brief_id
    if [ -n "${GAWD_DREAM_TEST_FORCE_BRIEF_ID:-}" ]; then
        brief_id="${GAWD_DREAM_TEST_FORCE_BRIEF_ID}"
    else
        brief_id="$(python3 -c 'import uuid; print(str(uuid.uuid4()))' 2>/dev/null \
            || printf '%s-%s' "$(date -u +%s)" "$$")"
    fi

    local prompt_text="Dream consolidation of messages ${from_id}–${to_id}"
    local covered_ts
    if [ -n "${GAWD_DREAM_TEST_FORCE_COVERED_TS:-}" ]; then
        # TEST HOOK: override covered_ts for escape testing.
        covered_ts="${GAWD_DREAM_TEST_FORCE_COVERED_TS}"
    else
        covered_ts="$(sqlite3 "$GAWD_LCM_DB" \
            "SELECT COALESCE(MAX(created_at), datetime('now'))
             FROM messages WHERE message_id BETWEEN $from_id AND $to_id;" \
            2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"
    fi
    # GUARD (b): escape single quotes in covered_ts before SQL interpolation.
    # covered_ts is sqlite-derived today (harmless), but defense-in-depth: apply
    # the same single-quote-doubling used for model_out so a timestamp value
    # containing an apostrophe can never break out of the SQL string literal.
    local covered_ts_escaped
    covered_ts_escaped="$(printf '%s' "$covered_ts" | sed "s/'/''/g")"

    local token_count
    token_count="$(printf '%s' "$model_out" | wc -w || echo 0)"

    # BLOCKER-1 FIX: SQLite transaction uses -bail so that any SQL error
    # (CHECK violation, FK violation, duplicate primary key, etc.) causes sqlite3
    # to abort immediately with a non-zero exit code BEFORE reaching COMMIT.
    # SQLite automatically rolls back any open transaction when the connection
    # closes without a COMMIT — so the supersede UPDATE is rolled back if the
    # INSERT fails. Without -bail, sqlite3 reports the error but continues to
    # COMMIT, leaving the old brief superseded and the new one absent (zero
    # active briefs for the conversation — corruption).
    sqlite3 -bail "$GAWD_DREAM_FOCUS_DB" <<ENDSQL
BEGIN;
UPDATE focus_briefs
  SET status = 'superseded',
      superseded_at = datetime('now'),
      updated_at = datetime('now')
  WHERE conversation_id = ${conv_id}
    AND status IN ('draft', 'active');
INSERT INTO focus_briefs (
    brief_id, conversation_id, session_key, prompt, content, status,
    token_count, target_tokens, covered_latest_at, covered_message_seq,
    source_context_hash, generator_run_id
) VALUES (
    '${brief_id}',
    ${conv_id},
    'dreaming',
    '${prompt_text}',
    '$(printf '%s' "$model_out" | sed "s/'/''/g")',
    'active',
    ${token_count},
    ${token_count},
    '${covered_ts_escaped}',
    ${to_id},
    'dream-${from_id}-${to_id}',
    'safe-dream-$$'
);
COMMIT;
ENDSQL
    local t2_rc=$?
    if [ "$t2_rc" != "0" ]; then
        log "WARN" "T2 focus_briefs write failed (rc=$t2_rc) for chunk ${from_id}-${to_id}"
        return "$t2_rc"
    fi

    # ── T3 WRITE: day-note .md for memory-core indexing ──────────────────────
    # Written with generation:0 front-matter so wiki-gen-guard (Task 3.1)
    # admits it as a source artifact (not a summary). Uses atomic tmp+mv so
    # a crash mid-write leaves the prior note (or nothing) intact.
    mkdir -p "$GAWD_DREAM_DAY_NOTE_DIR"
    local note_file="${GAWD_DREAM_DAY_NOTE_DIR}/dream-$(date -u +%Y%m%d-%H%M%S)-${from_id}-${to_id}.md"
    local note_tmp
    note_tmp="$(mktemp "${note_file}.XXXXXX")"
    {
        printf -- '---\n'
        printf 'generation: 0\n'
        printf 'dream_run: safe-dream-%s\n' "$$"
        printf 'covered_from: %s\n' "$from_id"
        printf 'covered_to: %s\n' "$to_id"
        printf 'covered_latest_at: %s\n' "$covered_ts"
        printf 'created_at: %s\n' "$(date -u +%FT%TZ)"
        printf -- '---\n\n'
        printf '%s\n' "$model_out"
    } > "$note_tmp"
    mv -f "$note_tmp" "$note_file"

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# CHUNK LOOP — cursor-bounded, chunked, back-pressure, safe-abort.
# ──────────────────────────────────────────────────────────────────────────────
from_id=$(( last_id + 1 ))
committed_id="$last_id"

while [ "$from_id" -le "$max_id" ]; do
    to_id=$(( from_id + GAWD_DREAM_CHUNK - 1 ))
    [ "$to_id" -gt "$max_id" ] && to_id="$max_id"

    # Apply inter-call pacing before each chunk's synthesis.
    pace_gate

    # Attempt synthesis with exponential backoff (dream-pace.sh).
    if retry_with_backoff synthesize_chunk "$from_id" "$to_id"; then
        # Chunk fully committed. Advance the cursor.
        # ts: convert the covered_latest_at ISO8601 from the db to epoch for the
        # cursor's companion field. Use python3 as a portable ISO→epoch converter
        # (date -d is GNU/Linux only and may not be installed in all images).
        local_covered_ts="$(sqlite3 "$GAWD_LCM_DB" \
            "SELECT COALESCE(MAX(created_at), '1970-01-01T00:00:00Z')
             FROM messages WHERE message_id <= $to_id;" \
            2>/dev/null || echo "1970-01-01T00:00:00Z")"
        ts_epoch="$(python3 -c \
            "import datetime; \
             s='${local_covered_ts}'; \
             s=s.rstrip('Z'); \
             dt=datetime.datetime.fromisoformat(s); \
             print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))" \
            2>/dev/null || echo 0)"

        cursor_checkpoint "$to_id" "$ts_epoch"
        committed_id="$to_id"
        log "INFO" "chunk ${from_id}-${to_id} consolidated; cursor at $committed_id"

        from_id=$(( to_id + 1 ))
    else
        # retry_with_backoff exhausted without success.
        # SAFE-ABORT: checkpoint the cursor at the last FULLY-committed chunk
        # (committed_id, not to_id), log WARN, exit 0.
        # The cursor is NOT advanced past what was proven committed, so there
        # is no possibility of skip (missing messages) or dup (re-processing).
        log "WARN" "synthesis chain exhausted for chunk ${from_id}-${to_id};" \
            "safe-abort. cursor stays at committed=${committed_id}." \
            "Partial chunk NOT written. Resume next cron run."
        # Day-narrative fail-loud verification (non-fatal; self-defending).
        # Run here on safe-abort so verification fires even when dreaming
        # exits early — ensuring the silence is loud, not swallowed.
        _VERIFY_ABORT="$(dirname "$0")/dream-verify.sh"
        [ -x "$_VERIFY_ABORT" ] && "$_VERIFY_ABORT" || log "INFO" "dream-verify not present/failed (non-fatal)"
        exit 0
    fi
done

log "INFO" "dream complete; cursor at ${committed_id}"

# ──────────────────────────────────────────────────────────────────────────────
# T3 SUMMARIES — GATED WIKI REFRESH
#
# This step composes all three recursion guards (spec §4.3, Task 3.3):
#
#   Guard #1 (wiki-startup-check.sh): refuse if GAWD_WIKI_OUT is inside
#     GAWD_INGEST_SCOPE — the structural disjoint-path check.
#
#   Guard #2 (wiki-gen-guard.sh → gen_should_ingest): skip any source whose
#     front-matter generation >= 1. Only gen:0 (or untagged) source artifacts
#     are admitted. Wiki summaries (gen:1) can never feed back into synthesis.
#
#   Guard #3 (wiki-upsert.sh → wiki_upsert): hash-dedup per topic key.
#     Identical content → no write → no mtime change → no fs event →
#     no wiki bridge re-trigger.
#
# CADENCE: runs only when due (GAWD_WIKI_FORCE=1, or no .last-refresh marker,
#   or .last-refresh is older than 7 days). This bounds wiki synthesis to at
#   most once per week under normal operation.
#
# MODEL DISPATCH: follows the same stub/real pattern as synthesize_chunk (Q2).
#   - GAWD_DREAM_MODEL unset (stub mode): extracts the source body as-is.
#     No model call. Guard #3 still suppresses re-writes of unchanged content.
#   - GAWD_DREAM_MODEL set (real mode): dispatches a cheap synthesis call to
#     produce a 1-paragraph summary from the source body. A model failure for
#     any single topic is logged as WARN and skipped (non-fatal — the topic
#     will retry on the next due cadence). The wiki step never blocks dreaming.
#
# DEPTH BOUND: one pass, maxdepth 1 scan of GAWD_INGEST_SCOPE (no recursion
#   into subdirectories — only the direct .md files are candidates).
#
# ENV:
#   GAWD_INGEST_SCOPE  — source dir (day-notes from safe-dream T3 write path)
#   GAWD_WIKI_OUT      — output dir (must be disjoint from GAWD_INGEST_SCOPE)
#   GAWD_WIKI_FORCE    — set to 1 to force cadence regardless of .last-refresh
# ──────────────────────────────────────────────────────────────────────────────

GAWD_INGEST_SCOPE="${GAWD_INGEST_SCOPE:-/home/gawd/.openclaw/workspace/memory}"
GAWD_WIKI_OUT="${GAWD_WIKI_OUT:-/home/gawd/.openclaw/workspace/wiki}"

# Source the guard libraries (idempotent if already sourced).
# shellcheck source=lib/wiki-gen-guard.sh
source "${LIB}/wiki-gen-guard.sh"
# shellcheck source=lib/wiki-upsert.sh
source "${LIB}/wiki-upsert.sh"

# ── Guard #1: Startup self-check — disjoint-path enforcement ─────────────────
# wiki-startup-check.sh exits 3 if GAWD_WIKI_OUT is inside GAWD_INGEST_SCOPE.
# On failure: skip the wiki step with a loud WARN (but do NOT fail dreaming —
# spec §8 graceful degradation: wiki down must not break dreaming or recall).
_wiki_check_rc=0
GAWD_INGEST_SCOPE="$GAWD_INGEST_SCOPE" GAWD_WIKI_OUT="$GAWD_WIKI_OUT" \
    bash "${LIB}/../wiki-startup-check.sh" >/dev/null 2>&1 \
    || _wiki_check_rc=$?
if [ "${_wiki_check_rc}" != "0" ]; then
    log "WARN" "wiki startup-check failed (rc=${_wiki_check_rc}): output ($GAWD_WIKI_OUT) may be inside ingest scope ($GAWD_INGEST_SCOPE). Skipping wiki refresh — fix GAWD_WIKI_OUT path to restore."
    exit 0
fi

# ── Cadence gate ─────────────────────────────────────────────────────────────
# Due if: GAWD_WIKI_FORCE=1, OR no .last-refresh marker exists, OR marker is
# older than 7 days (604800 seconds). On any stat/math error, treat as due
# (safe default: a missed synthesis is less harmful than a blocked one).
_wiki_marker="${GAWD_WIKI_OUT}/.last-refresh"
_wiki_due=0
if [ "${GAWD_WIKI_FORCE:-0}" = "1" ]; then
    _wiki_due=1
elif [ ! -f "$_wiki_marker" ]; then
    _wiki_due=1
else
    _marker_age=$(( $(date +%s) - $(stat -c %Y "$_wiki_marker" 2>/dev/null || echo 0) )) \
        2>/dev/null || _marker_age=0
    [ "${_marker_age:-0}" -ge 604800 ] && _wiki_due=1
fi

if [ "${_wiki_due}" != "1" ]; then
    log "INFO" "wiki refresh: cadence not due (last run < 7 days ago); skipping"
    exit 0
fi

log "INFO" "wiki refresh: cadence due; scanning $GAWD_INGEST_SCOPE for gen:0 sources"

# ── Per-topic synthesis pass ──────────────────────────────────────────────────
# One pass, maxdepth 1 — no recursion into subdirectories. Each source is
# processed at most once per dream run (per-run topic dedup via associative array).
declare -A _wiki_seen_topics

# Synthesize body for a single source file. Prints the synthesized text to
# stdout. Returns 0 on success, non-zero on failure.
# In stub mode: extracts the source body as-is (passthrough).
# In real mode: dispatches to GAWD_DREAM_MODEL via the gateway.
wiki_synthesize_body() {
    local src="$1" topic="$2"
    # Strip front-matter (everything between the first and second "---" lines)
    # and return the body. awk: skip until past the second "---" delimiter.
    local body
    body="$(awk '
        NR==1 && $0=="---"{ delim=1; next }
        delim==1 && $0=="---"{ delim=2; next }
        delim==2{ print }
    ' "$src" 2>/dev/null)"

    if [ -z "$GAWD_DREAM_MODEL" ]; then
        # STUB: passthrough — no model call.
        printf '%s' "$body"
        return 0
    fi

    # REAL DISPATCH: produce a 1-paragraph summary from the source body via the
    # gateway. DemiGawd pattern: narrow context, no personality injection.
    local prompt_msg
    prompt_msg="$(printf 'Summarize the following notes about "%s" in one concise paragraph (3-5 sentences). Capture the key facts. Be specific and factual — no filler, no preamble.\n\nNotes:\n---\n%s\n---\n\nSummary:' \
        "$topic" "$body")"

    local raw_json
    # shellcheck disable=SC2086
    raw_json="$(timeout 60 \
        ${GAWD_DREAM_OPENCLAW_CMD} agent \
            --agent main \
            --model "${GAWD_DREAM_MODEL}" \
            --session-key "wiki-synth:${topic}" \
            --json \
            -m "${prompt_msg}" \
        2>/dev/null)" || return 1

    local synthesized
    synthesized="$(printf '%s' "$raw_json" | \
        jq -r '.result.payloads[0].text // empty' 2>/dev/null)"

    if [ -z "$synthesized" ]; then
        return 1
    fi

    printf '%s' "$synthesized"
    return 0
}

_wiki_synth_count=0
_wiki_skip_count=0
_wiki_fail_count=0

while IFS= read -r src_file; do
    # Guard #2: skip gen>=1 sources (summaries must not feed back into synthesis).
    gen_should_ingest "$src_file" || { _wiki_skip_count=$(( _wiki_skip_count + 1 )); continue; }

    # Per-run topic dedup: derive topic key from filename (strip path + .md).
    local_topic="$(basename "$src_file" .md)"

    # Dedup within this dream run.
    if [ -n "${_wiki_seen_topics[$local_topic]:-}" ]; then
        log "INFO" "wiki: topic '$local_topic' already processed this run; skipping duplicate"
        continue
    fi
    _wiki_seen_topics["$local_topic"]=1

    # Synthesize: get the body text for this topic.
    local_body="$(wiki_synthesize_body "$src_file" "$local_topic" 2>/dev/null)" \
        || {
            log "WARN" "wiki: synthesis failed for topic '$local_topic' (src: $src_file); skipping — will retry next cadence"
            _wiki_fail_count=$(( _wiki_fail_count + 1 ))
            continue
        }

    if [ -z "$local_body" ]; then
        log "INFO" "wiki: empty body for topic '$local_topic'; skipping"
        continue
    fi

    # Guard #3: hash-upsert — no write if content is identical.
    wiki_upsert "$local_topic" "$local_body"
    _wiki_synth_count=$(( _wiki_synth_count + 1 ))

done < <(find "$GAWD_INGEST_SCOPE" -maxdepth 1 -name '*.md' -type f 2>/dev/null)

log "INFO" "wiki refresh complete: ${_wiki_synth_count} upserted, ${_wiki_skip_count} skipped (gen>=1), ${_wiki_fail_count} failed"

# Touch the cadence marker (also creates GAWD_WIKI_OUT if it doesn't exist yet).
# Suppress mkdir/touch stderr: if GAWD_WIKI_OUT is a default path we don't own
# (e.g. /home/gawd/... running outside a Gawd container), the failure is benign.
mkdir -p "$GAWD_WIKI_OUT" 2>/dev/null || true
touch "${_wiki_marker}" 2>/dev/null || true

# ── Day-narrative fail-loud verification (non-fatal; self-defending) ──────────
# Runs immediately after each dream cycle in the same cron env so all relevant
# env vars (GAWD_LCM_DB, GAWD_DREAM_DAY_NOTE_DIR, GAWD_PROPHIT_ID, etc.) are
# already set. dream-verify.sh always exits 0 — this tail call never blocks
# dreaming or produces a cron failure even if the verify script is missing.
_VERIFY="$(dirname "$0")/dream-verify.sh"
[ -x "$_VERIFY" ] && "$_VERIFY" || log "INFO" "dream-verify not present/failed (non-fatal)"

exit 0
