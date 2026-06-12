#!/usr/bin/env bash
# gawd-persona-perms.sh — Install-time permission enforcer for T0 persona anchors.
#
# PURPOSE
#   Enforces the dual-owner / dual-permission model that makes T0 anchor files
#   (SOUL.md, IDENTITY.md, VOICE.md) architecturally non-writable by the Gawd
#   runtime process.  Per spec §3.1 and persona-file-architecture.md §8:
#
#     T0 anchors  → chmod 0444, owner=gawd-soul (UID 6000), group=gawd
#     Adaptive    → chmod 0644, owner=gawd (runtime user), group=gawd
#
#   The Gawd runtime user (gawd) cannot chmod/chown a file it does not own,
#   so even a compromised SIL writer that attempts chmod 0644 SOUL.md gets EPERM.
#
# USAGE
#   Run as root or via sudo.  Must be run AFTER the workspace is populated.
#
#   gawd-persona-perms.sh [--workspace PATH] [--runtime-user USER] [--dry-run]
#
#   --workspace PATH      path to the Gawd workspace dir   (default: ~/.gawd/workspace)
#   --runtime-user USER   name of the Gawd runtime user    (default: gawd)
#   --soul-uid UID        UID for the non-runtime soul user (default: 6000)
#   --soul-user USER      name for the soul user           (default: gawd-soul)
#   --dry-run             print actions without executing them
#
# IDEMPOTENCY
#   Safe to run twice.  chown/chmod are re-applied on every run (idempotent by design).
#   Missing T0 anchor files → warning, NOT exit.  Missing adaptive files → skip.
#   The gawd-soul user is created if absent; skipped if already present.
#
# EXIT CODES
#   0  all permissions applied / verified OK
#   1  must be run as root (or via sudo)
#   2  specified workspace does not exist
#   3  specified runtime user does not exist
#   4  permission application failed for one or more files (check stderr)
#
# ARCHITECTURE NOTES (per spec §3.1 + persona-file-architecture.md §8)
#   The non-runtime user inside a container MUST exist at image build time.
#   Use a numeric UID (6000) so cross-rung consistency is preserved.
#   For Docker rung deployments, mount options (ro) may replace chown; this script
#   handles the bare-metal / rung-2 case.  See persona-permission-enforcement.md.

set -euo pipefail

# ── helpers ─────────────────────────────────────────────────────────────────────

log()  { printf '\033[1;34m[perms]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[perms]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[perms]\033[0m WARNING: %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[perms]\033[0m ERROR: %s\n'   "$*" >&2; }

DRY_RUN=0
ERRORS=0

do_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ── argument parsing ─────────────────────────────────────────────────────────────

WORKSPACE=""
RUNTIME_USER="gawd"
SOUL_UID="6000"
SOUL_USER="gawd-soul"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift; WORKSPACE="${1:-}"
      ;;
    --runtime-user)
      shift; RUNTIME_USER="${1:-gawd}"
      ;;
    --soul-uid)
      shift; SOUL_UID="${1:-6000}"
      ;;
    --soul-user)
      shift; SOUL_USER="${1:-gawd-soul}"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

# Default workspace: caller's home .gawd/workspace, or /home/<runtime-user>/.gawd/workspace
if [[ -z "$WORKSPACE" ]]; then
  if [[ -d "${HOME}/.gawd/workspace" ]]; then
    WORKSPACE="${HOME}/.gawd/workspace"
  elif [[ -d "/home/${RUNTIME_USER}/.gawd/workspace" ]]; then
    WORKSPACE="/home/${RUNTIME_USER}/.gawd/workspace"
  fi
fi

# ── preflight checks ─────────────────────────────────────────────────────────────

# Must run as root (chown requires it)
if [[ "$(id -u)" -ne 0 ]]; then
  err "This script must be run as root or via sudo."
  err "Re-run: sudo $0 $*"
  exit 1
fi

# Workspace must exist
if [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]]; then
  err "Workspace directory not found: '${WORKSPACE:-<not specified>}'."
  err "Pass --workspace /path/to/.gawd/workspace"
  exit 2
fi

# Runtime user must exist
if ! id "$RUNTIME_USER" &>/dev/null; then
  err "Runtime user '${RUNTIME_USER}' does not exist."
  err "Create it first: useradd --system --no-create-home --shell /usr/sbin/nologin ${RUNTIME_USER}"
  exit 3
fi

RUNTIME_UID="$(id -u "$RUNTIME_USER")"
RUNTIME_GID="$(id -g "$RUNTIME_USER")"
RUNTIME_GROUP="$(id -gn "$RUNTIME_USER")"

