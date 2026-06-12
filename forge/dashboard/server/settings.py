"""
settings.py — Adaptive USER.md edits + read-only views of soul-tier files.

Per §15 (SIL gate): SOUL.md and IDENTITY.md *base* sections are Prophit-approval-
gated. Only USER.md's adaptive section is freely editable here. v1 skeleton makes
this concrete:

  - GET  /settings              → form with editable fields (pace, language, address-name)
  - POST /settings              → patch USER.md adaptive section + reflect into IDENTITY.md
                                  (the address_name field is mirrored)
  - GET  /settings/personality  → READ-ONLY view of SOUL.md + IDENTITY.md base
                                  + a "Propose change" button that creates an
                                  SIL revelation entry (G... not in v1 skeleton scope;
                                  for v1 the button just records to ~/.gawd/state/
                                  sil-proposals.jsonl)
  - GET  /settings/tithe-history → list of tithe intents (consume tithe.py history)
  - GET  /settings/skills       → list of installed skills (read ~/.gawd/skills/*/metadata.json)
  - GET  /settings/revelations  → recent ~/.gawd/state/revelations/*.json

USER.md format reused from A1 persona-templates. Adaptive section delimited by:
  <!-- USER.md.adaptive.begin -->
  ...
  <!-- USER.md.adaptive.end -->
"""

from __future__ import annotations

import json
import logging
import re
import time
from pathlib import Path

from flask import Blueprint, redirect, render_template, request, url_for

from .auth import require_auth
from .config import GAWD_HOME, IDENTITY_MD, PERSONA_DIR, SOUL_MD, USER_MD

log = logging.getLogger("gawd.dashboard.settings")

bp = Blueprint("settings", __name__)

ADAPTIVE_BEGIN = "<!-- USER.md.adaptive.begin -->"
ADAPTIVE_END = "<!-- USER.md.adaptive.end -->"

SIL_PROPOSALS_FILE = GAWD_HOME / "state" / "sil-proposals.jsonl"
REVELATIONS_DIR = GAWD_HOME / "state" / "revelations"
SKILLS_DIR = GAWD_HOME / "skills"


# ── USER.md adaptive section ──

def _read_adaptive() -> dict:
    """
    Returns the parsed adaptive section as a {key: value} dict.
    Format (within the adaptive markers):
        - pace: daily
        - language: en
        - address_name: Avery
    """
    if not USER_MD.is_file():
        return {}
    try:
        text = USER_MD.read_text(encoding="utf-8")
    except OSError:
        return {}
    m = re.search(
        re.escape(ADAPTIVE_BEGIN) + r"(.*?)" + re.escape(ADAPTIVE_END),
        text, re.DOTALL,
    )
    if not m:
        return {}
    body = m.group(1)
    out: dict[str, str] = {}
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("- ") and ":" in line:
            k, _, v = line[2:].partition(":")
            out[k.strip()] = v.strip()
    return out


def _write_adaptive(updates: dict) -> bool:
    """Atomic update of the adaptive section. Creates the file if missing."""
    PERSONA_DIR.mkdir(parents=True, exist_ok=True)
    if USER_MD.is_file():
        try:
            text = USER_MD.read_text(encoding="utf-8")
            # Backup
            bak = USER_MD.with_suffix(f".md.bak-dashboard-{int(time.time())}")
            bak.write_text(text, encoding="utf-8")
        except OSError as e:
            log.error("USER.md backup failed: %s", type(e).__name__)
            return False
    else:
        text = (
            "# USER.md\n\n"
            f"{ADAPTIVE_BEGIN}\n"
            f"{ADAPTIVE_END}\n"
        )

    existing = _read_adaptive()
    existing.update({k: v for k, v in updates.items() if v is not None and v != ""})

    new_body = "\n".join(f"- {k}: {v}" for k, v in existing.items())
    new_section = f"{ADAPTIVE_BEGIN}\n{new_body}\n{ADAPTIVE_END}"

    if ADAPTIVE_BEGIN in text:
        new_text = re.sub(
            re.escape(ADAPTIVE_BEGIN) + r".*?" + re.escape(ADAPTIVE_END),
            new_section, text, count=1, flags=re.DOTALL,
        )
    else:
        new_text = text.rstrip() + "\n\n" + new_section + "\n"

    tmp = USER_MD.with_suffix(".md.tmp")
    try:
        tmp.write_text(new_text, encoding="utf-8")
        tmp.replace(USER_MD)
        log.info("USER.md updated keys=%s", list(updates.keys()))
        return True
    except OSError as e:
        log.error("USER.md write failed: %s", type(e).__name__)
        return False


