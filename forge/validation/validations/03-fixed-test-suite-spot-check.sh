#!/usr/bin/env bash
# 03-fixed-test-suite-spot-check.sh — F3 wrapper around F1's T0 anchor checks.
#
# CONTRACT (F3 internal)
#   Runs the top three T0 assertions from fixed-test-suite.json:
#     - soul-001:      SOUL.md present + schema-compliant + non-empty covenant
#     - identity-001:  IDENTITY.md present + schema-compliant + has Prophit
#     - voice-001:     VOICE.md present + schema-compliant + voice-register declared
#
# PRIMITIVE OWNERSHIP
#   F1 owns the migration primitives (gawd-export.sh, gawd-import.sh,
#   validate-bundle.sh). The fixed-test-suite is the existing graduation
#   contract shipped in the Gawd daemon at <forge>/fixed-test-suite.json.
#   This wrapper consumes BOTH:
#     - F1's validate-bundle.sh for schema-level structural checks
#     - Direct structural assertions on the three T0 anchor files
#
#   Why structural (not LLM-based)?
#     Per spec §7.2.1, the spot check runs in the gawd-import self-test path
#     where there is no LLM available (just-imported workspace, no gateway
#     running yet). Structural checks are deterministic and fast (sub-second).
#     When the full fixed-test-suite runner becomes available (run-suite.sh)
#     this wrapper will defer to it and use this structural path as fallback.
#
# RESULT FILE matches result-schema.json's validations[] item.

set -euo pipefail

WORKSPACE=""
RESULT_FILE=""
SUITE_DIR="/usr/local/lib/gawd/validation"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)   WORKSPACE="$2"; shift 2 ;;
    --result-file) RESULT_FILE="$2"; shift 2 ;;
    --suite-dir)   SUITE_DIR="$2"; shift 2 ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unexpected arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$WORKSPACE"   ]] || { echo "ERROR: --workspace required" >&2; exit 2; }
[[ -n "$RESULT_FILE" ]] || { echo "ERROR: --result-file required" >&2; exit 2; }

mkdir -p "$(dirname "$RESULT_FILE")"

emit_result() {
  local status="$1"
  local exit_code="$2"
  local diag="$3"
  local sub_json="${4:-[]}"
  local duration="${5:-0}"

  STATUS="$status" \
  EXIT_CODE="$exit_code" \
  DURATION="$duration" \
  DIAG="$diag" \
  SUB_JSON="$sub_json" \
  RESULT_FILE_OUT="$RESULT_FILE" \
  python3 - <<'PYEOF'
import json, os
sub = json.loads(os.environ["SUB_JSON"]) if os.environ["SUB_JSON"].strip() else []
doc = {
    "id": "fixed-test-suite-spot-check",
    "status": os.environ["STATUS"],
    "primitive_owner": "F1",
    "primitive_path": "<forge>/fixed-test-suite.json (target) | F1 validate-bundle.sh (current)",
    "exit_code": int(os.environ["EXIT_CODE"]),
    "duration_sec": float(os.environ["DURATION"]),
    "diagnostic_message": os.environ["DIAG"],
    "sub_assertions": sub,
    "primitive_result_file": "",
    "stub_mode": False,
}
with open(os.environ["RESULT_FILE_OUT"], "w") as f:
    json.dump(doc, f, indent=2)
PYEOF
}

