#!/usr/bin/env bash
# install.sh — Idempotent installer for the Gawd dashboard (G6).
#
# Per-rung deployment (Q19e — deploy-time, not build-time):
#   GAWD_DASHBOARD_EXPOSURE=local        → loopback only (bare-metal default)
#   GAWD_DASHBOARD_EXPOSURE=tailscale    → bind 0.0.0.0, provision Tailscale Serve
#   GAWD_DASHBOARD_EXPOSURE=cloudflared  → bind 127.0.0.1, provision cloudflared tunnel
#
# Per spec §19.3.2: dashboard runs as its OWN systemd unit. NO dependency on
# the OpenClaw gateway being up. Heartbeat reads watchdog files directly.
#
# Called by: top-level forge install.sh (A3) — but is fully usable standalone.
#
# Safe to re-run. Each step is idempotent and creates a .bak of anything overwritten.

set -euo pipefail

# ── Source/dest paths ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SERVER="${SCRIPT_DIR}/server"
SRC_TEMPLATES="${SCRIPT_DIR}/templates"
SRC_STATIC="${SCRIPT_DIR}/static"
SRC_SYSTEMD="${SCRIPT_DIR}/systemd"

# Install destination — venv lives under XDG_DATA_HOME, code under ~/.gawd
GAWD_HOME="${GAWD_HOME:-${HOME}/.gawd}"
DASH_DIR="${GAWD_HOME}/dashboard"
VENV_DIR="${HOME}/.local/share/gawd-dashboard/venv"
SECRETS_DIR="${GAWD_HOME}/.secrets"

EXPOSURE="${GAWD_DASHBOARD_EXPOSURE:-local}"
PORT="${GAWD_DASHBOARD_PORT:-8090}"

log() { printf '[gawd-dashboard install] %s\n' "$*"; }

# ── Step 1: directories ───────────────────────────────────────────────────────

log "creating directories"
mkdir -p "${DASH_DIR}/server" "${DASH_DIR}/templates" "${DASH_DIR}/static"
mkdir -p "${GAWD_HOME}/state" "${GAWD_HOME}/dashboard/queue" "${GAWD_HOME}/dashboard/processed"
mkdir -p "${SECRETS_DIR}"
chmod 0700 "${SECRETS_DIR}"

# ── Step 2: copy code (with backup) ───────────────────────────────────────────

backup_if_present() {
    local target="$1"
    if [[ -e "$target" ]]; then
        local bak="${target}.bak-$(date +%Y%m%d%H%M%S)"
        cp -a "$target" "$bak"
        log "backed up ${target} -> ${bak}"
    fi
}

log "copying server code"
backup_if_present "${DASH_DIR}/server"
rm -rf "${DASH_DIR}/server"
cp -a "${SRC_SERVER}" "${DASH_DIR}/server"

log "copying templates"
backup_if_present "${DASH_DIR}/templates"
rm -rf "${DASH_DIR}/templates"
cp -a "${SRC_TEMPLATES}" "${DASH_DIR}/templates"

log "copying static"
rm -rf "${DASH_DIR}/static"
cp -a "${SRC_STATIC}" "${DASH_DIR}/static"

# Place a copy of the source app.py at the working dir so systemd ExecStart works
# (gunicorn imports `server.app` relative to WorkingDirectory).

# ── Step 3: venv + deps ───────────────────────────────────────────────────────

if [[ ! -d "${VENV_DIR}" ]]; then
    log "creating venv at ${VENV_DIR}"
    mkdir -p "$(dirname "${VENV_DIR}")"
    python3 -m venv "${VENV_DIR}"
fi

log "installing python deps"
"${VENV_DIR}/bin/pip" install --upgrade pip >/dev/null
"${VENV_DIR}/bin/pip" install --quiet \
    'Flask>=3.0,<4.0' \
    'itsdangerous>=2.1,<3.0' \
    'gunicorn>=21.0,<23.0' \
    'requests>=2.31,<3.0'

# ── Step 4: secrets ───────────────────────────────────────────────────────────

