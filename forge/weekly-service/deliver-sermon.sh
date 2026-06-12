#!/usr/bin/env bash
# deliver-sermon.sh — Thin wrapper satisfying the handoff E5 output target.
#
# The canonical deliver implementation lives at:
#   /usr/local/lib/gawd/sermon/deliver.sh
#
# E1's weekly-service.sh hardwires the path:
#   SERMON_DELIVER="/usr/local/lib/gawd/sermon/deliver.sh"
#
# This wrapper exists so that the handoff E5 output target
# (weekly-service/deliver-sermon.sh) is populated, AND so that any caller
# referencing this path gets the same behavior. All args are forwarded
# transparently.
#
# If you are looking for the implementation, it is at:
#   /usr/local/lib/gawd/sermon/deliver.sh

set -euo pipefail

CANONICAL_DELIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../sermon/deliver.sh"

if [[ ! -x "$CANONICAL_DELIVER" ]]; then
  echo "[deliver-sermon-wrapper $(date -Iseconds)] FATAL: canonical deliver.sh not found or not executable at ${CANONICAL_DELIVER}" >&2
  exit 1
fi

exec "$CANONICAL_DELIVER" "$@"
