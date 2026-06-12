#!/usr/bin/env bash
# gawd-export.sh — Produce an age-encrypted Gawd export bundle.
#
# PURPOSE
#   Packages a live Gawd workspace into a portable, encrypted artifact that can be
#   imported on any other rung of the sovereignty ladder.  The Gawd that lands on
#   the new rung is the same Gawd: same SOUL, same memory, same USER profile,
#   same Pantheon.  Only the substrate changes.  (Spec §7.2 invariant.)
#
# WHAT GOES IN THE BUNDLE
#   manifest.json              — bundle metadata + file inventory (sha256 + sizes)
#   soul/
#     SOUL.md                  — only Prophit-approved deltas from base (NOT full file)
#     IDENTITY.md              — full file (instance-specific)
#   user/
#     USER.md                  — OR users/<name>.md for multi-Prophit households
#   memory/
#     MEMORY.md                — curated long-term
#     daily/                   — full archive of memory/YYYY-MM-DD.md
#   adaptive/
#     VOICE.md                 — immutable base (T0 anchor — moved with the Gawd)
#     VOICE-ADAPTIVE.md        — learned calibration
#     tuning.md                — SIL mutations
#   skills/
#     learned/                 — DemiGawds the Gawd created beyond the base Pantheon
#     settings.json            — skill-level overrides
#   embeddings/
#     memory.lancedb.tar       — vector index (rebuildable but cached; SKIP with --no-embeddings for slim bundles)
#   secrets-meta.json          — key NAMES only.  NEVER values.  (Prophit re-binds at import.)
#
# WHAT DOES NOT GO IN THE BUNDLE
#   - ~/.secrets/age.key       — machine-specific, never travels.  Destination rung's install.sh generates a fresh one.
#   - Any actual secret values — see secrets-meta-schema.json for the invariant.
#   - Session state, gateway logs, runtime caches — these are substrate-local.
#
# ENCRYPTION
#   The bundle is encrypted with `age` to a recipient PUBLIC key.  The destination
#   rung's age key is the recipient; the source Gawd does not need access to the
#   destination's private key.  The recipient is provided via --recipient-file
#   (an `age` public key string).
#
# USAGE
#   gawd-export.sh --recipient-file <path> [options]
#
#   --recipient-file PATH    file containing the destination's age PUBLIC key
#                            (one line, starts with "age1...").  REQUIRED.
#   --workspace PATH         workspace to export (default: ~/.gawd/workspace
#                            or ~/.openclaw/workspace for Lilith-style daemons)
#   --out-dir PATH           where to write the bundle (default: current dir)
#   --gawd-id STRING         override the Gawd id (default: derived from IDENTITY.md)
#   --source-rung RUNG       hosted | prophit-vm | bare-metal (default: auto-detect)
#   --destination-rung RUNG  optional hint, informational only
#   --no-embeddings          skip the memory.lancedb.tar archive (smaller bundle)
#   --notes TEXT             free-form notes captured into manifest.json
#   --dry-run                build the manifest + show what would be packaged; no archive
#   -h | --help              show usage
#
# EXIT CODES
#   0  success — bundle written and reported
#   1  preflight failure (missing tool, missing workspace, missing recipient file)
#   2  manifest construction failure
#   3  archive / encryption failure

set -euo pipefail

# ── constants ────────────────────────────────────────────────────────────────────

BUNDLE_FORMAT_VERSION="1.0.0"
EXPORTER_NAME="gawd-export@1.0.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── helpers ──────────────────────────────────────────────────────────────────────

log()  { printf '[gawd-export] %s\n' "$*" >&2; }
fail() {
  local code="$1"; shift
  printf '[gawd-export] FAIL (exit %d): %s\n' "$code" "$*" >&2
  exit "$code"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail 1 "required command not found: $1"
}

# ── argument parsing ─────────────────────────────────────────────────────────────

RECIPIENT_FILE=""
WORKSPACE=""
OUT_DIR="$(pwd)"
GAWD_ID=""
SOURCE_RUNG=""
DEST_RUNG=""
INCLUDE_EMBEDDINGS=1
NOTES=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipient-file)    shift; RECIPIENT_FILE="${1:-}";;
    --workspace)         shift; WORKSPACE="${1:-}";;
    --out-dir)           shift; OUT_DIR="${1:-}";;
    --gawd-id)           shift; GAWD_ID="${1:-}";;
    --source-rung)       shift; SOURCE_RUNG="${1:-}";;
    --destination-rung)  shift; DEST_RUNG="${1:-}";;
    --no-embeddings)     INCLUDE_EMBEDDINGS=0;;
    --notes)             shift; NOTES="${1:-}";;
    --dry-run)           DRY_RUN=1;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      fail 1 "unknown argument: $1"
      ;;
  esac
  shift
