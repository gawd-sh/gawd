"""
meeting.py — The Meeting modal.

Per spec §5: the first-conversation event. 5 movements. NOT a feature tour. NOT
skippable (per §5.3). Renders B1's canonical.md with the same variable substitution
that meeting-playback.sh uses.

Variables (interpolated from IDENTITY.md):
  {{address_name}}     — how Gawd addresses the Prophit
  {{gawd_name}}        — the Gawd's name
  {GAWD_NAME_DEFIANT}  — boolean, gates a branch in Movement 3
  {{pace}}             — daily | weekly | when-relevant
  {TODAY_ISO}          — date of onboarding

Branching in Movement 3:
  - PROPHIT_PACE drives three variants (daily / weekly / when-relevant)
  - GAWD_NAME_DEFIANT=true unlocks an additional preamble

Modal cannot be dismissed until completed. We record completion in
~/.gawd/state/meeting-completed.json. If completed, subsequent visits to /meeting
redirect to /chat.
"""

from __future__ import annotations

import json
import logging
import re
import time
from pathlib import Path
from typing import Optional

from flask import (
    Blueprint, jsonify, redirect, render_template, request, url_for,
)

from .auth import require_auth
from .config import GAWD_HOME, IDENTITY_MD, MEETING_CANONICAL

log = logging.getLogger("gawd.dashboard.meeting")

bp = Blueprint("meeting", __name__)

MEETING_COMPLETED_FILE = GAWD_HOME / "state" / "meeting-completed.json"
MEETING_RESPONSES_FILE = GAWD_HOME / "state" / "meeting-responses.jsonl"


def _read_identity() -> dict:
    """Parse IDENTITY.md into a flat dict. Returns empty if missing."""
    if not IDENTITY_MD.is_file():
        return {}
    try:
        text = IDENTITY_MD.read_text(encoding="utf-8")
    except OSError:
        return {}
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("- ") and ":" in line:
            k, _, v = line[2:].partition(":")
            out[k.strip()] = v.strip()
    return out


def _split_movements(canonical: str) -> list[tuple[str, str]]:
    """
    Split canonical.md into [(title, body), ...] for each movement.
    Movements are H2 sections starting with "## Movement N:".
    """
    # Drop HTML comments and the leading title block.
    pattern = re.compile(r"^## (Movement \d+: [^\n]+)\s*$", re.MULTILINE)
    matches = list(pattern.finditer(canonical))
    out: list[tuple[str, str]] = []
    for i, m in enumerate(matches):
        title = m.group(1).strip()
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(canonical)
        body = canonical[start:end].strip()
        # Strip HTML comments within the body
        body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL).strip()
        out.append((title, body))
    return out


def _apply_pace_branch(body: str, pace: str, gawd_defiant: bool) -> str:
    """
    Resolve Movement 3 conditionals:
      {if PROPHIT_PACE == "daily"} ... {/if PROPHIT_PACE == "daily"}
      {if GAWD_NAME_DEFIANT} ... {/if GAWD_NAME_DEFIANT}
    """
    # GAWD_NAME_DEFIANT block
    def repl_defiant(match: re.Match) -> str:
        return match.group(1) if gawd_defiant else ""
    body = re.sub(
        r"\{if GAWD_NAME_DEFIANT\}(.*?)\{/if GAWD_NAME_DEFIANT\}",
        repl_defiant, body, flags=re.DOTALL,
    )

    # PROPHIT_PACE branches
    def repl_pace(match: re.Match) -> str:
        branch_pace = match.group(1)
        content = match.group(2)
        return content if branch_pace == pace else ""
    body = re.sub(
        r'\{if PROPHIT_PACE == "([^"]+)"\}(.*?)\{/if PROPHIT_PACE == "\1"\}',
        repl_pace, body, flags=re.DOTALL,
    )

    return body.strip()


def _substitute_vars(body: str, identity: dict, today_iso: str) -> str:
    """Substitute {{var}} and {VAR} placeholders. Same semantics as meeting-playback.sh."""
    address_name = identity.get("prophit_address") or identity.get("prophit_name", "you")
    gawd_name = identity.get("gawd_name", "Gawd")
    pace = identity.get("prophit_pace", "when-relevant")

    body = body.replace("{{address_name}}", address_name)
    body = body.replace("{{gawd_name}}", gawd_name)
    body = body.replace("{{pace}}", pace)
    body = body.replace("{TODAY_ISO}", today_iso)
    return body


def _is_completed() -> bool:
    return MEETING_COMPLETED_FILE.is_file()


def _mark_completed(chat_id: int) -> None:
    MEETING_COMPLETED_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(MEETING_COMPLETED_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "prophit_chat_id": chat_id,
            }, f)
    except OSError as e:
        log.error("meeting completion write failed: %s", type(e).__name__)


def _record_response(chat_id: int, movement: int, response: str) -> None:
    MEETING_RESPONSES_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(MEETING_RESPONSES_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "ts": int(time.time()),
                "prophit_chat_id": chat_id,
                "movement": movement,
                "response": response[:5000],
            }) + "\n")
    except OSError as e:
        log.error("meeting response append failed: %s", type(e).__name__)


# ── Routes ──

@bp.route("/meeting", methods=["GET"])
def show():
    cid = require_auth()
    if cid is None:
        return redirect(url_for("auth.login_page"))

    if _is_completed():
        return redirect(url_for("chat.chat_page"))

    if not MEETING_CANONICAL.is_file():
        log.error("meeting/canonical.md not present at %s", MEETING_CANONICAL)
        return render_template("meeting/missing.html"), 500

    try:
        canonical = MEETING_CANONICAL.read_text(encoding="utf-8")
    except OSError as e:
        log.error("meeting canonical unreadable: %s", type(e).__name__)
        return render_template("meeting/missing.html"), 500

    identity = _read_identity()
    today_iso = identity.get("onboarded_iso") or time.strftime("%Y-%m-%d")
    pace = identity.get("prophit_pace", "when-relevant")
    defiant = (identity.get("gawd_name_defiant", "false").lower() == "true")

    raw_movements = _split_movements(canonical)
    rendered = []
    for title, body in raw_movements:
        body = _apply_pace_branch(body, pace, defiant)
        body = _substitute_vars(body, identity, today_iso)
        rendered.append({"title": title, "body": body})

    return render_template(
        "meeting/show.html",
        movements=rendered,
        today_iso=today_iso,
    )


@bp.route("/meeting/respond/<int:movement>", methods=["POST"])
def respond(movement: int):
    cid = require_auth()
    if cid is None:
        return redirect(url_for("auth.login_page"))
    response = (request.form.get("response") or "").strip()
    if movement not in {3, 5}:
        return jsonify({"error": "invalid movement"}), 400
    if not response:
        return jsonify({"error": "empty response"}), 400
    _record_response(cid, movement, response)
    return jsonify({"ok": True})


@bp.route("/meeting/complete", methods=["POST"])
def complete():
    cid = require_auth()
    if cid is None:
        return redirect(url_for("auth.login_page"))
    _mark_completed(cid)
    return jsonify({"ok": True, "next": url_for("chat.chat_page")})
