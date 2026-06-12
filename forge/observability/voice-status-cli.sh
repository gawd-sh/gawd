#!/usr/bin/env bash
# voice-status-cli.sh — CLI surface for write_voice_status.
#
# Used by D2's voice-relay systemd ExecStartPre/ExecStopPost (and any future
# voice-side health-check shim) to publish state without bundling shell
# logic inside the Node process.
#
# Usage:
#   voice-status-cli.sh <state> <reason> [stt_failures] [tts_failures]
#
# Examples:
#   voice-status-cli.sh active enabled_ok 0 0
#   voice-status-cli.sh degraded provider_failure_stt 3 0
#   voice-status-cli.sh stopped shutdown_normal 0 0
#
# Exit codes:
#   0  status written
#   2  invalid args
#
# Idempotent. Safe to call from ExecStopPost even if relay never started.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/usr/local/lib/gawd/observability/voice-status.sh
source "$SCRIPT_DIR/voice-status.sh"

if [[ $# -lt 2 ]]; then
    cat >&2 <<'EOF'
Usage: voice-status-cli.sh <state> <reason> [stt_failures] [tts_failures]
  state:  active | degraded | disabled | stopped | unknown
  reason: short enum (see voice-status.sh)
EOF
    exit 2
fi

write_voice_status "$1" "$2" "${3:-0}" "${4:-0}"
