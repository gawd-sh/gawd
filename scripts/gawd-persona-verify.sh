#!/usr/bin/env bash
# gawd-persona-verify.sh — Read-only permission verifier for Gawd persona files.
#
# PURPOSE
#   Returns exit 0 if all T0 anchor and adaptive file permissions are correct.
#   Returns exit 1 with a diff-style report if any permission is wrong.
#
#   Intended to be called from the session-start hook so the Gawd refuses to
#   start with a corrupt permission state.
#
# USAGE (does NOT require root — reads only)
#   gawd-persona-verify.sh [--workspace PATH] [--runtime-user USER]
#                          [--soul-user USER] [--quiet]
#
#   --workspace PATH     path to the Gawd workspace dir   (default: ~/.gawd/workspace)
#   --runtime-user USER  name of the Gawd runtime user    (default: gawd)
#   --soul-user USER     name of the soul/anchor user     (default: gawd-soul)
#   --quiet              suppress OK lines; print only violations
#
# OUTPUT FORMAT (on violation)
#   VIOLATION  VOICE.md  expected: 0444 gawd-soul:<group>  actual: 0644 gawd:<group>
#
# EXIT CODES
#   0  all permissions correct
#   1  one or more permission violations found
#   2  workspace not found
#
# WHEN TO RUN
#   - At session start (wired into the OpenClaw session-start hook)
#   - After any gawd-persona-perms.sh run, to confirm it succeeded
#   - After a revelation upgrade lands, to confirm merge preserved T0 perms
#   - After gawd-import completes, to confirm import-time perm assertion worked

set -uo pipefail
# Note: no -e so we collect all violations before exiting.

# ── helpers ─────────────────────────────────────────────────────────────────────

QUIET=0

ok_line()   {
  [[ "$QUIET" -eq 1 ]] && return
  printf '\033[1;32m[verify]\033[0m OK         %s\n' "$*"
}
fail_line() { printf '\033[1;31m[verify]\033[0m VIOLATION  %s\n' "$*" >&2; }
warn_line() { printf '\033[1;33m[verify]\033[0m WARNING    %s\n' "$*" >&2; }
info_line() {
  [[ "$QUIET" -eq 1 ]] && return
  printf '\033[1;34m[verify]\033[0m %s\n' "$*"
}

VIOLATIONS=0

# ── argument parsing ─────────────────────────────────────────────────────────────

WORKSPACE=""
RUNTIME_USER="gawd"
SOUL_USER="gawd-soul"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift; WORKSPACE="${1:-}"
      ;;
    --runtime-user)
      shift; RUNTIME_USER="${1:-gawd}"
      ;;
    --soul-user)
      shift; SOUL_USER="${1:-gawd-soul}"
      ;;
    --quiet)
      QUIET=1
      ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

# Default workspace resolution
if [[ -z "$WORKSPACE" ]]; then
  if [[ -d "${HOME}/.gawd/workspace" ]]; then
    WORKSPACE="${HOME}/.gawd/workspace"
  elif [[ -d "/home/${RUNTIME_USER}/.gawd/workspace" ]]; then
    WORKSPACE="/home/${RUNTIME_USER}/.gawd/workspace"
  fi
fi

if [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]]; then
  printf '\033[1;31m[verify]\033[0m Workspace not found: %s\n' "${WORKSPACE:-<not resolved>}" >&2
  exit 2
fi

# Resolve expected group from runtime user
RUNTIME_GROUP=""
if id "$RUNTIME_USER" &>/dev/null; then
  RUNTIME_GROUP="$(id -gn "$RUNTIME_USER")"
fi

info_line "Workspace:    ${WORKSPACE}"
info_line "Runtime user: ${RUNTIME_USER}  group: ${RUNTIME_GROUP}"
info_line "Soul user:    ${SOUL_USER}"
info_line ""

# ── portable stat helper ─────────────────────────────────────────────────────────
# Linux: stat -c '%a %U %G'
# macOS: stat -f '%Mp%Lp %Su %Sg'

get_perm_owner_group() {
  local fpath="$1"
  local mode owner group
  if stat --version &>/dev/null 2>&1; then
    # GNU stat (Linux)
    read -r mode owner group < <(stat -c '%a %U %G' "$fpath" 2>/dev/null || echo "000 unknown unknown")
  else
    # BSD stat (macOS)
    # %Mp%Lp = octal mode (4 digits), %Su = owner name, %Sg = group name
    read -r mode owner group < <(stat -f '%Mp%Lp %Su %Sg' "$fpath" 2>/dev/null || echo "0000 unknown unknown")
    # Strip leading 0 from 4-digit BSD octal if needed (e.g., 0644 → 644)
    mode="${mode#0}"
  fi
  echo "$mode $owner $group"
}

