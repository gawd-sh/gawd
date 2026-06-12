"""
chat.py — Chat panel routes. Bidirectional via POST + HTMX swap (no WebSocket for v1).

Outbound (Prophit → Gawd):
  POST /chat/send {message}
    → forwards to OpenClaw gateway (via GAWD_GATEWAY_URL)
    → if gateway unreachable / 5xx / timeout: degrades gracefully
        - shows G2 fallback banner via SSE-driven banner partial
        - queues message to ~/.gawd/state/chat-outbox.jsonl for when Gawd returns
        - returns an in-character "I'm hiccuping, hold on" partial INLINE
    → on success: returns the rendered conversation partial (Prophit msg + Gawd reply)

Inbound (Gawd → Prophit):
  Two paths:
    a) Direct: gateway pushes /api/chat/inbound (when chat happens via Telegram/voice
       and we want it mirrored in dashboard) — not implemented in v1 skeleton
    b) Fallback: G2 deliver/dashboard.sh writes to ~/.gawd/dashboard/queue/*.json
       OR POSTs to /api/fallback/ingest — fallback_ingest.py handles those.
       The chat panel SSE stream merges these.

For v1 skeleton, the chat panel renders:
  - History from ~/.gawd/state/chat-history.jsonl (append-only)
  - Live SSE stream of new inbound messages (chat events emitted by fallback_ingest)
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Optional

import requests
from flask import (
    Blueprint, Response, current_app, redirect, render_template, request,
    stream_with_context, url_for,
)

from .auth import require_auth
from .config import GAWD_HOME, load_config
from .heartbeat import read_status
from .punt import maybe_punt_to_desktop
from .stream_limits import StreamGate, stream_lifetime_exceeded

log = logging.getLogger("gawd.dashboard.chat")

bp = Blueprint("chat", __name__)

CHAT_HISTORY_FILE = GAWD_HOME / "state" / "chat-history.jsonl"
CHAT_OUTBOX_FILE = GAWD_HOME / "state" / "chat-outbox.jsonl"
CHAT_INBOUND_FILE = GAWD_HOME / "dashboard" / "queue"  # G2 drops .json files here

# dash-HIGH H3: cap a single chat-SSE stream's lifetime; the browser EventSource
# reconnects automatically, freeing the gunicorn worker thread periodically.
CHAT_STREAM_MAX_LIFETIME_S = 300  # 5 min


# ── History persistence ──

def _append_history(role: str, text: str, kind: str = "text", meta: Optional[dict] = None) -> None:
    """Append a single chat record. role in {prophit, gawd, system, fallback}."""
    CHAT_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "ts": int(time.time()),
        "role": role,
        "text": text,
        "kind": kind,
        "meta": meta or {},
    }
    try:
        with open(CHAT_HISTORY_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError as e:
        log.error("chat history append failed: %s", type(e).__name__)


def _load_history(limit: int = 100) -> list[dict]:
    if not CHAT_HISTORY_FILE.is_file():
        return []
    try:
        with open(CHAT_HISTORY_FILE, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return []
    out = []
    for line in lines[-limit:]:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def _append_outbox(text: str) -> None:
    """Queue a message for when the gateway returns."""
    CHAT_OUTBOX_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(CHAT_OUTBOX_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": int(time.time()), "text": text}) + "\n")
    except OSError as e:
        log.error("outbox append failed: %s", type(e).__name__)


# ── Routes ──

@bp.route("/chat", methods=["GET"])
def chat_page():
    if require_auth() is None:
        return redirect(url_for("auth.login_page"))
    cfg = load_config()
    return render_template(
        "chat.html",
        history=_load_history(),
        novnc_url=cfg.novnc_url,
        has_novnc=cfg.has_novnc,
    )


@bp.route("/chat/send", methods=["POST"])
def chat_send():
    if require_auth() is None:
        return redirect(url_for("auth.login_page"))

    cfg = load_config()
    raw = (request.form.get("message") or "").strip()
    if not raw:
        return Response("", status=204)

    # Record prophit's message first (it's already happened from their POV)
    _append_history("prophit", raw, kind="text")

    # Punt-to-desktop check (per maintainer clarification: dashboard knows its boundary)
    punt = maybe_punt_to_desktop(raw)
    if punt:
        _append_history("system", punt["message"], kind="punt", meta=punt)
        return render_template("_chat_message.html", role="system", record={
            "ts": int(time.time()), "role": "system", "text": punt["message"],
            "kind": "punt", "meta": punt,
        })

    # Try the gateway
    status = read_status()
    if status.state == "offline":
        # Don't even try the gateway — banner already shows the situation
        _append_outbox(raw)
        text = "I can't reach my own brain right now. Your message is held — I'll answer when I'm back."
        _append_history("fallback", text, kind="fallback")
        return render_template("_chat_message.html", role="fallback", record={
            "ts": int(time.time()), "role": "fallback", "text": text, "kind": "fallback", "meta": {},
        })

    try:
        # Minimal protocol — actual gateway contract depends on OpenClaw HTTP API.
        # For v1 skeleton, this is a placeholder. Archon wires the actual endpoint.
        resp = requests.post(
            f"{cfg.gateway_url}/api/chat",
            json={"message": raw, "channel": "dashboard"},
            timeout=cfg.silence_threshold_s,
        )
        if resp.status_code != 200:
            raise requests.HTTPError(f"gateway returned {resp.status_code}")
        reply_text = (resp.json().get("reply") or "").strip()
        if not reply_text:
            raise ValueError("empty reply")
        _append_history("gawd", reply_text, kind="text")
        return render_template("_chat_message.html", role="gawd", record={
            "ts": int(time.time()), "role": "gawd", "text": reply_text, "kind": "text", "meta": {},
        })
    except (requests.RequestException, ValueError) as e:
        log.warning("chat gateway failure: %s", type(e).__name__)
        _append_outbox(raw)
        text = "Something on my end is hiccuping. Working through it — try again in a moment."
        _append_history("fallback", text, kind="fallback")
        return render_template("_chat_message.html", role="fallback", record={
            "ts": int(time.time()), "role": "fallback", "text": text, "kind": "fallback", "meta": {},
        })


@bp.route("/chat/stream")
def chat_stream():
    """
    SSE stream of NEW chat events arriving from G2 fallback or gateway inbound.

    Implementation: tails ~/.gawd/dashboard/queue/ directory; emits each new .json
    as it appears; moves processed files to ~/.gawd/dashboard/processed/.

    Simple polling (1s interval) — sufficient for v1 single-Prophit volume.
    """
    cid = require_auth()
    if cid is None:
        return Response("auth required", status=401)

    # dash-HIGH H3: bound concurrent streams per session + globally so the
    # single gunicorn worker's 16 threads can't be exhausted.
    gate = StreamGate(str(cid))
    if not gate.acquire():
        return Response("too many concurrent streams", status=429)

    queue_dir = GAWD_HOME / "dashboard" / "queue"
    processed_dir = GAWD_HOME / "dashboard" / "processed"
    queue_dir.mkdir(parents=True, exist_ok=True)
    processed_dir.mkdir(parents=True, exist_ok=True)

    @stream_with_context
    def generate():
        started_at = time.monotonic()
        try:
            # Send an initial comment so the browser knows the connection is alive
            yield ": connected\n\n"
            seen: set[str] = set()
            while True:
                # dash-HIGH H3: cap lifetime; EventSource reconnects transparently.
                if stream_lifetime_exceeded(started_at, CHAT_STREAM_MAX_LIFETIME_S):
                    return
                time.sleep(1.0)
                try:
                    files = sorted(queue_dir.glob("*.json"))
                    for fp in files:
                        name = fp.name
                        if name in seen:
                            continue
                        try:
                            with open(fp, "r", encoding="utf-8") as f:
                                evt = json.load(f)
                            msg_html = evt.get("html") or evt.get("text") or ""
                            if msg_html:
                                # Record + emit
                                _append_history("fallback", msg_html, kind="fallback", meta={"src": "g2"})
                                payload = json.dumps({
                                    "role": "fallback",
                                    "html": msg_html,
                                    "ts": int(time.time()),
                                })
                                yield f"data: {payload}\n\n"
                            # Move to processed
                            target = processed_dir / name
                            fp.replace(target)
                            seen.add(name)
                        except (OSError, json.JSONDecodeError) as e:
                            log.warning("chat queue file unreadable: %s (%s)", name, type(e).__name__)
                            # Move it out so we don't loop on it
                            try:
                                fp.replace(processed_dir / f"BAD-{name}")
                            except OSError:
                                pass
                            seen.add(name)
                except OSError as e:
                    log.error("chat stream scan failed: %s", type(e).__name__)
        finally:
            gate.release()

    return Response(generate(), mimetype="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
    })
