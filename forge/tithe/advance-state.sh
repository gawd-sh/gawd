#!/usr/bin/env bash
# advance-state.sh — Thin shim called by E1's daily-reset.sh
#
# E1's daily-reset.sh §3 calls:
#     /usr/local/lib/gawd/tithe/advance-state.sh \
#         --workspace "$GAWD_WORKSPACE" \
#         --state "$GAWD_STATE_DIR"
#
# This shim translates that call to the canonical money-voice state machine's
# advance-4am subcommand. Per spec §12.4: state transitions are evaluated at
# the daily 4am session reset, not in real-time.
#
# Why this path (not /usr/local/lib/gawd/tithing/...): E1's daily-reset.sh
# was authored before E3 settled on the "tithing" subdirectory name. To avoid
# touching E1, we provide the script at the legacy path; the canonical state
# machine implementation lives at /usr/local/lib/gawd/tithing/state-machine.sh.
#
# Exit codes propagated from state-machine.sh advance-4am.

set -euo pipefail

WORKSPACE=""
STATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --state)     STATE="$2"; shift 2 ;;
        *) echo "[advance-state] unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$WORKSPACE" ]]; then
    export GAWD_WORKSPACE="$WORKSPACE"
fi
if [[ -n "$STATE" ]]; then
    export GAWD_STATE_DIR="$STATE"
fi

CANONICAL="/usr/local/lib/gawd/tithing/state-machine.sh"
[[ -x "$CANONICAL" ]] || { echo "[advance-state] state-machine.sh not executable at $CANONICAL" >&2; exit 1; }

exec "$CANONICAL" advance-4am
