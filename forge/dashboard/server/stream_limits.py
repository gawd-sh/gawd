"""
stream_limits.py — dash-HIGH H3 mitigation: bound SSE/stream resource use.

The dashboard runs gunicorn with a SINGLE worker and 16 threads (see app.py
docstring). Each long-lived SSE stream (heartbeat, chat) holds one thread for
its whole lifetime. Without bounds, a handful of stale/abandoned EventSource
connections — or a deliberate flood from one authenticated session — can
exhaust all 16 threads and freeze the dashboard for everyone.

Two mitigations, both lightweight and in-memory (v1 is single-Prophit; a worker
restart resets the counters, which is acceptable):

  1. Per-session concurrent-stream cap (StreamGate). A session may hold at most
     MAX_STREAMS_PER_SESSION simultaneous streams. Excess attempts get 429.

  2. Stream max-lifetime (stream_lifetime_exceeded). Generators check elapsed
     time each loop and return when the cap is hit; the browser EventSource
     reconnects automatically, so this is invisible to the user but frees the
     thread periodically.

No new dependency. Pure stdlib.
"""

from __future__ import annotations

import logging
import threading
import time
from collections import defaultdict
from typing import Optional

log = logging.getLogger("gawd.dashboard.stream_limits")

# Max concurrent streams a single session may hold open at once. Two is enough
# for the dashboard (heartbeat SSE + chat SSE). A third concurrent stream from
# the same session indicates a leak or abuse → reject.
MAX_STREAMS_PER_SESSION = 3

# Global ceiling across ALL sessions, leaving headroom on the 16-thread worker
# for normal (short) request handling.
MAX_STREAMS_GLOBAL = 8

_lock = threading.Lock()
_per_session: dict[str, int] = defaultdict(int)
_global_count = 0


def stream_lifetime_exceeded(started_at: float, max_lifetime_s: float) -> bool:
    """True once a stream has run longer than its allotted lifetime."""
    return (time.monotonic() - started_at) >= max_lifetime_s


class StreamGate:
    """
    Context manager that reserves a stream slot for a session.

    Usage:
        gate = StreamGate(session_key)
        if not gate.acquire():
            return Response("too many streams", status=429)
        try:
            ... yield frames ...
        finally:
            gate.release()

    `acquire()` returns False if either the per-session or global cap is hit.
    `release()` is idempotent and safe to call exactly once per successful
    acquire (call it in a finally).
    """

    def __init__(self, session_key: Optional[str]) -> None:
        # Fall back to a shared bucket for unauthenticated/unknown sessions.
        # In practice every streaming route is auth-gated before a gate is
        # constructed, so session_key is a real chat_id string.
        self._key = session_key or "_anon"
        self._held = False

    def acquire(self) -> bool:
        global _global_count
        with _lock:
            if _global_count >= MAX_STREAMS_GLOBAL:
                log.warning("stream rejected: global cap %d reached", MAX_STREAMS_GLOBAL)
                return False
            if _per_session[self._key] >= MAX_STREAMS_PER_SESSION:
                log.warning(
                    "stream rejected: session cap %d reached for key=%s",
                    MAX_STREAMS_PER_SESSION, self._key,
                )
                return False
            _per_session[self._key] += 1
            _global_count += 1
            self._held = True
            return True

    def release(self) -> None:
        global _global_count
        with _lock:
            if not self._held:
                return
            self._held = False
            _global_count = max(0, _global_count - 1)
            n = _per_session.get(self._key, 0) - 1
            if n <= 0:
                _per_session.pop(self._key, None)
            else:
                _per_session[self._key] = n
