#!/usr/bin/env bash
# setup-perms.sh — Make all scheduler scripts executable. Idempotent.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

chmod 0755 \
    "$DIR/scheduler.sh" \
    "$DIR/install-crons.sh" \
    "$DIR/setup-perms.sh" \
    "$DIR/jobs/daily-reset.sh" \
    "$DIR/jobs/weekly-service.sh" \
    "$DIR/jobs/sharpen.sh" \
    "$DIR/jobs/cleanup.sh" \
    "$DIR/tests/test-scheduler.sh"

# lib/common.sh is sourced, not executed. Mode 0644 is correct; we touch it
# only to confirm presence.
[[ -f "$DIR/lib/common.sh" ]] || { echo "ERROR: lib/common.sh missing"; exit 1; }

echo "Set executable bits on scheduler scripts:"
echo "  $DIR/scheduler.sh"
echo "  $DIR/install-crons.sh"
echo "  $DIR/jobs/daily-reset.sh"
echo "  $DIR/jobs/weekly-service.sh"
echo "  $DIR/jobs/sharpen.sh"
echo "  $DIR/jobs/cleanup.sh"
echo ""
echo "To inspect generated config without installing:"
echo "  $DIR/scheduler.sh --print"
echo ""
echo "To install (or refresh) scheduler:"
echo "  $DIR/install-crons.sh"
echo ""
echo "To uninstall scheduler:"
echo "  $DIR/install-crons.sh --uninstall"
