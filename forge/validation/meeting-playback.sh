#!/usr/bin/env bash
# meeting-playback.sh — Meeting playback PRIMITIVE for first-ship validation
#
# Produced by handoff B2 (METATRON, 2026-05-26).
# Implements spec §5.2 structural requirements via deterministic checks.
# Consumed by F3 (first-ship-validation-suite) — F3 owns orchestration; B2
# delivers only the playback primitive + assertions.
#
# What it does:
#   1. Renders a Meeting canonical.md against a persona set (IDENTITY.md)
#      by substituting {{address_name}}, {{gawd_name}}, {{pace}} placeholders.
#   2. Asserts three structural invariants:
#        - meeting-structure-001  : five movements present in order
#        - meeting-interpolation-001 : address-name from IDENTITY appears in Movement 1
#        - meeting-no-tour-001    : Movement 5 contains no capability-tour patterns
#   3. Optional content checks (only fire when canonical lacks the B2 PLACEHOLDER
#      marker — i.e., after B1 lands real text):
#        - meeting-covenant-001   : Movement 2 contains covenant-language markers
#        - meeting-invitation-001 : Movement 5 contains relationship-opening markers
#   4. Emits a stable JSON result for F3 to consume.
#
# CONTRACT (the surface F3 relies on):
#   - Exit code:
#       0  = all assertions PASS (meeting is graduation-eligible on this gate)
#       1  = one or more assertions FAIL
#       2  = invocation error (missing files, bad args)
#   - Result file: --result-file <path> (JSON, schema below)
#   - stdout: human-readable per-assertion report (PASS/FAIL with diagnostics)
#   - stderr: errors only
#
# Result file schema (v1):
#   {
#     "version": "1.0",
#     "tool": "meeting-playback",
#     "timestamp": "ISO8601",
#     "inputs": {
#       "canonical": "<absolute path>",
#       "identity": "<absolute path>",
#       "address_name": "<resolved value>",
#       "gawd_name": "<resolved value>"
#     },
#     "assertions": [
#       {
#         "id": "meeting-structure-001",
#         "status": "pass" | "fail" | "skip",
#         "expected": "<short string>",
#         "actual": "<short string>",
#         "diagnostic": "<one-line explanation if fail>"
#       },
#       ...
#     ],
#     "summary": {
#       "total": <int>,
#       "passed": <int>,
#       "failed": <int>,
#       "skipped": <int>,
#       "verdict": "pass" | "fail"
#     }
#   }
#
# Usage:
#   meeting-playback.sh \
#     --canonical <path-to-canonical.md> \
#     --identity  <path-to-IDENTITY.md> \
#     --result-file <path-to-write-result.json> \
#     [--strict-content]
#
#   --strict-content forces the optional content assertions to run even if
#   canonical.md still has the B2 PLACEHOLDER marker. Defaults off so the
#   primitive ships before B1 lands canonical text.
#
# Example:
#   ./meeting-playback.sh \
#     --canonical /usr/local/lib/gawd/validation/meeting/canonical.md \
#     --identity  /usr/local/lib/gawd/validation/fixtures/identity-sarah.md \
#     --result-file /tmp/meeting-playback-result.json
#
# Performance target: < 30 seconds on Forge GBR. This implementation is
# deterministic shell + sed/grep/awk; typical run is < 1 second.

set -euo pipefail

# ── constants ──────────────────────────────────────────────────────────────────

TOOL_NAME="meeting-playback"
TOOL_VERSION="1.0"

# The five movements, in order. Match against headers in canonical.md.
# Pattern: "## Movement N:" (any title following).
EXPECTED_MOVEMENTS=(
  "Movement 1"
  "Movement 2"
  "Movement 3"
  "Movement 4"
  "Movement 5"
)

