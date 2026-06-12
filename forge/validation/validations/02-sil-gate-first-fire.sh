#!/usr/bin/env bash
# 02-sil-gate-first-fire.sh — F3 wrapper around E3's SIL-gate primitive.
#
# STUB STATUS (2026-05-26)
#   E3 (sil-gate-and-tithing-abstraction) has NOT shipped at the time this
#   wrapper was written. The wrapper IS the interface contract — it documents
#   what E3 must produce. While E3 is in-flight, this wrapper runs in STUB
#   mode and emits a `skip` result with `stub_mode: true`. The aggregate
#   verdict in gawd-validate.sh becomes `conditional` rather than `pass`,
#   surfacing the gap to F2 (graduation gate) and operators.
#
# STUB-CUTOVER TOKEN: E3_F3_STUB_CUTOVER
#   When E3 lands, grep this file for the token and remove the stub branch.
#
# CONTRACT WE EXPECT FROM E3 (the interface this wrapper drives)
#
#   E3 ships:
#     /usr/local/lib/gawd/sil/gate.sh
#     /usr/local/lib/gawd/sil/proposal-template.md
#
#   Invocation contract (gate.sh):
#     gate.sh propose \
#       --proposal-file <path>          read a SIL proposal from this file
#       --workspace <path>              the live Gawd workspace
#       [--scripted-input <accept|reject>]  scripted-Prophit mode; bypasses Telegram
#       [--result-file <path>]          where gate.sh writes its own JSON result
#
#   gate.sh exit codes:
#     0  proposal handled per scripted-input (accept → applied; reject → archived)
#     1  proposal handled but a step failed (e.g., apply-to-soul-anchor failed)
#     2  invocation error (TOOL-BROKEN)
#
#   Filesystem post-conditions (workspace-relative):
#     workspace/sil/pending/<proposal-id>.md     created at propose time
#     workspace/sil/archived/<proposal-id>.md    after accept or reject
#     workspace/<target>.md                       mutated only on accept,
#                                                 only via the perm-aware A2 path
#
# PRE-CUTOVER (current behavior): If gate.sh is missing, emit a `skip`
# result with `stub_mode: true` and a diagnostic that cites E3.
#
# POST-CUTOVER (when E3 ships): drives gate.sh in both accept-path and
# reject-path, asserts the filesystem invariants above, and emits pass/fail.
#
# CONTRACT (F3 internal)
#   Invoked by gawd-validate.sh with:
#     --workspace <path>     absolute path to the Gawd workspace under test
#     --result-file <path>   where to write this wrapper's per-validation JSON
#     --sil-dir <path>       where E3's gate.sh lives (default: /usr/local/lib/gawd/sil)
#
# RESULT FILE matches result-schema.json's validations[] item.

set -euo pipefail

WORKSPACE=""
RESULT_FILE=""
SIL_DIR="/usr/local/lib/gawd/sil"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)   WORKSPACE="$2"; shift 2 ;;
    --result-file) RESULT_FILE="$2"; shift 2 ;;
    --sil-dir)     SIL_DIR="$2"; shift 2 ;;
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

GATE_PRIMITIVE="${SIL_DIR}/gate.sh"
PROPOSAL_TEMPLATE="${SIL_DIR}/proposal-template.md"

