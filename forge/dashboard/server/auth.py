"""
auth.py — Magic-link auth via Telegram (Q19b locked).

Flow:
  1. GET /login                                        → form ("send me a link")
  2. POST /login {chat_id}                             → server generates token,
                                                          sends it via Telegram DM,
                                                          renders "check your phone"
  3. GET /login/verify?t=<token>                       → exchange token for session
                                                          cookie, redirect to /
  4. /logout                                           → clear cookie

Security model:
  - Token: itsdangerous URLSafeTimedSerializer signed with dashboard_signing.key
  - Token TTL: 600s (10 min) — long enough to switch from dashboard to phone, short
    enough to limit blast radius if intercepted
  - Token single-use: consumed token written to ~/.gawd/state/consumed-tokens.txt
    (sorted, last 10000); rejected on reuse
  - Session cookie: Flask session, signed, HttpOnly, SameSite=Lax, 30-day TTL
  - Per-Gawd-per-Prophit binding: dashboard only accepts magic-link requests for
    chat_ids that match the bound Prophit chat_id from identity.json. Other chat_ids
    silently get an "if your account is allowed, check Telegram" response.

Rate limiting: in-memory dict, 5 requests per chat_id per hour. Memory is fine for v1
(one Prophit). For multi-tenant hosting, swap to Redis.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import time
from collections import defaultdict
from pathlib import Path
from typing import Optional

from flask import (
    Blueprint, current_app, jsonify, make_response, redirect, render_template,
    request, session, url_for,
)
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from .config import (
    GAWD_HOME, get_bound_prophit_chat_id, get_signing_key, load_config,
)
from .telegram_send import send_dm

log = logging.getLogger("gawd.dashboard.auth")

bp = Blueprint("auth", __name__)

MAGIC_LINK_TTL_S = 600
RATE_LIMIT_WINDOW_S = 3600
RATE_LIMIT_MAX = 5

CONSUMED_TOKENS_FILE = GAWD_HOME / "state" / "consumed-tokens.txt"
CONSUMED_TOKENS_KEEP = 10_000

# BLOCKER 4 — voice-relay upgrade ticket.
# The browser voice WebSocket (voice/browser-relay.mjs) had ZERO auth: anyone who
# could reach the URL could drive paid STT/LLM/TTS. We mint a short-lived signed
# ticket here from the AUTHENTICATED dashboard session and the relay (Node)
# verifies it at WebSocket-upgrade time. Portable HMAC-SHA256 scheme (NOT
# itsdangerous wire format) so the Node side can verify with node:crypto using
# the SAME dashboard_signing.key. Format: b64url(payload).b64url(hmac_sha256).
VOICE_TICKET_TTL_S = 120  # 2 min — enough to open the socket, short blast radius
VOICE_TICKET_AUD = "voice-relay"

# In-memory rate limit (chat_id -> [(timestamp, ...)])
_rate_buckets: dict[int, list[float]] = defaultdict(list)


def _serializer() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(secret_key=get_signing_key(), salt="gawd-dashboard-magic-link-v1")


def _rate_limit_ok(chat_id: int) -> bool:
    now = time.time()
    bucket = _rate_buckets[chat_id]
    # Drop stale
    cutoff = now - RATE_LIMIT_WINDOW_S
    bucket[:] = [t for t in bucket if t > cutoff]
    if len(bucket) >= RATE_LIMIT_MAX:
        return False
    bucket.append(now)
    return True


def _is_token_consumed(token: str) -> bool:
    if not CONSUMED_TOKENS_FILE.is_file():
        return False
    try:
        with open(CONSUMED_TOKENS_FILE, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip() == token:
                    return True
    except OSError:
        pass
    return False


def _mark_token_consumed(token: str) -> None:
    CONSUMED_TOKENS_FILE.parent.mkdir(parents=True, exist_ok=True)
    # Append and trim
    try:
        with open(CONSUMED_TOKENS_FILE, "a", encoding="utf-8") as f:
            f.write(token + "\n")
    except OSError as e:
        log.error("consumed-token write failed: %s", type(e).__name__)
        return
    # Periodic trim (probabilistic, cheap)
    try:
        if os.path.getsize(CONSUMED_TOKENS_FILE) > 1024 * 1024:  # >1 MiB
            with open(CONSUMED_TOKENS_FILE, "r", encoding="utf-8") as f:
                lines = f.readlines()
            if len(lines) > CONSUMED_TOKENS_KEEP:
                lines = lines[-CONSUMED_TOKENS_KEEP:]
                tmp = CONSUMED_TOKENS_FILE.with_suffix(".txt.tmp")
                with open(tmp, "w", encoding="utf-8") as f:
                    f.writelines(lines)
                tmp.replace(CONSUMED_TOKENS_FILE)
    except OSError:
        pass


def issue_magic_link_token(chat_id: int) -> str:
    """Generate and sign a magic-link token for chat_id. Returns the urlsafe token."""
    return _serializer().dumps({"chat_id": int(chat_id), "iat": int(time.time())})


def verify_magic_link_token(token: str) -> Optional[int]:
    """
    Verify a token. Returns chat_id if valid, unconsumed, and not expired. Else None.
    Atomic: marks token consumed BEFORE returning success, to prevent races.
    """
    try:
        payload = _serializer().loads(token, max_age=MAGIC_LINK_TTL_S)
    except SignatureExpired:
        log.info("magic-link expired")
        return None
    except BadSignature:
        log.warning("magic-link bad signature (token tampered or wrong key)")
        return None

    chat_id = payload.get("chat_id")
    if not isinstance(chat_id, int):
        return None

    if _is_token_consumed(token):
        log.warning("magic-link reuse attempt chat_id=%s", chat_id)
        return None

    _mark_token_consumed(token)
    return chat_id


def login_user(chat_id: int) -> None:
    """Set the session cookie for chat_id. 30-day TTL set in app factory."""
    session.clear()
    session["chat_id"] = int(chat_id)
    session["issued_at"] = int(time.time())
    session.permanent = True


def current_user() -> Optional[int]:
    """Returns the chat_id of the current authenticated session, or None."""
    cid = session.get("chat_id")
    if cid is None:
        return None
    try:
        return int(cid)
    except (TypeError, ValueError):
        return None


def require_auth() -> Optional[int]:
    """
    Returns the chat_id if authenticated AND matches the bound Prophit.
    Otherwise None — caller should redirect to /login.
    """
    cid = current_user()
    if cid is None:
        return None
    bound = get_bound_prophit_chat_id()
    if bound is None:
        # No bound Prophit yet — onboarding hasn't happened. Allow auth flow but
        # gate the rest of the app. Onboarding routes handle this case directly.
        return cid
    if cid != bound:
        log.warning("session chat_id mismatch session=%s bound=%s", cid, bound)
        session.clear()
        return None
    return cid


# ── Routes ──

@bp.route("/login", methods=["GET"])
def login_page():
    return render_template("login.html", sent=False, error=None)


@bp.route("/login", methods=["POST"])
def login_send():
    chat_id_raw = request.form.get("chat_id", "").strip()
    try:
        chat_id = int(chat_id_raw)
    except ValueError:
        return render_template(
            "login.html", sent=False,
            error="That doesn't look like a Telegram numeric chat_id.",
        ), 400

    bound = get_bound_prophit_chat_id()

    # Rate-limit BEFORE we reveal anything about whether the chat_id is bound.
    if not _rate_limit_ok(chat_id):
        log.warning("rate-limited magic-link request chat_id=%s", chat_id)
        # Same generic response — never confirm/deny binding.
        return render_template("login.html", sent=True, error=None)

    # Bootstrap mode: when no Prophit is bound yet (pre-onboarding), accept ANY
    # chat_id. The first chat_id to complete onboarding becomes the binding.
    # After that, only the bound chat_id can issue magic links.
    allow = (bound is None) or (chat_id == bound)

    if allow:
        token = issue_magic_link_token(chat_id)
        # Build verify URL using the configured external base URL so the link
        # is clickable from outside (Tailscale, cloudflared, etc.).
        # Never use url_for(_external=True) — it produces the internal bind address.
        ext_base = load_config().external_url
        verify_url = f"{ext_base}/login/verify?t={token}"
        text = (
            "Your dashboard login link (valid 10 minutes, single-use):\n\n"
            f"{verify_url}\n\n"
            "If you didn't ask for this, ignore — the link expires shortly."
        )
        ok, detail = send_dm(chat_id, text, parse_mode="")
        if not ok:
            log.error("magic-link send failed chat_id=%s detail=%s", chat_id, detail)
            # Still render generic — don't tip off bad actors.
    else:
        # Drop the request silently; pretend we sent something.
        log.info("magic-link request for non-bound chat_id; dropped silently")

    return render_template("login.html", sent=True, error=None)


@bp.route("/login/verify")
def login_verify():
    token = request.args.get("t", "")
    if not token:
        return redirect(url_for("auth.login_page"))

    chat_id = verify_magic_link_token(token)
    if chat_id is None:
        return render_template(
            "login.html", sent=False,
            error="That link is expired, already used, or invalid. Request a new one.",
        ), 400

    bound = get_bound_prophit_chat_id()
    if bound is not None and chat_id != bound:
        log.warning("magic-link chat_id mismatch token=%s bound=%s", chat_id, bound)
        return render_template(
            "login.html", sent=False,
            error="That link wasn't issued for this Gawd.",
        ), 403
    # bound is None → bootstrap (pre-onboarding); accept and let onboarding set
    # the binding

    login_user(chat_id)
    log.info("login success chat_id=%s", chat_id)
    return redirect(url_for("root.index"))


@bp.route("/logout", methods=["POST"])
def logout():
    # dash-HIGH H1: logout is state-changing — POST-only (was POST+GET, which
    # allowed CSRF-style forced logout via a GET <img>/link). The footer uses a
    # small POST form carrying the CSRF token.
    session.clear()
    resp = make_response(redirect(url_for("auth.login_page")))
    return resp


# ── BLOCKER 4: voice-relay ticket minting ──

def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def issue_voice_ticket(chat_id: int) -> str:
    """
    Mint a short-lived signed voice-relay ticket for an authenticated chat_id.
    Portable HMAC-SHA256 over dashboard_signing.key; verified by browser-relay.mjs.
    NEVER returns or logs the signing key.
    """
    payload = {
        "cid": int(chat_id),
        "exp": int(time.time()) + VOICE_TICKET_TTL_S,
        "aud": VOICE_TICKET_AUD,
    }
    payload_b = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    p64 = _b64url(payload_b)
    sig = hmac.new(get_signing_key().encode("utf-8"), p64.encode("ascii"), hashlib.sha256).digest()
    return f"{p64}.{_b64url(sig)}"


@bp.route("/voice/ticket", methods=["POST"])
def voice_ticket():
    """
    Mint a voice-relay upgrade ticket for the current authenticated session.
    POST-only (state-bearing intent) → CSRF-enforced by the app-wide hook.
    Returns {"ticket": "...", "expires_in": N}. NEVER includes the signing key.
    """
    cid = require_auth()
    if cid is None:
        return jsonify({"error": "auth required"}), 401
    return jsonify({
        "ticket": issue_voice_ticket(cid),
        "expires_in": VOICE_TICKET_TTL_S,
    })
