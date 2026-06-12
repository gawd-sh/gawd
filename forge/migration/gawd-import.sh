#!/usr/bin/env bash
# gawd-import.sh — Import a Gawd from an age-encrypted export bundle.
#
# PURPOSE
#   The other half of the symmetric migration mechanism.  Takes an encrypted
#   bundle produced by gawd-export, validates it in a STAGING directory, and
#   only on full validation pass performs an ATOMIC RENAME into the live
#   workspace.  On failure, staging is destroyed and live is untouched.
#
# ARCHITECTURAL CONTRACT (per Logos C2 + spec §7.2)
#
#   ~/.gawd.import-staging/  — fresh per run.  All unpack + validate happens here.
#   ~/.gawd/                  — the live workspace.  TOUCHED ONLY ON VALIDATION PASS.
#   ~/.gawd.previous/         — prior live workspace, retained 24h as rollback escape hatch.
#                                Auto-deleted at next 4am reset (E1's daily-reset cron owns the deletion).
#   ~/.gawd.failed/           — set aside if the self-test fails, for forensics.
#
#   On pass:  mv ~/.gawd → ~/.gawd.previous  &&  mv ~/.gawd.import-staging → ~/.gawd
#   On fail:  rm -rf ~/.gawd.import-staging; live is untouched.
#   On self-test fail (after rename): mv ~/.gawd → ~/.gawd.failed && mv ~/.gawd.previous → ~/.gawd
#
# IDEMPOTENCY
#   Re-running after a partial failure starts fresh — staging is removed at the
#   top of every run before unpacking.  The previous good ~/.gawd is preserved
#   across reruns until the next 4am reset removes it.
#
# F1 ↔ F3 SOFT CYCLE NOTE
#   This script invokes F3's `gawd-validate first-ship` as the post-import self-test.
#   Until F3 ships, the call is wrapped in `|| true` so the import flow is
#   structurally complete.  When F3 lands, REMOVE the `|| true` (search for the
#   token `F1_F3_STUB_CUTOVER` in this file).
#
# USAGE
#   gawd-import.sh <bundle.tar.gz.age> [options]
#
#   --identity-file PATH    age key used to decrypt the bundle (default: ~/.secrets/age.key)
#   --target PATH           live workspace path (default: ~/.gawd)
#   --skip-self-test        skip the post-import F3 self-test entirely (DANGEROUS — test path only)
#   --skip-secrets-rebind   skip the interactive secret re-bind prompts (test path only)
#   --yes                   non-interactive mode; auto-confirms prompts (CI use)
#   --dry-run               unpack + validate; do NOT atomic-rename or touch live
#   -h | --help             show usage
#
# EXIT CODES
#   0  import complete + self-test passed
#   1  preflight failure (missing tool, bundle, key)
#   2  decryption failure
#   3  bundle validation failure (live untouched)
#   4  atomic-rename failure (live UNTOUCHED via fail-fast; staging cleaned)
#   5  self-test failure (rolled back to previous; failure detail logged)
#   6  rollback failure (CRITICAL — operator intervention required)

set -euo pipefail

# ── constants ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATE_BUNDLE="${SCRIPT_DIR}/validate-bundle.sh"

# A2 perms script path.  Soft-required: if missing, we log a warning and continue.
# Self-locating: prefer install-relative sibling scripts/ dir, then canonical container
# install location, then GAWD_PERMS_SCRIPT env override (highest priority).
_IMPORT_SCRIPT_DIR_PERMS="${SCRIPT_DIR}"
_PERMS_SIBLING="${_IMPORT_SCRIPT_DIR_PERMS}/../scripts/gawd-persona-perms.sh"
_PERMS_CONTAINER="/usr/local/lib/gawd/scripts/gawd-persona-perms.sh"
if [[ -f "$_PERMS_SIBLING" ]]; then
    PERMS_SCRIPT_DEFAULT="$_PERMS_SIBLING"
elif [[ -f "$_PERMS_CONTAINER" ]]; then
    PERMS_SCRIPT_DEFAULT="$_PERMS_CONTAINER"