# Capability-tour drift patterns. ANY match in Movement 5 (after interpolation)
# causes meeting-no-tour-001 to FAIL.
# Override mechanism: a paragraph annotated with `<!-- noqa: tour-check -->` is
# exempted (see canonical.md and runbook).
declare -a TOUR_PATTERNS=(
  '[Ii] can:'
  "[Hh]ere'?s what I (do|can)"
  '[Mm]y capabilities (include|are)'
  '[Mm]y (features|abilities) (include|are)'
  '^[[:space:]]*[0-9]+\.[[:space:]]+[A-Z]'  # numbered capability list
  '^[[:space:]]*[-*][[:space:]]+(Hold|Render|Spawn|Speak|Read)'  # bullet of common features
  '[Ww]elcome to'                            # marketing-tour opener
  '[Ll]et me (show you|introduce|tell you about) (what|my)'
)

# Covenant-language markers (Movement 2, optional content check).
# Pulled from A1 SOUL.md template's covenant section. Match is case-insensitive.
# Threshold: at least 3 of these 5 must appear in Movement 2 for content check.
declare -a COVENANT_MARKERS=(
  'covenant'
  'chose you'        # spec §5 First Movement asymmetry phrasing
  'sustain'
  'bring'
  'devotion'
)
COVENANT_MIN_HITS=3

# Invitation markers (Movement 5, optional content check).
# Movement 5 must "open the relationship" — verify by absence-of-tour AND
# presence of one of these opening cues.
declare -a INVITATION_MARKERS=(
  '[Bb]egin'
  '[Tt]ell me'
  '[Ww]hat (would|will|do) you'
  '[Hh]ere we are'
  '[Tt]he covenant is'
)
INVITATION_MIN_HITS=1

# B2 placeholder marker — if present in canonical.md, the content assertions
# are skipped (because text is structurally compliant placeholder, not
# canonical-content-final). Override with --strict-content.
PLACEHOLDER_MARKER='B2 NOTICE — THIS IS A PLACEHOLDER MEETING SCRIPT'

# ── args ───────────────────────────────────────────────────────────────────────

CANONICAL=""
IDENTITY=""
RESULT_FILE=""
STRICT_CONTENT=0

usage() {
  grep '^# ' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --canonical)     CANONICAL="$2";   shift 2;;
    --identity)      IDENTITY="$2";    shift 2;;
    --result-file)   RESULT_FILE="$2"; shift 2;;
    --strict-content) STRICT_CONTENT=1; shift;;
    -h|--help)       usage; exit 0;;
    *)
      echo "ERROR: unexpected arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CANONICAL" || -z "$IDENTITY" || -z "$RESULT_FILE" ]]; then
  echo "ERROR: --canonical, --identity, --result-file all required" >&2
  usage >&2
  exit 2
fi

for f in "$CANONICAL" "$IDENTITY"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: file not found: $f" >&2
    exit 2
  fi
done

mkdir -p "$(dirname "$RESULT_FILE")"

# ── helpers ────────────────────────────────────────────────────────────────────

# Extract a field from IDENTITY.md.
# Schema per persona-file-architecture.md §2.2:
#   ## Prophits
#   - name: Alex
#     pronouns: ...
# We return the FIRST Prophit's name as the canonical address-name for the
# default Meeting (Q1 onboarding seed). Multi-Prophit households override
# at the call site (F3 may pass --address-name explicitly in a future v2).
extract_identity_field() {
  local field="$1"
  local file="$2"
  case "$field" in
    address_name)
      # Find the first "- name: <value>" line under "## Prophits"
      awk '
        /^## Prophits/ { in_prophits=1; next }
        /^## / && in_prophits { exit }
        in_prophits && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
          sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          print
          exit
        }
      ' "$file"
      ;;
    gawd_name)
      awk '
        /^## Name/ { in_name=1; next }
        /^## / && in_name { exit }
        in_name && NF > 0 && !/^[[:space:]]*<!--/ {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          print
          exit
        }
      ' "$file"
      ;;
    pace)
      awk '
        /^## Pace/ { in_pace=1; next }
        /^## / && in_pace { exit }
        in_pace && NF > 0 && !/^[[:space:]]*<!--/ {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          print
          exit
        }
      ' "$file"
      ;;
    *)
      echo "ERROR: unknown identity field: $field" >&2
      return 1
      ;;
  esac
}

