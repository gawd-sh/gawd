#!/usr/bin/env bash
# gawd-failure-alert.sh — fired by gawd-failure-alert@.service OnFailure.
# Sends a Prophit Telegram alert when a supervised unit gives up (entered
# 'failed' after exhausting StartLimitBurst). NEVER echoes the token.
#
# Usage: gawd-failure-alert.sh <failed-unit-name>
#
# Part of hardening 2 (crashloop circuit-breaker): a genuinely broken service
# gives up within ~1 minute and ALERTS the Prophit, rather than either storming
# (79K restarts) or dying silent. Silence-is-worst-outcome: a degraded daemon
# that tells the Prophit beats one that wedges quietly.
#
# CRED RESOLUTION (B1, 2026-05-28 fix): the alert MUST reach the Prophit with no
# separate provisioning step. We resolve the bot token + chat_id from the SAME
# source the daemon's own Telegram channel uses — the live openclaw.json
# `channels.telegram` block:
#   - chat_id  ← channels.telegram.allowFrom[0]  (the Prophit/admin id)
#   - token    ← channels.telegram.botToken {source,provider,id} resolved through
#                secrets.providers.<provider> (source:file → JSON key = id sans '/')
# This makes the alert automatically correct on any onboarded daemon. The legacy
# secrets-vault path (`secrets` helper / secrets.json telegram_* keys) remains a
# fallback for configs that pre-date channels.telegram. NEVER echoes the token.
#
# H1 (2026-05-28): the send is retried 3× with backoff; on total failure the
# alert is appended to a pending-alerts queue that watchdog/sweep.sh retries on
# its next cadence — a single dropped curl never loses the alert.
set -uo pipefail
UNIT="${1:-unknown.service}"
SECRETS_JSON="${HOME}/.openclaw/secrets/secrets.json"
OPENCLAW_JSON="${OPENCLAW_CONFIG:-${HOME}/.openclaw/openclaw.json}"
GAWD_HOME="${GAWD_HOME:-$HOME/.gawd}"
LOG="${GAWD_HOME}/logs/reliability.log"
PENDING="${GAWD_HOME}/state/pending-alerts"
mkdir -p "$(dirname "$LOG")" "$(dirname "$PENDING")" 2>/dev/null || true

NREST="$(systemctl --user show "$UNIT" --property=NRestarts --value 2>/dev/null \
         || systemctl show "$UNIT" --property=NRestarts --value 2>/dev/null || echo '?')"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo gawd)"
TS_CT="$(TZ=America/Chicago date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"
MSG="⚠️ Gawd reliability: ${UNIT} on ${HOSTNAME_SHORT} gave up after repeated restarts (NRestarts=${NREST}) at ${TS_CT}. The daemon stopped looping to protect your machine. It may need attention — open the dashboard or message me."

printf '%s ALERT unit=%s nrestarts=%s\n' "$(date -u +%FT%TZ)" "$UNIT" "$NREST" >> "$LOG" 2>/dev/null || true

# ── Resolve Telegram creds (no echo) ─────────────────────────────────────────
TG_TOKEN=""; CHAT_ID=""

# Primary (B1): resolve from the daemon's own channels.telegram, via openclaw.json.
# Token resolution mirrors OpenClaw's: botToken.{source,provider,id} → look up the
# provider in secrets.providers; for a file/json provider, the value is the JSON
# key named by `id` (leading '/' stripped). The chat_id is allowFrom[0].
if [[ -z "$TG_TOKEN" || -z "$CHAT_ID" ]] && [[ -f "$OPENCLAW_JSON" ]]; then
  _resolved="$(python3 - "$OPENCLAW_JSON" "$SECRETS_JSON" <<'PY' 2>/dev/null || true
import json, sys, os
cfg_path, fallback_secrets = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(cfg_path))
except Exception:
    sys.exit(0)
tg = (cfg.get("channels") or {}).get("telegram") or {}