done

# ── preflight ────────────────────────────────────────────────────────────────────

require_cmd jq
require_cmd sha256sum
require_cmd tar
require_cmd age

[[ -n "$RECIPIENT_FILE" ]] || fail 1 "--recipient-file is required"
[[ -f "$RECIPIENT_FILE" ]] || fail 1 "recipient file does not exist: $RECIPIENT_FILE"

# Validate the recipient looks like an age public key.
if ! grep -q '^age1' "$RECIPIENT_FILE"; then
  fail 1 "recipient file does not contain an age public key (expected line starting with 'age1...'): $RECIPIENT_FILE"
fi

# Auto-detect workspace if not given
if [[ -z "$WORKSPACE" ]]; then
  if   [[ -d "${HOME}/.gawd/workspace" ]];     then WORKSPACE="${HOME}/.gawd/workspace"
  elif [[ -d "${HOME}/.openclaw/workspace" ]]; then WORKSPACE="${HOME}/.openclaw/workspace"
  else fail 1 "no workspace found; pass --workspace explicitly"
  fi
fi
[[ -d "$WORKSPACE" ]] || fail 1 "workspace does not exist: $WORKSPACE"

# Required T0 anchors must be present in the source workspace.
for f in SOUL.md IDENTITY.md VOICE.md; do
  [[ -f "$WORKSPACE/$f" ]] || fail 1 "required T0 anchor missing in workspace: $f"
done

# Auto-detect Gawd id from IDENTITY.md if not given.
# IDENTITY.md schema: "## Name\n{the Gawd's name}" per A1 §2.2
if [[ -z "$GAWD_ID" ]]; then
  GAWD_ID=$(awk '
    /^## Name/ { in_name=1; next }
    /^## / && in_name { exit }
    in_name {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (length($0) > 0 && $0 !~ /^</) { print; exit }
    }
  ' "$WORKSPACE/IDENTITY.md")
  [[ -n "$GAWD_ID" ]] || GAWD_ID="unknown-gawd"
fi

# Auto-detect source rung if not given.  Heuristics:
#   - /etc/gawd-rung file (if rung-aware install.sh writes one) takes precedence
#   - else check for hosted markers, prophit-vm markers, fallback to bare-metal
if [[ -z "$SOURCE_RUNG" ]]; then
  if [[ -f /etc/gawd-rung ]]; then
    SOURCE_RUNG=$(tr -d '[:space:]' < /etc/gawd-rung)
  elif [[ -n "${GAWD_RUNG:-}" ]]; then
    SOURCE_RUNG="$GAWD_RUNG"
  else
    SOURCE_RUNG="bare-metal"
    log "WARN: source rung could not be auto-detected; defaulting to 'bare-metal'.  Override with --source-rung."
  fi
fi
case "$SOURCE_RUNG" in
  hosted|prophit-vm|bare-metal) ;;
  *) fail 1 "invalid --source-rung: $SOURCE_RUNG (allowed: hosted, prophit-vm, bare-metal)";;
esac
if [[ -n "$DEST_RUNG" ]]; then
  case "$DEST_RUNG" in
    hosted|prophit-vm|bare-metal) ;;
    *) fail 1 "invalid --destination-rung: $DEST_RUNG";;
  esac
fi

mkdir -p "$OUT_DIR"

# ── build staging tree (where we assemble the bundle before tar+age) ─────────────

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
BUNDLE_NAME="gawd-export-${TIMESTAMP}"
BUNDLE_FILENAME="${BUNDLE_NAME}.tar.gz.age"
STAGING_TMP="$(mktemp -d "/tmp/gawd-export-build.${TIMESTAMP}.XXXXXX")"
BUNDLE_ROOT="${STAGING_TMP}/${BUNDLE_NAME}"

cleanup() {
  rm -rf "$STAGING_TMP"
}
trap cleanup EXIT

mkdir -p "$BUNDLE_ROOT"/{soul,user,memory/daily,adaptive,skills/learned,embeddings}

