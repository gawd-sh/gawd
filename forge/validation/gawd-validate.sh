#!/usr/bin/env bash
# gawd-validate — First-Ship Validation Suite (orchestrator).
#
# Owned by F3 (METATRON 2026-05-26). Centralizes the three first-ship gates
# distributed across the spec (§5.4, §7.2.1, §15.4) into ONE entry point
# the Forge graduation pipeline and gawd-import self-test both invoke.
#
# F3 does NOT reimplement any validation. It orchestrates B2's, E3's, and
# F1's primitives via wrappers in validations/. Each wrapper black-boxes its
# primitive and emits a uniform per-validation result JSON. This script
# aggregates those into a single suite result.
#
# USAGE
#   gawd-validate first-ship --workspace <path> [--result-file <path>]
#                            [--validations-dir <path>] [--suite-dir <path>]
#                            [--sil-dir <path>] [--quiet]
#
# COMMANDS
#   first-ship    Run all three first-ship validations against the workspace
#                 and emit aggregate JSON + human summary.
#   list          List the validations the suite would run, then exit 0.
#   schema        Print the result-schema.json path and exit 0.
#   version       Print version info and exit 0.
#   help          Show this help.
#
# OPTIONS (first-ship)
#   --workspace <path>          Required. Absolute path to the Gawd workspace
#                               being validated. F1's gawd-import passes the
#                               just-renamed live workspace; F2's graduation
#                               gate passes the unpacked daemon workspace; an
#                               operator passes ~/.gawd or similar.
#   --result-file <path>        Where to write the aggregate result JSON.
#                               Default: ./validation-result.json
#   --validations-dir <path>    Where validations/*.sh live.
#                               Default: <script-dir>/validations
#   --suite-dir <path>          Where canonical.md + fixed-test-suite fragment
#                               live (passed to validations 01 and 03).
#                               Default: <script-dir>
#   --sil-dir <path>            Where E3's gate.sh lives (passed to validation 02).
#                               Default: /usr/local/lib/gawd/sil
#   --quiet                     Suppress per-validation stdout (keep summary).
#
# EXIT CODES (per spec / B2 contract)
#   0  PASS — all validations passed; build may graduate
#   1  FAIL — one or more validations failed OR conditional (any skip with stub_mode)
#   2  TOOL-BROKEN — orchestrator could not run (bad args, missing files,
#                    or a wrapper returned tool-broken)
#
# Note on `conditional` (verdict): F3 distinguishes `pass`, `fail`, and
# `conditional` in the result JSON. At the EXIT CODE level, conditional is
# treated as FAIL (exit 1) because the build is NOT verified end-to-end —
# F2's graduation gate must surface the stub-mode condition to operators
# rather than silently graduate. To explicitly allow conditional graduation
# during E3 in-flight, the caller passes --allow-conditional.
#
# RESULT JSON (full schema: result-schema.json in this same directory)

set -euo pipefail

# ── constants ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_VERSION="1.0.0"
DEFAULT_RESULT_FILE="./validation-result.json"

# ── command dispatch ───────────────────────────────────────────────────────────

CMD="${1:-help}"
[[ $# -gt 0 ]] && shift || true

case "$CMD" in
  first-ship) ;;  # fall through to main flow
  list)
    echo "First-ship validations (in execution order):"
    echo "  01-meeting-playback            (primitive owner: B2)"
    echo "  02-sil-gate-first-fire         (primitive owner: E3)"
    echo "  03-fixed-test-suite-spot-check (primitive owner: F1)"
    exit 0
    ;;
  schema)
    echo "${SCRIPT_DIR}/result-schema.json"
    exit 0
    ;;
  version)
    echo "gawd-validate ${TOOL_VERSION} (F3 / METATRON 2026-05-26)"
    exit 0
    ;;
  help|-h|--help)
    grep '^# ' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "ERROR: unknown command: $CMD (try 'gawd-validate help')" >&2
    exit 2
    ;;
esac

# ── first-ship: option parsing ────────────────────────────────────────────────

WORKSPACE=""
RESULT_FILE="$DEFAULT_RESULT_FILE"
VALIDATIONS_DIR="${SCRIPT_DIR}/validations"
SUITE_DIR="$SCRIPT_DIR"
SIL_DIR="/usr/local/lib/gawd/sil"
QUIET=0
ALLOW_CONDITIONAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)        WORKSPACE="$2"; shift 2 ;;
    --result-file)      RESULT_FILE="$2"; shift 2 ;;
    --validations-dir)  VALIDATIONS_DIR="$2"; shift 2 ;;
    --suite-dir)        SUITE_DIR="$2"; shift 2 ;;
    --sil-dir)          SIL_DIR="$2"; shift 2 ;;
    --quiet)            QUIET=1; shift ;;
    --allow-conditional) ALLOW_CONDITIONAL=1; shift ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unexpected arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$WORKSPACE" ]] || { echo "ERROR: --workspace is required" >&2; exit 2; }

