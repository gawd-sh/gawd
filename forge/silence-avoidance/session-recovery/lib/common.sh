#!/usr/bin/env bash
# lib/common.sh — shared helpers for session-recovery scripts.
#
# Sourced by detect.sh, clear.sh, recover.sh, sweep.sh, on-terminal-error.sh.
# Provides:
#   - SR_* env-var defaults (paths, thresholds)
#   - sr_log_* structured logging (delegates to forge/observability/logger.sh
#     if present; falls back to stderr-only otherwise)
#   - sr_backup_index <path> — copy index file to .bak.recovery-<ts>
#   - sr_atomic_write <path> <content> — tmp + rename
#   - sr_index_read_session <session-key> <field>  — jq query, no jq inline
#   - sr_index_is_wedged <session-key> — returns 0 if wedged per spec
#   - sr_index_archive_session <session-key> — produce mutated index (writes atomically)
#   - sr_emit_signal <event> <session-id> <session-key> <diagnostic-json>
#   - sr_log_recovery <session-id> <action> <outcome> <extras-json>
#
# NEVER source unguarded. Use:
#   SR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SR_DIR}/lib/common.sh"

if [[ -n "${__SESSION_RECOVERY_COMMON_LOADED:-}" ]]; then
    return 0
fi
__SESSION_RECOVERY_COMMON_LOADED=1

# ─────────────────────────────────────────────────────────────────────────
# Defaults — every callable may override via env before sourcing.
# ─────────────────────────────────────────────────────────────────────────

: "${SR_OPENCLAW_HOME:=${HOME}/.openclaw}"
: "${SR_AGENTS_DIR:=${SR_OPENCLAW_HOME}/agents}"
# We support multi-agent installs (main, plus future named agents). Default to main.
: "${SR_AGENT_ID:=main}"
: "${SR_SESSIONS_DIR:=${SR_AGENTS_DIR}/${SR_AGENT_ID}/sessions}"
: "${SR_INDEX_FILE:=${SR_SESSIONS_DIR}/sessions.json}"
: "${SR_ARCHIVE_DIR:=${SR_SESSIONS_DIR}/archived/error-sessions}"

# State / signals
: "${SR_STATE_DIR:=${HOME}/.gawd/state/session-recovery}"
: "${SR_SIGNAL_DIR:=${SR_STATE_DIR}/signals}"
: "${SR_RECOVERY_LOG:=${SR_STATE_DIR}/recovery-log.jsonl}"

# Behavior thresholds
# Grace window: don't act on a session whose last interaction is within
# this many milliseconds (might be in-flight).
: "${SR_WEDGE_GRACE_MS:=10000}"
# Dry-run: when set to 1, no mutation occurs; report only.
: "${SR_DRY_RUN:=0}"

# Terminal-error reasons we treat as wedge. OpenClaw currently exports only
# one: NON_DELIVERABLE_TERMINAL_TURN_REASON = "non_deliverable_terminal_turn"
# (see /usr/lib/node_modules/openclaw/dist/plugin-sdk/src/agents/pi-embedded-runner/run/attempt-trajectory-status.d.ts).
# We also accept the spec's `non_d*` family as future-proofing.
: "${SR_TERMINAL_ERROR_REGEX:=^non_d.*}"

# Logger integration
: "${SR_LOGGER_PATH:=/usr/local/lib/gawd/observability/logger.sh}"

mkdir -p "$SR_STATE_DIR" "$SR_SIGNAL_DIR" "$SR_ARCHIVE_DIR" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────
# Logging — prefer forge/observability/logger.sh; fall back to stderr.
# ─────────────────────────────────────────────────────────────────────────