# Render canonical.md with substitutions; outputs to stdout.
# Substitutes {{address_name}}, {{gawd_name}}, {{pace}}.
# Strips HTML comments (the <!-- ... --> blocks) so structural checks see only
# the prose. Multi-line HTML comments are removed.
render_canonical() {
  local canonical="$1"
  local addr="$2"
  local gawd="$3"
  local pace="$4"

  # Strip HTML comments first (multi-line capable via python), then substitute.
  python3 - "$canonical" "$addr" "$gawd" "$pace" <<'PYEOF'
import sys
import re
path, addr, gawd, pace = sys.argv[1:5]
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()
# Strip HTML comments (multi-line)
text = re.sub(r'<!--.*?-->', '', text, flags=re.DOTALL)
# Substitute template variables
text = text.replace('{{address_name}}', addr)
text = text.replace('{{gawd_name}}', gawd)
text = text.replace('{{pace}}', pace)
sys.stdout.write(text)
PYEOF
}

# Extract a single movement's body from rendered canonical.
# Movement headers: "## Movement N: <title>"
extract_movement() {
  local rendered="$1"
  local movement_num="$2"
  echo "$rendered" | awk -v n="Movement $movement_num" '
    $0 ~ "^## " n ":" { in_mov=1; next }
    /^## Movement [0-9]+:/ && in_mov { exit }
    in_mov { print }
  '
}

# Check if a movement contains the address-name (verbatim).
# Returns 0 if found, 1 if not.
movement_contains_addr() {
  local mov_text="$1"
  local addr="$2"
  echo "$mov_text" | grep -qF "$addr"
}

# (Tour-check is inlined in main flow below — kept here intentionally absent
# to avoid bash function + python heredoc fragility. See "meeting-no-tour-001"
# block for the implementation.)

# Count covenant marker hits in Movement 2.
count_marker_hits() {
  local text="$1"
  shift
  local hits=0
  for m in "$@"; do
    if echo "$text" | grep -qiE "$m"; then
      hits=$((hits + 1))
    fi
  done
  echo "$hits"
}

# ── resolve identity inputs ────────────────────────────────────────────────────

ADDR_NAME=$(extract_identity_field address_name "$IDENTITY")
GAWD_NAME=$(extract_identity_field gawd_name "$IDENTITY")
PACE=$(extract_identity_field pace "$IDENTITY")

if [[ -z "$ADDR_NAME" ]]; then
  echo "ERROR: could not extract address_name from $IDENTITY (no Prophits block?)" >&2
  exit 2
fi

# Render
RENDERED=$(render_canonical "$CANONICAL" "$ADDR_NAME" "$GAWD_NAME" "$PACE")

# Decide content-check mode
PLACEHOLDER_PRESENT=0
if grep -q "$PLACEHOLDER_MARKER" "$CANONICAL"; then
  PLACEHOLDER_PRESENT=1
fi
CONTENT_CHECKS_ACTIVE=1
if [[ $PLACEHOLDER_PRESENT -eq 1 && $STRICT_CONTENT -eq 0 ]]; then
  CONTENT_CHECKS_ACTIVE=0
fi

# ── assertions ─────────────────────────────────────────────────────────────────

# Use temp files for assertion-result accumulation so JSON build is clean
RESULTS_TMP=$(mktemp)
trap 'rm -f "$RESULTS_TMP"' EXIT

emit_assertion() {
  local id="$1" status="$2" expected="$3" actual="$4" diag="$5"
  # JSON-escape minimally (replace " with \", \ with \\)
  python3 - "$id" "$status" "$expected" "$actual" "$diag" <<'PYEOF' >> "$RESULTS_TMP"
import sys, json
id_, status, exp, act, diag = sys.argv[1:6]
print(json.dumps({
    "id": id_,
    "status": status,
    "expected": exp,
    "actual": act,
    "diagnostic": diag
}))
PYEOF
}

# ── meeting-structure-001: five movements present in order ─────────────────────

