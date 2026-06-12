"""
punt.py — Punt-to-desktop affordance.

Per maintainer clarification 2026-05-27 (Dashboard ↔ Desktop boundary):

  Dashboard renders: chat, status, simple media (images, audio clips ≤25 MB), controls,
                     onboarding, settings, Meeting, tithing tap, recovery button.

  Desktop (noVNC) renders: video files, large/streaming media, complex desktop apps.

This module owns the BOUNDARY: when a request would push the dashboard past its
capability envelope, we render a "Open in Gawd's desktop" affordance instead of
attempting it inline.

For v1 skeleton, the heuristic is keyword-based on the outbound message text
(triggers: "play video", "show me <url-to-mp4>", "open <desktop-app>"). When the
chat protocol matures to support attachments / content types, swap this for a
content-type check.

If GAWD_NOVNC_URL is unset, the dashboard renders an apology instead of a punt
("I can show you, but my desktop isn't installed here — open me on the rung that
has it.").
"""

from __future__ import annotations

import logging
import re
from typing import Optional

from .config import load_config

log = logging.getLogger("gawd.dashboard.punt")

# Patterns that trigger a punt.
_VIDEO_EXTS = (".mp4", ".mov", ".webm", ".mkv", ".avi", ".flv")
_PUNT_KEYWORDS = (
    "play video", "show video", "watch video",
    "open desktop", "show desktop", "browse to",
    "open browser", "open firefox", "open chrome",
    "screenshare", "screen share", "screen-share",
)


def detect_punt_reason(text: str) -> Optional[str]:
    """Returns a short reason if we should punt, else None."""
    low = text.lower()
    for ext in _VIDEO_EXTS:
        if ext in low:
            return f"video content ({ext})"
    for kw in _PUNT_KEYWORDS:
        if kw in low:
            return kw
    # Detect URLs that look like videos
    if re.search(r"https?://\S+\.(mp4|mov|webm|mkv|avi)\b", low):
        return "video URL"
    return None


def maybe_punt_to_desktop(text: str) -> Optional[dict]:
    """
    Inspect text. If we should punt, return a dict with:
      - reason: short label
      - message: in-Gawd-voice deflection text
      - novnc_url: the URL to open (if configured)
    Else return None.
    """
    reason = detect_punt_reason(text)
    if reason is None:
        return None

    cfg = load_config()
    return {
        "reason": reason,
        "novnc_url": cfg.novnc_url,  # may be None — template handles both cases
        # Plain-text fallback for clients that render record.text directly.
        "message": (
            f"That ({reason}) is desktop-class. "
            + ("Open my desktop and we'll watch together." if cfg.novnc_url
               else "My desktop isn't installed on this rung — catch me where I have a screen.")
        ),
    }
