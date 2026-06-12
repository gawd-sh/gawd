#!/usr/bin/env bash
# gawd-clean-state.sh — boot-time hygiene; runs BEFORE the gateway opens state.
# Clears stale flock lockfiles, checkpoints the sqlite WAL, trims oversize
# sessions. Idempotent + fail-loud-not-fail-stop (a clean box is a no-op).
#
# Hardening 5 (clean-state-on-boot): an unclean power-off leaves a held flock and
# an un-checkpointed WAL; both can block a clean restart. Runs at the START of the
# entrypoint (docker) and as ExecStartPre= on the gateway unit (systemd).
set -uo pipefail
GAWD_HOME="${GAWD_HOME:-$HOME/.gawd}"
OC_HOME="${HOME}/.openclaw"
LOG="${GAWD_HOME}/logs/reliability.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
_say() { printf '[clean-state] %s\n' "$*"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true; }

# 1) Stale flock lockfiles — only remove if NO live process holds them.
#    safe-dream / sharpen / janitor use *.lock under workspace. fuser checks
#    whether any process has the file open; if none, the lock is stale.
for lk in "${OC_HOME}/workspace"/*.lock "${OC_HOME}/workspace/dreaming"/*.lock "${GAWD_HOME}"/*.lock; do
  [[ -e "$lk" ]] || continue
  if command -v fuser >/dev/null 2>&1 && fuser "$lk" >/dev/null 2>&1; then
    _say "lock held by a live process, leaving: $lk"
  else
    rm -f "$lk" && _say "removed stale lock: $lk"
  fi
done

# 2) sqlite WAL checkpoint + integrity. The memory store is main.sqlite.
#    A power-off mid-write leaves a -wal/-shm; checkpoint folds it in. If the
#    DB is corrupt, MOVE it aside (never delete) and let openclaw re-create —
#    losing recall is recoverable; a wedged boot is not (silence-is-worst).
for db in "${OC_HOME}/memory/main.sqlite" "${OC_HOME}/workspace/memory/main.sqlite"; do
  [[ -f "$db" ]] || continue
  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1; then
      _say "WAL checkpointed: $db"
    else
      _say "WAL checkpoint FAILED: $db — running integrity_check"
    fi
    if ! sqlite3 "$db" 'PRAGMA integrity_check;' 2>/dev/null | grep -q '^ok$'; then
      BAK="${db}.corrupt.$(date +%s)"
      mv "$db" "$BAK" 2>/dev/null && _say "CORRUPT db moved aside to $BAK — openclaw will re-create (recall reset, boot preserved)"
      rm -f "${db}-wal" "${db}-shm" 2>/dev/null || true
    fi
  else
    # No sqlite3 binary: just clear orphaned -wal/-shm if the db is absent.
    [[ -f "${db}-wal" && ! -f "$db" ]] && rm -f "${db}-wal" "${db}-shm" && _say "orphan WAL cleared (no db): ${db}-wal"
  fi
done

# 3) Trim oversize sessions (the V8-heap / OOM vector). Mirror the lcm-watchdog
#    rule: any sessions.json > ~2000 messages is a freeze risk. Here we just
#    archive any session file > 50 MB so an oversized one can't crash the gateway
#    on load. The daily janitor does the message-count trim; this is the boot guard.
SESS_DIR="${OC_HOME}/agents/main/sessions"
ARCH="${OC_HOME}/archive/sessions"
if [[ -d "$SESS_DIR" ]]; then
  mkdir -p "$ARCH"
  find "$SESS_DIR" -type f -name '*.json' -size +50M -print0 2>/dev/null | while IFS= read -r -d '' f; do
    mv "$f" "${ARCH}/$(basename "$f").oversize.$(date +%s)" 2>/dev/null && _say "archived oversize session: $(basename "$f")"
  done
fi
_say "clean-state complete"
exit 0