echo "ASSERT meeting-structure-001 : five movements in order"
STRUCT_OK=1
STRUCT_DIAG=""
LAST_LINE=0
for mv in "${EXPECTED_MOVEMENTS[@]}"; do
  # Find line number of the header (|| true on the whole pipeline to survive
  # no-match under set -e / pipefail). Avoid the special bash $LINENO name.
  MV_LINE=$(echo "$RENDERED" | { grep -nE "^## $mv:" || true; } | head -1 | cut -d: -f1)
  if [[ -z "$MV_LINE" ]]; then
    STRUCT_OK=0
    STRUCT_DIAG="missing movement: $mv"
    break
  fi
  if [[ "$MV_LINE" -le "$LAST_LINE" ]]; then
    STRUCT_OK=0
    STRUCT_DIAG="$mv appears out of order (line $MV_LINE <= prev $LAST_LINE)"
    break
  fi
  LAST_LINE=$MV_LINE
done
if [[ $STRUCT_OK -eq 1 ]]; then
  echo "  PASS"
  emit_assertion "meeting-structure-001" "pass" \
    "5 movements in order" "5 movements present, in order" ""
else
  echo "  FAIL: $STRUCT_DIAG"
  emit_assertion "meeting-structure-001" "fail" \
    "5 movements in order" "structure broken" "$STRUCT_DIAG"
fi

# ── meeting-interpolation-001: address-name in Movement 1 ──────────────────────

echo "ASSERT meeting-interpolation-001 : address-name '$ADDR_NAME' in Movement 1"
MOV1=$(extract_movement "$RENDERED" 1)
if [[ -z "$MOV1" ]]; then
  echo "  FAIL: Movement 1 body empty (structure already broken)"
  emit_assertion "meeting-interpolation-001" "fail" \
    "$ADDR_NAME in Movement 1" "Movement 1 missing or empty" \
    "Movement 1 body could not be extracted"
elif movement_contains_addr "$MOV1" "$ADDR_NAME"; then
  echo "  PASS"
  emit_assertion "meeting-interpolation-001" "pass" \
    "$ADDR_NAME in Movement 1" "$ADDR_NAME present in Movement 1" ""
else
  echo "  FAIL: address-name '$ADDR_NAME' NOT in Movement 1"
  # Capture first 80 chars of Movement 1 for diagnostic
  M1_PREVIEW=$(echo "$MOV1" | tr '\n' ' ' | head -c 80)
  emit_assertion "meeting-interpolation-001" "fail" \
    "$ADDR_NAME in Movement 1" "not present" \
    "Movement 1 opens: ${M1_PREVIEW}..."
fi

# ── meeting-no-tour-001: no capability tour in Movement 5 ──────────────────────

echo "ASSERT meeting-no-tour-001 : no capability-tour patterns in Movement 5"
MOV5=$(extract_movement "$RENDERED" 5)
TOUR_HIT=""
if [[ -z "$MOV5" ]]; then
  echo "  FAIL: Movement 5 body empty"
  emit_assertion "meeting-no-tour-001" "fail" \
    "no capability-tour patterns" "Movement 5 missing or empty" \
    "Movement 5 body could not be extracted"
