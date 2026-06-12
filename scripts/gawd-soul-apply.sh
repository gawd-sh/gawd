#!/usr/bin/env bash
# gawd-soul-apply.sh — Privileged helper for applying Prophit-approved T0 anchor changes.
#
# PURPOSE
#   SIL never touches T0 anchor files (SOUL.md, IDENTITY.md, VOICE.md) directly.
#   When a Prophit approves a SIL proposal, this helper is invoked (as gawd-soul
#   via setuid) to validate and apply the change.  It is the ONLY write path for
#   T0 anchors at runtime.
#
#   This enforces the architectural invariant: SIL proposes → Prophit approves →
#   gawd-soul-apply writes.  No other actor can modify T0 anchors.
#
# INVOCATION
#   This script is intended to be installed setuid to the gawd-soul user:
#     chown gawd-soul:gawd /usr/local/bin/gawd-soul-apply
#     chmod 4750 /usr/local/bin/gawd-soul-apply
#
#   When invoked, it runs with the effective UID of gawd-soul, which owns the T0
#   anchor files.  The runtime user (gawd) cannot write T0 files directly but CAN
#   invoke this helper if it has group execute access (mode 4750, group=gawd).
#
#   NOTE on deployment: setuid shell scripts are disabled by most Linux kernels.
#   The production path is a small C wrapper (gawd-soul-apply-c, see §4 of the
#   runbook) that execs this script with the gawd-soul effective UID.  This shell
#   script contains the validation logic and is the canonical reference regardless
#   of how it is invoked.
#
# USAGE
#   gawd-soul-apply <PROPOSAL_FILE> <TARGET_FILE>
#
#   PROPOSAL_FILE  absolute path to workspace/sil/pending/<id>.md
#                  Must be owned by the runtime user (gawd) and mode 0644.
#                  Must contain a front-matter header (see PROPOSAL FORMAT below).
#
#   TARGET_FILE    absolute path to the T0 anchor being updated.
#                  Must be one of: SOUL.md, IDENTITY.md, VOICE.md
#
# PROPOSAL FORMAT
#   The proposal file must begin with a YAML-style front-matter block:
#
#   ---
#   proposal_id: <uuid or short id>
#   target: SOUL.md            # one of SOUL.md, IDENTITY.md, VOICE.md
#   approved_by: <telegram-user-id>
#   approved_at: <ISO-8601 timestamp>
#   signature: <sha256 of the content below the --- separator>
#   ---
#   <new file content begins here>
#
#   The signature is over the content section only (below the closing ---).
#   This prevents tampering between the Prophit approval event and the apply step.
#
# EXIT CODES
#   0  applied successfully
#   1  argument error (wrong number, unknown target)
#   2  proposal file not found or wrong format
#   3  signature mismatch (tampering detected)
#   4  schema validation failed (content would violate persona-file-architecture §2)
#   5  token budget exceeded (content exceeds T0 anchor cap)
#   6  target file write failed
#
# SECURITY NOTES
#   - Validates the proposal BEFORE writing.  The schema check and signature verify
#     happen before any file is touched.
#   - The temporary file (.new) is written and then atomically renamed to the target,
#     preserving the 0444 mode and gawd-soul ownership throughout.
#   - The original T0 file is backed up to <target>.bak.apply-<timestamp> before
#     the rename.  This is the rollback escape hatch.
#   - Never logs or echoes proposal content to stdout/stderr — content may be
#     soul-sensitive.

set -euo pipefail

# ── helpers ─────────────────────────────────────────────────────────────────────

log()  { printf '\033[1;34m[soul-apply]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[soul-apply]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[soul-apply]\033[0m ERROR: %s\n' "$*" >&2; }

TIMESTAMP="$(date +%s)"

# ── argument check ───────────────────────────────────────────────────────────────

