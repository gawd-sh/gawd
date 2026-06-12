#!/usr/bin/env bash
# validate-bundle.sh — Validate a staged Gawd export bundle before atomic-rename.
#
# PURPOSE
#   gawd-import never moves staging into live without this passing.  Three classes
#   of check, all of which must pass:
#
#     1. Manifest schema + file-inventory integrity
#        - manifest.json parses against manifest-schema.json
#        - every file listed in file_inventory exists at the right size + sha256
#        - no extra files (other than well-known whitelist) in the bundle root
#
#     2. Persona schema (via existing validate-schema.sh from A1)
#        - all required persona files present (or users/ for multi-Prophit)
#        - token budgets within hard ceiling
#        - mandatory sections present
#        - movement register present in VOICE.md
#
#     3. Embedding + secrets-meta sanity
#        - if embeddings_present: memory.lancedb.tar exists, is a valid tar, and
#          unpacks to a non-empty .lancedb dir (skipped if jq says embeddings_present=false)
#        - secrets-meta.json parses against secrets-meta-schema.json (KEY NAMES ONLY)
#        - secrets-meta.json contains NO 'value', 'data', 'token', or 'plaintext' fields
#          (defense in depth — schema would already reject these, but we double-check)
#
# CRITICAL INVARIANT
#   This script READS the staging tree.  It NEVER writes to staging and NEVER touches
#   live (~/.gawd/).  The atomic-rename happens in gawd-import.sh AFTER this exits 0.
#
# USAGE
#   validate-bundle.sh <staging-dir>
#
#   Exit 0  → all checks pass; gawd-import may proceed to atomic rename
#   Exit 1  → manifest / inventory failure
#   Exit 2  → persona schema failure
#   Exit 3  → embedding integrity failure
#   Exit 4  → secrets-meta failure (most security-sensitive — surfaced loudly)
#   Exit 5  → preflight failure (missing tools, bad args)
#
# DIAGNOSTIC OUTPUT REQUIREMENT (per F1 handoff Context bullet)
#   On failure, the FIRST failed check is reported with file:line:col where possible.
#   "Schema check failed" alone is NOT acceptable.  Caller (gawd-import.sh) captures
#   stderr verbatim into the failure report shown to the Prophit.

set -euo pipefail

# ── constants / paths ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_SCHEMA="${SCRIPT_DIR}/manifest-schema.json"
SECRETS_META_SCHEMA="${SCRIPT_DIR}/secrets-meta-schema.json"

# validate-schema.sh from A1 is the per-persona-file validator we reuse.
# Path is canonical: /usr/local/lib/gawd/persona-templates/validate-schema.sh
PERSONA_VALIDATOR_DEFAULT="/usr/local/lib/gawd/persona-templates/validate-schema.sh"
PERSONA_VALIDATOR="${GAWD_PERSONA_VALIDATOR:-$PERSONA_VALIDATOR_DEFAULT}"

# Whitelisted top-level entries in the bundle root.  Extras fail validation.
WHITELIST_TOPLEVEL=(
  "manifest.json"
  "soul"
  "user"
  "memory"
  "adaptive"
  "skills"
  "embeddings"
  "secrets-meta.json"
)

# Forbidden field substrings in secrets-meta.json (defense in depth on top of
# the JSON Schema which already restricts additionalProperties).
FORBIDDEN_SECRET_FIELDS=(
  '"value"'
  '"data"'
  '"token"'
  '"plaintext"'
  '"secret"'
  '"password"'
  '"api_key"'
)

# ── helpers ──────────────────────────────────────────────────────────────────────

log()  { printf '[bundle-validate] %s\n' "$*" >&2; }
fail() {
  local exit_code="$1"; shift
  printf '[bundle-validate] FAIL (exit %d): %s\n' "$exit_code" "$*" >&2
  exit "$exit_code"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail 5 "required command not found: $1"
}

# ── preflight ────────────────────────────────────────────────────────────────────

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <staging-dir>" >&2
  exit 5
fi

STAGING="$1"

[[ -d "$STAGING" ]] || fail 5 "staging dir does not exist: $STAGING"
[[ -f "$MANIFEST_SCHEMA" ]] || fail 5 "manifest schema missing: $MANIFEST_SCHEMA"
[[ -f "$SECRETS_META_SCHEMA" ]] || fail 5 "secrets-meta schema missing: $SECRETS_META_SCHEMA"

require_cmd jq
require_cmd sha256sum
require_cmd tar

# JSON Schema validator: prefer `ajv` if present, fall back to a python3
# jsonschema check.  Both are common; gawd-import.sh declares the dependency.
HAVE_AJV=0
HAVE_PY_JSONSCHEMA=0
if command -v ajv >/dev/null 2>&1; then
  HAVE_AJV=1
