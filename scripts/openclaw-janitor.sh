#!/usr/bin/env bash
# openclaw-janitor.sh — Daily disk janitor for Gawd daemon.
# Prevents unbounded growth of sessions and wiki/sources directories.
# Hardening item 2.5 (gawd-tarball-hardening-2026-04-29.md).
#
# Install via cron (handled by install.sh):
#   @daily bash $HOME/.openclaw/workspace/scripts/openclaw-janitor.sh \
#          >> $HOME/.openclaw/logs/janitor.log 2>&1
#
# Idempotent: safe to run multiple times. Only removes files that meet
# the age threshold — no forced deletions of recent content.
set -euo pipefail

SESSIONS_DIR="${HOME}/.openclaw/agents/main/sessions"
WIKI_SOURCES="${HOME}/.openclaw/workspace/memory/wiki/sources"
ARCHIVE_DIR="${HOME}/.openclaw/archive/sessions"
LOG="${HOME}/.openclaw/logs/janitor.log"

mkdir -p "$ARCHIVE_DIR" "$(dirname "$LOG")"

echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') janitor start" >> "$LOG"

# Archive session files that are 30-60 days old (keep accessible, not live).
if [[ -d "$SESSIONS_DIR" ]]; then
    find "$SESSIONS_DIR" -type f -mtime +30 -mtime -60 -print0 2>/dev/null | \
        tar --null -czf "${ARCHIVE_DIR}/sessions-$(date +%F-%s).tar.gz" -T - 2>/dev/null || true
    find "$SESSIONS_DIR" -name 'sessions.json.*.tmp' -mtime +7 -delete 2>/dev/null || true

    # Delete session files older than 60 days (already archived above).
    DELETED="$(find "$SESSIONS_DIR" -type f -mtime +60 -delete -print 2>/dev/null | wc -l)"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') sessions: deleted ${DELETED} files >60 days" >> "$LOG"
fi

# Prune wiki/sources older than 14 days.
# Per hardening 2.3: indexMemoryRoot=false prevents new recursion, but existing
# files may accumulate during normal bridge operation. 14-day retention is sufficient.
if [[ -d "$WIKI_SOURCES" ]]; then
    WIKI_DELETED="$(find "$WIKI_SOURCES" -type f -mtime +14 -delete -print 2>/dev/null | wc -l)"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') wiki/sources: deleted ${WIKI_DELETED} files >14 days" >> "$LOG"
fi

echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') janitor done" >> "$LOG"
