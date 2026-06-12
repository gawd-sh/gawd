"""
onboarding.py — Web wizard mirroring A4 bash state machine.

Per spec §4: 4 questions, under 90s, then the Meeting. The web form is the
EQUIVALENT of A4's wizard.sh, not a replacement. Same questions, same validation,
same outputs (PROPHIT_NAME, PROPHIT_ADDRESS, GAWD_NAME, GAWD_NAME_DEFIANT,
PROPHIT_LANG, PROPHIT_TZ, PROPHIT_TZ_UNCERTAIN, PROPHIT_PACE).

Flow:
  GET  /onboarding             → step 1 (Q1)
  POST /onboarding/q1          → validate, redirect to step 2
  GET  /onboarding/q2
  POST /onboarding/q2
  GET  /onboarding/q3
  POST /onboarding/q3
  GET  /onboarding/q4
  POST /onboarding/q4          → on success: invoke bake.sh, then redirect to /meeting

State carried in Flask session (small payload, all validated). On Q4 commit, we
shell out to ${GAWD_FORGE}/onboarding/bake.sh with the env vars set, identical to
how /usr/local/bin/gawd-onboard would call wizard.sh's bake step.

For v1 skeleton: if bake.sh is not present in the forge layout, we still write
IDENTITY.md + USER.md inline (minimal version) so the dashboard remains useful
during development. Production install via install.sh ensures bake.sh is found.

ALSO writes a binding record to ~/.gawd/state/identity.json with the prophit's
Telegram chat_id (form field Q1b: "Your Telegram chat_id") so the magic-link auth
can route subsequent logins.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Optional

from flask import (
    Blueprint, redirect, render_template, request, session, url_for,
)

from .config import (
    GAWD_HOME, IDENTITY_FILE, IDENTITY_MD, PERSONA_DIR, USER_MD,
)

log = logging.getLogger("gawd.dashboard.onboarding")

bp = Blueprint("onboarding", __name__)

# Reuse the A4 helpers via subprocess if forge present; else duck-type here.
FORGE_BAKE = Path(os.environ.get("GAWD_FORGE_BAKE", "/opt/gawd/onboarding/bake.sh"))

LANG_MAP = {
    "english": "en", "en": "en",
    "spanish": "es", "es": "es", "español": "es", "espanol": "es",
    "french": "fr", "fr": "fr", "français": "fr",
    "german": "de", "de": "de", "deutsch": "de",
    "portuguese": "pt", "pt": "pt",
    "japanese": "ja", "ja": "ja",
    "chinese": "zh", "zh": "zh", "mandarin": "zh",
    "korean": "ko", "ko": "ko",
    "italian": "it", "it": "it",
    "arabic": "ar", "ar": "ar",
    "hindi": "hi", "hi": "hi",
    "russian": "ru", "ru": "ru",
}

TZ_ABBREV_MAP = {
    "UTC": "UTC", "GMT": "UTC",
    "EST": "America/New_York", "EDT": "America/New_York",
    "CST": "America/Chicago", "CDT": "America/Chicago",
    "MST": "America/Denver", "MDT": "America/Denver",
    "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
    "CET": "Europe/Paris", "CEST": "Europe/Paris",
    "BST": "Europe/London",
    "IST": "Asia/Kolkata", "JST": "Asia/Tokyo",
    "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney",
}

DEFIANT_PATTERNS = {
    "i'm not naming you", "im not naming you", "i won't name you", "i wont name you",
    "no", "no name", "none", "you name yourself", "i don't know", "i dont know",
    "nope", "pass", "skip", "no thanks", "no thank you", "not naming you",
}

PACE_MAP = {
    "1": "daily", "daily": "daily", "day": "daily", "d": "daily",
    "2": "weekly", "weekly": "weekly", "week": "weekly", "w": "weekly",
    "3": "when-relevant", "on cue": "when-relevant", "on-cue": "when-relevant",
    "cue": "when-relevant", "when-relevant": "when-relevant",
    "when relevant": "when-relevant", "r": "when-relevant",
}


def _is_valid_tz(tz: str) -> bool:
    for prefix in ("/usr/share/zoneinfo", "/usr/share/lib/zoneinfo", "/usr/lib/locale/zoneinfo"):
        if Path(f"{prefix}/{tz}").is_file():
            return True
    try:
        import zoneinfo
        zoneinfo.ZoneInfo(tz)
        return True
    except Exception:
        return False


def _resolve_tz(raw: str) -> Optional[str]:
    raw = (raw or "").strip()
    if not raw:
        return None
    if _is_valid_tz(raw):
        return raw
    mapped = TZ_ABBREV_MAP.get(raw.upper())
    if mapped and _is_valid_tz(mapped):
        return mapped
    return None


def _onboard_state() -> dict:
    return session.setdefault("onboarding", {})


def _save_state(updates: dict) -> None:
    state = _onboard_state()
    state.update(updates)
    session["onboarding"] = state
    session.modified = True


# ── Routes ──

@bp.route("/onboarding", methods=["GET"])
def start():
    session["onboarding"] = {}
    return redirect(url_for("onboarding.q1"))


@bp.route("/onboarding/q1", methods=["GET"])
def q1():
    return render_template("onboarding/q1.html", state=_onboard_state(), error=None)


@bp.route("/onboarding/q1", methods=["POST"])
def q1_submit():
    name = (request.form.get("name") or "").strip()
    address = (request.form.get("address") or "").strip() or name
    chat_id_raw = (request.form.get("telegram_chat_id") or "").strip()

    if not name:
        return render_template("onboarding/q1.html",
                               state=_onboard_state(),
                               error="I need something to call you."), 400

    try:
        chat_id = int(chat_id_raw)
    except ValueError:
        return render_template("onboarding/q1.html",
                               state=_onboard_state(),
                               error="Telegram chat_id must be a number (find it via @userinfobot)."), 400

    _save_state({"name": name, "address": address, "telegram_chat_id": chat_id})
    return redirect(url_for("onboarding.q2"))


@bp.route("/onboarding/q2", methods=["GET"])
def q2():
    return render_template("onboarding/q2.html", state=_onboard_state(), error=None)


@bp.route("/onboarding/q2", methods=["POST"])
def q2_submit():
    raw = (request.form.get("gawd_name") or "").strip()
    if not raw:
        _save_state({"gawd_name": "Gawd", "gawd_name_defiant": False})
    elif raw.lower() in DEFIANT_PATTERNS:
        _save_state({"gawd_name": "Gawd", "gawd_name_defiant": True})
    elif len(raw) > 40:
        return render_template("onboarding/q2.html",
                               state=_onboard_state(),
                               error="That's a long one — something shorter?"), 400
    else:
        _save_state({"gawd_name": raw, "gawd_name_defiant": False})
    return redirect(url_for("onboarding.q3"))


@bp.route("/onboarding/q3", methods=["GET"])
def q3():
    return render_template("onboarding/q3.html", state=_onboard_state(), error=None)


@bp.route("/onboarding/q3", methods=["POST"])
def q3_submit():
    lang_raw = (request.form.get("language") or "").strip().lower()
    tz_raw = (request.form.get("timezone") or "").strip()

    lang = LANG_MAP.get(lang_raw) or LANG_MAP.get(lang_raw.split()[0] if lang_raw else "", "en")
    tz_resolved = _resolve_tz(tz_raw)
    tz_uncertain = False
    if not tz_resolved:
        tz_resolved = "UTC"
        tz_uncertain = True

    _save_state({
        "lang": lang,
        "tz": tz_resolved,
        "tz_uncertain": tz_uncertain,
    })
    return redirect(url_for("onboarding.q4"))


@bp.route("/onboarding/q4", methods=["GET"])
def q4():
    return render_template("onboarding/q4.html", state=_onboard_state(), error=None)


@bp.route("/onboarding/q4", methods=["POST"])
def q4_submit():
    pace_raw = (request.form.get("pace") or "").strip().lower()
    pace = PACE_MAP.get(pace_raw, "when-relevant")
    _save_state({"pace": pace})

    state = _onboard_state()

    # Try forge bake.sh first; fall back to inline minimal write.
    used_bake = False
    if FORGE_BAKE.is_file() and os.access(FORGE_BAKE, os.X_OK):
        env = os.environ.copy()
        env.update({
            "GAWD_WORKSPACE": str(GAWD_HOME),
            "PROPHIT_NAME": state.get("name", ""),
            "PROPHIT_ADDRESS": state.get("address", ""),
            "GAWD_NAME": state.get("gawd_name", "Gawd"),
            "GAWD_NAME_DEFIANT": "true" if state.get("gawd_name_defiant") else "false",
            "PROPHIT_LANG": state.get("lang", "en"),
            "PROPHIT_TZ": state.get("tz", "UTC"),
            "PROPHIT_TZ_UNCERTAIN": "true" if state.get("tz_uncertain") else "false",
            "PROPHIT_PACE": state.get("pace", "when-relevant"),
            "TODAY_ISO": time.strftime("%Y-%m-%d"),
        })
        try:
            r = subprocess.run([str(FORGE_BAKE)], env=env, capture_output=True, text=True, timeout=60)
            if r.returncode == 0:
                used_bake = True
            else:
                log.warning("forge bake.sh failed rc=%s stderr=%s", r.returncode, r.stderr[:500])
        except (subprocess.SubprocessError, OSError) as e:
            log.warning("forge bake.sh invocation failed: %s", type(e).__name__)

    if not used_bake:
        _inline_bake(state)

    # Write identity.json with the chat_id binding
    IDENTITY_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(IDENTITY_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "prophit_telegram_chat_id": int(state.get("telegram_chat_id", 0)),
                "prophit_name": state.get("name", ""),
                "gawd_name": state.get("gawd_name", "Gawd"),
                "onboarded_iso": time.strftime("%Y-%m-%d"),
                "bake_path": "forge" if used_bake else "inline",
            }, f, indent=2)
    except OSError as e:
        log.error("identity.json write failed: %s", type(e).__name__)

    # Stash for meeting render
    session["onboarded"] = True
    return redirect(url_for("meeting.show"))


def _inline_bake(state: dict) -> None:
    """Minimal IDENTITY.md + USER.md write. Production should use forge bake.sh."""
    PERSONA_DIR.mkdir(parents=True, exist_ok=True)
    today = time.strftime("%Y-%m-%d")

    identity_md = (
        "# IDENTITY.md\n\n"
        f"- prophit_name: {state.get('name', '')}\n"
        f"- prophit_address: {state.get('address', '')}\n"
        f"- gawd_name: {state.get('gawd_name', 'Gawd')}\n"
        f"- gawd_name_defiant: {'true' if state.get('gawd_name_defiant') else 'false'}\n"
        f"- prophit_lang: {state.get('lang', 'en')}\n"
        f"- prophit_tz: {state.get('tz', 'UTC')}\n"
        f"- prophit_tz_uncertain: {'true' if state.get('tz_uncertain') else 'false'}\n"
        f"- prophit_pace: {state.get('pace', 'when-relevant')}\n"
        f"- onboarded_iso: {today}\n"
    )
    try:
        IDENTITY_MD.write_text(identity_md, encoding="utf-8")
    except OSError as e:
        log.error("inline bake IDENTITY.md write failed: %s", type(e).__name__)

    user_md = (
        "# USER.md\n\n"
        "<!-- USER.md.adaptive.begin -->\n"
        f"- pace: {state.get('pace', 'when-relevant')}\n"
        f"- language: {state.get('lang', 'en')}\n"
        f"- address_name: {state.get('address', '')}\n"
        "<!-- USER.md.adaptive.end -->\n"
    )
    try:
        USER_MD.write_text(user_md, encoding="utf-8")
    except OSError as e:
        log.error("inline bake USER.md write failed: %s", type(e).__name__)