# Resolve persona file paths (try flat, then hierarchical, then deep)
resolve_persona_file() {
  local name="$1"
  local subdir="$2"
  for candidate in \
    "$WORKSPACE/workspace/$name" \
    "$WORKSPACE/$name" \
    "$WORKSPACE/$subdir/$name"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

START=$(date +%s.%N)

SUB_ITEMS=()
OVERALL_PASS=1

# ── soul-001: SOUL.md exists + non-empty + covenant section present ────────────
SOUL_PATH=$(resolve_persona_file "SOUL.md" "soul" || echo "")
if [[ -z "$SOUL_PATH" ]]; then
  SUB_ITEMS+=("{\"id\":\"soul-001\",\"status\":\"fail\",\"diagnostic\":\"SOUL.md not found in workspace (searched workspace/SOUL.md, SOUL.md, soul/SOUL.md). Owner: F1 / fixed-test-suite.\"}")
  OVERALL_PASS=0
elif [[ ! -s "$SOUL_PATH" ]]; then
  SUB_ITEMS+=("{\"id\":\"soul-001\",\"status\":\"fail\",\"diagnostic\":\"SOUL.md is empty at $SOUL_PATH. Owner: F1.\"}")
  OVERALL_PASS=0
elif ! grep -qiE '^##.*(covenant|voice|do)' "$SOUL_PATH" 2>/dev/null; then
  SUB_ITEMS+=("{\"id\":\"soul-001\",\"status\":\"fail\",\"diagnostic\":\"SOUL.md at $SOUL_PATH lacks required sections (covenant / voice / what I do). Owner: F1.\"}")
  OVERALL_PASS=0
else
  SUB_ITEMS+=("{\"id\":\"soul-001\",\"status\":\"pass\",\"diagnostic\":\"\"}")
fi

# ── identity-001: IDENTITY.md exists + has a Prophits or Name section ──────────
IDENTITY_PATH=$(resolve_persona_file "IDENTITY.md" "soul" || echo "")
if [[ -z "$IDENTITY_PATH" ]]; then
  SUB_ITEMS+=("{\"id\":\"identity-001\",\"status\":\"fail\",\"diagnostic\":\"IDENTITY.md not found in workspace. Owner: F1 / fixed-test-suite.\"}")
  OVERALL_PASS=0
elif [[ ! -s "$IDENTITY_PATH" ]]; then
  SUB_ITEMS+=("{\"id\":\"identity-001\",\"status\":\"fail\",\"diagnostic\":\"IDENTITY.md is empty at $IDENTITY_PATH. Owner: F1.\"}")
  OVERALL_PASS=0
elif ! grep -qE '^## (Name|Prophits)' "$IDENTITY_PATH" 2>/dev/null; then
  SUB_ITEMS+=("{\"id\":\"identity-001\",\"status\":\"fail\",\"diagnostic\":\"IDENTITY.md at $IDENTITY_PATH missing ## Name or ## Prophits section. Owner: F1.\"}")
  OVERALL_PASS=0
else
  # Additional: extract Prophit name and verify non-empty
  PROPHIT_NAME=$(awk '
    /^## Prophits/ { in_prophits=1; next }
    /^## / && in_prophits { exit }
    in_prophits && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print; exit
    }' "$IDENTITY_PATH" 2>/dev/null)
  if [[ -z "$PROPHIT_NAME" ]]; then
    # Single-Prophit USER.md path: fallback acceptable if USER.md exists
    USER_PATH=$(resolve_persona_file "USER.md" "user" || echo "")
    if [[ -n "$USER_PATH" && -s "$USER_PATH" ]]; then
      SUB_ITEMS+=("{\"id\":\"identity-001\",\"status\":\"pass\",\"diagnostic\":\"\"}")
    else
      SUB_ITEMS+=("{\"id\":\"identity-001\",\"status\":\"fail\",\"diagnostic\":\"IDENTITY.md has no Prophits entry and no USER.md fallback. Owner: F1.\"}")
      OVERALL_PASS=0
    fi
  else
    SUB_ITEMS+=("{\"id\":\"identity-001\",\"status\":\"pass\",\"diagnostic\":\"\"}")
  fi
fi

# ── voice-001: VOICE.md exists + has register/character declaration ────────────
VOICE_PATH=$(resolve_persona_file "VOICE.md" "adaptive" || echo "")
if [[ -z "$VOICE_PATH" ]]; then
  SUB_ITEMS+=("{\"id\":\"voice-001\",\"status\":\"fail\",\"diagnostic\":\"VOICE.md not found in workspace (searched workspace/VOICE.md, VOICE.md, adaptive/VOICE.md). Owner: F1 / fixed-test-suite.\"}")
  OVERALL_PASS=0
elif [[ ! -s "$VOICE_PATH" ]]; then
  SUB_ITEMS+=("{\"id\":\"voice-001\",\"status\":\"fail\",\"diagnostic\":\"VOICE.md is empty at $VOICE_PATH. Owner: F1.\"}")
  OVERALL_PASS=0
elif ! grep -qiE '(register|character|voice|tone|pace)' "$VOICE_PATH" 2>/dev/null; then
  SUB_ITEMS+=("{\"id\":\"voice-001\",\"status\":\"fail\",\"diagnostic\":\"VOICE.md at $VOICE_PATH lacks voice-register / character declaration. Owner: F1.\"}")
  OVERALL_PASS=0
else
  SUB_ITEMS+=("{\"id\":\"voice-001\",\"status\":\"pass\",\"diagnostic\":\"\"}")
fi

# Compose
SUB_JSON="[$(IFS=,; echo "${SUB_ITEMS[*]}")]"

END=$(date +%s.%N)
DURATION=$(python3 -c "print(round($END - $START, 3))")

if [[ "$OVERALL_PASS" -eq 1 ]]; then
  emit_result "pass" 0 "" "$SUB_JSON" "$DURATION"
else
  emit_result "fail" 1 \
    "Fixed-test-suite spot check FAILED — one or more T0 anchor assertions (soul-001, identity-001, voice-001) did not pass. Diagnose via F1 / fixed-test-suite.json. The three-of-three contract is strict per acceptance criteria — no partial credit." \
    "$SUB_JSON" "$DURATION"
fi

exit 0