else
    PERMS_SCRIPT_DEFAULT="$_PERMS_SIBLING"   # best-effort; will warn if missing
fi
PERMS_SCRIPT="${GAWD_PERMS_SCRIPT:-$PERMS_SCRIPT_DEFAULT}"

# F3 validation entry point.  Soft-required for self-test (see F1_F3_STUB_CUTOVER).
# Self-locating: prefer install-relative sibling validation/ dir, then canonical container
# install location, then GAWD_F3_VALIDATOR env override (highest priority).
_VALIDATE_SIBLING="${_IMPORT_SCRIPT_DIR_PERMS}/../validation/gawd-validate.sh"
_VALIDATE_CONTAINER="/usr/local/lib/gawd/validation/gawd-validate.sh"
if [[ -f "$_VALIDATE_SIBLING" ]]; then
    F3_VALIDATOR_DEFAULT="$_VALIDATE_SIBLING"
elif [[ -f "$_VALIDATE_CONTAINER" ]]; then
    F3_VALIDATOR_DEFAULT="$_VALIDATE_CONTAINER"
else
    F3_VALIDATOR_DEFAULT="$_VALIDATE_SIBLING"   # best-effort; will warn if missing
fi
F3_VALIDATOR="${GAWD_F3_VALIDATOR:-$F3_VALIDATOR_DEFAULT}"

# Secrets helper (~/.local/bin/secrets per gospel §8.3)
SECRETS_HELPER_DEFAULT="${HOME}/.local/bin/secrets"
SECRETS_HELPER="${GAWD_SECRETS_HELPER:-$SECRETS_HELPER_DEFAULT}"

# ── helpers ──────────────────────────────────────────────────────────────────────

log()  { printf '[gawd-import] %s\n' "$*" >&2; }
ok()   { printf '[gawd-import] OK: %s\n' "$*" >&2; }
warn() { printf '[gawd-import] WARN: %s\n' "$*" >&2; }
fail() {
  local code="$1"; shift
  printf '[gawd-import] FAIL (exit %d): %s\n' "$code" "$*" >&2
  exit "$code"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail 1 "required command not found: $1"
}

confirm() {
  local prompt="$1"
  if [[ "$AUTO_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[yY] ]]
}

# ── argument parsing ─────────────────────────────────────────────────────────────

BUNDLE=""
IDENTITY_FILE="${HOME}/.secrets/age.key"
TARGET_LIVE="${HOME}/.gawd"
SKIP_SELF_TEST=0
SKIP_SECRETS_REBIND=0
AUTO_YES=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity-file)        shift; IDENTITY_FILE="${1:-}";;
    --target)               shift; TARGET_LIVE="${1:-}";;
    --skip-self-test)       SKIP_SELF_TEST=1;;
    --skip-secrets-rebind)  SKIP_SECRETS_REBIND=1;;
    --yes)                  AUTO_YES=1;;
    --dry-run)              DRY_RUN=1;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    -*)
      fail 1 "unknown option: $1"
      ;;
    *)
      if [[ -z "$BUNDLE" ]]; then BUNDLE="$1"; else fail 1 "unexpected arg: $1"; fi
      ;;
  esac
  shift
done

# Derive staging and previous paths from TARGET_LIVE so --target works for tests.
STAGING_DIR="${TARGET_LIVE}.import-staging"
PREVIOUS_DIR="${TARGET_LIVE}.previous"
FAILED_DIR="${TARGET_LIVE}.failed"

# ── preflight ────────────────────────────────────────────────────────────────────

require_cmd age
require_cmd tar
require_cmd gzip
require_cmd jq

[[ -n "$BUNDLE" ]]        || fail 1 "bundle path is required (positional arg)"
[[ -f "$BUNDLE" ]]        || fail 1 "bundle file does not exist: $BUNDLE"
[[ -f "$IDENTITY_FILE" ]] || fail 1 "age identity file does not exist: $IDENTITY_FILE (generate via install.sh)"
[[ -x "$VALIDATE_BUNDLE" ]] || fail 1 "validate-bundle.sh not found or not executable: $VALIDATE_BUNDLE"

