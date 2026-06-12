#!/usr/bin/env bash
# memory_recall.sh — the single recall surface. Fans out to all tiers in
# parallel, merges, returns ONE provenance-tagged block. Recall NEVER fails
# because a tier is down (spec §3.2 rule 4, §8).
set -uo pipefail
QUERY="${1:?usage: memory_recall.sh <query> [budget]}"
BUDGET="${2:-2000}"
LIB="$(cd "$(dirname "$0")/lib" && pwd)"
source "${LIB}/tier-probes.sh"

# Run probes in parallel, collect to temp files to preserve outputs.
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
probe_t1 "$QUERY" >"$d/t1" 2>/dev/null & p1=$!
probe_t2 "$QUERY" >"$d/t2" 2>/dev/null & p2=$!
probe_t3a "$QUERY" >"$d/t3a" 2>/dev/null & p3=$!
probe_t3b "$QUERY" >"$d/t3b" 2>/dev/null & p4=$!
wait $p1 $p2 $p3 $p4

python3 - "$BUDGET" "$d" "$LIB" <<'PY'
import sys,json,os
budget=int(sys.argv[1]); d=sys.argv[2]; lib=sys.argv[3]
def load(f):
    try: return json.load(open(os.path.join(d,f)))
    except Exception: return []
tiers={"T1":load("t1"),"T2":load("t2"),"T3a":load("t3a"),"T3b":load("t3b")}
import subprocess
# Primary: lib dir passed via argv (works regardless of cwd or __file__ being <stdin>).
# Fallback: hardcoded /usr/local install path.
_local=os.path.join(lib,"recall-merge.py")
_fallback="/usr/local/lib/gawd/memory/lib/recall-merge.py"
merge_py=_local if os.path.exists(_local) else _fallback
p=subprocess.run([sys.executable, merge_py,"--budget",str(budget)],
                 input=json.dumps(tiers),capture_output=True,text=True)
sys.stdout.write(p.stdout if p.returncode==0 else json.dumps({"entries":[],"note":"merge-error"}))
PY
