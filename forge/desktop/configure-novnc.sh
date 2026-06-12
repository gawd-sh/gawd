#!/usr/bin/env bash
# =============================================================================
# configure-novnc.sh
# Gawd Desktop Stack — Phase 2: noVNC Configuration
# Spec: §8.1 (noVNC), §8.3 (per-rung notes)
# =============================================================================
#
# Configures noVNC to expose the xfce4/TigerVNC session via a browser-
# accessible HTML5 interface on a chosen port (default: 6080).
#
# install-desktop.sh handles the initial service install. This script handles:
#   - Port customization (for multi-Gawd hosted scenarios)
#   - noVNC path and SSL configuration
#   - Service unit regeneration if port changes
#   - Health-check verification
#
# IDEMPOTENT: safe to re-run. Backs up any unit it overwrites.
#
# Usage:
#   sudo ./configure-novnc.sh [--user <gawd-user>] [--novnc-port <port>]
#                              [--vnc-display <display>]
#
# Arguments:
#   --user         Linux user owning the session (default: gawd)
#   --novnc-port   Port for noVNC HTML5 frontend (default: 6080)
#   --vnc-display  TigerVNC X display number (default: 1; VNC port = 5900+display)
#
# Notes on multi-Gawd hosted rung:
#   On a hosted VPS running multiple Gawds, each Gawd needs a unique noVNC port
#   and VNC display. Canonical assignment: Gawd-1 = display :1/port 6080;
#   Gawd-2 = display :2/port 6081; etc. Tailscale Serve maps per-Gawd subdomain
#   to the correct port (configure-tailscale-serve.sh).
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
GAWD_USER="${GAWD_USER:-gawd}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_DISPLAY="${VNC_DISPLAY:-1}"
LOGFILE="/var/log/gawd-desktop-install.log"

# --------------------------------------------------------------------------- #
# Parse args
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)        GAWD_USER="$2";   shift 2 ;;
        --novnc-port)  NOVNC_PORT="$2";  shift 2 ;;
        --vnc-display) VNC_DISPLAY="$2"; shift 2 ;;
        *)             echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

exec > >(tee -a "$LOGFILE") 2>&1
echo "[$(date '+%Y-%m-%d %T')] configure-novnc.sh starting (user=$GAWD_USER, novnc-port=$NOVNC_PORT, vnc-display=$VNC_DISPLAY)"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: must be run as root" >&2
    exit 1
fi

if ! id "$GAWD_USER" &>/dev/null; then
    echo "ERROR: user '$GAWD_USER' does not exist" >&2
    exit 1
fi

VNC_PORT=$((5900 + VNC_DISPLAY))
NOVNC_UNIT="/etc/systemd/system/gawd-novnc.service"

# --------------------------------------------------------------------------- #
# Step 1: Verify noVNC and websockify are installed
# --------------------------------------------------------------------------- #
echo "[STEP 1] verify noVNC prerequisites"

if [[ ! -d /usr/share/novnc ]]; then
    echo "ERROR: /usr/share/novnc not found. Run install-desktop.sh first." >&2
    exit 1
fi

if ! command -v websockify &>/dev/null; then
    echo "ERROR: websockify not found. Run install-desktop.sh first." >&2
    exit 1
fi

echo "  noVNC: /usr/share/novnc present"
echo "  websockify: $(command -v websockify)"

# --------------------------------------------------------------------------- #
# Step 2: Check if noVNC index.html exists; create symlink if needed
# --------------------------------------------------------------------------- #
echo "[STEP 2] noVNC index.html"
NOVNC_INDEX="/usr/share/novnc/index.html"
if [[ ! -f "$NOVNC_INDEX" ]]; then
    # Some noVNC packages ship vnc.html as the entry point; create a symlink
    if [[ -f /usr/share/novnc/vnc.html ]]; then
        ln -sf /usr/share/novnc/vnc.html "$NOVNC_INDEX"
        echo "  created index.html → vnc.html symlink"
    else
        echo "  WARNING: no index.html or vnc.html found in /usr/share/novnc/"
    fi
else
    echo "  index.html present"
fi

# --------------------------------------------------------------------------- #
# Step 3: Write (or update) the gawd-novnc.service unit
# --------------------------------------------------------------------------- #
echo "[STEP 3] write gawd-novnc.service"

if [[ -f "$NOVNC_UNIT" ]]; then
    # Backup before overwriting
    cp "$NOVNC_UNIT" "${NOVNC_UNIT}.bak.novnc-$(date +%Y%m%d)"
    echo "  backed up existing unit"
fi

cat > "$NOVNC_UNIT" <<UNIT_EOF
[Unit]
Description=Gawd noVNC HTML5 frontend on 127.0.0.1:${NOVNC_PORT} (Tailscale-fronted)
# §8.1: noVNC exposes the xfce4 VNC session to the browser via websockify
After=gawd-vnc.service
Requires=gawd-vnc.service

[Service]
Type=simple
User=${GAWD_USER}
Group=${GAWD_USER}
# Binds to loopback only — Tailscale Serve provides the public-facing HTTPS
ExecStart=/usr/bin/websockify --web=/usr/share/novnc 127.0.0.1:${NOVNC_PORT} localhost:${VNC_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "  gawd-novnc.service written (port=$NOVNC_PORT, vnc=$VNC_PORT)"

# --------------------------------------------------------------------------- #
# Step 4: Reload and restart
# --------------------------------------------------------------------------- #
echo "[STEP 4] reload + restart"
systemctl daemon-reload
systemctl enable gawd-novnc.service

if systemctl is-active --quiet gawd-novnc.service; then
    systemctl restart gawd-novnc.service
    echo "  gawd-novnc.service restarted"
else
    systemctl start gawd-novnc.service
    echo "  gawd-novnc.service started"
fi

sleep 2

# --------------------------------------------------------------------------- #
# Step 5: Verify port is listening
# --------------------------------------------------------------------------- #
echo "[STEP 5] verify port $NOVNC_PORT"

RETRIES=5
for i in $(seq 1 $RETRIES); do
    if ss -tlnp | grep -q ":${NOVNC_PORT}"; then
        echo "  port $NOVNC_PORT: LISTENING"
        break
    fi
    if [[ $i -eq $RETRIES ]]; then
        echo "  WARNING: port $NOVNC_PORT not listening after ${RETRIES}s"
        echo "  Check: journalctl -u gawd-novnc.service --no-pager -n 20"
    fi
    sleep 1
done

# --------------------------------------------------------------------------- #
# Step 6: Output summary for configure-tailscale-serve.sh
# --------------------------------------------------------------------------- #
echo "[DONE] noVNC configured."
echo "  noVNC URL (after Tailscale Serve): https://<gawd>.tail<NET>.ts.net/vnc.html"
echo "  Internal URL: http://127.0.0.1:${NOVNC_PORT}/vnc.html"
echo "  noVNC port to use in configure-tailscale-serve.sh: ${NOVNC_PORT}"
echo "[$(date '+%Y-%m-%d %T')] configure-novnc.sh complete"
