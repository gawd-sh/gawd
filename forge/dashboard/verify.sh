#!/usr/bin/env bash
# verify.sh — Self-verification for the dashboard skeleton.
# Runs syntax checks on shell scripts and Python files; does not execute tests.
#
# Usage: bash verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[verify] %s\n' "$*"; }

# Shell syntax checks
log "bash -n install.sh"
bash -n "${SCRIPT_DIR}/install.sh"
log "bash -n tests/run-all.sh"
bash -n "${SCRIPT_DIR}/tests/run-all.sh"
log "bash -n verify.sh"
bash -n "${SCRIPT_DIR}/verify.sh"

# Python syntax checks
PY_FILES=(
    "${SCRIPT_DIR}/server/app.py"
    "${SCRIPT_DIR}/server/auth.py"
    "${SCRIPT_DIR}/server/chat.py"
    "${SCRIPT_DIR}/server/config.py"
    "${SCRIPT_DIR}/server/fallback_ingest.py"
    "${SCRIPT_DIR}/server/heartbeat.py"
    "${SCRIPT_DIR}/server/meeting.py"
    "${SCRIPT_DIR}/server/onboarding.py"
    "${SCRIPT_DIR}/server/punt.py"
    "${SCRIPT_DIR}/server/recovery.py"
    "${SCRIPT_DIR}/server/settings.py"
    "${SCRIPT_DIR}/server/telegram_send.py"
    "${SCRIPT_DIR}/server/tithe.py"
    "${SCRIPT_DIR}/tests/conftest.py"
    "${SCRIPT_DIR}/tests/test_auth.py"
    "${SCRIPT_DIR}/tests/test_heartbeat.py"
    "${SCRIPT_DIR}/tests/test_magic_link.py"
    "${SCRIPT_DIR}/tests/test_fallback_ingest.py"
    "${SCRIPT_DIR}/tests/test_punt.py"
)
for f in "${PY_FILES[@]}"; do
    log "py_compile ${f#${SCRIPT_DIR}/}"
    python3 -m py_compile "$f"
done

# Systemd unit syntax (basic line check; full check requires systemd-analyze)
log "systemd unit present"
test -f "${SCRIPT_DIR}/systemd/gawd-dashboard.service"

# Templates present
TEMPLATE_FILES=(
    base.html
    _heartbeat.html
    _degraded_banner.html
    _chat_message.html
    _tithe_result.html
    _recovery_result.html
    _sil_proposal.html
    login.html
    chat.html
    settings.html
    personality.html
    skills.html
    revelations.html
    tithe.html
    404.html
    500.html
    onboarding/q1.html
    onboarding/q2.html
    onboarding/q3.html
    onboarding/q4.html
    meeting/show.html
    meeting/missing.html
)
for t in "${TEMPLATE_FILES[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/templates/${t}" ]]; then
        log "MISSING template: ${t}"
        exit 1
    fi
done
log "all templates present"

log "OK"