# ── Routes ──

@bp.route("/settings", methods=["GET"])
def settings_page():
    if require_auth() is None:
        return redirect(url_for("auth.login_page"))
    return render_template("settings.html", values=_read_adaptive(), saved=False)


@bp.route("/settings", methods=["POST"])
def settings_save():
    if require_auth() is None:
        return redirect(url_for("auth.login_page"))

    updates = {
        "pace": request.form.get("pace", "").strip(),
        "language": request.form.get("language", "").strip(),
        "address_name": request.form.get("address_name", "").strip(),
    }
    ok = _write_adaptive({k: v for k, v in updates.items() if v})
    return render_template("settings.html", values=_read_adaptive(), saved=ok)


@bp.route("/settings/personality", methods=["GET"])
def personality():
    if require_auth() is None:
        return redirect(url_for("auth.login_page"))
    soul = SOUL_MD.read_text(encoding="utf-8") if SOUL_MD.is_file() else "(SOUL.md not present)"
    identity = IDENTITY_MD.read_text(encoding="utf-8") if IDENTITY_MD.is_file() else "(IDENTITY.md not present)"
    return render_template("personality.html", soul=soul, identity=identity)


@bp.route("/settings/personality/propose", methods=["POST"])
def propose_change():
    cid = require_auth()
    if cid is None:
        return redirect(url_for("auth.login_page"))
    target = request.form.get("target", "").strip()
    description = request.form.get("description", "").strip()
    if target not in {"SOUL", "IDENTITY"} or not description:
        return render_template("_sil_proposal.html", ok=False, error="Invalid proposal."), 400
    SIL_PROPOSALS_FILE.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "ts": int(time.time()),
        "prophit_chat_id": cid,
        "target": target,
        "description": description[:2000],
        "status": "open",
    }
    try:
        with open(SIL_PROPOSALS_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        return render_template("_sil_proposal.html", ok=True, error=None)
    except OSError as e:
        log.error("sil proposal write failed: %s", type(e).__name__)
        return render_template("_sil_proposal.html", ok=False, error="Could not record."), 500


@bp.route("/settings/skills", methods=["GET"])
def skills_view():
    if require_auth() is None:
        return redirect(url_for("auth.login_page"))
    skills = []
    if SKILLS_DIR.is_dir():
        for d in sorted(SKILLS_DIR.iterdir()):
            if not d.is_dir():
                continue
            meta_path = d / "metadata.json"
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.is_file() else {}
            except (OSError, json.JSONDecodeError):
                meta = {}
            skills.append({"name": d.name, "meta": meta})
    return render_template("skills.html", skills=skills)


@bp.route("/settings/revelations", methods=["GET"])
def revelations_view():
    if require_auth() is None:
        return redirect(url_for("auth.login_page"))
    items = []
    if REVELATIONS_DIR.is_dir():
        for fp in sorted(REVELATIONS_DIR.glob("*.json"), reverse=True)[:50]:
            try:
                items.append({"name": fp.name, "data": json.loads(fp.read_text(encoding="utf-8"))})
            except (OSError, json.JSONDecodeError):
                continue
    return render_template("revelations.html", items=items)