# ── verify a single file ─────────────────────────────────────────────────────────

# check_file FILE EXPECTED_MODE EXPECTED_OWNER EXPECTED_GROUP LABEL
check_file() {
  local fpath="$1"
  local exp_mode="$2"
  local exp_owner="$3"
  local exp_group="$4"
  local label="$5"

  if [[ ! -f "$fpath" ]]; then
    warn_line "${label}  file not found — cannot verify permissions (missing file)"
    return
  fi

  local actual
  actual="$(get_perm_owner_group "$fpath")"
  local act_mode act_owner act_group
  read -r act_mode act_owner act_group <<< "$actual"

  local pass=1

  # Normalize modes for comparison: strip any leading zeros
  local norm_exp_mode="${exp_mode#0}"
  local norm_act_mode="${act_mode#0}"
  norm_exp_mode="${norm_exp_mode#0}"
  norm_act_mode="${norm_act_mode#0}"

  if [[ "$norm_act_mode" != "$norm_exp_mode" || "$act_owner" != "$exp_owner" || "$act_group" != "$exp_group" ]]; then
    pass=0
  fi

  if [[ "$pass" -eq 1 ]]; then
    ok_line "${label}  ${act_mode} ${act_owner}:${act_group}"
  else
    fail_line "${label}  expected: ${exp_mode} ${exp_owner}:${exp_group}  actual: ${act_mode} ${act_owner}:${act_group}"
    VIOLATIONS=$(( VIOLATIONS + 1 ))
  fi
}

# ── verify T0 anchors ────────────────────────────────────────────────────────────
#
# Expected: 0444, owned by SOUL_USER, group RUNTIME_GROUP

info_line "── T0 anchors (expected: 0444 ${SOUL_USER}:${RUNTIME_GROUP}) ──"

T0_FILES=("SOUL.md" "IDENTITY.md" "VOICE.md" "AGENTS.md")

for fname in "${T0_FILES[@]}"; do
  check_file "${WORKSPACE}/${fname}" \
    "444" \
    "${SOUL_USER}" \
    "${RUNTIME_GROUP}" \
    "${fname} (T0 anchor)"
done

# ── verify adaptive files ────────────────────────────────────────────────────────
#
# Expected: 0644, owned by RUNTIME_USER, group RUNTIME_GROUP

info_line ""
info_line "── Adaptive layer (expected: 0644 ${RUNTIME_USER}:${RUNTIME_GROUP}) ──"

ADAPTIVE_FILES=("USER.md" "MEMORY.md" "VOICE-ADAPTIVE.md" "tuning.md")

for fname in "${ADAPTIVE_FILES[@]}"; do
  fpath="${WORKSPACE}/${fname}"

  # USER.md absent + users/ present = multi-Prophit, not a violation
  if [[ "$fname" == "USER.md" && ! -f "$fpath" && -d "${WORKSPACE}/users" ]]; then
    ok_line "USER.md (T0 anchor)  absent — multi-Prophit users/ detected (OK)"
    continue
  fi

  check_file "$fpath" \
    "644" \
    "${RUNTIME_USER}" \
    "${RUNTIME_GROUP}" \
    "${fname} (adaptive)"
done

# users/ directory in multi-Prophit case
if [[ -d "${WORKSPACE}/users" ]]; then
  info_line ""
  info_line "── users/ directory (multi-Prophit) ──"
  while IFS= read -r -d '' ufile; do
    check_file "$ufile" "644" "${RUNTIME_USER}" "${RUNTIME_GROUP}" "users/$(basename "$ufile") (adaptive)"
  done < <(find "${WORKSPACE}/users" -maxdepth 1 -type f -print0)
fi

# ── summary ──────────────────────────────────────────────────────────────────────

info_line ""

if [[ "$VIOLATIONS" -gt 0 ]]; then
  printf '\033[1;31m[verify]\033[0m %d violation(s) found. Run gawd-persona-perms.sh to remediate.\n' \
    "$VIOLATIONS" >&2
  printf '\033[1;31m[verify]\033[0m   sudo gawd-persona-perms.sh --workspace %s\n' \
    "$WORKSPACE" >&2
  exit 1
else
  [[ "$QUIET" -eq 0 ]] && printf '\033[1;32m[verify]\033[0m All persona permissions verified OK.\n'
  exit 0
fi