emit_result() {
  local status="$1"
  local exit_code="$2"
  local diag="$3"
  local sub_json="${4:-[]}"
  local stub="${5:-false}"
  local duration="${6:-0}"
  local prim_result="${7:-}"

  STATUS="$status" \
  PRIMITIVE_PATH="$GATE_PRIMITIVE" \
  EXIT_CODE="$exit_code" \
  DURATION="$duration" \
  DIAG="$diag" \
  PRIM_RESULT="$prim_result" \
  SUB_JSON="$sub_json" \
  STUB_MODE="$stub" \
  RESULT_FILE_OUT="$RESULT_FILE" \
  python3 - <<'PYEOF'
import json, os
sub = json.loads(os.environ["SUB_JSON"]) if os.environ["SUB_JSON"].strip() else []
stub = os.environ["STUB_MODE"].lower() in ("1", "true", "yes")
doc = {
    "id": "sil-gate-first-fire",
    "status": os.environ["STATUS"],
    "primitive_owner": "E3",
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

# ── E3_F3_STUB_CUTOVER: stub branch ────────────────────────────────────────────
# While E3 is in-flight, emit a skip-with-diagnostic and return.
# When E3 lands, remove this branch and let the real flow below execute.

if [[ ! -x "$GATE_PRIMITIVE" ]]; then
  STUB_DIAG="E3 SIL-gate primitive not present at $GATE_PRIMITIVE — STUB MODE. This validation is SKIPPED (status=skip, stub_mode=true). Aggregate verdict will be 'conditional'. When E3 ships, this branch self-disables (primitive becomes executable). E3_F3_STUB_CUTOVER token marks the removal point if the file-presence check is replaced. Primitive owner: E3 (sil-gate-and-tithing-abstraction)."
  STUB_SUB=$(cat <<'EOF'
[
  {"id": "sil-pending-write", "status": "skip", "diagnostic": "E3 not yet shipped"},
  {"id": "sil-accept-applies", "status": "skip", "diagnostic": "E3 not yet shipped"},
  {"id": "sil-reject-preserves", "status": "skip", "diagnostic": "E3 not yet shipped"}
]
EOF
)
  emit_result "skip" 0 "$STUB_DIAG" "$STUB_SUB" "true" "0"
  exit 0
fi
# ── end stub branch ────────────────────────────────────────────────────────────

# ── REAL FLOW (executes once E3 ships gate.sh) ─────────────────────────────────
# Two-path validation using E3's actual gate.sh surface:
#   accept-path: draft → apply (direct --proposal-id, with stub apply-impl)
#   reject-path: draft → reject (direct --proposal-id)
#
# gate.sh uses GAWD_WORKSPACE to locate its sil/pending and sil/archived dirs.
# We set GAWD_WORKSPACE=$WORKSPACE so all I/O stays inside the test workspace.

START=$(date +%s.%N)

# Resolve target soul-anchor file (VOICE.md preferred for first-fire to avoid touching SOUL/IDENTITY)
TARGET_FILE=""
for candidate in \
  "$WORKSPACE/workspace/VOICE.md" \
  "$WORKSPACE/VOICE.md" \
  "$WORKSPACE/adaptive/VOICE.md"; do
  if [[ -f "$candidate" ]]; then
    TARGET_FILE="$candidate"
    break
  fi
done

if [[ -z "$TARGET_FILE" ]]; then
  emit_result "tool-broken" 2 \
    "No VOICE.md found in workspace to use as SIL-gate target. Searched workspace/VOICE.md, VOICE.md, adaptive/VOICE.md. Primitive owner: E3 (validation needs a target soul-anchor file)." \
    "[]" "false" "0"
  exit 0
fi

# ── Ephemeral temp files ────────────────────────────────────────────────────────

TMPDIR_V2=$(mktemp -d -t sil-v2.XXXXXX)
trap 'rm -rf "$TMPDIR_V2" /tmp/sil-gate-accept.out.$$ /tmp/sil-gate-reject.out.$$ 2>/dev/null || true' EXIT

PROPOSAL_ID="ff-$(date -u +%Y%m%dT%H%M%S)"
PROPOSAL_REJ_ID="ff-rej-$(date -u +%Y%m%dT%H%M%S)"
ACCEPT_MARKER="f3-first-fire-${PROPOSAL_ID}"
CONTENT_FILE="${TMPDIR_V2}/content.md"
CONTENT_REJ_FILE="${TMPDIR_V2}/content-rej.md"
STUB_APPLY="${TMPDIR_V2}/stub-soul-apply.sh"

# Content for the accept-path proposal: append a trackable marker line.
# gate.sh draft wraps this in <<<NEW-CONTENT-BEGIN>>> / <<<NEW-CONTENT-END>>> sentinels.
# The stub apply-impl appends the content section to VOICE.md, enabling assertion B.
cat > "$CONTENT_FILE" << CONTENT_EOF
<!-- ${ACCEPT_MARKER} -->
CONTENT_EOF

# Content for the reject-path proposal (different marker, no tracking needed)
cat > "$CONTENT_REJ_FILE" << CONTENT_EOF
<!-- f3-first-fire-${PROPOSAL_REJ_ID} -->
CONTENT_EOF

# Stub gawd-soul-apply: extracts the <<<NEW-CONTENT-BEGIN>>> / <<<NEW-CONTENT-END>>>
# section from the proposal file and appends it to the target file.
# This stands in for A2's real gawd-soul-apply until A2 lands.
# Note: temporarily forces the target file writable (like A2 does via perm-aware
# path) so the stub can append even when T0 anchors are chmod 0444/0400.
cat > "$STUB_APPLY" << 'STUB_EOF'
#!/usr/bin/env bash
# Stub gawd-soul-apply — for F3 first-fire validation only.
# Usage: stub-soul-apply.sh <proposal-file> <target-file>
PROPOSAL="$1"
TARGET="$2"
[[ -f "$PROPOSAL" ]] || { echo "ERROR: proposal not found: $PROPOSAL" >&2; exit 2; }
[[ -f "$TARGET" ]]   || { echo "ERROR: target not found: $TARGET" >&2; exit 2; }
# Capture original mode so we can restore it after writing
ORIG_MODE=$(stat -c '%a' "$TARGET" 2>/dev/null || stat -f '%A' "$TARGET")
# Temporarily make writable so we can append the new content
chmod u+w "$TARGET" || { echo "ERROR: could not chmod target writable: $TARGET" >&2; exit 2; }
python3 - "$PROPOSAL" "$TARGET" <<'PYEOF'
import sys
BEGIN = '<<<NEW-CONTENT-BEGIN>>>'
END   = '<<<NEW-CONTENT-END>>>'
proposal_path, target_path = sys.argv[1], sys.argv[2]
with open(proposal_path, encoding='utf-8') as f:
    text = f.read()
b = text.find(BEGIN)
e = text.find(END)
if b == -1 or e == -1:
    print('ERROR: sentinels not found in proposal', file=sys.stderr)
    sys.exit(2)
content = text[b + len(BEGIN):e].strip()
with open(target_path, 'a', encoding='utf-8') as f:
    f.write('\n' + content + '\n')
PYEOF
PY_EXIT=$?
# Restore original mode
chmod "$ORIG_MODE" "$TARGET" 2>/dev/null || true
exit "$PY_EXIT"
STUB_EOF
chmod +x "$STUB_APPLY"

# gate.sh computes target_path as ${GAWD_WORKSPACE}/${target} (e.g. VOICE.md).
# We must set GAWD_WORKSPACE to the parent directory of TARGET_FILE so that
# gate.sh resolves the file correctly.  This also defines where sil/pending and
# sil/archived live (under GAWD_WORKSPACE/sil/).
GAWD_WORKSPACE_V2=$(dirname "$TARGET_FILE")
export GAWD_WORKSPACE="$GAWD_WORKSPACE_V2"

PENDING_DIR="${GAWD_WORKSPACE_V2}/sil/pending"
ARCHIVED_DIR="${GAWD_WORKSPACE_V2}/sil/archived"

# ── STEP 1: draft the accept-path proposal ─────────────────────────────────────

DRAFT_OUT="${TMPDIR_V2}/draft-accept.out"
set +e
GAWD_WORKSPACE="$GAWD_WORKSPACE_V2" "$GATE_PRIMITIVE" draft \
  --target VOICE.md \
  --cycle  "f3-first-fire" \
  --content-file "$CONTENT_FILE" \
  --proposal-id  "$PROPOSAL_ID" \
  > "$DRAFT_OUT" 2>&1
DRAFT_EXIT=$?
set -e

# gate.sh draft prints the pending proposal file path to stdout on success

OVERALL_PASS=1

# Sub-assertion status and diagnostic are collected in a JSONL file to avoid
# shell-level JSON quoting issues — gate.sh log output contains JSON itself,
# which would break naive string interpolation in the array items.
SUB_FILE="${TMPDIR_V2}/sub-assertions.jsonl"
: > "$SUB_FILE"

append_sub() {
  # append_sub <id> <status> <diagnostic>
  local sub_id="$1" sub_status="$2" sub_diag="$3"
  python3 -c "
import json, sys
print(json.dumps({'id': sys.argv[1], 'status': sys.argv[2], 'diagnostic': sys.argv[3]}))
" "$sub_id" "$sub_status" "$sub_diag" >> "$SUB_FILE"
}

# Assertion A: sil/pending/<id>.md exists after draft
if [[ "$DRAFT_EXIT" -eq 0 ]] && [[ -f "${PENDING_DIR}/${PROPOSAL_ID}.md" ]]; then
  append_sub "sil-pending-write" "pass" ""
else
  DIAG_A="gate.sh draft failed (exit=${DRAFT_EXIT}) or pending file not found at ${PENDING_DIR}/${PROPOSAL_ID}.md. Owner: E3."
  append_sub "sil-pending-write" "fail" "$DIAG_A"
  OVERALL_PASS=0
fi

# ── STEP 2: apply the accept-path proposal ─────────────────────────────────────
# Use --proposal-id + --apply-impl (direct call, not --scripted-input) so we can
# inject the stub apply-impl. --scripted-input would also work but cannot pass
# --apply-impl, requiring /usr/local/bin/gawd-soul-apply which may not exist yet.

ACCEPT_EXIT=1
if [[ "$DRAFT_EXIT" -eq 0 ]]; then
  set +e
  GAWD_WORKSPACE="$GAWD_WORKSPACE_V2" "$GATE_PRIMITIVE" apply \
    --proposal-id  "$PROPOSAL_ID" \
    --apply-impl   "$STUB_APPLY" \
    > /tmp/sil-gate-accept.out.$$ 2>&1
  ACCEPT_EXIT=$?
  set -e
fi

# Assertion B: accept-path applied the marker to the target file
if [[ "$ACCEPT_EXIT" -eq 0 ]] && grep -qF "$ACCEPT_MARKER" "$TARGET_FILE" 2>/dev/null; then
  append_sub "sil-accept-applies" "pass" ""
  # Remove the marker so we don't leave validation-noise in VOICE.md.
  # The file may be read-only (0444) after A2 runs, so temporarily chmod writable.
  chmod u+w "$TARGET_FILE" 2>/dev/null || true
  python3 -c "
import sys, os, stat as _stat
path = '$TARGET_FILE'
marker = '<!-- $ACCEPT_MARKER -->'
with open(path) as f: content = f.read()
content = content.replace(marker + '\n', '').replace(marker, '')
with open(path, 'w') as f: f.write(content)
" 2>/dev/null || true
  chmod u-w "$TARGET_FILE" 2>/dev/null || true
else
  DIAG_B="Accept-path did not apply marker to ${TARGET_FILE}. gate.sh apply exit=${ACCEPT_EXIT}. Owner: E3 (verify apply path uses stub-apply-impl)."
  append_sub "sil-accept-applies" "fail" "$DIAG_B"
  OVERALL_PASS=0
fi

# ── STEP 3: draft + reject the reject-path proposal ────────────────────────────

PRE_REJECT_HASH=$(sha256sum "$TARGET_FILE" | awk '{print $1}')

DRAFT_REJ_OUT="${TMPDIR_V2}/draft-rej.out"
set +e
GAWD_WORKSPACE="$GAWD_WORKSPACE_V2" "$GATE_PRIMITIVE" draft \
  --target VOICE.md \
  --cycle  "f3-first-fire-rej" \
  --content-file "$CONTENT_REJ_FILE" \
  --proposal-id  "$PROPOSAL_REJ_ID" \
  > "$DRAFT_REJ_OUT" 2>&1
DRAFT_REJ_EXIT=$?
set -e

REJECT_EXIT=1
if [[ "$DRAFT_REJ_EXIT" -eq 0 ]]; then
  set +e
  GAWD_WORKSPACE="$GAWD_WORKSPACE_V2" "$GATE_PRIMITIVE" reject \
    --proposal-id "$PROPOSAL_REJ_ID" \
    --reason      "f3-validation-reject-test" \
    > /tmp/sil-gate-reject.out.$$ 2>&1
  REJECT_EXIT=$?
  set -e
fi

POST_REJECT_HASH=$(sha256sum "$TARGET_FILE" | awk '{print $1}')

# Assertion C: reject-path left target file unchanged
if [[ "$REJECT_EXIT" -eq 0 ]] && [[ "$PRE_REJECT_HASH" == "$POST_REJECT_HASH" ]]; then
  append_sub "sil-reject-preserves" "pass" ""
else
  if [[ "$PRE_REJECT_HASH" != "$POST_REJECT_HASH" ]]; then
    append_sub "sil-reject-preserves" "fail" "Reject-path MUTATED target soul-anchor file — CRITICAL gate violation. Pre-hash=${PRE_REJECT_HASH} Post-hash=${POST_REJECT_HASH}. Owner: E3."
  else
    append_sub "sil-reject-preserves" "fail" "Reject-path failed: draft_exit=${DRAFT_REJ_EXIT} reject_exit=${REJECT_EXIT}. Owner: E3."
  fi
  OVERALL_PASS=0
fi

# ── Compose result — build SUB_JSON from JSONL file via Python (safe encoding) ──

SUB_JSON=$(python3 -c "
import json, sys
lines = open('$SUB_FILE').read().strip().splitlines()
items = [json.loads(l) for l in lines if l.strip()]
print(json.dumps(items))
")

END=$(date +%s.%N)
DURATION=$(python3 -c "print(round($END - $START, 3))")

ACCEPT_RESULT="${ARCHIVED_DIR}/${PROPOSAL_ID}.applied.md"

if [[ "$OVERALL_PASS" -eq 1 ]]; then
  emit_result "pass" 0 "" "$SUB_JSON" "false" "$DURATION" "$ACCEPT_RESULT"
else
  emit_result "fail" 1 \
    "SIL gate first-fire FAILED — one or more sub-assertions failed. Diagnose via E3 (primitive owner: sil-gate-and-tithing-abstraction)." \
    "$SUB_JSON" "false" "$DURATION" "$ACCEPT_RESULT"
fi

exit 0
