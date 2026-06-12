#!/usr/bin/env bash
# demigawd-spawn.sh — DemiGawd spawn primitive (sourced as a library).
#
# Source-as-library contract:
#   source /usr/local/lib/gawd/runtime/demigawd-spawn.sh
#   TASK_ID="$(spawn_demigawd <skill_name> <task_description> [injected_context])"
#
# This file deliberately does nothing when executed directly except print the
# contract reminder. Spawning a DemiGawd from a script that did not source
# this library is the architectural violation we want to surface early.
#
# Per Gawd v1 spec §6 (DemiGawd Architecture) and gospel §1 principle 8
# (background-by-default — no exceptions, no override flag).
#
# Reference spec: <install-root>/docs/superpowers/specs/2026-05-26-gawd-architecture-design.md §6
# Reference doc:  <install-root>/docs/architecture/demigawd-runtime.md

# ---------------------------------------------------------------------------
# If executed directly, just print contract reminder and exit 2.
# Spawn primitives that bypass this library are an architectural violation.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cat >&2 <<'EOF'
demigawd-spawn.sh is a library, not a runnable script.

Use it like:
    source /usr/local/lib/gawd/runtime/demigawd-spawn.sh
    TASK_ID="$(spawn_demigawd <skill_name> <task_description> [injected_context])"

Spawning a DemiGawd outside of this library is a contract violation.
EOF
    exit 2
fi

# Once: prevent double-source from setting traps twice.
if [[ -n "${__DEMIGAWD_SPAWN_LOADED:-}" ]]; then
    return 0
fi
__DEMIGAWD_SPAWN_LOADED=1

# ---------------------------------------------------------------------------
# Defaults & paths
# ---------------------------------------------------------------------------

# Workspace root — every persona file architecture (A1 §6) lays out
# ~/.gawd/workspace/. Skill scripts and state live underneath.
: "${GAWD_WORKSPACE_ROOT:=${HOME}/.gawd/workspace}"
: "${GAWD_SKILLS_ROOT:=${GAWD_WORKSPACE_ROOT}/skills}"
: "${GAWD_STATE_ROOT:=${GAWD_WORKSPACE_ROOT}/state}"

# Caps on injected context (chars). Keeps a runaway caller from injecting
# the whole MEMORY.md and blowing up the spawned DemiGawd's effective budget.
# DemiGawds are narrow-task by design (spec §6.4 "narrow task, minimal context").
: "${GAWD_DEMIGAWD_CONTEXT_MAX_CHARS:=8000}"

# Per-spawn description cap (chars). The task description is the prompt seed.
: "${GAWD_DEMIGAWD_DESC_MAX_CHARS:=4000}"

# Maximum simultaneous in-flight DemiGawds. Gospel §1.6 RAM-aware: default 3 on
# a constrained box. Callers receive exit code 75 (EX_TEMPFAIL) when full so
# they can queue/back off rather than get silently dropped.
: "${GAWD_DEMIGAWD_MAX_CONCURRENT:=3}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Print to stderr with a consistent prefix; never echo secrets.
_gawd_spawn_err() {
    printf 'demigawd-spawn: %s\n' "$*" >&2
}

# Validate skill name: lowercase, digits, hyphens; no path components.
_gawd_spawn_valid_skill_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z][a-z0-9-]{1,63}$ ]]
}

# Generate a TASK_ID matching Lilith's pattern with a uniqueness suffix.
# Lilith uses "<skill>-<YYYYMMDD>-<HHMMSS>". We append "-<random-4>" so that
# rapid same-second spawns of the same skill cannot collide on the result file.
_gawd_spawn_make_task_id() {
    local skill="$1"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local rand
    # 4 hex chars from /dev/urandom; portable on Linux + macOS.
    rand="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s-%s-%s' "$skill" "$ts" "$rand"
}

# Ensure state root exists with safe perms (0700 — Gawd-private).
_gawd_spawn_ensure_state_root() {
    if [[ ! -d "$GAWD_STATE_ROOT" ]]; then
        mkdir -p "$GAWD_STATE_ROOT"
        chmod 0700 "$GAWD_STATE_ROOT" 2>/dev/null || true
    fi
}

