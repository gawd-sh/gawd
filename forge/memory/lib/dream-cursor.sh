#!/usr/bin/env bash
# dream-cursor.sh — durable consolidation cursor (last fully-consolidated
# lcm.db message_id + created_at epoch). Atomic write (temp + mv) so a
# crash never half-advances or corrupts (spec §2.2, §5.2 safe-abort).
#
# File format: "<message_id> <ts_epoch>"   (space-separated, single line)
# Default path: /home/gawd/.openclaw/state/dream-cursor
#
# lcm.db anchoring (confirmed 2026-05-29 from gawd-rc5-observe live schema):
#   messages.message_id  INTEGER PRIMARY KEY AUTOINCREMENT  -- cursor unit
#   messages.created_at  TEXT DEFAULT (datetime('now'))     -- stored as space-separated "YYYY-MM-DD HH:MM:SS" (NOT RFC3339/ISO8601 T...Z format)
#   The cursor tracks message_id because it is the monotonically increasing PK.
#   created_at is stored as a human-readable companion for log/debugging.
#   Neither seq (per-conversation) nor session-level ids are used — message_id
#   is the only global ordering key that never resets across conversations.
#
# Functions exported:
#   cursor_read        -- prints last consolidated message_id (0 if none)
#   cursor_read_ts     -- prints last consolidated ts epoch (0 if none)
#   cursor_checkpoint  -- $1=message_id $2=ts_epoch (atomic write)

GAWD_DREAM_CURSOR="${GAWD_DREAM_CURSOR:-/home/gawd/.openclaw/state/dream-cursor}"

# cursor_read: print the last fully-consolidated message_id, or 0 if no cursor.
cursor_read() {
  local val
  if [ -f "$GAWD_DREAM_CURSOR" ]; then
    val="$(awk 'NR==1{print $1}' "$GAWD_DREAM_CURSOR" 2>/dev/null)"
    echo "${val:-0}"
  else
    echo 0
  fi
}

# cursor_read_ts: print the ts epoch companion, or 0 if no cursor.
cursor_read_ts() {
  local val
  if [ -f "$GAWD_DREAM_CURSOR" ]; then
    val="$(awk 'NR==1{print $2}' "$GAWD_DREAM_CURSOR" 2>/dev/null)"
    echo "${val:-0}"
  else
    echo 0
  fi
}

# cursor_checkpoint $1=message_id $2=ts_epoch
# Atomically writes the cursor via a temp file + mv so a mid-write crash
# (power loss, OOM kill, SIGKILL) never leaves a partial/corrupt cursor.
# The prior cursor value is intact until mv completes; mv on Linux is atomic
# when src and dst are on the same filesystem (kernel rename(2) guarantee).
cursor_checkpoint() {
  local id="${1:?cursor_checkpoint requires message_id}"
  local ts="${2:-0}"
  local dir
  dir="$(dirname "$GAWD_DREAM_CURSOR")"
  mkdir -p "$dir"
  local tmp
  tmp="$(mktemp "${GAWD_DREAM_CURSOR}.XXXXXX")"
  printf '%s %s\n' "$id" "$ts" > "$tmp"
  mv -f "$tmp" "$GAWD_DREAM_CURSOR"
}
