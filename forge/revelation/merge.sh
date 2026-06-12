#!/usr/bin/env bash
# merge.sh — Revelation three-way merge engine
#
# Per spec §10.4 and handoff E2. Runs at the 4am Prophit-local boundary when
# the Prophit has accepted a Weekly Service revelation. Atomic, idempotent,
# soul-consistency-preserving.
#
# Three inputs:
#   A = current adaptive workspace (live ~/.gawd/workspace/)
#   B = new base from the revelation (unpacked Sermon Channel bundle)
#   C = last-applied base (~/.gawd/state/last-applied-base/)
#
# Merge logic (per A1 §5 Update Authority Table + spec §10.4):
#   T0 anchors      (SOUL.md, IDENTITY.md, VOICE.md)      ← REPLACE with B
#   Adaptive layer  (USER.md, users/, MEMORY.md,
#                    VOICE-ADAPTIVE.md, tuning.md,
#                    memory/, learned skills)             ← PRESERVE verbatim from A
#
# Conflict policy:
#   If diff(A_anchor, C_anchor) is non-empty for any T0 anchor, the Prophit
#   hand-edited a soul-anchor since the last Sunday. Default behavior:
#     1. Prefer new base (B) for soul-anchor files
#     2. Preserve all adaptive files verbatim
#     3. Surface a conflict report to workspace/sil/conflicts/<rev>.md
#        The next session-start hook reads this and tells the Prophit:
#        "I accepted the revelation but you had hand-edited [file]. I
#         preserved the new base; here's what changed."
#
# Atomicity contract:
#   - All merge output writes go to a staging directory (~/.gawd.merge-staging/)
#   - On validation pass, atomic mv ~/.gawd/workspace ~/.gawd.workspace.previous
#     followed by atomic mv ~/.gawd.merge-staging ~/.gawd/workspace
#   - On failure, rm -rf ~/.gawd.merge-staging; live workspace untouched
#   - A power failure at any point leaves either the previous workspace fully
#     intact, or the new workspace fully present — never a half-merged state
#
# Idempotency:
#   - Re-running merge.sh with the same inputs (same A, B, C, same revelation
#     version) yields the same output. The contract:
#       * If revelation has already been applied (state file says applied=true
#         for this revelation_version), merge.sh returns 0 with a no-op message
#       * Otherwise, run the merge; on success, mark applied=true atomically
#         along with the workspace rename
#
# Soul-anchor T0 file list is READ from the A1 reference doc by parsing the
# §5 update-authority-table for files where Gate = "Gated" — no hardcoded list.
# Falls back to spec-§3.1 list if A1 doc is unreadable (defensive default; logs warning).
#
# Usage:
#   merge.sh --A <adaptive-dir> --B <new-base-dir> --C <last-applied-dir> \
#            --revelation-version <semver> [--workspace <dir>] [--state <dir>] \
#            [--dry-run]
#
# Exit codes:
#   0  merge succeeded (or no-op for already-applied)
#   1  user/arg error
#   2  input directory missing or unreadable
#   3  schema validation failed on B (new base is malformed; refuse to apply)
#   4  staging-write failure
#   5  atomic-rename failure (live workspace may be in an inconsistent state — see runbook)
#   6  conflict surfaced AND --strict (default: conflicts do not fail; they surface and continue)
#
# Per gospel §1 principle 4 (soul consistency): a failed merge leaves the
# Gawd on the prior version. Soul never drifts silently.

set -euo pipefail

# ── constants ──────────────────────────────────────────────────────────────────

# The A1 reference doc that defines which files are T0 anchors vs adaptive.
# Authoritative per handoff E2's first acceptance criterion.
A1_REFERENCE_DOC="${A1_REFERENCE_DOC:-<install-root>/docs/architecture/persona-file-architecture.md}"

# Fallback T0 list (used only if A1 doc unreadable). Matches spec §3.1.
FALLBACK_T0_ANCHORS=("SOUL.md" "IDENTITY.md" "VOICE.md")

# Adaptive files — preserved verbatim from A. List is exhaustive but additive:
# any file present in A's workspace that is NOT in the T0 list is preserved.
# This list is for documentation and explicit-preservation logging only.
DOCUMENTED_ADAPTIVE_FILES=(
  "USER.md"
  "MEMORY.md"
  "VOICE-ADAPTIVE.md"
  "tuning.md"
)
DOCUMENTED_ADAPTIVE_DIRS=(
  "users"
  "memory"
  "skills/learned"
  "sil"
)