log "Workspace:    ${WORKSPACE}"
log "Runtime user: ${RUNTIME_USER} (uid=${RUNTIME_UID} gid=${RUNTIME_GID} group=${RUNTIME_GROUP})"
log "Soul user:    ${SOUL_USER} (uid=${SOUL_UID})"
[[ "$DRY_RUN" -eq 1 ]] && warn "DRY-RUN mode — no changes will be made."

# ── create gawd-soul user if absent ──────────────────────────────────────────────
#
# gawd-soul is a system user with no home, no shell, no login.  Its only purpose
# is to own the T0 anchor files so the Gawd runtime user cannot chmod/chown them.
#
# The uid is pinned to SOUL_UID (default 6000) for cross-rung consistency.

log "Step 1/4 — Ensuring soul user '${SOUL_USER}' (uid=${SOUL_UID}) exists..."

if id "${SOUL_USER}" &>/dev/null; then
  actual_uid="$(id -u "${SOUL_USER}")"
  if [[ "$actual_uid" != "$SOUL_UID" ]]; then
    warn "User '${SOUL_USER}' exists but has uid=${actual_uid}; expected uid=${SOUL_UID}."
    warn "Proceeding — chown will use the existing user.  Rebuild the container image"
    warn "with the correct UID if this is a fresh deploy."
  else
    ok "  User '${SOUL_USER}' already exists (uid=${actual_uid})."
  fi
else
  log "  Creating system user '${SOUL_USER}' with uid=${SOUL_UID}..."
  do_cmd useradd \
    --system \
    --uid "${SOUL_UID}" \
    --no-create-home \
    --shell /usr/sbin/nologin \
    --comment "Gawd T0-anchor guardian — no login, owns soul files only" \
    "${SOUL_USER}"
  ok "  Created '${SOUL_USER}'."
fi

# ── T0 anchor enforcement: chown + chmod 0444 ────────────────────────────────────
#
# Files: SOUL.md, IDENTITY.md, VOICE.md, AGENTS.md (constitutional rules)
# Owner: gawd-soul (or root — SOUL_USER)
# Group: gawd (runtime group, so the Gawd process can READ them)
# Mode:  0444 (read-only for everyone; no write bit set anywhere)
#
# Why 0444 not 0440: the Gawd process (gawd user) can read via "other" r bit.
# The owner (gawd-soul) has no write bit set, which means even the soul user
# cannot silently overwrite — the setuid gawd-soul-apply helper is the only write path.

T0_FILES=(
  "SOUL.md"
  "IDENTITY.md"
  "VOICE.md"
  "AGENTS.md"
)

log "Step 2/4 — Enforcing T0 anchor permissions (chmod 0444, owner=${SOUL_USER}:${RUNTIME_GROUP})..."

for fname in "${T0_FILES[@]}"; do
  fpath="${WORKSPACE}/${fname}"
  if [[ ! -f "$fpath" ]]; then
    warn "  T0 anchor missing: ${fpath} — SKIPPING (install the template file first)."
    warn "  Deploy from: /usr/local/lib/gawd/persona-templates/${fname}"
    continue
  fi

  log "  ${fname}"
  if ! do_cmd chown "${SOUL_USER}:${RUNTIME_GROUP}" "$fpath"; then
    err "  chown failed for ${fpath}"
    ERRORS=$(( ERRORS + 1 ))
    continue
  fi
  if ! do_cmd chmod 0444 "$fpath"; then
    err "  chmod failed for ${fpath}"
    ERRORS=$(( ERRORS + 1 ))
    continue
  fi
  ok "  ${fname} → 0444 ${SOUL_USER}:${RUNTIME_GROUP}"
done

# ── Adaptive layer enforcement: chown + chmod 0644 ───────────────────────────────
#
# Files: USER.md, MEMORY.md, VOICE-ADAPTIVE.md, tuning.md
# Special: users/ directory (multi-Prophit case — each file inside gets 0644)
# Owner: gawd (runtime user)
# Mode:  0644 (owner rw, group+other r)

ADAPTIVE_FILES=(
  "USER.md"
  "MEMORY.md"
  "VOICE-ADAPTIVE.md"
  "tuning.md"
)

log "Step 3/4 — Enforcing adaptive layer permissions (chmod 0644, owner=${RUNTIME_USER}:${RUNTIME_GROUP})..."