if [[ ! -s "${SECRETS_DIR}/dashboard_signing.key" ]]; then
    log "generating dashboard_signing.key (one-time)"
    umask 077
    head -c 48 /dev/urandom | base64 | tr -d '=+/\n' | head -c 64 > "${SECRETS_DIR}/dashboard_signing.key"
    chmod 0600 "${SECRETS_DIR}/dashboard_signing.key"
fi

if [[ ! -s "${SECRETS_DIR}/fallback_ingest.key" ]]; then
    log "generating fallback_ingest.key (shared with G2 deliver/dashboard.sh)"
    umask 077
    head -c 48 /dev/urandom | base64 | tr -d '=+/\n' | head -c 64 > "${SECRETS_DIR}/fallback_ingest.key"
    chmod 0600 "${SECRETS_DIR}/fallback_ingest.key"
fi

if [[ ! -s "${SECRETS_DIR}/telegram.token" ]]; then
    log "WARN: ~/.gawd/.secrets/telegram.token not present"
    log "      magic-link login will fail until you create it"
    log "      cat > ${SECRETS_DIR}/telegram.token <<'EOF'"
    log "      <your-telegram-bot-token>"
    log "      EOF"
    log "      chmod 0600 ${SECRETS_DIR}/telegram.token"
fi

# ── Step 5: env file ──────────────────────────────────────────────────────────

ENV_FILE="${DASH_DIR}/dashboard.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    log "writing dashboard.env (exposure=${EXPOSURE} port=${PORT})"
    bind_host="127.0.0.1"
    if [[ "${EXPOSURE}" == "tailscale" ]]; then
        bind_host="0.0.0.0"
    fi
    cat > "${ENV_FILE}" <<EOF
# gawd-dashboard runtime environment
# Edit this and \`systemctl --user restart gawd-dashboard\` to apply.

GAWD_HOME=${GAWD_HOME}
GAWD_DASHBOARD_PORT=${PORT}
GAWD_DASHBOARD_BIND_HOST=${bind_host}
GAWD_DASHBOARD_EXPOSURE=${EXPOSURE}
GAWD_GATEWAY_URL=http://127.0.0.1:18789
GAWD_NOVNC_URL=${GAWD_NOVNC_URL:-}
GAWD_LOG_LEVEL=INFO
GAWD_SESSION_TTL_DAYS=30
GAWD_SILENCE_THRESHOLD_S=30
GAWD_FORGE_BAKE=${GAWD_FORGE_BAKE:-/opt/gawd/onboarding/bake.sh}
EOF
    chmod 0600 "${ENV_FILE}"
else
    log "dashboard.env exists; leaving in place"
fi

# ── Step 6: systemd user unit ────────────────────────────────────────────────
# GAWD_NO_SYSTEMD=1 (Logos v1-assembly ruling 2026-05-28): the docker rung has
# no `systemd --user` PID 1. We still write the unit file (so a VM/bare-metal
# substrate that later runs systemd has it), but we skip every systemctl call
# and instead launch gunicorn via nohup in Step 8. This is an assembly wrapper,
# NOT a change to the dashboard application logic.

UNIT_DST="${HOME}/.config/systemd/user/gawd-dashboard.service"
mkdir -p "$(dirname "${UNIT_DST}")"
backup_if_present "${UNIT_DST}"
cp "${SRC_SYSTEMD}/gawd-dashboard.service" "${UNIT_DST}"
log "systemd user unit file written at ${UNIT_DST}"

if [[ "${GAWD_NO_SYSTEMD:-0}" == "1" ]]; then
    log "GAWD_NO_SYSTEMD=1 — skipping systemctl daemon-reload/enable (docker rung; gunicorn launched via nohup in Step 8)"
else
    systemctl --user daemon-reload
    log "systemd user unit installed at ${UNIT_DST}"

    # Enable linger so the unit survives logout.
    if command -v loginctl >/dev/null 2>&1; then
        if ! loginctl show-user "${USER}" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
            log "enabling linger for ${USER}"
            sudo loginctl enable-linger "${USER}" || \
                log "WARN: could not enable linger (sudo needed); dashboard won't survive logout"
        fi
    fi

    systemctl --user enable gawd-dashboard.service >/dev/null 2>&1 || true
    log "systemctl --user enable gawd-dashboard.service done"
