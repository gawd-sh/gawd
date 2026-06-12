#!/usr/bin/env bash
# setup-perms.sh — One-shot: make the revelation engine scripts executable.
#
# Idempotent. Run once after pulling the revelation/ tree, or whenever a new
# script lands. Safe to re-run.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

chmod 0755 \
  "$DIR/merge.sh" \
  "$DIR/check-pending.sh" \
  "$DIR/offer.sh" \
  "$DIR/tests/run-tests.sh" \
  "$DIR/setup-perms.sh"

echo "Set executable bits on revelation engine scripts:"
echo "  $DIR/merge.sh"
echo "  $DIR/check-pending.sh"
echo "  $DIR/offer.sh"
echo "  $DIR/tests/run-tests.sh"
echo ""
echo "To run the test suite:"
echo "  $DIR/tests/run-tests.sh"
