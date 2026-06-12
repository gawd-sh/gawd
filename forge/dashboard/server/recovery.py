"""
recovery.py — Manual "Restart Gawd" button.

Per acceptance criterion: button visible ONLY when heartbeat is DEGRADED or OFFLINE
for >10 minutes. On tap, calls the B0 prophit-restart primitive
(gawd-prophit-restart.sh), which performs a real gateway restart and verifies
/health returns ok:true. It exits 0 only on a verified restart, non-zero on
failure — so the button reports success ONLY when a real restart succeeded.

Path discovery (in order):
  1. ${GAWD_RESTART_SCRIPT} env var
  2. /opt/gawd/scripts/gawd-prophit-restart.sh
  3. ~/.gawd/engine/scripts/gawd-prophit-restart.sh
  4. /usr/local/lib/gawd/scripts/gawd-prophit-restart.sh
  5. (forge dev only) /usr/local/lib/gawd/scripts/gawd-prophit-restart.sh

If none found: render an apology and a link to the runbook.

Safety: this is the only Prophit-facing surface that triggers a process restart,
so:
  - Rate-limited: 1 invocation per 60s per session
  - Logged with prophit_chat_id, timestamp, and resulting exit code
  - Returns a partial showing progress; if recovery doesn't restore health within
    60s, escalates the message to "still trying — contact us if this persists"
"""

from __future__ import annotations

import logging
import os
import subprocess
import time
from pathlib import Path
from typing import Optional

from flask import (
    Blueprint, jsonify, redirect, render_template, request, session, url_for,
)

from .auth import require_auth
from .heartbeat import read_status

log = logging.getLogger("gawd.dashboard.recovery")

bp = Blueprint("recovery", __name__)

RATE_LIMIT_S = 60

RESTART_PATHS = [
    os.environ.get("GAWD_RESTART_SCRIPT", ""),
    "/opt/gawd/scripts/gawd-prophit-restart.sh",
    str(Path.home() / ".gawd" / "engine" / "scripts" / "gawd-prophit-restart.sh"),
    "/usr/local/lib/gawd/scripts/gawd-prophit-restart.sh",
    "/usr/local/lib/gawd/scripts/gawd-prophit-restart.sh",
]


def _find_restart_script() -> Optional[Path]:
    for p in RESTART_PATHS:
        if not p:
            continue
        path = Path(p)
        if path.is_file() and os.access(path, os.X_OK):
            return path
    return None


@bp.route("/recovery/restart", methods=["POST"])
def restart_gawd():
    cid = require_auth()
    if cid is None:
        return redirect(url_for("auth.login_page"))

    last = session.get("recovery_last_at", 0)
    now = int(time.time())
    if now - last < RATE_LIMIT_S:
        return render_template("_recovery_result.html",
                               status="rate_limited",
                               message=f"Already triggered recently. Try again in {RATE_LIMIT_S - (now - last)}s."), 429

    # Gate on actual degraded state. Don't let healthy state restart for no reason.
    current = read_status()
    if current.state == "healthy":
        return render_template("_recovery_result.html",
                               status="not_needed",
                               message="I'm already responsive. No restart needed.")

    # Stamp the rate-limit window only after we've decided a restart is warranted —
    # a click while healthy must not burn the 60s window.
    session["recovery_last_at"] = now

    script = _find_restart_script()
    if script is None:
        log.error("no gawd-prophit-restart.sh found at any known path")
        return render_template("_recovery_result.html",
                               status="unavailable",
                               message=(
                                   "I can't find my recovery script on this rung. "
                                   "Contact whoever set me up; the runbook covers it."
                               )), 500

    log.info("recovery triggered by chat_id=%s script=%s", cid, script)
    try:
        r = subprocess.run([str(script)], capture_output=True, text=True, timeout=60)
        rc = r.returncode
        stderr_snippet = (r.stderr or "")[:300]
        log.info("recovery script rc=%s", rc)
    except subprocess.TimeoutExpired:
        log.warning("recovery script timed out")
        return render_template("_recovery_result.html",
                               status="timeout",
                               message=(
                                   "Recovery is taking longer than expected. I'll keep trying. "
                                   "If I'm still quiet in a few minutes, message my owner."
                               )), 504
    except (subprocess.SubprocessError, OSError) as e:
        log.error("recovery script failed: %s", type(e).__name__)
        return render_template("_recovery_result.html",
                               status="error",
                               message=(
                                   "The recovery attempt errored. I'm still here — try again in a moment."
                               )), 500

    if rc == 0:
        return render_template("_recovery_result.html",
                               status="ok",
                               message=(
                                   "Restarting now — give me about 30 seconds. "
                                   "The status bar turns green when I'm back."
                               ))
    else:
        return render_template("_recovery_result.html",
                               status="failed",
                               message=(
                                   "Recovery script ran but reported a problem. "
                                   "I'll keep trying. If silence persists, contact my owner."
                               )), 500