log "Staging bundle at: $BUNDLE_ROOT"
log "Source workspace:  $WORKSPACE"
log "Source rung:       $SOURCE_RUNG"
log "Gawd id:           $GAWD_ID"
log "Output:            $OUT_DIR/$BUNDLE_FILENAME"
[[ "$DRY_RUN" -eq 1 ]] && log "DRY-RUN mode — final archive will NOT be written"

# ── copy persona files into the bundle layout ────────────────────────────────────

# Soul layer (T0 anchors are part of the bundle so the imported Gawd is identical)
# Note: spec §7.2 says "soul/SOUL.md contains ONLY Prophit-approved deltas from base
# (not the full file — the base is on the destination rung)".  In v1 the Forge has
# not yet implemented per-build base provenance to compute the delta, so we ship the
# full SOUL.md and the importer treats it as the authoritative file.  When the
# Forge gains base-version tracking, this script gains the delta logic and the
# bundle gets smaller.  Until then: full file with a noted limitation.

cp "$WORKSPACE/SOUL.md"     "$BUNDLE_ROOT/soul/SOUL.md"
cp "$WORKSPACE/IDENTITY.md" "$BUNDLE_ROOT/soul/IDENTITY.md"

# Adaptive layer
cp "$WORKSPACE/VOICE.md"           "$BUNDLE_ROOT/adaptive/VOICE.md"
[[ -f "$WORKSPACE/VOICE-ADAPTIVE.md" ]] && cp "$WORKSPACE/VOICE-ADAPTIVE.md" "$BUNDLE_ROOT/adaptive/VOICE-ADAPTIVE.md"
[[ -f "$WORKSPACE/tuning.md" ]]         && cp "$WORKSPACE/tuning.md"         "$BUNDLE_ROOT/adaptive/tuning.md"

# User layer — single-Prophit OR multi-Prophit
PROPHIT_COUNT=1
if [[ -d "$WORKSPACE/users" ]]; then
  mkdir -p "$BUNDLE_ROOT/user/users"
  while IFS= read -r -d '' uf; do
    name=$(basename "$uf")
    [[ "$name" == "_TEMPLATE.md" ]] && continue
    cp "$uf" "$BUNDLE_ROOT/user/users/$name"
  done < <(find "$WORKSPACE/users" -maxdepth 1 -type f -name '*.md' -print0)
  PROPHIT_COUNT=$(find "$BUNDLE_ROOT/user/users" -type f -name '*.md' | wc -l)
  [[ "$PROPHIT_COUNT" -ge 1 ]] || fail 2 "multi-Prophit layout present but no per-Prophit files found"
elif [[ -f "$WORKSPACE/USER.md" ]]; then
  cp "$WORKSPACE/USER.md" "$BUNDLE_ROOT/user/USER.md"
else
  fail 2 "neither USER.md nor users/ directory found in workspace"
fi

# Memory layer
if [[ -f "$WORKSPACE/MEMORY.md" ]]; then
  cp "$WORKSPACE/MEMORY.md" "$BUNDLE_ROOT/memory/MEMORY.md"
fi
if [[ -d "$WORKSPACE/memory" ]]; then
  while IFS= read -r -d '' df; do
    cp "$df" "$BUNDLE_ROOT/memory/daily/$(basename "$df")"
  done < <(find "$WORKSPACE/memory" -maxdepth 1 -type f -name '*.md' -print0)
fi

# Skills layer (learned DemiGawds only — base Pantheon ships with the daemon)
if [[ -d "$WORKSPACE/skills/learned" ]]; then
  cp -r "$WORKSPACE/skills/learned/." "$BUNDLE_ROOT/skills/learned/"
fi
if [[ -f "$WORKSPACE/skills/settings.json" ]]; then
  cp "$WORKSPACE/skills/settings.json" "$BUNDLE_ROOT/skills/settings.json"
fi