if [[ ! -d "$WORKSPACE" ]]; then
  echo "ERROR: workspace path is not a directory: $WORKSPACE" >&2
  exit 2
fi

# Normalize result-file to absolute path
case "$RESULT_FILE" in
  /*) ;;
  *)  RESULT_FILE="$(pwd)/$RESULT_FILE" ;;
esac

mkdir -p "$(dirname "$RESULT_FILE")"

# ── helpers ────────────────────────────────────────────────────────────────────
log()    { [[ "$QUIET" -eq 1 ]] || echo "$*"; }
banner() { [[ "$QUIET" -eq 1 ]] || echo "[gawd-validate] $*"; }
err()    { echo "[gawd-validate] $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "required command not found: $1"; exit 2; }
}

# ── preflight ──────────────────────────────────────────────────────────────────
require_cmd python3
require_cmd jq
require_cmd sha256sum

if [[ ! -d "$VALIDATIONS_DIR" ]]; then
  err "validations directory missing: $VALIDATIONS_DIR"
  exit 2
fi

for v in 01-meeting-playback.sh 02-sil-gate-first-fire.sh 03-fixed-test-suite-spot-check.sh; do
  if [[ ! -f "${VALIDATIONS_DIR}/$v" ]]; then
    err "missing validation wrapper: ${VALIDATIONS_DIR}/$v"
    exit 2
  fi
  # Ensure executable; chmod is idempotent
  chmod +x "${VALIDATIONS_DIR}/$v" 2>/dev/null || true
done

# ── run validations ────────────────────────────────────────────────────────────

SUITE_START=$(date +%s.%N)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WORK_DIR="$(mktemp -d -t gawd-validate.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

banner "==================================================================="
banner "Gawd v1 First-Ship Validation Suite"
banner "  Workspace:   $WORKSPACE"
banner "  Result file: $RESULT_FILE"
banner "  Timestamp:   $TIMESTAMP"
banner "==================================================================="

# Validation 1 — Meeting playback (B2)
banner ""
banner "--- 1/3 : Meeting playback (primitive owner: B2) ---"
V1_RESULT="$WORK_DIR/01-meeting-playback.result.json"
set +e
"${VALIDATIONS_DIR}/01-meeting-playback.sh" \
  --workspace "$WORKSPACE" \
  --result-file "$V1_RESULT" \
  --suite-dir "$SUITE_DIR"
V1_WRAPPER_EXIT=$?
set -e
if [[ "$V1_WRAPPER_EXIT" -ne 0 ]]; then
  err "validation 1 wrapper exit $V1_WRAPPER_EXIT — orchestrator preflight failed"
  exit 2
fi
V1_STATUS=$(python3 -c "import json; print(json.load(open('$V1_RESULT'))['status'])")
log "  → $V1_STATUS"

# Validation 2 — SIL gate first-fire (E3)
banner ""
banner "--- 2/3 : SIL gate first-fire (primitive owner: E3) ---"
V2_RESULT="$WORK_DIR/02-sil-gate-first-fire.result.json"
set +e
"${VALIDATIONS_DIR}/02-sil-gate-first-fire.sh" \
  --workspace "$WORKSPACE" \
  --result-file "$V2_RESULT" \
  --sil-dir "$SIL_DIR"
V2_WRAPPER_EXIT=$?
set -e
if [[ "$V2_WRAPPER_EXIT" -ne 0 ]]; then
  err "validation 2 wrapper exit $V2_WRAPPER_EXIT — orchestrator preflight failed"
  exit 2
fi
V2_STATUS=$(python3 -c "import json; print(json.load(open('$V2_RESULT'))['status'])")
V2_STUB=$(python3 -c "import json; print(json.load(open('$V2_RESULT')).get('stub_mode', False))")
log "  → $V2_STATUS$([[ "$V2_STUB" == "True" ]] && echo " (stub mode — E3 pending)" || echo "")"

# Validation 3 — Fixed-test-suite spot check (F1)
banner ""
banner "--- 3/3 : Fixed-test-suite spot check (primitive owner: F1) ---"
V3_RESULT="$WORK_DIR/03-fixed-test-suite-spot-check.result.json"
set +e
"${VALIDATIONS_DIR}/03-fixed-test-suite-spot-check.sh" \
  --workspace "$WORKSPACE" \
  --result-file "$V3_RESULT" \
  --suite-dir "$SUITE_DIR"
V3_WRAPPER_EXIT=$?
set -e
if [[ "$V3_WRAPPER_EXIT" -ne 0 ]]; then
  err "validation 3 wrapper exit $V3_WRAPPER_EXIT — orchestrator preflight failed"
  exit 2
fi
V3_STATUS=$(python3 -c "import json; print(json.load(open('$V3_RESULT'))['status'])")
log "  → $V3_STATUS"

SUITE_END=$(date +%s.%N)
DURATION=$(python3 -c "print(round($SUITE_END - $SUITE_START, 3))")

# ── aggregate ──────────────────────────────────────────────────────────────────

AGGREGATE_JSON=$(python3 - "$V1_RESULT" "$V2_RESULT" "$V3_RESULT" \
  "$WORKSPACE" "$TIMESTAMP" "$TOOL_VERSION" "$DURATION" "$RESULT_FILE" <<'PYEOF'
import json, sys
v1_path, v2_path, v3_path, workspace, ts, tool_version, dur, out_path = sys.argv[1:9]

validations = []
for p in (v1_path, v2_path, v3_path):
    with open(p) as f:
        validations.append(json.load(f))

passed       = sum(1 for v in validations if v["status"] == "pass")
failed       = sum(1 for v in validations if v["status"] == "fail")
skipped      = sum(1 for v in validations if v["status"] == "skip")
tool_broken  = sum(1 for v in validations if v["status"] == "tool-broken")
any_stubbed  = any(v.get("stub_mode") for v in validations)

if failed > 0 or tool_broken > 0:
    verdict = "fail"
elif any_stubbed or skipped > 0:
    verdict = "conditional"
else:
    verdict = "pass"

doc = {
    "version": "1.0",
    "tool": "gawd-validate-first-ship",
    "tool_version": tool_version,
    "timestamp": ts,
    "workspace": workspace,
    "duration_sec": float(dur),
    "validations": validations,
    "summary": {
        "verdict": verdict,
        "total": len(validations),
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "tool_broken": tool_broken,
    },
}

with open(out_path, "w") as f:
    json.dump(doc, f, indent=2)

# Print just the verdict so caller can capture it cheaply
print(verdict)
PYEOF
)
VERDICT="$AGGREGATE_JSON"

# ── summary print ──────────────────────────────────────────────────────────────

banner ""
banner "==================================================================="
banner "FIRST-SHIP VALIDATION SUITE — SUMMARY"
banner "==================================================================="

python3 - "$RESULT_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: doc = json.load(f)
def line(s): print(f"[gawd-validate] {s}")
line(f"Workspace:    {doc['workspace']}")
line(f"Duration:     {doc['duration_sec']}s")
line("")
for v in doc["validations"]:
    status = v["status"].upper()
    owner = v["primitive_owner"]
    stub = " [STUB]" if v.get("stub_mode") else ""
    line(f"  [{owner}] {v['id']:<35} : {status}{stub}")
    for sa in v.get("sub_assertions", []):
        line(f"          {sa['id']:<35}   : {sa['status']}")
    if v.get("diagnostic_message"):
        line(f"          DIAG: {v['diagnostic_message']}")
line("")
s = doc["summary"]
line(f"Verdict: {s['verdict'].upper()}  ({s['passed']} pass, {s['failed']} fail, {s['skipped']} skip, {s['tool_broken']} tool-broken)")
PYEOF

banner "==================================================================="
banner ""

# ── exit code ──────────────────────────────────────────────────────────────────

case "$VERDICT" in
  pass)
    banner "GRADUATION-ELIGIBLE on first-ship validation."
    exit 0
    ;;
  conditional)
    if [[ "$ALLOW_CONDITIONAL" -eq 1 ]]; then
      banner "CONDITIONAL PASS — operator opted in via --allow-conditional."
      banner "Stubbed validations indicate upstream primitive(s) not yet shipped."
      exit 0
    else
      banner "CONDITIONAL — one or more validations are stubbed (upstream primitive pending)."
      banner "F2 graduation gate MUST surface this rather than silently graduate."
      banner "Pass --allow-conditional to override (e.g., E3 still in-flight)."
      exit 1
    fi
    ;;
  fail|*)
    err "FIRST-SHIP VALIDATION FAILED. Build is NOT graduation-eligible."
    err "Diagnose via the primitive_owner of each failing validation:"
    err "  B2 = meeting-playback-test handoff (METATRON)"
    err "  E3 = sil-gate-and-tithing-abstraction handoff (LOGOS)"
    err "  F1 = migration-mechanism handoff (METATRON)"
    exit 1
    ;;
esac
