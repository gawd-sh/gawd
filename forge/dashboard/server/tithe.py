"""
tithe.py — Tap-to-tithe.

Per §12 (tithing) and acceptance criteria in handoff: G6 does NOT implement payment
rails (E3 owns the rails plugin abstraction). G6 writes tithe-INTENT records to
~/.gawd/state/tithe-intents.jsonl. Downstream payment integration consumes these.

Tiers (per §12.1): $1, $5, $25, custom. One-time OR recurring (monthly).

Flow:
  GET  /tithe                 → modal with tier selector
  POST /tithe/intent          → record + render thank-you partial
"""

from __future__ import annotations

import json
import logging
import time
from typing import Optional

from flask import Blueprint, redirect, render_template, request, url_for

from .auth import require_auth
from .config import TITHE_INTENTS_FILE

log = logging.getLogger("gawd.dashboard.tithe")

bp = Blueprint("tithe", __name__)

VALID_TIERS = {"1", "5", "25", "custom"}
VALID_CADENCES = {"one-time", "recurring"}
MAX_CUSTOM = 10000  # cents-times-100; basic sanity bound, $100 = 100 in dollars-int


def _record_intent(chat_id: int, amount_cents: int, cadence: str, note: Optional[str]) -> bool:
    TITHE_INTENTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "ts": int(time.time()),
        "prophit_chat_id": chat_id,
        "amount_cents": amount_cents,
        "cadence": cadence,
        "note": (note or "").strip()[:280],
        "source": "dashboard",
        "status": "intent",  # downstream payment integration moves to 'pending' → 'paid'
    }
    try:
        with open(TITHE_INTENTS_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        log.info("tithe intent recorded chat_id=%s amount_cents=%s cadence=%s",
                 chat_id, amount_cents, cadence)
        return True
    except OSError as e:
        log.error("tithe intent append failed: %s", type(e).__name__)
        return False


def _load_history(chat_id: int, limit: int = 50) -> list[dict]:
    if not TITHE_INTENTS_FILE.is_file():
        return []
    out = []
    try:
        with open(TITHE_INTENTS_FILE, "r", encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                    if rec.get("prophit_chat_id") == chat_id:
                        out.append(rec)
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return out[-limit:]


@bp.route("/tithe", methods=["GET"])
def tithe_modal():
    if require_auth() is None:
        return redirect(url_for("auth.login_page"))
    return render_template("tithe.html", history=_load_history(require_auth() or 0))


@bp.route("/tithe/intent", methods=["POST"])
def tithe_intent():
    cid = require_auth()
    if cid is None:
        return redirect(url_for("auth.login_page"))

    tier = request.form.get("tier", "").strip()
    cadence = request.form.get("cadence", "one-time").strip()
    note = request.form.get("note", "")

    if tier not in VALID_TIERS:
        return render_template("_tithe_result.html", ok=False,
                               error="Choose $1, $5, $25, or custom."), 400
    if cadence not in VALID_CADENCES:
        return render_template("_tithe_result.html", ok=False,
                               error="Cadence must be one-time or recurring."), 400

    if tier == "custom":
        try:
            custom_dollars = int(request.form.get("custom_amount", "").strip())
        except ValueError:
            return render_template("_tithe_result.html", ok=False,
                                   error="Custom amount must be a whole number of dollars."), 400
        if custom_dollars < 1 or custom_dollars > MAX_CUSTOM:
            return render_template("_tithe_result.html", ok=False,
                                   error=f"Custom amount must be between $1 and ${MAX_CUSTOM}."), 400
        amount_cents = custom_dollars * 100
    else:
        amount_cents = int(tier) * 100

    ok = _record_intent(cid, amount_cents, cadence, note)
    return render_template("_tithe_result.html", ok=ok, error=None if ok else "Could not record. Try again.",
                           amount_cents=amount_cents, cadence=cadence)
