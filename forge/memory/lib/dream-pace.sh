#!/usr/bin/env bash
# dream-pace.sh — back-pressure for dreaming (spec §5.2).
#
# Single responsibility: rate-aware pacing + retry-with-backoff.
# Prevents the 2026-05-27 failure mode where dreaming's unbounded burst
# of model calls hit rate limits with no back-pressure, killing the run.
#
# Two mechanisms:
#   1. retry_with_backoff  — exponential backoff + jitter on any non-zero exit.
#                            After GAWD_DREAM_RETRY_MAX attempts it returns the
#                            command's last exit code (NON-ZERO) so the caller
#                            (safe-dream) can checkpoint-and-exit cleanly rather
#                            than hang or crash-loop.
#   2. pace_gate           — simple inter-call spacing (token-bucket / min-interval)
#                            to bound calls-per-minute before they ever hit the
#                            rate-limit wall. Called once per chunk by safe-dream.
#
# Clean-give-up contract (critical):
#   retry_with_backoff ALWAYS returns non-zero when retries are exhausted without
#   a success. It NEVER returns 0 on exhaustion. This is the signal safe-dream
#   uses to checkpoint the cursor and exit 0 (SAFE-ABORT). Callers MUST check
#   the return code of retry_with_backoff to honour the safe-abort design.
#
# Env vars (all have safe defaults):
#   GAWD_DREAM_RETRY_MAX         max attempts before giving up (default 5)
#   GAWD_DREAM_BACKOFF_BASE      base sleep seconds for exponential schedule (default 2)
#   GAWD_DREAM_MAX_CALLS_PER_MIN max model calls per minute for pacing (default 20;
#                                0 = no pacing — used in tests to skip sleeping)

GAWD_DREAM_RETRY_MAX="${GAWD_DREAM_RETRY_MAX:-5}"
GAWD_DREAM_BACKOFF_BASE="${GAWD_DREAM_BACKOFF_BASE:-2}"
GAWD_DREAM_MAX_CALLS_PER_MIN="${GAWD_DREAM_MAX_CALLS_PER_MIN:-20}"

# retry_with_backoff <command> [args...]
#
# Runs the command up to GAWD_DREAM_RETRY_MAX times. On each failure it sleeps
# for an exponentially-increasing interval (with uniform jitter up to BASE+1s)
# before retrying. On success (exit 0) returns 0 immediately. When all retries
# are exhausted without success, returns the command's last non-zero exit code.
#
# Backoff schedule (BASE=2):
#   attempt 1 fail → sleep 2+jitter
#   attempt 2 fail → sleep 4+jitter
#   attempt 3 fail → sleep 8+jitter
#   ... up to MAX, then return last exit code
#
# The caller MUST treat a non-zero return as a signal to safe-abort and
# checkpoint — NOT to retry in a new loop (that would recreate the crash-loop).
retry_with_backoff() {
  local attempt=0
  local rc=0
  local delay jitter

  while :; do
    # Run the command.
    "$@"
    rc=$?
    [ "$rc" = "0" ] && return 0

    attempt=$((attempt + 1))

    # Exhausted — return the last non-zero code so the caller can safe-abort.
    if [ "$attempt" -ge "$GAWD_DREAM_RETRY_MAX" ]; then
      return "$rc"
    fi

    # Exponential backoff: BASE * 2^(attempt-1), floored at 0.
    delay=$(( GAWD_DREAM_BACKOFF_BASE * (1 << (attempt - 1)) ))

    # Uniform jitter in [0, BASE] to avoid thundering-herd on parallel runs.
    # When BASE=0 (test mode), jitter is always 0 — no sleep.
    if [ "$GAWD_DREAM_BACKOFF_BASE" -gt "0" ]; then
      jitter=$(( RANDOM % (GAWD_DREAM_BACKOFF_BASE + 1) ))
    else
      jitter=0
    fi

    local total=$(( delay + jitter ))
    if [ "$total" -gt "0" ]; then
      sleep "$total" 2>/dev/null || true
    fi
  done
}

# pace_gate
#
# Enforces a minimum inter-call interval to keep calls-per-minute at or below
# GAWD_DREAM_MAX_CALLS_PER_MIN. Call this once before each chunk's model call in
# safe-dream. This provides the token-bucket / rate-limiting layer so dreaming
# decelerates before hitting a hard API rate limit, rather than after.
#
# With GAWD_DREAM_MAX_CALLS_PER_MIN=0, pace_gate is a no-op (used in tests and
# for local-only models that have no external rate limit to respect).
pace_gate() {
  local max_per_min="$GAWD_DREAM_MAX_CALLS_PER_MIN"

  # 0 = no pacing (test mode or local model with no rate limit).
  if [ "$max_per_min" -le "0" ] 2>/dev/null; then
    return 0
  fi

  # min_interval = 60 / max_per_min (integer, floored).
  # e.g. 20 calls/min -> sleep 3s between calls.
  local min_interval
  min_interval=$(( 60 / max_per_min ))

  if [ "$min_interval" -gt "0" ]; then
    sleep "$min_interval" 2>/dev/null || true
  fi
}