# Write an in-progress marker so the cleanup never deletes a still-running
# spawn. Per handoff acceptance: only complete/failed + age threshold.
# $2 = child PID (recorded so cleanup can kill the process group on orphan reap).
_gawd_spawn_write_marker() {
    local task_id="$1"
    local child_pid="${2:-}"
    local marker="${GAWD_STATE_ROOT}/${task_id}.marker"
    # JSON marker so cleanup can read status field deterministically.
    # status:"incomplete" is what cleanup explicitly refuses to delete.
    # pid field is used by orphan-reap logic in demigawd-cleanup.sh to
    # kill -- -$pid (process group) for a hung DemiGawd.
    printf '{"status":"incomplete","task_id":"%s","spawned_at":"%s","pid":%s}\n' \
        "$task_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${child_pid:-null}" >"$marker"
    chmod 0600 "$marker" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Public function: spawn_demigawd
#
# Args:
#   $1 = skill_name        (required; matches dir under $GAWD_SKILLS_ROOT)
#   $2 = task_description  (required; the prompt seed; capped)
#   $3 = injected_context  (optional; capped; pre-trimmed by caller for relevance)
#
# Output (stdout):
#   TASK_ID on success, single line, nothing else.
#
# Behavior:
#   - Resolves skill path, validates skill exists and is executable.
#   - Builds TASK_ID, writes the incomplete marker.
#   - Forks the skill in the background (`&`), passing (TASK_ID, desc, context).
#   - Disowns the child so the parent shell can exit without taking it down.
#   - Returns the TASK_ID on stdout. Caller hands it to demigawd-await.sh.
#
# Background invariant:
#   - There is NO foreground flag. There is no override.
#   - The function always backgrounds with `&` and disowns.
#   - A separate test (tests/test-background-invariant.sh) asserts this.
# ---------------------------------------------------------------------------
spawn_demigawd() {
    local skill="${1:?skill_name required}"
    local desc="${2:?task_description required}"
    local context="${3:-}"

    _gawd_spawn_valid_skill_name "$skill" || {
        _gawd_spawn_err "invalid skill name: $skill (must match ^[a-z][a-z0-9-]{1,63}$)"
        return 64  # EX_USAGE
    }

    local skill_path="${GAWD_SKILLS_ROOT}/${skill}/skill.sh"
    if [[ ! -x "$skill_path" ]]; then
        _gawd_spawn_err "skill not executable: $skill_path"
        return 66  # EX_NOINPUT
    fi

    if (( ${#desc} > GAWD_DEMIGAWD_DESC_MAX_CHARS )); then
        _gawd_spawn_err "task description exceeds cap (${#desc} > ${GAWD_DEMIGAWD_DESC_MAX_CHARS} chars)"
        return 65  # EX_DATAERR
    fi
    if (( ${#context} > GAWD_DEMIGAWD_CONTEXT_MAX_CHARS )); then
        _gawd_spawn_err "injected context exceeds cap (${#context} > ${GAWD_DEMIGAWD_CONTEXT_MAX_CHARS} chars)"
        return 65
    fi

    _gawd_spawn_ensure_state_root

    # dem-H3: concurrency cap — count live .marker files that have no
    # matching .result yet (i.e., still in-flight).
    local in_flight
    in_flight=0
    local mf
    for mf in "${GAWD_STATE_ROOT}/"*.marker; do
        [[ -f "$mf" ]] || continue          # glob no-match yields literal '*'
        local tf
        tf="${mf%.marker}.result"
        [[ -f "$tf" ]] && continue          # already completed
        in_flight=$(( in_flight + 1 ))
    done
    if (( in_flight >= GAWD_DEMIGAWD_MAX_CONCURRENT )); then
        _gawd_spawn_err "concurrency cap reached (${in_flight}/${GAWD_DEMIGAWD_MAX_CONCURRENT} in-flight); caller should queue/back off"
        return 75  # EX_TEMPFAIL — distinct code so callers can branch
    fi

    local task_id
    task_id="$(_gawd_spawn_make_task_id "$skill")"

    # Write marker without PID first (placeholder); we update with real PID after fork.
    _gawd_spawn_write_marker "$task_id" ""

    # Background invariant: ALWAYS detach.
    # - setsid: detach from the controlling terminal so the child survives
    #   parent exit cleanly. setsid also creates a new process group whose
    #   PGID == child PID, enabling `kill -- -$child_pid` for group kill.
    # - stdout/stderr: append to a per-task log so debugging is possible
    #   without leaking to the parent shell's transcript.
    local log="${GAWD_STATE_ROOT}/${task_id}.log"
    setsid bash "$skill_path" "$task_id" "$desc" "$context" \
        >>"$log" 2>&1 </dev/null &

    # dem-H2: capture child PID BEFORE disown so it can be recorded and later
    # used by cleanup to kill the process group on orphan reap.
    local child_pid="$!"

    # Disown so the parent shell loses any job-control responsibility.
    disown "$child_pid" 2>/dev/null || true

    # Rewrite the marker with the real child PID now that we have it.
    _gawd_spawn_write_marker "$task_id" "$child_pid"

    # Contract: TASK_ID on stdout, nothing else.
    printf '%s\n' "$task_id"
}

# ---------------------------------------------------------------------------
# Public function: spawn_demigawd_check
#
# Lightweight introspection — caller can ask "is this skill installed?"
# without attempting a spawn.
# ---------------------------------------------------------------------------
spawn_demigawd_check() {
    local skill="${1:?skill_name required}"
    _gawd_spawn_valid_skill_name "$skill" || return 64
    local skill_path="${GAWD_SKILLS_ROOT}/${skill}/skill.sh"
    [[ -x "$skill_path" ]]
}