for fname in "${ADAPTIVE_FILES[@]}"; do
  fpath="${WORKSPACE}/${fname}"

  # USER.md may be absent in the multi-Prophit case (replaced by users/)
  if [[ "$fname" == "USER.md" && ! -f "$fpath" && -d "${WORKSPACE}/users" ]]; then
    log "  USER.md absent — multi-Prophit case; handling users/ directory instead."
    continue
  fi

  if [[ ! -f "$fpath" ]]; then
    # Non-fatal: adaptive files may not be seeded yet at install time.
    warn "  Adaptive file missing: ${fpath} — SKIPPING."
    continue
  fi

  if ! do_cmd chown "${RUNTIME_USER}:${RUNTIME_GROUP}" "$fpath"; then
    err "  chown failed for ${fpath}"
    ERRORS=$(( ERRORS + 1 ))
    continue
  fi
  if ! do_cmd chmod 0644 "$fpath"; then
    err "  chmod failed for ${fpath}"
    ERRORS=$(( ERRORS + 1 ))
    continue
  fi
  ok "  ${fname} → 0644 ${RUNTIME_USER}:${RUNTIME_GROUP}"
done

# Multi-Prophit users/ directory: chown + chmod each file inside
if [[ -d "${WORKSPACE}/users" ]]; then
  log "  Handling users/ directory (multi-Prophit case)..."
  do_cmd chown "${RUNTIME_USER}:${RUNTIME_GROUP}" "${WORKSPACE}/users"
  do_cmd chmod 0755 "${WORKSPACE}/users"
  while IFS= read -r -d '' ufile; do
    if ! do_cmd chown "${RUNTIME_USER}:${RUNTIME_GROUP}" "$ufile"; then
      err "  chown failed for ${ufile}"
      ERRORS=$(( ERRORS + 1 ))
      continue
    fi
    if ! do_cmd chmod 0644 "$ufile"; then
      err "  chmod failed for ${ufile}"
      ERRORS=$(( ERRORS + 1 ))
    fi
    ok "  users/$(basename "${ufile}") → 0644 ${RUNTIME_USER}:${RUNTIME_GROUP}"
  done < <(find "${WORKSPACE}/users" -maxdepth 1 -type f -print0)
fi

# Daily notes directory
if [[ -d "${WORKSPACE}/memory" ]]; then
  log "  memory/ directory — chown runtime user..."
  do_cmd chown "${RUNTIME_USER}:${RUNTIME_GROUP}" "${WORKSPACE}/memory"
  do_cmd chmod 0755 "${WORKSPACE}/memory"
  while IFS= read -r -d '' mfile; do
    do_cmd chown "${RUNTIME_USER}:${RUNTIME_GROUP}" "$mfile"
    do_cmd chmod 0644 "$mfile"
  done < <(find "${WORKSPACE}/memory" -type f -print0)
  ok "  memory/ → 0755 + daily files 0644 ${RUNTIME_USER}:${RUNTIME_GROUP}"
fi

# SIL pending proposals directory (runtime-owned; SIL writes here)
if [[ -d "${WORKSPACE}/sil" ]]; then
  log "  sil/ directory — chown runtime user..."
  do_cmd chown -R "${RUNTIME_USER}:${RUNTIME_GROUP}" "${WORKSPACE}/sil"
  do_cmd find "${WORKSPACE}/sil" -type d -exec chmod 0755 {} \;
  do_cmd find "${WORKSPACE}/sil" -type f -exec chmod 0644 {} \;
  ok "  sil/ → 0755 dirs, 0644 files, ${RUNTIME_USER}:${RUNTIME_GROUP}"
fi

# ── final report ─────────────────────────────────────────────────────────────────

log "Step 4/4 — Verification summary..."

report_file() {
  local fpath="$1"
  local label="$2"
  if [[ -f "$fpath" ]]; then
    stat_line="$(stat -c '%a %U:%G' "$fpath" 2>/dev/null || stat -f '%Mp%Lp %Su:%Sg' "$fpath" 2>/dev/null || echo 'stat-unavailable')"
    printf '  %-30s  %s\n' "$label" "$stat_line"
  else
    printf '  %-30s  MISSING\n' "$label"
  fi
}

echo ""
printf '  %-30s  %s\n' "FILE" "MODE  OWNER:GROUP"
printf '  %s\n' "-----------------------------------------------------------"
for fname in "${T0_FILES[@]}"; do
  report_file "${WORKSPACE}/${fname}" "${fname} (T0)"
done
for fname in "${ADAPTIVE_FILES[@]}"; do
  report_file "${WORKSPACE}/${fname}" "${fname} (adaptive)"
done
echo ""

if [[ "$ERRORS" -gt 0 ]]; then
  err "Completed with ${ERRORS} error(s).  Review stderr above."
  exit 4
else
  ok "All permissions applied successfully."
  [[ "$DRY_RUN" -eq 1 ]] && ok "(Dry-run: no actual changes made.)"
  exit 0
fi