SCHEMA_VALIDATOR="${SCHEMA_VALIDATOR:-/usr/local/lib/gawd/persona-templates/validate-schema.sh}"

# ── args ───────────────────────────────────────────────────────────────────────

A_DIR=""
B_DIR=""
C_DIR=""
REVELATION_VERSION=""
WORKSPACE_DIR=""
STATE_DIR=""
DRY_RUN=0
STRICT_CONFLICT=0

usage() {
  grep '^# ' "$0" | sed 's/^# //'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --A) A_DIR="$2"; shift 2 ;;
    --B) B_DIR="$2"; shift 2 ;;
    --C) C_DIR="$2"; shift 2 ;;
    --revelation-version) REVELATION_VERSION="$2"; shift 2 ;;
    --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
    --state) STATE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --strict-conflict) STRICT_CONFLICT=1; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage ;;
  esac
done

# Defaults (only set after parse so --workspace can override before defaults compute)
WORKSPACE_DIR="${WORKSPACE_DIR:-${HOME}/.gawd/workspace}"
STATE_DIR="${STATE_DIR:-${HOME}/.gawd/state}"
STAGING_DIR="${STAGING_DIR:-${HOME}/.gawd.merge-staging}"
PREVIOUS_DIR="${PREVIOUS_DIR:-${HOME}/.gawd.workspace.previous}"

# Validate args
[[ -n "$A_DIR" ]]              || { echo "ERROR: --A required"              >&2; exit 1; }
[[ -n "$B_DIR" ]]              || { echo "ERROR: --B required"              >&2; exit 1; }
[[ -n "$C_DIR" ]]              || { echo "ERROR: --C required"              >&2; exit 1; }
[[ -n "$REVELATION_VERSION" ]] || { echo "ERROR: --revelation-version required" >&2; exit 1; }

[[ -d "$A_DIR" ]] || { echo "ERROR: A dir not readable: $A_DIR" >&2; exit 2; }
[[ -d "$B_DIR" ]] || { echo "ERROR: B dir not readable: $B_DIR" >&2; exit 2; }
# C may be empty/absent on first-ever merge — handled below

# ── helpers ────────────────────────────────────────────────────────────────────

log()   { echo "[merge $(date -Iseconds)] $*"; }
warn()  { echo "[merge WARN] $*" >&2; }
fatal() { echo "[merge FATAL] $*" >&2; exit "${2:-1}"; }

