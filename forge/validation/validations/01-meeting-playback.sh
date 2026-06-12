#!/usr/bin/env bash
# 01-meeting-playback.sh — F3 wrapper around B2's meeting-playback primitive.
#
# CONTRACT (F3 internal)
#   Invoked by gawd-validate.sh with:
#     --workspace <path>         absolute path to the Gawd workspace under test
#     --result-file <path>       where to write THIS wrapper's per-validation JSON
#     --suite-dir <path>         where canonical.md / fixtures live (optional;
#                                defaults to /usr/local/lib/gawd/validation)
#
# PRIMITIVE OWNERSHIP
#   B2 owns meeting-playback.sh. We invoke it as a black box and respect its
#   contract:
#     - exit 0 = all B2 assertions PASS
#     - exit 1 = one or more B2 assertions FAIL
#     - exit 2 = invocation error (TOOL-BROKEN)
#   F3 does NOT reimplement B2's assertions; we capture B2's result file and
#   forward its sub-assertions into our schema.
#
# RESULT FILE (this wrapper writes)
#   Matches the `validations[]` item in result-schema.json:
#     {
#       "id": "meeting-playback",
#       "status": "pass" | "fail" | "tool-broken",
#       "primitive_owner": "B2",
#       "primitive_path": "...",
#       "exit_code": <int>,
#       "duration_sec": <float>,
#       "diagnostic_message": "...",
#       "sub_assertions": [ ... from B2's result ],
#       "primitive_result_file": "...",
#       "stub_mode": false
#     }
#
# EXIT CODE
#   This wrapper always exits 0 if it could write the result file.  It exits
#   non-zero ONLY on invocation error (bad args, can't write result).  The
#   pass/fail/tool-broken outcome is encoded in the result file; the orchestrator
#   reads it.

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

PRIMITIVE="${SUITE_DIR}/meeting-playback.sh"

# Resolve canonical.md + IDENTITY.md.
# Per spec §5.4 the Meeting playback runs against the Gawd's actual IDENTITY.md.
# Two locations to check inside the workspace, in priority order:
#   1. <workspace>/workspace/IDENTITY.md  (F1 flat materialized view)
#   2. <workspace>/IDENTITY.md            (direct flat layout)
#   3. <workspace>/soul/IDENTITY.md       (F1 hierarchical layout)
# canonical.md ships in the SUITE_DIR (B2 placeholder until B1 lands).

IDENTITY=""
for candidate in \
  "$WORKSPACE/workspace/IDENTITY.md" \
  "$WORKSPACE/IDENTITY.md" \
  "$WORKSPACE/soul/IDENTITY.md"; do
  if [[ -f "$candidate" ]]; then
    IDENTITY="$candidate"
    break
  fi
done

CANONICAL="${SUITE_DIR}/meeting/canonical.md"

emit_result() {
  local status="$1"
  local exit_code="$2"
  local diag="$3"
  local prim_result="${4:-}"
  local sub_assertions_json="${5:-[]}"
  local stub="${6:-false}"
  local duration="${7:-0}"

  # Pass strings via argv (json-safe); pass numerics/raw-json via env (validated).
  STATUS="$status" \
  PRIMITIVE_PATH="$PRIMITIVE" \
  EXIT_CODE="$exit_code" \
  DURATION="$duration" \
  DIAG="$diag" \
  PRIM_RESULT="$prim_result" \
  SUB_JSON="$sub_assertions_json" \
  STUB_MODE="$stub" \
  RESULT_FILE_OUT="$RESULT_FILE" \
  python3 - <<'PYEOF'
import json, os
sub = json.loads(os.environ["SUB_JSON"]) if os.environ["SUB_JSON"].strip() else []
stub = os.environ["STUB_MODE"].lower() in ("1", "true", "yes")
doc = {
    "id": "meeting-playback",
    "status": os.environ["STATUS"],
    "primitive_owner": "B2",
    "primitive_path": os.environ["PRIMITIVE_PATH"],
    "exit_code": int(os.environ["EXIT_CODE"]),
    "duration_sec": float(os.environ["DURATION"]),
    "diagnostic_message": os.environ["DIAG"],
    "sub_assertions": sub,
    "primitive_result_file": os.environ["PRIM_RESULT"],
    "stub_mode": stub,
}
with open(os.environ["RESULT_FILE_OUT"], "w") as f:
    json.dump(doc, f, indent=2)
PYEOF
}

# Preflight checks
if [[ ! -x "$PRIMITIVE" ]]; then
  emit_result "tool-broken" 2 \
    "B2 primitive not found or not executable at $PRIMITIVE — escalate to B2 (METATRON 2026-05-26)" \
    "" "[]" "false" "0"
  exit 0
fi

if [[ -z "$IDENTITY" ]]; then
  emit_result "tool-broken" 2 \
    "IDENTITY.md not found in workspace (searched workspace/IDENTITY.md, IDENTITY.md, soul/IDENTITY.md). Workspace may not be a valid Gawd workspace. Primitive owner: B2 expects an IDENTITY.md to render against." \
    "" "[]" "false" "0"
  exit 0
fi

if [[ ! -f "$CANONICAL" ]]; then
  emit_result "tool-broken" 2 \
    "Meeting canonical.md not found at $CANONICAL (B2 ships the placeholder; check forge/validation/meeting/). Primitive owner: B2." \
    "" "[]" "false" "0"
  exit 0
fi

# Invoke B2 primitive
PRIM_RESULT="$(mktemp -t meeting-playback-result.XXXXXX.json)"
START=$(date +%s.%N)
set +e
"$PRIMITIVE" \
  --canonical   "$CANONICAL" \
  --identity    "$IDENTITY" \
  --result-file "$PRIM_RESULT" \
  > /tmp/meeting-playback.stdout.$$ 2> /tmp/meeting-playback.stderr.$$
EXIT_CODE=$?
set -e
END=$(date +%s.%N)
DURATION=$(python3 -c "print(round($END - $START, 3))")

# Parse B2's result and forward sub-assertions
SUB_JSON="[]"
DIAG=""
STATUS=""

case "$EXIT_CODE" in
  0)
    STATUS="pass"
    DIAG=""
    ;;
  1)
    STATUS="fail"
    DIAG="Meeting playback FAILED — one or more B2 structural assertions did not pass. Diagnose via B2 (primitive owner). See primitive_result_file for per-assertion detail."
    ;;
  2)
    STATUS="tool-broken"
    DIAG="Meeting playback primitive returned TOOL-BROKEN (exit 2 — invocation error). Diagnose B2's meeting-playback.sh: $(head -c 200 /tmp/meeting-playback.stderr.$$ 2>/dev/null || true)"
    ;;
  *)
    STATUS="tool-broken"
    DIAG="Meeting playback primitive returned unexpected exit code $EXIT_CODE — B2 contract violated. Escalate to B2."
    ;;
esac

if [[ -f "$PRIM_RESULT" ]]; then
  SUB_JSON=$(python3 - "$PRIM_RESULT" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        doc = json.load(f)
    sub = []
    for a in doc.get("assertions", []):
        sub.append({
            "id": a.get("id", "unknown"),
            "status": a.get("status", "unknown"),
            "diagnostic": a.get("diagnostic", "")
        })
    print(json.dumps(sub))
except Exception as e:
    print("[]")
PYEOF
)
fi

emit_result "$STATUS" "$EXIT_CODE" "$DIAG" "$PRIM_RESULT" "$SUB_JSON" "false" "$DURATION"

rm -f /tmp/meeting-playback.stdout.$$ /tmp/meeting-playback.stderr.$$ 2>/dev/null || true
exit 0
