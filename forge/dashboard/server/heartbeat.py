"""
heartbeat.py — Server-Sent Events endpoint for live Gawd status.

LOAD-BEARING per spec §19.3.2: this endpoint MUST NOT call the LLM chain or
the OpenClaw gateway. It reads a single file (~/.gawd/state/watchdog/last-sweep.json,
produced by G5 watchdog) and pushes status to subscribed dashboard clients.

States emitted (per spec §19.2 Layer 5):
  - healthy   — all G5 probes 'ok'
  - thinking  — gateway 'ok' but last-activity recent (≤2s); a model call is in flight
  - degraded  — one or more probes 'warn' / 'fail' but engine still responding
  - offline   — watchdog file missing/stale OR gateway probe 'fail'

The dashboard banner uses this to render: never frozen, always-truthful.

Why SSE not WebSocket:
  - One-way push only. SSE is simpler, no handshake state, reconnects automatically.
  - Works through cloudflared / Tailscale Serve without special config.
  - Chat panel separately handles bidirectional (POST + HTMX swap, not WS).
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from pathlib import Path

from flask import Blueprint, Response, current_app, stream_with_context

from .auth import require_auth
from .config import WATCHDOG_STATE
from .stream_limits import StreamGate, stream_lifetime_exceeded

log = logging.getLogger("gawd.dashboard.heartbeat")

bp = Blueprint("heartbeat", __name__)

# How often to push a status frame to subscribed clients.
HEARTBEAT_INTERVAL_S = 2.0

# If watchdog file hasn't been updated in this many seconds, status -> offline.
WATCHDOG_STALE_THRESHOLD_S = 90  # G5 default sweep is 60s; allow 1.5x

# dash-HIGH H3: cap a single SSE stream's lifetime so the browser EventSource
# reconnects (cheap) instead of pinning a gunicorn worker thread indefinitely.
HEARTBEAT_STREAM_MAX_LIFETIME_S = 300  # 5 min; EventSource auto-reconnects


@dataclass(frozen=True)
class GawdStatus:
    state: str          # healthy | thinking | degraded | offline
    reason: str         # human-readable, in-Gawd-voice when degraded/offline
    last_seen_iso: str  # last successful watchdog sweep timestamp
    probes: dict        # raw probe results from G5

    def to_sse_data(self) -> str:
        payload = {
            "state": self.state,
            "reason": self.reason,
            "last_seen_iso": self.last_seen_iso,
            "probes": self.probes,
        }
        return json.dumps(payload, separators=(",", ":"))


def read_status() -> GawdStatus:
    """
    Pure file-read. NEVER hits gateway, NEVER hits LLM, NEVER hits network.
    If watchdog file is missing, returns 'offline' — which is truthful.
    """
    path: Path = WATCHDOG_STATE
    if not path.is_file():
        return GawdStatus(
            state="offline",
            reason="Watchdog has not run. The Gawd may still be booting.",
            last_seen_iso="never",
            probes={},
        )

    try:
        with open(path, "r", encoding="utf-8") as f:
            sweep = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        log.warning("watchdog file unreadable: %s", type(e).__name__)
        return GawdStatus(
            state="offline",
            reason="Cannot read watchdog state. This is unusual.",
            last_seen_iso="unknown",
            probes={},
        )

    # Staleness check
    try:
        stat = path.stat()
        age_s = time.time() - stat.st_mtime
    except OSError:
        age_s = WATCHDOG_STALE_THRESHOLD_S + 1
    if age_s > WATCHDOG_STALE_THRESHOLD_S:
        return GawdStatus(
            state="offline",
            reason=(
                f"Watchdog last ran {int(age_s)}s ago — that's longer than expected. "
                "I'm checking on myself."
            ),
            last_seen_iso=sweep.get("timestamp_central", sweep.get("timestamp", "unknown")),
            probes=sweep.get("probes", {}),
        )

    probes = sweep.get("probes", {})
    last_seen_iso = sweep.get("timestamp_central", sweep.get("timestamp", "unknown"))

    # Derive overall state
    failed_probes = [name for name, result in probes.items() if result == "fail"]
    warn_probes = [name for name, result in probes.items() if str(result).startswith("warn")]

    if probes.get("gateway-health") == "fail":
        return GawdStatus(
            state="offline",
            reason="My brain is offline. I'm working on it.",
            last_seen_iso=last_seen_iso,
            probes=probes,
        )

    if failed_probes:
        return GawdStatus(
            state="degraded",
            reason=f"Something on my end is hiccuping ({', '.join(failed_probes)}). Working through it.",
            last_seen_iso=last_seen_iso,
            probes=probes,
        )

    if warn_probes:
        return GawdStatus(
            state="degraded",
            reason="I'm here but slower than usual. Apologies for the lag.",
            last_seen_iso=last_seen_iso,
            probes=probes,
        )

    return GawdStatus(
        state="healthy",
        reason="Present.",
        last_seen_iso=last_seen_iso,
        probes=probes,
    )


@bp.route("/heartbeat/sse")
def heartbeat_sse() -> Response:
    """
    SSE stream. Client subscribes; server pushes a frame every HEARTBEAT_INTERVAL_S.
    Reconnects are handled by EventSource on the browser side (no manual logic).
    """
    # dash-HIGH H2: this endpoint exposes probe state — gate it behind auth.
    cid = require_auth()
    if cid is None:
        return Response("auth required", status=401)

    # dash-HIGH H3: bound concurrent streams per session + globally.
    gate = StreamGate(str(cid))
    if not gate.acquire():
        return Response("too many concurrent streams", status=429)

    @stream_with_context
    def generate():
        started_at = time.monotonic()
        try:
            # Initial frame immediately (don't make the client wait 2s for first paint).
            yield _format_sse(read_status().to_sse_data())
            while True:
                # dash-HIGH H3: cap lifetime; EventSource reconnects transparently.
                if stream_lifetime_exceeded(started_at, HEARTBEAT_STREAM_MAX_LIFETIME_S):
                    return
                time.sleep(HEARTBEAT_INTERVAL_S)
                try:
                    status = read_status()
                    yield _format_sse(status.to_sse_data())
                except (OSError, RuntimeError) as e:
                    # Pure-file pipeline; this should never happen. Don't crash the stream.
                    log.error("heartbeat read failed: %s", type(e).__name__)
                    yield _format_sse(json.dumps({
                        "state": "offline",
                        "reason": "Status stream hiccupped. Retrying.",
                        "last_seen_iso": "unknown",
                        "probes": {},
                    }))
        finally:
            gate.release()

    return Response(generate(), mimetype="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",  # disable buffering on reverse proxies
    })


@bp.route("/heartbeat/snapshot.json")
def heartbeat_snapshot() -> Response:
    """JSON snapshot of current status. Used by non-SSE clients + the degraded banner partial."""
    # dash-HIGH H2: snapshot leaks probe state — gate it behind auth.
    if require_auth() is None:
        return Response("auth required", status=401)
    status = read_status()
    return Response(status.to_sse_data(), mimetype="application/json")


def _format_sse(data: str) -> str:
    """Format a single SSE frame. Multi-line data needs each line prefixed."""
    lines = data.split("\n")
    return "".join(f"data: {line}\n" for line in lines) + "\n"