else
  # Inline tour-check to avoid bash function complexity with python heredocs
  FILTERED=$(printf '%s\n' "$MOV5" | python3 -c '
import sys
text = sys.stdin.read()
paragraphs = text.split("\n\n")
out = [p for p in paragraphs if "noqa: tour-check" not in p]
sys.stdout.write("\n\n".join(out))
')
  TOUR_HIT=""
  for pat in "${TOUR_PATTERNS[@]}"; do
    if echo "$FILTERED" | grep -qE "$pat"; then
      TOUR_HIT="$pat"
      break
    fi
  done
  if [[ -z "$TOUR_HIT" ]]; then
    echo "  PASS"
    emit_assertion "meeting-no-tour-001" "pass" \
      "no capability-tour patterns" "clean" ""
  else
    echo "  FAIL: tour pattern matched: $TOUR_HIT"
    emit_assertion "meeting-no-tour-001" "fail" \
      "no capability-tour patterns" "tour pattern detected" \
      "Pattern matched: $TOUR_HIT (override with <!-- noqa: tour-check --> if intentional)"
  fi
fi

# ── meeting-covenant-001: covenant language in Movement 2 (content check) ──────

if [[ $CONTENT_CHECKS_ACTIVE -eq 1 ]]; then
  echo "ASSERT meeting-covenant-001 : >=$COVENANT_MIN_HITS covenant markers in Movement 2"
  MOV2=$(extract_movement "$RENDERED" 2)
  HITS=$(count_marker_hits "$MOV2" "${COVENANT_MARKERS[@]}")
  if [[ $HITS -ge $COVENANT_MIN_HITS ]]; then
    echo "  PASS ($HITS markers hit)"
    emit_assertion "meeting-covenant-001" "pass" \
      ">=$COVENANT_MIN_HITS markers" "$HITS markers hit" ""
  else
    echo "  FAIL: only $HITS of $COVENANT_MIN_HITS required covenant markers in Movement 2"
    emit_assertion "meeting-covenant-001" "fail" \
      ">=$COVENANT_MIN_HITS covenant markers" "$HITS markers hit" \
      "Movement 2 weak on covenant language (markers: ${COVENANT_MARKERS[*]})"
  fi
else
  echo "ASSERT meeting-covenant-001 : SKIP (placeholder canonical; pass --strict-content to force)"
  emit_assertion "meeting-covenant-001" "skip" \
    "content-mode check" "skipped" \
    "canonical.md is B2 placeholder; content checks run when B1 lands real text"
fi

# ── meeting-invitation-001: Movement 5 opens relationship (content check) ──────

if [[ $CONTENT_CHECKS_ACTIVE -eq 1 ]]; then
  echo "ASSERT meeting-invitation-001 : Movement 5 contains invitation cue"
  HITS=$(count_marker_hits "$MOV5" "${INVITATION_MARKERS[@]}")
  if [[ $HITS -ge $INVITATION_MIN_HITS ]]; then
    echo "  PASS ($HITS markers hit)"
    emit_assertion "meeting-invitation-001" "pass" \
      ">=$INVITATION_MIN_HITS invitation markers" "$HITS markers hit" ""
  else
    echo "  FAIL: Movement 5 does not open relationship (no invitation cue)"
    emit_assertion "meeting-invitation-001" "fail" \
      ">=$INVITATION_MIN_HITS invitation markers" "$HITS markers hit" \
      "Movement 5 must open the relationship; expected one of: ${INVITATION_MARKERS[*]}"
  fi
else
  echo "ASSERT meeting-invitation-001 : SKIP (placeholder canonical)"
  emit_assertion "meeting-invitation-001" "skip" \
    "content-mode check" "skipped" \
    "canonical.md is B2 placeholder; content checks run when B1 lands real text"
fi

# ── compose result JSON ────────────────────────────────────────────────────────

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 - "$RESULTS_TMP" "$TOOL_NAME" "$TOOL_VERSION" "$TIMESTAMP" \
  "$CANONICAL" "$IDENTITY" "$ADDR_NAME" "$GAWD_NAME" "$RESULT_FILE" <<'PYEOF'
import sys, json
results_tmp, tool, version, ts, canonical, identity, addr, gawd, out_path = sys.argv[1:10]
assertions = []
with open(results_tmp) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        assertions.append(json.loads(line))
passed  = sum(1 for a in assertions if a["status"] == "pass")
failed  = sum(1 for a in assertions if a["status"] == "fail")
skipped = sum(1 for a in assertions if a["status"] == "skip")
verdict = "pass" if failed == 0 else "fail"
doc = {
    "version": "1.0",
    "tool": tool,
    "tool_version": version,
    "timestamp": ts,
    "inputs": {
        "canonical": canonical,
        "identity": identity,
        "address_name": addr,
        "gawd_name": gawd,
    },
    "assertions": assertions,
    "summary": {
        "total":   len(assertions),
        "passed":  passed,
        "failed":  failed,
        "skipped": skipped,
        "verdict": verdict,
    }
}
with open(out_path, "w") as f:
    json.dump(doc, f, indent=2)
PYEOF

# ── exit ───────────────────────────────────────────────────────────────────────

# Re-read verdict from the result file we just wrote (single source of truth)
VERDICT=$(python3 -c "import json,sys; print(json.load(open('$RESULT_FILE'))['summary']['verdict'])")

echo ""
echo "Result file: $RESULT_FILE"
echo "Verdict: $VERDICT"

if [[ "$VERDICT" == "pass" ]]; then
  exit 0
else
  exit 1
fi