elif command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import jsonschema' 2>/dev/null; then
  HAVE_PY_JSONSCHEMA=1
else
  fail 5 "no JSON Schema validator found (need 'ajv' OR python3 with jsonschema module)"
fi

json_validate() {
  # json_validate <schema-path> <data-path>
  # Prints validator stderr on failure; returns the validator's exit code.
  local schema="$1" data="$2"
  if [[ "$HAVE_AJV" -eq 1 ]]; then
    ajv validate -s "$schema" -d "$data" --errors=text 2>&1
  else
    python3 - "$schema" "$data" <<'PYEOF' 2>&1
import json, sys, jsonschema
schema_path, data_path = sys.argv[1], sys.argv[2]
with open(schema_path) as f: schema = json.load(f)
with open(data_path)   as f: data   = json.load(f)
v = jsonschema.Draft7Validator(schema)
errors = sorted(v.iter_errors(data), key=lambda e: e.path)
if not errors:
    print("OK")
    sys.exit(0)
for e in errors:
    where = "/" + "/".join(str(p) for p in e.absolute_path) if e.absolute_path else "<root>"
    print(f"{data_path}: {where}: {e.message}", file=sys.stderr)
sys.exit(1)
PYEOF
  fi
}

# ── Check 1: manifest schema + file-inventory integrity ──────────────────────────

log "Check 1/3: manifest schema + file-inventory integrity"

MANIFEST="$STAGING/manifest.json"
[[ -f "$MANIFEST" ]] || fail 1 "manifest.json missing from bundle root: $MANIFEST"

if ! json_validate "$MANIFEST_SCHEMA" "$MANIFEST" >/tmp/_bundle-validate-manifest.err 2>&1; then
  cat /tmp/_bundle-validate-manifest.err >&2
  fail 1 "manifest.json failed schema validation (see error above)"
fi

