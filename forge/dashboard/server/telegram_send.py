"""
telegram_send.py — Direct-curl Telegram delivery (no MCP).

Per GAWDFATHER-DOCTRINE §7.5 and feedback_telegram_must_call_reply_tool: when the
dashboard sends Telegram messages (magic-link delivery, optional notifications), it
uses the Bot API directly — NEVER through an MCP plugin (the plugin may be the
thing that's down).

Token source: ~/.gawd/.secrets/telegram.token (per reference_bot_identities,
matches Lilith pattern).
"""

from __future__ import annotations

import logging
from typing import Tuple

import requests

from .config import get_telegram_token

log = logging.getLogger("gawd.dashboard.telegram_send")

_BOT_API = "https://api.telegram.org"


def send_dm(chat_id: int, text: str, parse_mode: str = "Markdown") -> Tuple[bool, str]:
    """
    Send a Telegram DM via direct Bot API curl.

    Returns (success, detail). detail is safe to log (never contains the token).
    """
    token = get_telegram_token()
    if not token:
        return False, "telegram_token_missing"

    url = f"{_BOT_API}/bot{token}/sendMessage"
    try:
        resp = requests.post(
            url,
            json={"chat_id": chat_id, "text": text, "parse_mode": parse_mode},
            timeout=10,
        )
    except requests.RequestException as e:
        log.warning("telegram send network error: %s", type(e).__name__)
        return False, f"network_error:{type(e).__name__}"

    if resp.status_code != 200:
        # Body MAY contain the token in error scenarios? No — Telegram never echoes it.
        # But strip just in case.
        body = (resp.text or "")[:200]
        log.warning("telegram send non-200: %s body=%s", resp.status_code, body)
        return False, f"http_{resp.status_code}"

    return True, "ok"


def verify_bot_identity() -> Tuple[bool, str]:
    """
    Verify the token works by calling getMe. Returns (ok, bot_username_or_error).

    Per feedback_diagnose_secrets_without_leaking: extract only id+username, never
    log the raw response.
    """
    token = get_telegram_token()
    if not token:
        return False, "telegram_token_missing"

    try:
        resp = requests.get(f"{_BOT_API}/bot{token}/getMe", timeout=10)
    except requests.RequestException as e:
        return False, f"network_error:{type(e).__name__}"

    if resp.status_code != 200:
        return False, f"http_{resp.status_code}"

    try:
        data = resp.json()
        username = data.get("result", {}).get("username", "?")
        bot_id = data.get("result", {}).get("id", "?")
        return True, f"@{username} (id={bot_id})"
    except (ValueError, KeyError):
        return False, "malformed_response"
