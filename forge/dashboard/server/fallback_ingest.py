"""
fallback_ingest.py — Inbound endpoint for G2 silence-avoidance engine.

Two inbound paths (G2 deliver/dashboard.sh supports both):

  1) HTTP POST /api/fallback/ingest
       Headers: X-Gawd-Fallback-Key: <shared secret from ~/.gawd/.secrets/fallback_ingest.key>
       Body: {"type": "fallback", "prophit": "...", "ts": "...", "html": "..."}
       → Writes the message to ~/.gawd/dashboard/queue/<ts>-<rand>.json
         (the same file format the file-queue path uses; chat.py SSE picks it up)
       → Updates banner state file ~/.gawd/state/dashboard-banner.json

  2) File queue at ~/.gawd/dashboard/queue/*.json
       Handled by chat.py's stream tail; no HTTP involvement.

Both paths converge on the same queue directory + banner file, so the dashboard
treats them uniformly downstream.

The shared-secret check is mandatory on the HTTP path (without it, anyone who
could reach the port could spoof Gawd's voice). The file-queue path is implicitly
trusted because it requires local filesystem write access.
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import time
from pathlib import Path

from flask import Blueprint, jsonify, request

from .auth import require_auth
from .config import (
    DASHBOARD_QUEUE_DIR, GAWD_HOME, get_fallback_ingest_key,
)

log = logging.getLogger("gawd.dashboard.fallback_ingest")

bp = Blueprint("fallback_ingest", __name__)

BANNER_FILE = GAWD_HOME / "state" / "dashboard-banner.json"


def _write_banner(state: str, message: str) -> None:
    """Persist current banner state for cold-load on page render."""
    BANNER_FILE.parent.mkdir(parents=True, exist_ok=True)
    payload = {"state": state, "message": message, "ts": int(time.time())}
    tmp = BANNER_FILE.with_suffix(".json.tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        tmp.replace(BANNER_FILE)
    except OSError as e:
        log.error("banner write failed: %s", type(e).__name__)


def read_banner() -> dict:
    """Render the banner partial on page load. Returns {state, message, ts} or empty."""
    if not BANNER_FILE.is_file():
        return {}
    try:
        with open(BANNER_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


@bp.route("/api/fallback/ingest", methods=["POST"])
def ingest():
    expected = get_fallback_ingest_key()
    if expected is None:
        log.warning("fallback ingest disabled (no key); refusing HTTP path")
        return jsonify({"error": "ingest disabled"}), 503

    sent = request.headers.get("X-Gawd-Fallback-Key", "")
    if not hmac.compare_digest(sent, expected):
        log.warning("fallback ingest bad key from %s", request.remote_addr)
        return jsonify({"error": "forbidden"}), 403

    try:
        body = request.get_json(force=True, silent=False)
    except Exception:  # broad: we don't want raw JSON parse errors leaking
        return jsonify({"error": "bad json"}), 400

    if not isinstance(body, dict):
        return jsonify({"error": "bad payload"}), 400

    msg_type = body.get("type", "fallback")
    html = body.get("html") or body.get("text") or ""
    prophit = str(body.get("prophit") or "")
    ts = body.get("ts") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    if not html:
        return jsonify({"error": "empty"}), 400

    # Write to queue (atomic temp + rename — same protocol as G2 file path)
    DASHBOARD_QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    fname = f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{prophit or 'unknown'}-{os.getpid()}-{int(time.time()*1000)%100000}.json"
    queue_path = DASHBOARD_QUEUE_DIR / fname
    tmp = queue_path.with_suffix(".json.tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"type": msg_type, "prophit": prophit, "ts": ts, "html": html}, f)
        os.chmod(tmp, 0o600)
        tmp.replace(queue_path)
    except OSError as e:
        log.error("fallback queue write failed: %s", type(e).__name__)
        return jsonify({"error": "queue write failed"}), 500

    # Update banner if this is a degraded/recovered marker
    if msg_type in ("fallback", "degraded"):
        _write_banner("degraded", html)
    elif msg_type == "recovered":
        _write_banner("recovered", html)

    log.info("fallback ingest ok type=%s bytes=%d", msg_type, len(html))
    return jsonify({"ok": True}), 200


@bp.route("/api/banner/dismiss", methods=["POST"])
def banner_dismiss():
    """Prophit-initiated dismiss (e.g., on 'recovered' acknowledgment)."""
    # dash-HIGH H2: mutating endpoint reachable pre-auth let anyone clear the
    # banner state. Require an authenticated Prophit session.
    if require_auth() is None:
        return jsonify({"error": "auth required"}), 401
    try:
        if BANNER_FILE.is_file():
            BANNER_FILE.unlink()
    except OSError:
        pass
    return jsonify({"ok": True}), 200