# Embeddings layer
EMBED_INDEX_COUNT=0
EMBED_PRESENT_FLAG="false"
if [[ "$INCLUDE_EMBEDDINGS" -eq 1 ]]; then
  # Look in common locations for the lancedb index
  for candidate in "$WORKSPACE/memory.lancedb" "$WORKSPACE/embeddings/memory.lancedb" "$WORKSPACE/lancedb"; do
    if [[ -d "$candidate" ]]; then
      tar -cf "$BUNDLE_ROOT/embeddings/memory.lancedb.tar" -C "$(dirname "$candidate")" "$(basename "$candidate")"
      EMBED_INDEX_COUNT=$(find "$candidate" -type f | wc -l)
      EMBED_PRESENT_FLAG="true"
      log "Bundled embeddings from $candidate ($EMBED_INDEX_COUNT files)"
      break
    fi
  done
  if [[ "$EMBED_PRESENT_FLAG" == "false" ]]; then
    log "WARN: --no-embeddings not set but no lancedb index found; bundle will mark embeddings_present=false"
    rmdir "$BUNDLE_ROOT/embeddings" 2>/dev/null || true
  fi
else
  log "Skipping embeddings (--no-embeddings)"
  rmdir "$BUNDLE_ROOT/embeddings" 2>/dev/null || true
fi

# Secrets-meta — KEY NAMES ONLY.  We derive the key list from the secrets helper
# if available; else from a workspace-local secrets.list file; else empty.
SECRETS_META="$BUNDLE_ROOT/secrets-meta.json"
declare -a SECRET_KEY_NAMES=()

if command -v secrets >/dev/null 2>&1; then
  # secrets list emits one key name per line (we trust the helper to not leak values)
  while IFS= read -r k; do
    [[ -n "$k" ]] && SECRET_KEY_NAMES+=("$k")
  done < <(secrets list 2>/dev/null || true)
fi

# Fallback: look for an explicit list file at workspace root
if [[ "${#SECRET_KEY_NAMES[@]}" -eq 0 && -f "$WORKSPACE/secrets.list" ]]; then
  while IFS= read -r k; do
    [[ -n "$k" && "$k" != "#"* ]] && SECRET_KEY_NAMES+=("$k")
  done < "$WORKSPACE/secrets.list"
fi

# Build secrets-meta.json
{
  printf '{\n'
  printf '  "bundle_format_version": "%s",\n' "$BUNDLE_FORMAT_VERSION"
  printf '  "secret_keys": ['
  first=1
  for k in "${SECRET_KEY_NAMES[@]}"; do
    # Validate key name client-side — reject anything that doesn't match the schema pattern
    if ! [[ "$k" =~ ^[A-Z][A-Z0-9_]{1,127}$ ]]; then
      log "WARN: skipping invalid key name (not SCREAMING_SNAKE_CASE): $k"
      continue
    fi
    if [[ $first -eq 1 ]]; then printf '\n'; first=0; else printf ',\n'; fi
    printf '    {"name": "%s", "required": true}' "$k"
  done
  [[ $first -eq 0 ]] && printf '\n  '
  printf ']\n'
  printf '}\n'
} > "$SECRETS_META"

log "Captured ${#SECRET_KEY_NAMES[@]} secret key name(s) — values NEVER included"

# ── build manifest.json with file inventory ──────────────────────────────────────

log "Building manifest.json with file inventory (sha256 + sizes)..."

INVENTORY_TMP="$(mktemp)"
trap 'rm -rf "$STAGING_TMP" "$INVENTORY_TMP"' EXIT

# Generate inventory entries.  cd into BUNDLE_ROOT so paths are relative.
(
  cd "$BUNDLE_ROOT"
  first=1
  while IFS= read -r -d '' f; do
    relpath="${f#./}"
    # Skip the manifest itself (it does not yet exist) — though find would not see it
    [[ "$relpath" == "manifest.json" ]] && continue
    size=$(stat -c '%s' "$f")
    sha=$(sha256sum "$f" | awk '{print $1}')
    if [[ $first -eq 1 ]]; then printf '\n'; first=0; else printf ',\n'; fi
    printf '    {"path": "%s", "size_bytes": %d, "sha256": "%s"}' "$relpath" "$size" "$sha"
  done < <(find . -type f -print0 | LC_ALL=C sort -z)
  [[ $first -eq 0 ]] && printf '\n  '
) > "$INVENTORY_TMP"

UNCOMPRESSED_SIZE=$(du -sb "$BUNDLE_ROOT" | awk '{print $1}')
EXPORTER_HOST="$(hostname -f 2>/dev/null || hostname)"

