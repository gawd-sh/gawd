#!/usr/bin/env bash
# gawd-safe-mutate.sh — safe-abort + auto-rollback wrapper for self-mutating ops.
#
# This is the GENERALIZATION of the guards that protected Lilith on 2026-05-28:
# every self-modifying operation the daemon performs (self-update, config change,
# recovery action) MUST:
#   (a) verify preconditions — abort CLEAN + report on mismatch (never proceed-and-break)
#   (b) after mutating, health-check
#   (c) on health-check failure, auto-rollback to last-good + alert the Prophit
#
# The locked-down `openclaw update` self-exec (project_dasra_elevated_lockdown)
# is the cautionary example of self-mutation WITHOUT this guard: it could
# self-exec and break with no precondition check, no post-health-check, no
# rollback. This wrapper makes that failure mode structurally impossible for any
# op routed through it.
#
# Usage:
#   gawd-safe-mutate.sh \
#       --label <op-name> \
#       --backup <path-to-snapshot>          (file OR dir; snapshotted before mutate) \
#       [--precond <cmd>]                    (must exit 0 BEFORE mutate, else abort clean) \
#       --mutate <cmd>                       (the self-mutating action) \
#       --healthcheck <cmd>                  (must exit 0 AFTER mutate, else rollback) \
#       [--alert]                            (fire gawd-failure-alert.sh on rollback)
#
# All <cmd> args are run via `bash -c`. Exit codes:
#   0  mutate applied and health-check passed
#   10 precondition failed — aborted CLEAN, nothing mutated (NOT an error state)
#   20 mutate command itself failed — rolled back
#   30 health-check failed after mutate — rolled back
#   40 invalid invocation
#
# Idempotent: re-running is safe; the backup is timestamped, never overwritten.
# Fail-loud: every decision is logged to reliability.log. NEVER echoes secrets.
set -uo pipefail

LABEL=""; BACKUP=""; PRECOND=""; MUTATE=""; HEALTHCHECK=""; DO_ALERT=0
GAWD_HOME="${GAWD_HOME:-$HOME/.gawd}"
LOG="${GAWD_HOME}/logs/reliability.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_say() { printf '[safe-mutate] %s\n' "$*"; printf '%s safe-mutate %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)       LABEL="${2:-}"; shift 2 ;;
    --backup)      BACKUP="${2:-}"; shift 2 ;;
    --precond)     PRECOND="${2:-}"; shift 2 ;;
    --mutate)      MUTATE="${2:-}"; shift 2 ;;
    --healthcheck) HEALTHCHECK="${2:-}"; shift 2 ;;
    --alert)       DO_ALERT=1; shift ;;
    *) _say "invalid arg: $1"; exit 40 ;;
  esac
done

[[ -z "$LABEL" || -z "$MUTATE" || -z "$HEALTHCHECK" ]] && { _say "missing --label/--mutate/--healthcheck"; exit 40; }

# (a) Precondition: verify BEFORE mutating. Mismatch → abort CLEAN, mutate nothing.
if [[ -n "$PRECOND" ]]; then
  if ! bash -c "$PRECOND" >>"$LOG" 2>&1; then
    _say "PRECONDITION FAILED for '${LABEL}' — aborting CLEAN, nothing mutated"
    exit 10
  fi
  _say "precondition ok for '${LABEL}'"
fi

# Snapshot last-good for rollback (timestamped; never clobbers an existing snap).
# M2 (2026-05-28): record whether the target EXISTED before the mutate. A
# create-from-nothing mutation has no pre-existing backup to restore — the correct
# pre-mutate state is "the artifact does not exist", so rollback must DELETE the
# created artifact, not leave a half-created one behind looking like success.
SNAP=""
TARGET_EXISTED=0
if [[ -n "$BACKUP" && -e "$BACKUP" ]]; then
  TARGET_EXISTED=1
  SNAP="${BACKUP}.lastgood.$(date +%s)"
  if cp -a "$BACKUP" "$SNAP" 2>>"$LOG"; then
    _say "snapshot of '${BACKUP}' → '${SNAP}'"
  else
    _say "WARN: could not snapshot '${BACKUP}' — proceeding WITHOUT rollback capability for '${LABEL}'"
    SNAP=""
  fi
elif [[ -n "$BACKUP" ]]; then
  _say "target '${BACKUP}' does not exist pre-mutate (create-from-nothing) — rollback will REMOVE the created artifact to restore true pre-mutate state"
fi

_rollback() {
  if [[ "$TARGET_EXISTED" -eq 0 && -n "$BACKUP" ]]; then
    # M2: create-from-nothing — true pre-mutate state is "absent". Remove whatever
    # the mutate created so a failed create never leaves a partial artifact.
    if rm -rf "$BACKUP" 2>>"$LOG"; then
      _say "ROLLED BACK '${LABEL}' by REMOVING created artifact '${BACKUP}' (restored absent pre-mutate state)"
    else
      _say "ERROR: rollback REMOVE FAILED for '${LABEL}' — '${BACKUP}' partial artifact retained for manual recovery"
    fi
  elif [[ -n "$SNAP" && -e "$SNAP" ]]; then
    rm -rf "$BACKUP" 2>>"$LOG" || true
    if cp -a "$SNAP" "$BACKUP" 2>>"$LOG"; then
      _say "ROLLED BACK '${BACKUP}' to last-good snapshot for '${LABEL}'"
    else
      _say "ERROR: rollback copy FAILED for '${LABEL}' — '${SNAP}' retained for manual recovery"
    fi
  else
    _say "no snapshot available — cannot auto-rollback '${LABEL}' (manual recovery needed)"
  fi
  if [[ "$DO_ALERT" -eq 1 && -x "${SCRIPT_DIR}/gawd-failure-alert.sh" ]]; then
    bash "${SCRIPT_DIR}/gawd-failure-alert.sh" "self-mutate:${LABEL}" || true
  fi
}

# (b) Mutate.
if ! bash -c "$MUTATE" >>"$LOG" 2>&1; then
  _say "MUTATE command FAILED for '${LABEL}' — rolling back"
  _rollback
  exit 20
fi
_say "mutate applied for '${LABEL}'"

# (c) Post-mutate health-check → rollback on failure.
if ! bash -c "$HEALTHCHECK" >>"$LOG" 2>&1; then
  _say "HEALTH-CHECK FAILED after mutate for '${LABEL}' — auto-rolling back to last-good"
  _rollback
  exit 30
fi

_say "mutate + health-check PASSED for '${LABEL}' — change committed"
exit 0