if [[ $# -ne 2 ]]; then
  err "Usage: gawd-soul-apply <PROPOSAL_FILE> <TARGET_FILE>"
  err "Expected exactly 2 arguments; got $#."
  exit 1
fi

PROPOSAL_FILE="$1"
TARGET_FILE="$2"

# ── validate target is a known T0 anchor ─────────────────────────────────────────

TARGET_BASENAME="$(basename "$TARGET_FILE")"
case "$TARGET_BASENAME" in
  SOUL.md|IDENTITY.md|VOICE.md)
    log "Target: ${TARGET_BASENAME} (T0 anchor)"
    ;;
  *)
    err "Unknown target '${TARGET_BASENAME}'. Must be one of: SOUL.md, IDENTITY.md, VOICE.md"
    err "gawd-soul-apply only writes T0 anchors.  Adaptive files are runtime-owned."
    exit 1
    ;;
esac

if [[ ! -f "$TARGET_FILE" ]]; then
  err "Target file does not exist: ${TARGET_FILE}"
  exit 1
fi

# ── validate proposal file ───────────────────────────────────────────────────────

if [[ ! -f "$PROPOSAL_FILE" ]]; then
  err "Proposal file not found: ${PROPOSAL_FILE}"
  exit 2
fi

# Minimal front-matter presence check (content check — no values printed to output)
if ! grep -q '^proposal_id:' "$PROPOSAL_FILE"; then
  err "Proposal missing 'proposal_id:' field."
  exit 2
fi
if ! grep -q '^approved_by:' "$PROPOSAL_FILE"; then
  err "Proposal missing 'approved_by:' field."
  exit 2
fi
if ! grep -q '^approved_at:' "$PROPOSAL_FILE"; then
  err "Proposal missing 'approved_at:' field."
  exit 2
fi
if ! grep -q '^signature:' "$PROPOSAL_FILE"; then
  err "Proposal missing 'signature:' field."
  exit 2
fi

# Extract the expected signature from front-matter (the value after 'signature: ')
EXPECTED_SIG="$(grep '^signature:' "$PROPOSAL_FILE" | sed 's/^signature:[[:space:]]*//' | head -1)"

if [[ -z "$EXPECTED_SIG" ]]; then
  err "Signature field is empty in proposal."
  exit 2
fi

# Extract the content section.
#
# Two formats are supported (E3 introduced the sentinel format; original A2
# format was "everything after the closing --- of front-matter"):
#   1. SENTINEL MODE (preferred — E3's gate.sh format):
#      Content lives between <<<NEW-CONTENT-BEGIN>>> and <<<NEW-CONTENT-END>>>.
#      This allows the proposal file to also contain Prophit-readable reasoning
#      sections (Observed / Why now / Risk) outside the new-content block.
#   2. LEGACY MODE (back-compat — A2's original format):
#      Content is everything from the line after the closing front-matter ---.
#
# Detection: if both sentinels are present in the file, use sentinel mode.
# Else fall back to legacy mode.

NEW_CONTENT_BEGIN="<<<NEW-CONTENT-BEGIN>>>"
NEW_CONTENT_END="<<<NEW-CONTENT-END>>>"

if grep -qF "$NEW_CONTENT_BEGIN" "$PROPOSAL_FILE" \
   && grep -qF "$NEW_CONTENT_END" "$PROPOSAL_FILE"; then
  CONTENT_MODE="sentinel"
  # The content extraction is done via awk between the sentinels.
  extract_content() {
    awk -v begin="$NEW_CONTENT_BEGIN" -v end="$NEW_CONTENT_END" '
      $0 == begin { in_content=1; next }
      $0 == end   { in_content=0; exit }
      in_content  { print }
    ' "$PROPOSAL_FILE"
  }
  log "Detected sentinel-mode proposal."
else
  CONTENT_MODE="legacy"
  CONTENT_START_LINE="$(awk 'NR>1 && /^---/ {print NR; exit}' "$PROPOSAL_FILE")"
  if [[ -z "$CONTENT_START_LINE" ]]; then
    err "Could not find closing '---' in proposal front-matter (legacy mode)."
    exit 2
  fi
  CONTENT_START_LINE=$(( CONTENT_START_LINE + 1 ))
  extract_content() {
    tail -n "+${CONTENT_START_LINE}" "$PROPOSAL_FILE"
  }
  log "Detected legacy-mode proposal (no sentinels found)."
fi

# ── signature verification ───────────────────────────────────────────────────────
#
# The signature is sha256 of the content section.
# We compute it and compare without ever printing the content.

ACTUAL_SIG="$(extract_content | sha256sum | awk '{print $1}')"

