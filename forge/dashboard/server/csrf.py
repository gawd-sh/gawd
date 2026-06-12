"""
csrf.py — dash-HIGH H1: hand-rolled CSRF protection (no Flask-WTF dependency).

Flask-WTF is NOT in the dashboard's dependency set (install.sh pins only Flask,
itsdangerous, gunicorn, requests). Rather than add a dependency, this reuses the
SAME signing-key family as auth.py (itsdangerous + ~/.gawd/.secrets/
dashboard_signing.key) to mint and verify a per-session CSRF token.

Model:
  - Token = itsdangerous-signed value bound to the session's chat_id (or a
    per-session random nonce pre-auth). Same secret key as the session cookie.
  - Tokens carry an issue timestamp and are accepted for CSRF_TOKEN_TTL_S.
  - Templates emit the token via the `csrf_token()` Jinja global (hidden field
    AND a <meta> tag); HTMX sends it on every request via a body-level
    `hx-headers` attribute as the `X-CSRF-Token` header.
  - Enforcement is CENTRALIZED in a before_request hook (register_csrf) so every
    state-changing method (POST/PUT/PATCH/DELETE) is covered without per-route
    edits — closing the whole bug class, not just the listed routes.

Safe methods (GET/HEAD/OPTIONS) and a small allowlist (the magic-link send and
the G2 machine-to-machine ingest, which authenticate by other means) are exempt.
NEVER logs token values.
"""

from __future__ import annotations

import logging
import secrets as _secrets

from flask import current_app, g, jsonify, request, session
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from .config import get_signing_key

log = logging.getLogger("gawd.dashboard.csrf")

CSRF_TOKEN_TTL_S = 60 * 60 * 12  # 12h — comfortably longer than a session sits idle
CSRF_HEADER = "X-CSRF-Token"
CSRF_FORM_FIELD = "csrf_token"
CSRF_SALT = "gawd-dashboard-csrf-v1"

# Routes (by endpoint name) exempt from CSRF because they authenticate by a
# non-cookie mechanism and have no ambient-authority risk:
#   - auth.login_send : pre-session magic-link request, rate-limited, no session
#   - auth.login_page : GET (also covered by safe-method check)
#   - fallback_ingest.ingest : G2 machine path, HMAC shared-secret auth
#   - root.healthz : liveness probe
_CSRF_EXEMPT_ENDPOINTS = {
    "auth.login_send",
    "fallback_ingest.ingest",
    "root.healthz",
    "static",
}

_SAFE_METHODS = {"GET", "HEAD", "OPTIONS", "TRACE"}


def _serializer() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(secret_key=get_signing_key(), salt=CSRF_SALT)


def _session_nonce() -> str:
    """Stable per-session nonce the CSRF token is bound to. Survives login (we
    do NOT clear it on login_user) so a token minted on the login page stays
    valid after authentication within its TTL."""
    nonce = session.get("_csrf_nonce")
    if not nonce:
        nonce = _secrets.token_urlsafe(16)
        session["_csrf_nonce"] = nonce
    return nonce


def generate_csrf_token() -> str:
    """Mint a signed CSRF token bound to this session's nonce."""
    return _serializer().dumps({"n": _session_nonce()})


def _token_valid(token: str) -> bool:
    if not token:
        return False
    try:
        payload = _serializer().loads(token, max_age=CSRF_TOKEN_TTL_S)
    except SignatureExpired:
        log.info("csrf token expired")
        return False
    except BadSignature:
        log.warning("csrf token bad signature")
        return False
    if not isinstance(payload, dict):
        return False
    # Bind to the current session nonce — a token from another session is invalid.
    expected = session.get("_csrf_nonce")
    return bool(expected) and _secrets.compare_digest(str(payload.get("n", "")), str(expected))


def _submitted_token() -> str:
    # HTMX/AJAX send it as a header; classic form posts as a hidden field.
    hdr = request.headers.get(CSRF_HEADER, "")
    if hdr:
        return hdr
    return request.form.get(CSRF_FORM_FIELD, "")


def register_csrf(app) -> None:
    """Wire CSRF enforcement + the csrf_token() template global into the app."""

    @app.before_request
    def _enforce_csrf():
        if request.method in _SAFE_METHODS:
            return None
        endpoint = request.endpoint or ""
        if endpoint in _CSRF_EXEMPT_ENDPOINTS:
            return None
        if _token_valid(_submitted_token()):
            return None
        log.warning("CSRF rejected method=%s endpoint=%s", request.method, endpoint)
        return jsonify({"error": "csrf validation failed"}), 400

    @app.context_processor
    def _inject_csrf():
        # Lazily mint so every rendered page carries a valid token.
        return {"csrf_token": generate_csrf_token}
