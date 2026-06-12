"""
app.py — Flask app factory for the Gawd dashboard.

Run via:
  GAWD_DASHBOARD_PORT=8090 GAWD_DASHBOARD_EXPOSURE=local \
    python -m gawd_dashboard.server.app

Or via gunicorn (production):
  gunicorn -w 1 -k gthread --threads 16 \
    --bind 127.0.0.1:8090 \
    'gawd_dashboard.server.app:create_app()'

Note: w=1 because the heartbeat SSE + chat SSE keep long-lived connections open.
Multiple workers would each tail the file-queue independently — works correctly
but wastes the inotify-like overhead. v1 single-Prophit volume: 1 worker is plenty.
"""

from __future__ import annotations

import datetime as _dt
import logging
import os
from pathlib import Path

from flask import Blueprint, Flask, redirect, render_template, url_for

from .config import (
    DashboardConfig, ensure_runtime_dirs, get_signing_key, load_config,
)
from .auth import bp as auth_bp, current_user, require_auth
from .csrf import register_csrf
from .chat import bp as chat_bp
from .fallback_ingest import bp as fallback_bp, read_banner
from .heartbeat import bp as heartbeat_bp
from .meeting import bp as meeting_bp
from .onboarding import bp as onboarding_bp
from .recovery import bp as recovery_bp
from .settings import bp as settings_bp
from .tithe import bp as tithe_bp

log = logging.getLogger("gawd.dashboard.app")

# Resolve template/static dirs relative to this file (works dev + production).
_HERE = Path(__file__).resolve().parent
_FORGE_ROOT = _HERE.parent  # /usr/local/lib/gawd/dashboard
TEMPLATE_DIR = str(_FORGE_ROOT / "templates")
STATIC_DIR = str(_FORGE_ROOT / "static")


# dash-HIGH H1: the dashboard has no cross-site entry flow (magic-link verify is
# a top-level GET navigation, which SameSite=Strict permits). Strict is the
# correct posture and a defense-in-depth layer atop the CSRF token check.
SESSION_COOKIE_SAMESITE = "Strict"


root_bp = Blueprint("root", __name__)


@root_bp.route("/")
def index():
    cid = require_auth()
    if cid is None:
        return redirect(url_for("auth.login_page"))

    # Determine where to land:
    # - No onboarding yet → /onboarding
    # - Onboarded, not met → /meeting
    # - Otherwise → /chat
    from .config import IDENTITY_FILE
    from .meeting import _is_completed

    if not IDENTITY_FILE.is_file():
        return redirect(url_for("onboarding.start"))
    if not _is_completed():
        return redirect(url_for("meeting.show"))
    return redirect(url_for("chat.chat_page"))


@root_bp.route("/healthz")
def healthz():
    """Liveness probe for systemd / load balancer. Pure file-read; no LLM, no gateway."""
    return {"ok": True, "service": "gawd-dashboard"}, 200


def _configure_logging(cfg: DashboardConfig) -> None:
    level = getattr(logging, cfg.log_level.upper(), logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def create_app() -> Flask:
    cfg = load_config()
    _configure_logging(cfg)
    ensure_runtime_dirs()

    app = Flask(
        __name__,
        template_folder=TEMPLATE_DIR,
        static_folder=STATIC_DIR,
    )
    app.config["SECRET_KEY"] = get_signing_key()
    app.config["PERMANENT_SESSION_LIFETIME"] = _dt.timedelta(days=cfg.session_ttl_days)
    app.config["SESSION_COOKIE_HTTPONLY"] = True
    app.config["SESSION_COOKIE_SAMESITE"] = SESSION_COOKIE_SAMESITE
    # Secure cookie: only when exposed via TLS-fronting
    app.config["SESSION_COOKIE_SECURE"] = cfg.exposure in {"tailscale", "cloudflared"}

    # Register blueprints
    app.register_blueprint(root_bp)
    app.register_blueprint(auth_bp)
    app.register_blueprint(heartbeat_bp)
    app.register_blueprint(chat_bp)
    app.register_blueprint(onboarding_bp)
    app.register_blueprint(meeting_bp)
    app.register_blueprint(tithe_bp)
    app.register_blueprint(settings_bp)
    app.register_blueprint(recovery_bp)
    app.register_blueprint(fallback_bp)

    # dash-HIGH H1: centralized CSRF enforcement (hand-rolled, itsdangerous-based,
    # no Flask-WTF dep). Covers every state-changing method on every route except
    # the explicit allowlist in csrf.py (magic-link send, G2 HMAC ingest, healthz).
    register_csrf(app)

    @app.context_processor
    def inject_globals():
        return {
            "novnc_url": cfg.novnc_url,
            "has_novnc": cfg.has_novnc,
            "exposure": cfg.exposure,
            "current_user_chat_id": current_user(),
            "banner": read_banner(),
        }

    @app.errorhandler(404)
    def not_found(e):
        return render_template("404.html"), 404

    @app.errorhandler(500)
    def internal(e):
        log.error("500: %s", e)
        return render_template("500.html"), 500

    log.info(
        "gawd-dashboard ready bind=%s:%s exposure=%s gateway=%s novnc=%s",
        cfg.bind_host, cfg.bind_port, cfg.exposure, cfg.gateway_url,
        cfg.novnc_url or "(unset)",
    )
    return app


if __name__ == "__main__":
    cfg = load_config()
    app = create_app()
    app.run(host=cfg.bind_host, port=cfg.bind_port, debug=False, threaded=True)