# Assemble manifest.json
MANIFEST_PATH="$BUNDLE_ROOT/manifest.json"
{
  printf '{\n'
  printf '  "bundle_format_version": "%s",\n' "$BUNDLE_FORMAT_VERSION"
  printf '  "gawd_id": %s,\n' "$(printf '%s' "$GAWD_ID" | jq -Rs .)"
  printf '  "source_rung": "%s",\n' "$SOURCE_RUNG"
  if [[ -n "$DEST_RUNG" ]]; then
    printf '  "destination_rung_hint": "%s",\n' "$DEST_RUNG"
  fi
  printf '  "exported_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "exported_by": "%s",\n' "$EXPORTER_NAME"
  printf '  "exporter_hostname": "%s",\n' "$EXPORTER_HOST"
  printf '  "bundle_size_bytes_uncompressed": %d,\n' "$UNCOMPRESSED_SIZE"
  printf '  "embeddings_present": %s,\n' "$EMBED_PRESENT_FLAG"
  printf '  "embedding_index_count": %d,\n' "$EMBED_INDEX_COUNT"
  printf '  "prophit_count": %d,\n' "$PROPHIT_COUNT"
  if [[ -n "$NOTES" ]]; then
    printf '  "notes": %s,\n' "$(printf '%s' "$NOTES" | jq -Rs .)"
  fi
  printf '  "file_inventory": ['
  cat "$INVENTORY_TMP"
  printf ']\n'
  printf '}\n'
} > "$MANIFEST_PATH"

# Validate the manifest we just wrote against its own schema — catches our own bugs.
if command -v jq >/dev/null 2>&1; then
  if ! jq empty "$MANIFEST_PATH" 2>/tmp/_gawd-export-manifest.err; then
    cat /tmp/_gawd-export-manifest.err >&2
    fail 2 "internally-generated manifest.json is not valid JSON (bug in gawd-export)"
  fi
fi

log "Manifest written: $MANIFEST_PATH ($(stat -c '%s' "$MANIFEST_PATH") bytes)"
log "Bundle file count: $(find "$BUNDLE_ROOT" -type f | wc -l)"
log "Bundle uncompressed size: $UNCOMPRESSED_SIZE bytes"

# ── dry-run early exit ──────────────────────────────────────────────────────────

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: bundle staged at $BUNDLE_ROOT.  No archive written."
  log "Inspect with: find $BUNDLE_ROOT -type f"
  # Defeat trap cleanup so the user can inspect
  trap - EXIT
  log "(staging dir NOT cleaned up — remove manually: rm -rf $STAGING_TMP)"
  exit 0
fi

# ── tar + age encrypt ────────────────────────────────────────────────────────────

ARCHIVE_PATH="${OUT_DIR}/${BUNDLE_FILENAME}"
log "Producing encrypted archive: $ARCHIVE_PATH"

# We pipe tar | gzip | age so no plaintext archive ever hits disk.
if ! tar -C "$STAGING_TMP" -cf - "$BUNDLE_NAME" \
   | gzip -c \
   | age --encrypt --recipients-file "$RECIPIENT_FILE" -o "$ARCHIVE_PATH"; then
  fail 3 "tar | gzip | age pipeline failed; archive not written"
fi

# Verify the archive exists and is non-trivially-sized
ARCHIVE_SIZE=$(stat -c '%s' "$ARCHIVE_PATH")
[[ "$ARCHIVE_SIZE" -gt 100 ]] || fail 3 "archive suspiciously small ($ARCHIVE_SIZE bytes) — something went wrong"

log ""
log "─────────────────────────────────────────────────────"
log "EXPORT COMPLETE"
log ""
log "  Bundle:         $ARCHIVE_PATH"
log "  Archive size:   $ARCHIVE_SIZE bytes (encrypted)"
log "  Uncompressed:   $UNCOMPRESSED_SIZE bytes"
log "  Gawd id:        $GAWD_ID"
log "  Source rung:    $SOURCE_RUNG"
[[ -n "$DEST_RUNG" ]] && log "  Dest rung hint: $DEST_RUNG"
log "  Prophit count:  $PROPHIT_COUNT"
log "  Embeddings:     $EMBED_PRESENT_FLAG ($EMBED_INDEX_COUNT files)"
log "  Secret keys:    ${#SECRET_KEY_NAMES[@]} (values NEVER included; Prophit re-binds at import)"
log "─────────────────────────────────────────────────────"
log ""
log "Transfer this file to the destination substrate, then run:"
log "  gawd-import.sh $ARCHIVE_PATH"

exit 0