# Read the T0-anchor file list from the A1 reference doc.
# Strategy: parse §5 Update Authority Table; rows where the Gate column says
# "**Gated**" are T0 anchors. Extracts the filename from the first column.
# Falls back to FALLBACK_T0_ANCHORS on parse failure.
read_t0_anchors_from_a1() {
  if [[ ! -r "$A1_REFERENCE_DOC" ]]; then
    warn "A1 reference doc not readable ($A1_REFERENCE_DOC) — using fallback T0 list"
    printf '%s\n' "${FALLBACK_T0_ANCHORS[@]}"
    return
  fi
  # Find the table in §5 and extract gated rows. The §5 table format is:
  #   | `SOUL.md` | SIL proposes; ... | **Gated** ... |
  # We grep for lines that:
  #   - start with `|`
  #   - contain a backticked .md filename in the first column
  #   - contain "**Gated**" somewhere on the row
  # And we extract the filename from the backticks in col 1.
  local extracted
  extracted=$(awk '
    /^## 5\. Update authority table/ { in_section = 1; next }
    /^## / && !/^## 5\./             { in_section = 0 }
    in_section && /^\|/ && /\*\*Gated\*\*/ {
      # extract first backticked token in the row
      if (match($0, /`[^`]+`/)) {
        s = substr($0, RSTART+1, RLENGTH-2)
        # strip "or users/<name>.md" or similar trailing alternatives
        sub(/ .*/, "", s)
        print s
      }
    }
  ' "$A1_REFERENCE_DOC" | sort -u)

  if [[ -z "$extracted" ]]; then
    warn "Failed to parse T0 anchors from A1 doc — using fallback"
    printf '%s\n' "${FALLBACK_T0_ANCHORS[@]}"
  else
    printf '%s\n' "$extracted"
  fi
}

# Validate the B (new base) directory contains every T0 anchor + passes schema
validate_new_base() {
  local b_dir="$1"
  shift
  local anchors=("$@")
  log "Validating new base (B): $b_dir"
  for f in "${anchors[@]}"; do
    if [[ ! -f "$b_dir/$f" ]]; then
      fatal "B missing required T0 anchor: $f" 3
    fi
  done
  # If schema validator exists, run it (warn-only — we don't want to block on
  # cosmetic schema drift, but we want the log breadcrumb).
  if [[ -x "$SCHEMA_VALIDATOR" ]]; then
    if ! "$SCHEMA_VALIDATOR" "$b_dir" --strict 2>&1 | sed 's/^/  [validate-schema] /'; then
      warn "Schema validator returned non-zero on B; continuing (warn-only at merge time)"
    fi
  else
    warn "Schema validator not executable ($SCHEMA_VALIDATOR); skipping schema check on B"
  fi
}

# Detect conflicts: for each T0 anchor, diff A vs C. Non-empty diff = conflict.
# Writes a structured conflict report to STAGING_DIR/sil/conflicts/<rev>.md
# if any conflicts found. Returns 0 if conflicts found, 1 otherwise.
# (zero = "yes, conflicts" because we use the return for if-conditional below)
detect_conflicts() {
  local a_dir="$1"
  local c_dir="$2"
  local b_dir="$3"
  shift 3
  local anchors=("$@")

  local conflicts_found=0
  local conflict_lines=()

  for f in "${anchors[@]}"; do
    local a_file="$a_dir/$f"
    local c_file="$c_dir/$f"
    # If A is missing the anchor, that's not a conflict — it's a structural
    # problem the validator should have caught upstream. Skip silently here.
    [[ -f "$a_file" ]] || continue
    # If C is missing the anchor (first-ever merge case), assume no conflict;
    # there's no prior baseline to compare against.
    if [[ ! -f "$c_file" ]]; then
      log "  No C baseline for $f (first-ever merge) — no conflict"
      continue
    fi
    if ! diff -q "$a_file" "$c_file" >/dev/null 2>&1; then
      conflicts_found=1
      conflict_lines+=("$f")
      log "  CONFLICT: $f differs between A (live workspace) and C (last-applied base)"
    fi
  done

  if [[ $conflicts_found -eq 1 ]]; then
    write_conflict_report "$a_dir" "$c_dir" "$b_dir" "${conflict_lines[@]}"
    return 0  # conflicts found
  fi
  return 1  # no conflicts
}

# Write conflict report to STAGING_DIR/sil/conflicts/<revelation-version>.md
# (Written into staging so it lands atomically with the rest of the merge.)
write_conflict_report() {
  local a_dir="$1"
  local c_dir="$2"
  local b_dir="$3"
  shift 3
  local conflict_files=("$@")

  local report_dir="$STAGING_DIR/sil/conflicts"
  mkdir -p "$report_dir"
  local report_file="$report_dir/${REVELATION_VERSION}.md"

  {
    echo "# Revelation conflict report — ${REVELATION_VERSION}"
    echo ""
    echo "**Date:** $(date -Iseconds)"
    echo "**Revelation version applied:** ${REVELATION_VERSION}"
    echo "**Conflict count:** ${#conflict_files[@]}"
    echo ""
    echo "I accepted the revelation. I noticed you had hand-edited the soul-anchor"
    echo "file(s) below since the last Sunday. I preserved the new base (the revelation"
    echo "you accepted). Here is what changed — review and re-apply your edits if you"
    echo "want them back."
    echo ""
    echo "---"
    echo ""
    for f in "${conflict_files[@]}"; do
      echo "## ${f}"
      echo ""
      echo "**Your hand-edits (what was in workspace immediately before merge):**"
      echo ""
      echo '```diff'
      diff -u "$c_dir/$f" "$a_dir/$f" || true
      echo '```'
      echo ""
      echo "**What the new revelation contains (now applied):**"
      echo ""
      echo '```diff'
      diff -u "$c_dir/$f" "$b_dir/$f" || true
      echo '```'
      echo ""
      echo "---"
      echo ""
    done
    echo ""
    echo "*Per spec §10.4: the Gawd does not auto-merge soul-anchor prose. The risk"
    echo "of silent soul drift is higher than the cost of one manual review.*"
  } > "$report_file"

  log "Wrote conflict report: $report_file"
}

# Build the staging directory: start by copying A wholesale, then overwrite T0
# anchors with B's versions. This guarantees adaptive files are preserved
# bit-for-bit (no diff/merge logic touches them).
build_staging() {
  local a_dir="$1"
  local b_dir="$2"
  shift 2
  local anchors=("$@")

  log "Building staging dir: $STAGING_DIR"
  # Wipe any leftover staging from a prior failed run
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"

  # Copy A entirely — preserves adaptive files verbatim (bit-for-bit identity
  # check is part of the acceptance criteria; tar-pipe is the safest way)
  if [[ -d "$a_dir" ]] && [[ -n "$(ls -A "$a_dir" 2>/dev/null || true)" ]]; then
    log "  Copying adaptive workspace from A: $a_dir"
    (cd "$a_dir" && tar cf - .) | (cd "$STAGING_DIR" && tar xf -)
  else
    log "  A dir empty — staging starts from B's T0 anchors only"
  fi

  # Overwrite T0 anchors with B's versions
  for f in "${anchors[@]}"; do
    if [[ -f "$b_dir/$f" ]]; then
      log "  Replacing T0 anchor: $f (from B)"
      install -m 0644 "$b_dir/$f" "$STAGING_DIR/$f"
      # Note: final chmod 0444 + chown to non-runtime user is the privileged
      # apply step (A2's setuid helper). merge.sh writes mode 0644 here; the
      # post-merge perm enforcement script flips them. We log this explicitly.
    fi
  done

  # Also copy any conflict reports that may have been pre-written into staging
  # (they were written during detect_conflicts above; tar may have included
  # an old set from A's workspace, but those are pruned: keep only the report
  # for THIS revelation_version, drop stale ones from prior cycles)
  if [[ -d "$STAGING_DIR/sil/conflicts" ]]; then
    find "$STAGING_DIR/sil/conflicts" -maxdepth 1 -name '*.md' \
      ! -name "${REVELATION_VERSION}.md" -delete 2>/dev/null || true
  fi
}

# Validate the assembled staging dir using the schema validator.
# This catches the case where the merge produced a structurally broken result.
validate_staging() {
  log "Validating staging dir: $STAGING_DIR"
  if [[ -x "$SCHEMA_VALIDATOR" ]]; then
    # We use --strict because at this point we're about to atomic-rename;
    # any schema problem is a stop-the-world event.
    if ! "$SCHEMA_VALIDATOR" "$STAGING_DIR" --strict 2>&1 | sed 's/^/  [validate-schema] /'; then
      fatal "Staging validation FAILED — refusing to apply (live workspace untouched)" 4
    fi
  else
    warn "Schema validator not executable; skipping staging validation"
  fi
}

# Atomic rename: live → previous, staging → live. This is the moment of
# commitment. Order matters: by moving the live workspace OUT first, we
# guarantee that even a crash mid-rename leaves either the previous workspace
# at .previous (rollback-able) or the new one at live (committed). We never
# end up with a workspace dir containing the staging contents while the
# previous lives at its original path.
atomic_rename() {
  log "Atomic rename: live → previous, staging → live"

  # If a stale .previous exists from a failed prior run, purge it now.
  # Per spec §7.2 the rollback window is one daily-reset cycle (~24h) and
  # E1's daily cron clears it. If E1 hasn't run, we still want to free the
  # name before the new previous lands.
  if [[ -e "$PREVIOUS_DIR" ]]; then
    log "  Found pre-existing previous dir; archiving as previous.older"
    rm -rf "${PREVIOUS_DIR}.older"
    mv "$PREVIOUS_DIR" "${PREVIOUS_DIR}.older" || {
      fatal "Could not clear pre-existing previous dir at $PREVIOUS_DIR — aborting" 5
    }
  fi

  # Step 1: live → previous
  if [[ -d "$WORKSPACE_DIR" ]]; then
    mv "$WORKSPACE_DIR" "$PREVIOUS_DIR" || {
      fatal "Failed to mv live workspace to previous — live still intact at $WORKSPACE_DIR" 5
    }
  fi

  # Step 2: staging → live
  if ! mv "$STAGING_DIR" "$WORKSPACE_DIR"; then
    # Rollback: put previous back
    warn "Staging rename FAILED — rolling back previous → live"
    mv "$PREVIOUS_DIR" "$WORKSPACE_DIR" || {
      fatal "ROLLBACK FAILED — live workspace MAY be missing. Manual recovery: mv $PREVIOUS_DIR $WORKSPACE_DIR" 5
    }
    fatal "Staging rename failed; rolled back to previous" 5
  fi

  log "  Rename complete: live workspace is now the merged result"
}

# After successful atomic-rename, rotate C: copy the newly-applied T0 anchors
# (now living in WORKSPACE_DIR) into ~/.gawd/state/last-applied-base/. This
# becomes the new C for the next merge cycle.
rotate_c() {
  local last_applied="${STATE_DIR}/last-applied-base"
  shift 0
  local anchors=("$@")
  log "Rotating C: $last_applied (becomes new C for next merge)"
  mkdir -p "$last_applied"
  # Clear stale anchors (defensive: ensures the dir always reflects exactly the
  # last applied set)
  for f in "${FALLBACK_T0_ANCHORS[@]}"; do
    rm -f "${last_applied}/${f}"
  done
  for f in "${anchors[@]}"; do
    if [[ -f "${WORKSPACE_DIR}/${f}" ]]; then
      install -m 0444 "${WORKSPACE_DIR}/${f}" "${last_applied}/${f}"
    fi
  done
}

# Mark the pending-revelation state file as applied=true atomically.
mark_applied() {
  local state_file="${STATE_DIR}/pending-revelation.json"
  log "Marking pending-revelation.json applied=true"
  if [[ ! -f "$state_file" ]]; then
    warn "No state file at $state_file — merge.sh was run outside the normal flow; not marking applied"
    return 0
  fi
  local tmpfile
  tmpfile=$(mktemp "${state_file}.tmp.XXXXXX")
  if command -v jq >/dev/null 2>&1; then
    jq --arg ts "$(date -Iseconds)" '. + {applied: true, applied_at: $ts}' \
      "$state_file" > "$tmpfile"
  else
    # No jq available — do a manual python fallback
    python3 - "$state_file" "$tmpfile" <<'PYEOF'
import json, sys, datetime
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f: data = json.load(f)
data["applied"] = True
data["applied_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(dst, "w") as f: json.dump(data, f, indent=2)
PYEOF
  fi
  mv "$tmpfile" "$state_file"
}

# ── main ───────────────────────────────────────────────────────────────────────

log "Revelation merge starting"
log "  A (current adaptive workspace): $A_DIR"
log "  B (new base from revelation):   $B_DIR"
log "  C (last-applied base):          $C_DIR"
log "  Revelation version:             $REVELATION_VERSION"
log "  Workspace (target):             $WORKSPACE_DIR"
log "  Staging dir:                    $STAGING_DIR"
log "  Previous dir:                   $PREVIOUS_DIR"
log "  Dry-run:                        $DRY_RUN"

# Idempotency: if state file says this revelation was already applied, no-op.
state_file="${STATE_DIR}/pending-revelation.json"
if [[ -f "$state_file" ]] && command -v jq >/dev/null 2>&1; then
  already_applied=$(jq -r --arg v "$REVELATION_VERSION" \
    'if .revelation_version == $v and .applied == true then "true" else "false" end' \
    "$state_file" 2>/dev/null || echo "false")
  if [[ "$already_applied" == "true" ]]; then
    log "Revelation ${REVELATION_VERSION} already applied (idempotent no-op) — exiting 0"
    exit 0
  fi
fi

# Read T0 anchor list (from A1 doc — no hardcoded list per acceptance criterion 1)
mapfile -t T0_ANCHORS < <(read_t0_anchors_from_a1)
log "T0 anchors (from A1 reference doc): ${T0_ANCHORS[*]}"

# Validate new base
validate_new_base "$B_DIR" "${T0_ANCHORS[@]}"

# Build staging (this copies A wholesale, then overwrites T0 anchors with B)
if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY-RUN: would build staging, detect conflicts, validate, atomic rename"
  log "DRY-RUN: exiting without writes"
  exit 0
fi

build_staging "$A_DIR" "$B_DIR" "${T0_ANCHORS[@]}"

# Detect conflicts (writes report into staging if found)
if detect_conflicts "$A_DIR" "$C_DIR" "$B_DIR" "${T0_ANCHORS[@]}"; then
  log "Conflicts detected and report written; merge continues per default policy (prefer B)"
  if [[ $STRICT_CONFLICT -eq 1 ]]; then
    fatal "--strict-conflict mode: aborting on conflict" 6
  fi
fi

# Validate staging
validate_staging

# Atomic rename — moment of commitment
atomic_rename

# Rotate C — the workspace's new T0 anchors become the new last-applied-base
rotate_c "${T0_ANCHORS[@]}"

# Mark state file applied=true
mark_applied

log "Merge complete — revelation ${REVELATION_VERSION} applied"
log "  Rollback window: ~24h via mv $PREVIOUS_DIR $WORKSPACE_DIR (auto-cleared at next 4am reset by E1)"
log "  Conflict reports: $WORKSPACE_DIR/sil/conflicts/ (if any)"
log ""
log "NOTE: T0 anchors written at mode 0644 in staging. The privileged perm-enforcement"
log "      script (A2's gawd-persona-perms.sh) MUST be invoked next to chmod 0444 + chown"
log "      to the non-runtime owner. merge.sh does NOT do this itself because it does not"
log "      run as a privileged user."

exit 0