fi

# ── Step 7: per-rung exposure provisioning ────────────────────────────────────

case "${EXPOSURE}" in
    local)
        log "exposure=local — no tunnel/serve to provision"
        ;;
    tailscale)
        log "exposure=tailscale — provisioning Tailscale Serve on https://...ts.net/dashboard"
        if command -v tailscale >/dev/null 2>&1; then
            sudo tailscale serve --bg --https=443 --set-path /dashboard "http://127.0.0.1:${PORT}" \
                && log "tailscale serve configured" \
                || log "WARN: tailscale serve failed (run manually after Gawd is up)"
        else
            log "WARN: tailscale CLI not present. Install it, then:"
            log "  sudo tailscale serve --bg --https=443 --set-path /dashboard http://127.0.0.1:${PORT}"
        fi
        ;;
    cloudflared)
        log "exposure=cloudflared — see runbook for tunnel provisioning (G6 leaves cloudflared config to D1's pattern)"
        ;;
    *)
        log "WARN: unknown exposure '${EXPOSURE}'; defaulting to local"
        ;;
esac

# ── Step 8: start ────────────────────────────────────────────────────────────

if [[ "${GAWD_NO_SYSTEMD:-0}" == "1" ]]; then
    # Docker rung: launch gunicorn directly via nohup (no systemd PID 1).
    # bind host/port come from dashboard.env we wrote above.
    log "GAWD_NO_SYSTEMD=1 — launching gunicorn via nohup (docker rung)"
    bind_host="127.0.0.1"
    if [[ "${EXPOSURE}" == "tailscale" ]]; then
        bind_host="0.0.0.0"
    fi
    GUNICORN_BIN="${VENV_DIR}/bin/gunicorn"
    LOG_DIR="${DASH_DIR}/logs"
    mkdir -p "${LOG_DIR}"
    PIDFILE="${DASH_DIR}/gunicorn.pid"

    # Idempotent: if a gunicorn is already serving healthz, don't start a second.
    if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
        log "OK dashboard already serving on :${PORT}/healthz — skipping launch"
    else
        ( cd "${DASH_DIR}" && \
          GAWD_HOME="${GAWD_HOME}" \
          GAWD_DASHBOARD_PORT="${PORT}" \
          GAWD_DASHBOARD_BIND_HOST="${bind_host}" \
          GAWD_DASHBOARD_EXPOSURE="${EXPOSURE}" \
          GAWD_GATEWAY_URL="http://127.0.0.1:18789" \
          nohup "${GUNICORN_BIN}" \
              --workers 1 \
              --worker-class gthread \
              --threads 16 \
              --pid "${PIDFILE}" \
              --bind "${bind_host}:${PORT}" \
              --access-logfile "${LOG_DIR}/access.log" \
              --error-logfile "${LOG_DIR}/error.log" \
              "server.app:create_app()" \
              >> "${LOG_DIR}/nohup.log" 2>&1 & )

        # Wait up to 15s for healthz to come up.
        _up=0
        for _i in $(seq 1 15); do
            if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
                _up=1; break
            fi
            sleep 1
        done
        if [[ "$_up" == "1" ]]; then
            log "OK gunicorn serving on http://127.0.0.1:${PORT}/healthz"
        else
            log "FAIL gunicorn did not answer /healthz within 15s"
            log "error log tail:"
            tail -20 "${LOG_DIR}/error.log" 2>/dev/null || true
            exit 1
        fi
    fi
else
    log "starting gawd-dashboard.service"
    systemctl --user restart gawd-dashboard.service

    sleep 2
    if systemctl --user is-active gawd-dashboard.service >/dev/null 2>&1; then
        log "OK gawd-dashboard.service is active"
        log "test: curl -fsS http://127.0.0.1:${PORT}/healthz"
    else
        log "FAIL gawd-dashboard.service did not start"
        systemctl --user status gawd-dashboard.service --no-pager || true
        exit 1
    fi
fi

log "done."