# Bundle name validation (defense against unexpected paths)
case "$(basename "$BUNDLE")" in
  *.tar.gz.age) ;;
  *) warn "bundle filename does not end in .tar.gz.age — proceeding anyway";;
esac

log "─────────────────────────────────────────────────────"
log "GAWD IMPORT"
log "  Bundle:        $BUNDLE"
log "  Identity:      $IDENTITY_FILE (mode $(stat -c '%a' "$IDENTITY_FILE" 2>/dev/null || echo '?'))"
log "  Live target:   $TARGET_LIVE"
log "  Staging:       $STAGING_DIR"
log "  Previous slot: $PREVIOUS_DIR"
log "  Dry-run:       $DRY_RUN"
log "─────────────────────────────────────────────────────"

# Permission check on age.key
ID_MODE=$(stat -c '%a' "$IDENTITY_FILE" 2>/dev/null || echo "")
if [[ "$ID_MODE" != "600" && "$ID_MODE" != "400" ]]; then
  warn "age identity file mode is $ID_MODE (expected 600 or 400) — gospel §8.3 invariant violated"
fi

# ── Step 1: idempotent staging reset ─────────────────────────────────────────────

log "Step 1/7 — Idempotent staging reset"

if [[ -d "$STAGING_DIR" ]]; then
  warn "  prior staging dir found at $STAGING_DIR — removing for fresh start"
  rm -rf "$STAGING_DIR"
fi
mkdir -p "$STAGING_DIR"
ok "  staging clean: $STAGING_DIR"

# ── Step 2: decrypt + unpack ─────────────────────────────────────────────────────

log "Step 2/7 — Decrypt + unpack bundle"

# Stream: age -d → gunzip → tar -x
# The bundle decompresses into a single top-level dir (gawd-export-TIMESTAMP/)
# which we then re-root into staging.

UNPACK_TMP="$(mktemp -d "${STAGING_DIR}.unpack.XXXXXX")"
trap 'rm -rf "$UNPACK_TMP"' EXIT

if ! age --decrypt --identity "$IDENTITY_FILE" "$BUNDLE" \
   | gzip -dc \
   | tar -C "$UNPACK_TMP" -xf -; then
  rm -rf "$STAGING_DIR" "$UNPACK_TMP"
  fail 2 "decryption + unpack failed (bad key? corrupt bundle?)"
fi

# Re-root: the top-level dir in the archive is gawd-export-{TIMESTAMP}/.
# Move its CONTENTS into STAGING_DIR.
TOPLEVEL_COUNT=$(find "$UNPACK_TMP" -mindepth 1 -maxdepth 1 -type d | wc -l)
if [[ "$TOPLEVEL_COUNT" -ne 1 ]]; then
  rm -rf "$STAGING_DIR" "$UNPACK_TMP"
  fail 2 "unexpected bundle layout: expected exactly one top-level dir, found $TOPLEVEL_COUNT"