# chat_id ← allowFrom[0] (the Prophit/admin id the daemon already trusts).
chat_id = ""
allow = tg.get("allowFrom") or []
if isinstance(allow, list) and allow:
    chat_id = str(allow[0]).strip()

# token ← resolve botToken template through secrets.providers.
token = ""
bt = tg.get("botToken")
if isinstance(bt, str):           # rare: literal token inline
    token = bt
elif isinstance(bt, dict):
    src = bt.get("source"); prov = bt.get("provider"); key = (bt.get("id") or "").lstrip("/")
    if src == "env":
        token = os.environ.get(key, "") or os.environ.get(bt.get("id",""), "")
    elif src == "file":
        providers = ((cfg.get("secrets") or {}).get("providers")) or {}
        pdef = providers.get(prov) or {}
        path = pdef.get("path") or fallback_secrets
        mode = pdef.get("mode", "json")
        try:
            if mode == "json":
                token = str(json.load(open(path)).get(key, "") or "")
            else:
                # raw/text provider: whole-file is the token
                token = open(path).read().strip()
        except Exception:
            token = ""
# Emit on two lines: token, chat_id. Caller reads via mapfile — never echoed.
print(token)
print(chat_id)
PY
)"
  if [[ -n "$_resolved" ]]; then
    TG_TOKEN="$(printf '%s\n' "$_resolved" | sed -n '1p')"
    CHAT_ID="$(printf '%s\n' "$_resolved" | sed -n '2p')"
  fi
  unset _resolved
fi

# Fallback 1: secrets vault helper.
if [[ -z "$TG_TOKEN" || -z "$CHAT_ID" ]] && command -v secrets >/dev/null 2>&1; then
  [[ -z "$TG_TOKEN" ]] && TG_TOKEN="$(secrets get TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  [[ -z "$CHAT_ID"  ]] && CHAT_ID="$(secrets get TELEGRAM_ADMIN_CHAT_ID 2>/dev/null || true)"
fi
# Fallback 2: legacy secrets.json explicit telegram_* keys (Dasra/Lilith-style).
if [[ -z "$TG_TOKEN" || -z "$CHAT_ID" ]] && [[ -f "$SECRETS_JSON" ]]; then
  [[ -z "$TG_TOKEN" ]] && TG_TOKEN="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('telegram_bot_token',''))" "$SECRETS_JSON" 2>/dev/null || true)"
  [[ -z "$CHAT_ID"  ]] && CHAT_ID="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('telegram_admin_chat_id',''))" "$SECRETS_JSON" 2>/dev/null || true)"
fi

# ── Send (H1: 3 attempts w/ backoff; on total failure queue for sweep retry) ──
if [[ -n "$TG_TOKEN" && -n "$CHAT_ID" ]]; then
  _sent=0
  for i in 1 2 3; do
    if curl -sf -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
         -d "chat_id=${CHAT_ID}" --data-urlencode "text=${MSG}" >/dev/null 2>&1; then
      _sent=1; break
    fi
    printf '%s WARN telegram send attempt %d failed for %s\n' "$(date -u +%FT%TZ)" "$i" "$UNIT" >> "$LOG" 2>/dev/null || true
    [[ "$i" -lt 3 ]] && sleep 5
  done
  if [[ "$_sent" -eq 1 ]]; then
    printf '%s OK telegram alert delivered for %s\n' "$(date -u +%FT%TZ)" "$UNIT" >> "$LOG" 2>/dev/null || true
  else
    # All attempts failed — queue for sweep.sh retry. Store chat_id + message only
    # (NEVER the token; sweep re-resolves the token from config at retry time).
    printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$CHAT_ID" "$MSG" >> "$PENDING" 2>/dev/null || true
    printf '%s WARN telegram send failed 3x for %s — queued to pending-alerts\n' "$(date -u +%FT%TZ)" "$UNIT" >> "$LOG" 2>/dev/null || true
  fi
else
  printf '%s WARN no telegram creds resolvable (config+vault) — alert for %s logged only\n' "$(date -u +%FT%TZ)" "$UNIT" >> "$LOG" 2>/dev/null || true
fi
exit 0
