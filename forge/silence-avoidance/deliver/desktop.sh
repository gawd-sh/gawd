#!/usr/bin/env bash
# deliver/desktop.sh — Desktop notification fallback delivery.
#
# Wraps notify-send. Per spec §19.5 desktop template is plain text, under
# 100 chars (notify-send display limit).
#
# Usage:
#   deliver/desktop.sh <prophit_id> <rendered_text>
#
# Environment:
#   DISPLAY        — required for notify-send to reach the user's session
#   DBUS_SESSION_BUS_ADDRESS — required for the bus
#
# Exit:
#   0  notify-send returned 0
#   1  notify-send unavailable or failed

set -euo pipefail

prophit_id="${1:-}"
message="${2:-}"

if [[ -z "$prophit_id" || -z "$message" ]]; then
    printf 'usage: deliver/desktop.sh <prophit_id> <message>\n' >&2
    exit 1
fi

# Source logger.
if [[ -f /usr/local/lib/gawd/observability/logger.sh ]]; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source /usr/local/lib/gawd/observability/logger.sh
else
    log_info()  { printf '[fb-desktop] [info]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_warn()  { printf '[fb-desktop] [warn]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_error() { printf '[fb-desktop] [error] %s: %s\n'  "${1:-}" "${*:2}" >&2; }
fi

# Dry-network mode for tests.
if [[ "${GAWD_FALLBACK_NO_NETWORK:-0}" == "1" ]]; then
    log_info fb-desktop "GAWD_FALLBACK_NO_NETWORK=1 — would notify-send ${#message} bytes prophit=$prophit_id"
    exit 0
fi

if ! command -v notify-send >/dev/null 2>&1; then
    log_error fb-desktop "notify-send not installed; cannot deliver desktop notification"
    exit 1
fi

# Summary stays short ("Gawd"); body is the rendered message.
# Urgency normal; icon dialog-information (degraded state is informational,
# not a system error in the Prophit's eyes).
if ! notify-send \
    --urgency=normal \
    --icon=dialog-information \
    --app-name="Gawd" \
    "Gawd" \
    "$message" 2>/dev/null
then
    log_error fb-desktop "notify-send returned non-zero prophit=$prophit_id"
    exit 1
fi

log_info fb-desktop "delivered prophit=$prophit_id bytes=${#message}"
exit 0
