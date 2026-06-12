#!/usr/bin/env bash
# apply-or-archive.sh — Thin shim called by E1's daily-reset.sh
#
# E1's daily-reset.sh §2 calls:
#     /usr/local/lib/gawd/sil/apply-or-archive.sh \
#         --workspace "$GAWD_WORKSPACE" \
#         --state "$GAWD_STATE_DIR"
#
# This shim translates that call to gate.sh batch mode. In v1:
#   - There is NO auto-decline for SIL (spec §15; explicitly distinct from
#     revelation's 3-Sunday auto-decline).
#   - Pending proposals stay pending indefinitely until the Prophit responds.
#   - The batch mode exists so future v1.1 enhancements (e.g., stale-sweep
#     after N months with operator confirm) have a single place to land.
#
# Exit codes propagated from gate.sh batch.

set -euo pipefail

WORKSPACE=""
STATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --state)     STATE="$2"; shift 2 ;;
        *) echo "[apply-or-archive] unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$WORKSPACE" ]]; then
    export GAWD_WORKSPACE="$WORKSPACE"
fi
if [[ -n "$STATE" ]]; then
    export GAWD_STATE_DIR="$STATE"
fi

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate.sh"
[[ -x "$GATE" ]] || { echo "[apply-or-archive] gate.sh not executable at $GATE" >&2; exit 1; }

exec "$GATE" batch