if [[ -r "$SR_LOGGER_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$SR_LOGGER_PATH"
    sr_log_info()  { log_info  "session-recovery" "$@"; }
    sr_log_warn()  { log_warn  "session-recovery" "$@"; }
    sr_log_error() { log_error "session-recovery" "$@"; }
else
    # Minimal fallback — keeps recovery functional even before D3 lands.
    _sr_fallback_log() {
        local sev="$1"; shift
        printf '{"severity":"%s","source":"session-recovery","ts":"%s","message":"%s"}\n' \
            "$sev" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
    }
    sr_log_info()  { _sr_fallback_log info  "$@"; }
    sr_log_warn()  { _sr_fallback_log warn  "$@"; }
    sr_log_error() { _sr_fallback_log error "$@"; }
fi

# ─────────────────────────────────────────────────────────────────────────
# Time helpers
# ─────────────────────────────────────────────────────────────────────────

sr_now_ms() {
    # GNU date: %N gives ns; we want ms. Portable fallback uses seconds-only.
    local ns
    ns=$(date +%s%N 2>/dev/null) || ns=""
    if [[ "$ns" =~ ^[0-9]+$ ]] && (( ${#ns} >= 13 )); then
        echo $(( ns / 1000000 ))
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

sr_now_iso() {
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ
}

sr_now_ns() {
    date +%s%N 2>/dev/null || echo $(( $(date +%s) * 1000000000 ))
}

# ─────────────────────────────────────────────────────────────────────────
# Backup discipline (DOCTRINE §5.3)
# ─────────────────────────────────────────────────────────────────────────

# sr_backup_index <path>
# Copies the file to <path>.bak.recovery-<iso-timestamp>. Echoes the backup
# path on stdout. Returns 0 on success, non-zero on failure.
sr_backup_index() {
    local src="$1"
    if [[ ! -f "$src" ]]; then
        sr_log_warn "backup: source not present: ${src}"
        return 1
    fi
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local dst="${src}.bak.recovery-${ts}"
    if cp -p -- "$src" "$dst" 2>/dev/null; then
        sr_log_info "backup: ${src} -> ${dst}"
        echo "$dst"
        return 0
    fi
    sr_log_error "backup failed: ${src} -> ${dst}"
    return 2
}

# ─────────────────────────────────────────────────────────────────────────
# Atomic write — tmp + rename in the same directory (preserves rename atomicity)
# ─────────────────────────────────────────────────────────────────────────

# sr_atomic_write <dst> <content-string>
sr_atomic_write() {
    local dst="$1"
    local content="$2"
    local dir
    dir="$(dirname -- "$dst")"
    mkdir -p -- "$dir"
    local tmp
    tmp="$(mktemp -- "${dst}.tmp.XXXXXX")"
    printf '%s' "$content" > "$tmp"
    # Preserve mode if dst already exists; otherwise default 0644.
    if [[ -f "$dst" ]]; then
        chmod --reference="$dst" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    else
        chmod 0644 "$tmp"
    fi
    mv -f -- "$tmp" "$dst"
}

# sr_atomic_write_file <dst> <src-file>
sr_atomic_write_file() {
    local dst="$1"
    local src="$2"
    local dir
    dir="$(dirname -- "$dst")"
    mkdir -p -- "$dir"
    local tmp
    tmp="$(mktemp -- "${dst}.tmp.XXXXXX")"
    cp -- "$src" "$tmp"
    if [[ -f "$dst" ]]; then
        chmod --reference="$dst" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    else
        chmod 0644 "$tmp"
    fi
    mv -f -- "$tmp" "$dst"
}

# ─────────────────────────────────────────────────────────────────────────
# Index queries (read-only)
# ─────────────────────────────────────────────────────────────────────────

# sr_index_keys — print every session-key in the index, one per line.
sr_index_keys() {
    if [[ ! -f "$SR_INDEX_FILE" ]]; then
        return 0
    fi
    jq -r 'keys[]' "$SR_INDEX_FILE" 2>/dev/null || return 0
}

# sr_index_field <session-key> <field>
sr_index_field() {
    local key="$1"
    local field="$2"
    if [[ ! -f "$SR_INDEX_FILE" ]]; then
        return 1
    fi
    jq -r --arg k "$key" --arg f "$field" '.[$k][$f] // empty' "$SR_INDEX_FILE" 2>/dev/null
}

# sr_index_session_id_for_key <session-key> — the session UUID.
sr_index_session_id_for_key() {
    sr_index_field "$1" "sessionId"
}

# sr_index_key_for_session_id <session-id>
# Reverse lookup: find the session-key whose entry has sessionId == <session-id>.
sr_index_key_for_session_id() {
    local sid="$1"
    if [[ ! -f "$SR_INDEX_FILE" ]]; then
        return 1
    fi
    jq -r --arg sid "$sid" 'to_entries[] | select(.value.sessionId == $sid) | .key' \
        "$SR_INDEX_FILE" 2>/dev/null | head -n 1
}

# ─────────────────────────────────────────────────────────────────────────
# Wedge detection — the central rule
# ─────────────────────────────────────────────────────────────────────────

# sr_is_session_wedged_by_key <session-key>
#
# Returns:
#   0 = wedged (recovery should run)
#   1 = healthy / in-flight (do not act)
#   2 = unknown (index missing, key absent, malformed)
sr_is_session_wedged_by_key() {
    local key="$1"

    if [[ ! -f "$SR_INDEX_FILE" ]]; then
        return 2
    fi

    # Pull the whole entry once; cheap, avoids 6 jq invocations.
    local entry
    entry="$(jq -c --arg k "$key" '.[$k] // empty' "$SR_INDEX_FILE" 2>/dev/null)"
    if [[ -z "$entry" || "$entry" == "null" || "$entry" == "empty" ]]; then
        return 2
    fi

    local status terminal_error aborted last_at session_id
    status="$(printf '%s' "$entry"          | jq -r '.status // empty')"
    terminal_error="$(printf '%s' "$entry"  | jq -r '.terminalError // empty')"
    aborted="$(printf '%s' "$entry"         | jq -r '.abortedLastRun // false')"
    last_at="$(printf '%s' "$entry"         | jq -r '.lastInteractionAt // 0')"
    session_id="$(printf '%s' "$entry"      | jq -r '.sessionId // empty')"

    # Rule 1: terminal-error marker present OR status is in error family with terminalError
    local has_terminal_error=0
    if [[ -n "$terminal_error" && "$terminal_error" =~ $SR_TERMINAL_ERROR_REGEX ]]; then
        has_terminal_error=1
    fi
    # The index sometimes lacks the explicit terminalError but has status:"failed"
    # AND a non_d* in the trajectory file. We check the trajectory only if status
    # signals trouble — keeps the hot path cheap.
    if [[ $has_terminal_error -eq 0 ]] && [[ "$status" == "failed" || "$status" == "error" ]]; then
        local jsonl="${SR_SESSIONS_DIR}/${session_id}.jsonl"
        if [[ -f "$jsonl" ]]; then
            # Read the last few lines and look for a non_d* terminal-error reason.
            if tail -n 50 "$jsonl" 2>/dev/null \
                | grep -E "\"terminalError\"[[:space:]]*:[[:space:]]*\"non_d[a-zA-Z_]*\"" \
                  >/dev/null 2>&1; then
                has_terminal_error=1
            fi
        fi
    fi

    if [[ $has_terminal_error -eq 0 ]]; then
        return 1
    fi

    # Rule 2: aborted must be true. If the last run completed, it's not wedged
    # even if a terminal error was recorded earlier.
    if [[ "$aborted" != "true" ]]; then
        return 1
    fi

    # Rule 3: grace window — don't pre-empt an in-flight retry.
    local now grace_floor
    now="$(sr_now_ms)"
    grace_floor=$(( now - SR_WEDGE_GRACE_MS ))
    # last_at is in ms (OpenClaw convention). If unset/zero, treat as old.
    if [[ "$last_at" =~ ^[0-9]+$ ]] && (( last_at > grace_floor )); then
        return 1
    fi

    # Rule 4: idempotence — already recovered?
    if [[ -f "$SR_RECOVERY_LOG" && -n "$session_id" ]]; then
        # Look for any 'recovered' entry whose session_id matches and whose
        # ts is >= last_at. Cheap line filter; jq parse only matching lines.
        local already
        already="$(grep -F "\"$session_id\"" "$SR_RECOVERY_LOG" 2>/dev/null \
            | jq -c --arg sid "$session_id" --argjson floor "$last_at" \
                'select(.session_id == $sid)
                 | select(.action == "recovered")
                 | select((.last_interaction_at_ms // 0) >= $floor)' 2>/dev/null \
            | head -n 1)"
        if [[ -n "$already" ]]; then
            return 1
        fi
    fi

    return 0
}

# sr_is_session_wedged_by_id <session-id>
# Convenience wrapper for callers (L7) that only have the UUID.
sr_is_session_wedged_by_id() {
    local sid="$1"
    local key
    key="$(sr_index_key_for_session_id "$sid")"
    if [[ -z "$key" ]]; then
        return 2
    fi
    sr_is_session_wedged_by_key "$key"
}

# ─────────────────────────────────────────────────────────────────────────
# Index mutation — produce a mutated copy via jq, write atomically
# ─────────────────────────────────────────────────────────────────────────

# sr_index_archive_entry <session-key>
#
# Mutation policy (history-preserving):
#   - Remove the session-key entry from the index. OpenClaw will allocate a
#     fresh session on the next inbound message for that key, which is the
#     desired behavior. The transcript .jsonl moves to archive (sr_archive_jsonl
#     below), so history is preserved on disk.
#   - Backup the index first via sr_backup_index.
#   - Atomic-write the mutated index.
#
# Returns 0 on success; 2 on any failure (no partial state left behind).
sr_index_archive_entry() {
    local key="$1"

    if [[ "$SR_DRY_RUN" == "1" ]]; then
        sr_log_info "DRY_RUN: would archive entry key=${key} (no mutation)"
        return 0
    fi

    if [[ ! -f "$SR_INDEX_FILE" ]]; then
        sr_log_error "index missing: ${SR_INDEX_FILE}"
        return 2
    fi

    # Backup first — non-fatal if backup itself fails, but warn loudly.
    if ! sr_backup_index "$SR_INDEX_FILE" >/dev/null; then
        sr_log_error "backup failed; aborting mutation for safety"
        return 2
    fi

    # jq the entry out.
    local mutated
    mutated="$(jq --arg k "$key" 'del(.[$k])' "$SR_INDEX_FILE" 2>/dev/null)"
    if [[ -z "$mutated" ]]; then
        sr_log_error "jq mutation produced empty output for key=${key}"
        return 2
    fi

    # Sanity check: still valid JSON, still an object.
    if ! printf '%s' "$mutated" | jq -e 'type == "object"' >/dev/null 2>&1; then
        sr_log_error "mutated index is not a JSON object — refusing to write"
        return 2
    fi

    sr_atomic_write "$SR_INDEX_FILE" "$mutated"
    sr_log_info "index entry archived: key=${key}"
    return 0
}

# sr_archive_jsonl <session-id>
# Move the trajectory file(s) to SR_ARCHIVE_DIR with a timestamped name.
# Preserves history (move, not delete). Trajectory + trajectory-path move
# together so audit replays are coherent.
sr_archive_jsonl() {
    local sid="$1"

    if [[ "$SR_DRY_RUN" == "1" ]]; then
        sr_log_info "DRY_RUN: would archive jsonl for session=${sid}"
        return 0
    fi

    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$SR_ARCHIVE_DIR"

    local rc=0
    for suffix in ".jsonl" ".trajectory.jsonl" ".trajectory-path.json"; do
        local src="${SR_SESSIONS_DIR}/${sid}${suffix}"
        if [[ -f "$src" ]]; then
            local dst="${SR_ARCHIVE_DIR}/${sid}${suffix}.recovered.${stamp}"
            if mv -- "$src" "$dst" 2>/dev/null; then
                sr_log_info "archived: ${src} -> ${dst}"
            else
                sr_log_warn "archive move failed: ${src} -> ${dst}"
                rc=1
            fi
        fi
    done

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────
# Signal emission for L6 engine subscription
# ─────────────────────────────────────────────────────────────────────────

# sr_emit_signal <event> <session-id> <session-key> <diagnostic-json>
#
# Writes a JSON marker to SR_SIGNAL_DIR. L6 engine reads markers at next
# message-arrival time (or on its own poll), then deletes them after
# processing.
#
# Filename: <event>-<session-id>-<unix-ns>.json
sr_emit_signal() {
    local event="$1"           # stuck-state | recovered
    local sid="$2"
    local key="$3"
    local diag="${4:-{\}}"     # JSON object; defaults to {}

    case "$event" in
        stuck-state|recovered) ;;
        *)
            sr_log_error "sr_emit_signal: unknown event '${event}'"
            return 2
            ;;
    esac

    if ! printf '%s' "$diag" | jq -e . >/dev/null 2>&1; then
        sr_log_warn "diagnostic not valid JSON; substituting empty object"
        diag="{}"
    fi

    local now_iso ns marker
    now_iso="$(sr_now_iso)"
    ns="$(sr_now_ns)"
    marker="${SR_SIGNAL_DIR}/${event}-${sid}-${ns}.json"

    # Address-name and channel hints are read from the entry's metadata where
    # available; fall back to empty (L6 will route by Prophit default).
    local body
    body="$(jq -nc \
        --arg event "$event" \
        --arg sid "$sid" \
        --arg key "$key" \
        --arg ts "$now_iso" \
        --argjson diag "$diag" \
        '{
            event: $event,
            session_id: $sid,
            session_key: $key,
            occurred_at: $ts,
            diagnostic: $diag
        }')"

    if [[ "$SR_DRY_RUN" == "1" ]]; then
        sr_log_info "DRY_RUN: would emit signal ${event} for session=${sid}"
        return 0
    fi

    sr_atomic_write "$marker" "$body"
    sr_log_info "signal emitted: ${event} session=${sid} marker=${marker}"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Recovery log — append-only, jsonl
# ─────────────────────────────────────────────────────────────────────────

# sr_log_recovery <session-id> <session-key> <action> <outcome> <extras-json>
#   action ∈ {detected, cleared, recovered, skipped, failed, stuck-state-signaled}
#   outcome ∈ {ok, error, noop}
sr_log_recovery() {
    local sid="${1:-}"
    local key="${2:-}"
    local action="${3:-}"
    local outcome="${4:-}"
    local extras="${5:-{\}}"

    if ! printf '%s' "$extras" | jq -e . >/dev/null 2>&1; then
        extras="{}"
    fi

    mkdir -p "$(dirname -- "$SR_RECOVERY_LOG")"
    local line
    line="$(jq -nc \
        --arg ts "$(sr_now_iso)" \
        --arg sid "$sid" \
        --arg key "$key" \
        --arg action "$action" \
        --arg outcome "$outcome" \
        --argjson extras "$extras" \
        '{
            ts: $ts,
            session_id: $sid,
            session_key: $key,
            action: $action,
            outcome: $outcome
        } + $extras')"

    # Append. The jsonl format is one object per line; tiny race window on
    # concurrent writers is acceptable (single-machine daemon).
    printf '%s\n' "$line" >> "$SR_RECOVERY_LOG"
}

# ─────────────────────────────────────────────────────────────────────────
# Diagnostic snapshot — for archived sessions, helpful for postmortems
# ─────────────────────────────────────────────────────────────────────────

# sr_diagnostic_for_key <session-key> → JSON object on stdout
sr_diagnostic_for_key() {
    local key="$1"
    if [[ ! -f "$SR_INDEX_FILE" ]]; then
        echo '{}'
        return 0
    fi
    jq -c --arg k "$key" '
        .[$k] // {}
        | {
            terminal_error: (.terminalError // null),
            status: (.status // null),
            last_provider: (.modelProvider // null),
            last_model: (.model // null),
            last_interaction_at_ms: (.lastInteractionAt // null),
            session_key: $k
        }
    ' "$SR_INDEX_FILE" 2>/dev/null || echo '{}'
}