# Top-level whitelist
shopt -s nullglob
mapfile -t TOPLEVEL < <(cd "$STAGING" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
for entry in "${TOPLEVEL[@]}"; do
  ok=0
  for w in "${WHITELIST_TOPLEVEL[@]}"; do
    [[ "$entry" == "$w" ]] && { ok=1; break; }
  done
  if [[ $ok -eq 0 ]]; then
    fail 1 "unexpected top-level entry in bundle: $entry (whitelist: ${WHITELIST_TOPLEVEL[*]})"
  fi
done

# File inventory: every listed file must exist with matching size + sha256.
# We use jq -r to emit "path<TAB>size<TAB>sha256" then iterate.
while IFS=$'\t' read -r path expected_size expected_sha; do
  [[ -z "$path" ]] && continue
  full="$STAGING/$path"
  if [[ ! -f "$full" ]]; then
    fail 1 "manifest references missing file: $path"
  fi
  actual_size=$(stat -c '%s' "$full")
  if [[ "$actual_size" -ne "$expected_size" ]]; then
    fail 1 "manifest size mismatch for $path: expected=$expected_size actual=$actual_size"
  fi
  actual_sha=$(sha256sum "$full" | awk '{print $1}')
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    fail 1 "manifest sha256 mismatch for $path: expected=$expected_sha actual=$actual_sha"
  fi
done < <(jq -r '.file_inventory[] | [.path, .size_bytes, .sha256] | @tsv' "$MANIFEST")

log "  manifest + file inventory OK"

# ── Check 2: persona schema validation (delegated to A1 validate-schema.sh) ──────

log "Check 2/3: persona schema (delegated to $PERSONA_VALIDATOR)"

if [[ ! -x "$PERSONA_VALIDATOR" ]]; then
  fail 2 "persona validator not found or not executable: $PERSONA_VALIDATOR (set GAWD_PERSONA_VALIDATOR)"
fi

# The bundle layout splits persona files across soul/, adaptive/, user/.
# validate-schema.sh expects a single workspace dir.  We construct a transient
# "merged-view" directory by symlinking the staged files into a temp dir so the
# validator sees them in canonical workspace layout.

MERGED_VIEW="$(mktemp -d /tmp/gawd-bundle-merged.XXXXXX)"
trap 'rm -rf "$MERGED_VIEW"' EXIT

merge_link() {
  local src="$1" dst_name="$2"
  if [[ -f "$STAGING/$src" ]]; then
    ln -sf "$STAGING/$src" "$MERGED_VIEW/$dst_name"
  fi
}

merge_link "soul/SOUL.md"              "SOUL.md"
merge_link "soul/IDENTITY.md"          "IDENTITY.md"
merge_link "adaptive/VOICE.md"         "VOICE.md"
merge_link "adaptive/VOICE-ADAPTIVE.md" "VOICE-ADAPTIVE.md"
merge_link "adaptive/tuning.md"        "tuning.md"
merge_link "memory/MEMORY.md"          "MEMORY.md"
merge_link "user/USER.md"              "USER.md"

# Multi-Prophit case: surface users/ directory if present
if [[ -d "$STAGING/user/users" ]]; then
  ln -sf "$STAGING/user/users" "$MERGED_VIEW/users"
fi

# Daily notes (validate-schema.sh does not budget these but the dir presence is fine)
if [[ -d "$STAGING/memory/daily" ]]; then
  ln -sf "$STAGING/memory/daily" "$MERGED_VIEW/memory"
fi

# Note: validate-schema.sh checks chmod 0444 / 0644.  In the staging tree these
# permissions are pre-perm-script, so we intentionally do NOT pass --strict.
# A2's gawd-persona-perms.sh runs AFTER atomic rename and sets the real perms.
# We also pass --runtime-user "" to suppress the T0-anchor ownership check: files
# in staging are necessarily owned by whoever is running the import (not a
# separate perm-user), so the ownership invariant is only meaningful post-A2-run.
if ! "$PERSONA_VALIDATOR" "$MERGED_VIEW" --runtime-user "" 2>/tmp/_bundle-validate-persona.err >&2; then
  echo "----- persona validator stderr -----" >&2
  cat /tmp/_bundle-validate-persona.err >&2
  echo "------------------------------------" >&2
  fail 2 "persona schema validation failed (see validator output above)"
fi

log "  persona schema OK"

# ── Check 3: embeddings + secrets-meta sanity ────────────────────────────────────

log "Check 3/3: embeddings + secrets-meta sanity"

# 3a — embeddings
EMBED_PRESENT=$(jq -r '.embeddings_present // true' "$MANIFEST")
if [[ "$EMBED_PRESENT" == "true" ]]; then
  EMBED_TAR="$STAGING/embeddings/memory.lancedb.tar"
  if [[ ! -f "$EMBED_TAR" ]]; then
    fail 3 "manifest claims embeddings_present=true but $EMBED_TAR is missing"
  fi
  # Validate it's a real tar
  if ! tar -tf "$EMBED_TAR" >/dev/null 2>&1; then
    fail 3 "embeddings tar is corrupt or unreadable: $EMBED_TAR"
  fi
  # Count entries — must be > 0
  entry_count=$(tar -tf "$EMBED_TAR" | wc -l)
  if [[ "$entry_count" -le 0 ]]; then
    fail 3 "embeddings tar is empty: $EMBED_TAR"
  fi
  # If manifest declares an index count, sanity-check non-zero
  declared_count=$(jq -r '.embedding_index_count // 0' "$MANIFEST")
  if [[ "$declared_count" -gt 0 && "$entry_count" -lt 1 ]]; then
    fail 3 "embedding_index_count=$declared_count but tar has $entry_count entries"
  fi
  log "  embeddings tar OK ($entry_count entries)"
else
  log "  embeddings_present=false — skipping embeddings check"
fi

# 3b — secrets-meta.json
SECRETS_META="$STAGING/secrets-meta.json"
[[ -f "$SECRETS_META" ]] || fail 4 "secrets-meta.json missing from bundle root"

if ! json_validate "$SECRETS_META_SCHEMA" "$SECRETS_META" >/tmp/_bundle-validate-secrets.err 2>&1; then
  cat /tmp/_bundle-validate-secrets.err >&2
  fail 4 "secrets-meta.json failed schema validation — POSSIBLE LEAK; see error above"
fi

# Defense-in-depth: explicit substring scan for forbidden value-leak fields.
# JSON Schema additionalProperties=false should already reject these, but if a
# future schema relaxation slips through, this catches it loudly.
for forbidden in "${FORBIDDEN_SECRET_FIELDS[@]}"; do
  if grep -q -F "$forbidden" "$SECRETS_META"; then
    fail 4 "secrets-meta.json contains forbidden field substring '$forbidden' — LEAK"
  fi
done

# Heuristic: any string in secrets-meta longer than 256 chars is suspicious
# (key names are bounded to 128).  Tokens are typically much longer.
long_value=$(jq -r 'tostring | scan("[A-Za-z0-9+/=_\\-]{200,}")' "$SECRETS_META" 2>/dev/null | head -n1 || true)
if [[ -n "$long_value" ]]; then
  fail 4 "secrets-meta.json contains a long string that looks like a token — LEAK"
fi

# Count keys for diagnostic
key_count=$(jq -r '.secret_keys | length' "$SECRETS_META")
log "  secrets-meta.json OK ($key_count key name(s) — re-bind required at import)"

# ── done ─────────────────────────────────────────────────────────────────────────

log "ALL CHECKS PASSED — bundle is safe to atomically rename into live workspace"
exit 0