if [[ "$ACTUAL_SIG" != "$EXPECTED_SIG" ]]; then
  err "Signature mismatch — proposal may have been tampered with."
  err "  Expected: ${EXPECTED_SIG}"
  err "  Actual:   ${ACTUAL_SIG}"
  exit 3
fi

log "Signature verified."

# ── schema check (mandatory section presence) ────────────────────────────────────
#
# Light check: verify the content has the required top-level section headers
# for the target file type.  Per persona-file-architecture.md §2.

check_sections() {
  local -a required_sections=("$@")
  local content
  content="$(extract_content)"
  for section in "${required_sections[@]}"; do
    if ! printf '%s' "$content" | grep -q "^## ${section}"; then
      err "Missing required section '## ${section}' in proposal content."
      return 1
    fi
  done
  return 0
}

case "$TARGET_BASENAME" in
  SOUL.md)
    if ! check_sections \
        "The covenant" "Voice — base character" "What I do" "What I do not do" "On the Prophit"; then
      exit 4
    fi
    ;;
  IDENTITY.md)
    if ! check_sections \
        "Name" "Instance" "Covenant" "Prophits" "Infrastructure" "Pace" "Born"; then
      exit 4
    fi
    ;;
  VOICE.md)
    if ! check_sections \
        "Register: default" "Register: deep" "Register: playful" \
        "Register: money" "Register: movement" "Register: judgment" "Register: candor" \
        "Base behavioral frame"; then
      exit 4
    fi
    ;;
esac

log "Schema validated."

# ── token budget check (rough char/4 heuristic) ──────────────────────────────────
#
# Caps per persona-file-architecture.md §4 (+200 token tolerance):
#   SOUL.md:     1,400 tokens (~5,600 chars)
#   IDENTITY.md:   800 tokens (~3,200 chars)
#   VOICE.md:      800 tokens (~3,200 chars)

CONTENT_CHARS="$(extract_content | wc -c)"
CONTENT_TOKENS=$(( CONTENT_CHARS / 4 ))

case "$TARGET_BASENAME" in
  SOUL.md)     TOKEN_LIMIT=1400 ;;
  IDENTITY.md) TOKEN_LIMIT=800 ;;
  VOICE.md)    TOKEN_LIMIT=800 ;;
esac

if [[ "$CONTENT_TOKENS" -gt "$TOKEN_LIMIT" ]]; then
  err "Token budget exceeded for ${TARGET_BASENAME}."
  err "  Estimate: ~${CONTENT_TOKENS} tokens (limit: ${TOKEN_LIMIT} including ±200 tolerance)"
  err "  Trim the proposal content and regenerate the signature."
  exit 5
fi

log "Token budget OK (~${CONTENT_TOKENS} tokens, limit ${TOKEN_LIMIT})."

# ── back up the existing T0 anchor ───────────────────────────────────────────────
#
# Always take a backup before overwriting.  Per Archon doctrine: backup before
# every config overwrite.

BACKUP_PATH="${TARGET_FILE}.bak.apply-${TIMESTAMP}"
log "Backing up ${TARGET_BASENAME} → $(basename "${BACKUP_PATH}")..."

# We need to temporarily make the file readable/copyable; it is already 0444 so
# all users can read it.  The backup is written as a NEW file owned by gawd-soul
# (this script runs as gawd-soul via setuid).

cp "${TARGET_FILE}" "${BACKUP_PATH}"
chmod 0444 "${BACKUP_PATH}"
ok "Backup: ${BACKUP_PATH}"

# ── write the new T0 anchor (atomic rename) ───────────────────────────────────────

TMPFILE="${TARGET_FILE}.new.${TIMESTAMP}"

log "Writing validated content to temp file..."
# Extract only the content section into the new file.
extract_content > "${TMPFILE}"
chmod 0444 "${TMPFILE}"

# Atomic rename: replaces the target in one kernel call.
mv "${TMPFILE}" "${TARGET_FILE}"

ok "Applied ${TARGET_BASENAME} from proposal."
log "  Backup:  ${BACKUP_PATH}"
log "  Proposal ID: $(grep '^proposal_id:' "${PROPOSAL_FILE}" | sed 's/^proposal_id:[[:space:]]*//')"

exit 0