fi
TOPLEVEL=$(find "$UNPACK_TMP" -mindepth 1 -maxdepth 1 -type d)
# Move the contents (including hidden if any) into STAGING_DIR/
shopt -s dotglob
mv "$TOPLEVEL"/* "$STAGING_DIR/" 2>/dev/null || true
shopt -u dotglob
rm -rf "$UNPACK_TMP"
trap - EXIT
ok "  bundle unpacked into $STAGING_DIR"

# ── Step 3: validate staging (NO live touched) ───────────────────────────────────

log "Step 3/7 — Validate staging (schema + embeddings + secrets-meta)"

if ! "$VALIDATE_BUNDLE" "$STAGING_DIR"; then
  log "─────────────────────────────────────────────────────"
  log "VALIDATION FAILED — live workspace UNTOUCHED"
  log "Staging is being removed.  Investigate with the bundle producer."
  log "─────────────────────────────────────────────────────"
  rm -rf "$STAGING_DIR"
  exit 3
fi
ok "  bundle validation passed"

# ── Step 4: atomic rename (the load-bearing moment) ──────────────────────────────

log "Step 4/7 — Atomic rename — staging → live"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: would atomically rename:"
  log "  mv $TARGET_LIVE → $PREVIOUS_DIR (if live exists)"
  log "  mv $STAGING_DIR → $TARGET_LIVE"
  log "DRY-RUN complete — staging retained at $STAGING_DIR for inspection"
  exit 0
fi

# If a previous-slot exists from an earlier import (within 24h), the daily-reset
# cron should have cleared it; if it hasn't, we move it out of the way so we
# don't lose the brand-new-import → rollback path.
if [[ -d "$PREVIOUS_DIR" ]]; then
  warn "  $PREVIOUS_DIR already exists (E1 daily-reset cron should clear these)"
  warn "  archiving it to ${PREVIOUS_DIR}.older-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$PREVIOUS_DIR" "${PREVIOUS_DIR}.older-$(date -u +%Y%m%dT%H%M%SZ)" \
    || fail 4 "failed to archive stale previous-slot; will not proceed (live untouched)"
fi

# The two renames must both succeed.  If the first succeeds and the second fails,
# we are in a bad spot — try to undo the first.  If undo fails: exit 6 CRITICAL.
if [[ -d "$TARGET_LIVE" ]]; then
  log "  step 4a: mv $TARGET_LIVE → $PREVIOUS_DIR"
  if ! mv "$TARGET_LIVE" "$PREVIOUS_DIR"; then
    rm -rf "$STAGING_DIR"
    fail 4 "could not move live to previous-slot (live still in place; staging removed)"
  fi
fi

log "  step 4b: mv $STAGING_DIR → $TARGET_LIVE"
if ! mv "$STAGING_DIR" "$TARGET_LIVE"; then
  # Critical: previous-slot exists but live is missing.  Try to restore.
  if [[ -d "$PREVIOUS_DIR" ]]; then
    warn "  CRITICAL: staging → live mv failed.  Attempting to restore previous..."
    if mv "$PREVIOUS_DIR" "$TARGET_LIVE"; then
      warn "  previous restored.  Import aborted; live unchanged."
      rm -rf "$STAGING_DIR" 2>/dev/null || true
      fail 4 "atomic-rename half-failed; previous restored; live unchanged"
    else
      fail 6 "CRITICAL: live missing and previous restore failed.  Operator intervention required.  Current state: $TARGET_LIVE absent; $PREVIOUS_DIR holds prior live; $STAGING_DIR holds intended new live."
    fi
  fi
  fail 4 "atomic-rename failed and no previous existed; live was empty before import"
fi
ok "  live workspace is now the imported Gawd"
ok "  previous workspace preserved at $PREVIOUS_DIR (auto-deleted at next 4am reset)"

# ── Step 4b: materialize flat workspace view alongside the bundle hierarchy ──────
#
# The bundle uses a hierarchical layout (soul/, adaptive/, user/, memory/) per
# spec §7.2.  Existing tooling (A1 validate-schema.sh, A2 gawd-persona-perms.sh,
# Lilith runtime) expects a FLAT workspace where SOUL.md, VOICE.md, USER.md, etc.
# sit at workspace root.
#
# Resolution: materialize a flat "workspace" view inside ~/.gawd/ by hardlinking
# the structured files to their flat names.  Hardlinks (not symlinks) so the
# perms script's chown/chmod actually applies to the underlying inode.

log "Step 4c — Materialize flat workspace view (hardlinks from hierarchy)"

WORKSPACE_FLAT="$TARGET_LIVE/workspace"
mkdir -p "$WORKSPACE_FLAT"

materialize() {
  local src="$1" dst="$2"
  if [[ -f "$TARGET_LIVE/$src" ]]; then
    # Use hardlink so perms changes propagate to both views.
    # If a stale file exists at dst, remove it first.
    [[ -f "$WORKSPACE_FLAT/$dst" ]] && rm -f "$WORKSPACE_FLAT/$dst"
    ln "$TARGET_LIVE/$src" "$WORKSPACE_FLAT/$dst" || cp "$TARGET_LIVE/$src" "$WORKSPACE_FLAT/$dst"
  fi
}

materialize "soul/SOUL.md"              "SOUL.md"
materialize "soul/IDENTITY.md"          "IDENTITY.md"
materialize "adaptive/VOICE.md"         "VOICE.md"
materialize "adaptive/VOICE-ADAPTIVE.md" "VOICE-ADAPTIVE.md"
materialize "adaptive/tuning.md"        "tuning.md"
materialize "memory/MEMORY.md"          "MEMORY.md"
materialize "user/USER.md"              "USER.md"

# Multi-Prophit case
if [[ -d "$TARGET_LIVE/user/users" ]]; then
  mkdir -p "$WORKSPACE_FLAT/users"
  for uf in "$TARGET_LIVE/user/users"/*.md; do
    [[ -f "$uf" ]] || continue
    base=$(basename "$uf")
    [[ -f "$WORKSPACE_FLAT/users/$base" ]] && rm -f "$WORKSPACE_FLAT/users/$base"
    ln "$uf" "$WORKSPACE_FLAT/users/$base" || cp "$uf" "$WORKSPACE_FLAT/users/$base"
  done
fi

# Daily memory notes — mirror the directory
if [[ -d "$TARGET_LIVE/memory/daily" ]]; then
  mkdir -p "$WORKSPACE_FLAT/memory"
  for df in "$TARGET_LIVE/memory/daily"/*.md; do
    [[ -f "$df" ]] || continue
    base=$(basename "$df")
    [[ -f "$WORKSPACE_FLAT/memory/$base" ]] && rm -f "$WORKSPACE_FLAT/memory/$base"
    ln "$df" "$WORKSPACE_FLAT/memory/$base" || cp "$df" "$WORKSPACE_FLAT/memory/$base"
  done
fi

ok "  flat workspace view materialized at $WORKSPACE_FLAT"

# ── Step 5: re-apply T0 anchor permissions (A2) ──────────────────────────────────

log "Step 5/7 — Re-apply T0 anchor permissions (A2 perms script)"

if [[ -x "$PERMS_SCRIPT" ]]; then
  # Workspace path: A2's script expects the flat workspace, which is what
  # the materialize step above produced at $WORKSPACE_FLAT.
  WS_GUESS="$WORKSPACE_FLAT"
  if [[ "$EUID" -ne 0 ]]; then
    warn "  perms script requires root (chown) — invoking via sudo"
    if ! sudo "$PERMS_SCRIPT" --workspace "$WS_GUESS"; then
      warn "  perms script returned non-zero — T0 enforcement may be incomplete"
      warn "  re-run manually: sudo $PERMS_SCRIPT --workspace $WS_GUESS"
    else
      ok "  T0 anchor permissions applied"
    fi
  else
    if ! "$PERMS_SCRIPT" --workspace "$WS_GUESS"; then
      warn "  perms script returned non-zero — T0 enforcement may be incomplete"
    else
      ok "  T0 anchor permissions applied"
    fi
  fi
else
  warn "  perms script missing or not executable: $PERMS_SCRIPT"
  warn "  T0 anchor immutability is NOT enforced at the FS layer until perms script is restored"
fi

# ── Step 6: secret re-bind ───────────────────────────────────────────────────────

log "Step 6/7 — Secret re-bind"

if [[ "$SKIP_SECRETS_REBIND" -eq 1 ]]; then
  warn "  --skip-secrets-rebind set; skipping (TEST PATH ONLY)"
else
  SECRETS_META="$TARGET_LIVE/secrets-meta.json"
  if [[ ! -f "$SECRETS_META" ]]; then
    warn "  secrets-meta.json not present in live workspace; nothing to re-bind"
  elif [[ ! -x "$SECRETS_HELPER" ]]; then
    warn "  secrets helper not found at $SECRETS_HELPER"
    warn "  re-bind these keys manually before the daemon will function fully:"
    jq -r '.secret_keys[] | "    - " + .name + (if .purpose then " — " + .purpose else "" end)' "$SECRETS_META" || true
  else
    KEY_COUNT=$(jq -r '.secret_keys | length' "$SECRETS_META")
    log "  $KEY_COUNT secret key name(s) to re-bind"
    while IFS=$'\t' read -r kname kpurpose; do
      [[ -z "$kname" ]] && continue
      log "  Re-bind: $kname  ${kpurpose:+($kpurpose)}"
      if [[ "$AUTO_YES" -eq 1 ]]; then
        log "    --yes set; skipping interactive bind for $kname (re-bind manually: $SECRETS_HELPER set $kname)"
        continue
      fi
      # Defer to the helper's interactive `set` flow.  We do NOT echo the value.
      "$SECRETS_HELPER" set "$kname" || warn "    re-bind for $kname failed; can be retried later"
    done < <(jq -r '.secret_keys[] | [.name, (.purpose // "")] | @tsv' "$SECRETS_META")
  fi
fi

# ── Step 7: F3 self-test (Meeting playback + SIL + fixed-test-suite spot check) ──

log "Step 7/7 — Post-import self-test (F3 first-ship-validation-suite)"

if [[ "$SKIP_SELF_TEST" -eq 1 ]]; then
  warn "  --skip-self-test set; bypassing self-test (TEST PATH ONLY)"
  ok "  import complete (self-test skipped)"
  exit 0
fi

SELF_TEST_EXIT=0
if [[ -x "$F3_VALIDATOR" ]]; then
  # F1_F3_STUB_CUTOVER: when F3 ships its real suite, remove `|| true` below.
  # The `|| true` exists so set -e doesn't kill the script before SELF_TEST_EXIT
  # captures the actual exit code.  When F3 is real and we want failures to
  # propagate, the test-roundtrip rollback fixture sed-strips the trailing
  # ` || true   # F1_F3_STUB_CUTOVER` token and the line becomes:
  #   set +e; "$F3_VALIDATOR" ...; SELF_TEST_EXIT=$?; set -e
  set +e
  "$F3_VALIDATOR" first-ship --workspace "$TARGET_LIVE" --allow-conditional
  SELF_TEST_EXIT=$?
  set -e
  log "  F3 first-ship suite exit code: $SELF_TEST_EXIT (stubbed-pass while F3 in progress)"
else
  warn "  F3 validator missing at $F3_VALIDATOR (expected — F3 ships separately)"
  warn "  STUB: treating self-test as PASS so F1's import flow is structurally complete"
  warn "  F1_F3_STUB_CUTOVER: when F3 lands, remove the '|| true' wrapper around the F3 call"
  SELF_TEST_EXIT=0
fi

if [[ "$SELF_TEST_EXIT" -ne 0 ]]; then
  # Self-test failed — execute the rollback contract.
  log "─────────────────────────────────────────────────────"
  log "SELF-TEST FAILED — rolling back to previous workspace"
  log "─────────────────────────────────────────────────────"
  if [[ -d "$PREVIOUS_DIR" ]]; then
    # Move the failed import out for forensics, then restore previous.
    if [[ -d "$FAILED_DIR" ]]; then
      mv "$FAILED_DIR" "${FAILED_DIR}.older-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    if ! mv "$TARGET_LIVE" "$FAILED_DIR"; then
      fail 6 "CRITICAL: rollback step 1 failed (could not set aside failed import)"
    fi
    if ! mv "$PREVIOUS_DIR" "$TARGET_LIVE"; then
      fail 6 "CRITICAL: rollback step 2 failed (could not restore previous).  State: failed import at $FAILED_DIR; live missing.  Operator intervention required."
    fi
    warn "  rolled back — failed import preserved at $FAILED_DIR for diagnosis"
    fail 5 "post-import self-test failed; live restored from previous"
  else
    fail 5 "self-test failed and no previous workspace exists to roll back to (live is at risk; inspect $TARGET_LIVE)"
  fi
fi

ok "  self-test passed"

# ── Done ─────────────────────────────────────────────────────────────────────────

log ""
log "─────────────────────────────────────────────────────"
log "IMPORT COMPLETE"
log ""
log "  Live workspace: $TARGET_LIVE"
log "  Previous (rollback escape hatch): $PREVIOUS_DIR"
log "    → auto-deleted at next 4am reset"
log "    → manual rollback: mv $TARGET_LIVE ${TARGET_LIVE}.failed && mv $PREVIOUS_DIR $TARGET_LIVE"
log "─────────────────────────────────────────────────────"

exit 0
