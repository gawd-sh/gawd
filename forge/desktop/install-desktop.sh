#!/usr/bin/env bash
# =============================================================================
# install-desktop.sh
# Gawd Desktop Stack — Phase 1: Base Install
# Spec: §8.1 (stack), §8.3 (per-rung notes)
# =============================================================================
#
# Installs xfce4 + browser (Chromium preferred, Firefox fallback) + TigerVNC
# + noVNC + websockify on a clean Debian/Ubuntu base.
#
# IDEMPOTENT: safe to re-run. Each step checks current state before acting.
# RUNTIME: under 10 minutes on a well-connected VPS (apt cache warmed).
#
# Usage:
#   sudo ./install-desktop.sh [--user <gawd-user>] [--browser chromium|firefox]
#
# Arguments:
#   --user       Linux user who will own the desktop session (default: gawd)
#   --browser    Browser to prefer: "chromium" (default) or "firefox"
#
# Called by:
#   - Forge tarball install.sh (A3) at setup time
#   - Per-rung override scripts in per-rung/ (for rung-specific tweaks)
#
# Assumptions:
#   - Debian / Ubuntu base (apt package manager)
#   - Running as root (sudo)
#   - Tailscale already joined the tailnet (A3 installs + joins before this)
#   - Port 5901 (VNC) + 6080 (noVNC) used internally; never opened in UFW
#     (Tailscale Serve fronts them — see configure-tailscale-serve.sh)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
GAWD_USER="${GAWD_USER:-gawd}"
BROWSER_PREF="${BROWSER_PREF:-chromium}"
LOGFILE="/var/log/gawd-desktop-install.log"

# --------------------------------------------------------------------------- #
# Parse args
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)     GAWD_USER="$2";   shift 2 ;;
        --browser)  BROWSER_PREF="$2"; shift 2 ;;
        *)          echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #
exec > >(tee -a "$LOGFILE") 2>&1
echo "[$(date '+%Y-%m-%d %T')] install-desktop.sh starting (user=$GAWD_USER, browser=$BROWSER_PREF)"

# --------------------------------------------------------------------------- #
# Verify caller is root
# --------------------------------------------------------------------------- #
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: must be run as root (sudo ./install-desktop.sh)" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Verify user exists
# --------------------------------------------------------------------------- #
if ! id "$GAWD_USER" &>/dev/null; then
    echo "ERROR: user '$GAWD_USER' does not exist. Create it before running." >&2
    exit 1
fi

GAWD_HOME="$(getent passwd "$GAWD_USER" | cut -d: -f6)"

# --------------------------------------------------------------------------- #
# Helper: check if a package is installed
# --------------------------------------------------------------------------- #
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# --------------------------------------------------------------------------- #
# Step 1: apt update (refresh only; do not upgrade — idempotent)
# --------------------------------------------------------------------------- #
echo "[STEP 1] apt update"
apt-get update -qq

# --------------------------------------------------------------------------- #
# Step 2: Install xfce4
# §8.1: "xfce4 — Lightweight desktop environment"
# --------------------------------------------------------------------------- #
echo "[STEP 2] xfce4"
if pkg_installed xfce4; then
    echo "  xfce4 already installed — skipping"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xfce4 xfce4-goodies dbus-x11
    echo "  xfce4 installed"
fi

# --------------------------------------------------------------------------- #
# Step 3: Install browser
# §8.1: "Firefox or Chromium — browser the Gawd uses for research"
# Chromium is preferred (lighter, better for headless DemiGawd use via
# Xvfb/VNC). Firefox is the fallback if Chromium is not available.
# --------------------------------------------------------------------------- #
echo "[STEP 3] browser ($BROWSER_PREF preferred)"
BROWSER_INSTALLED=false

if [[ "$BROWSER_PREF" == "chromium" ]]; then
    # Try chromium-browser (Ubuntu snap wrapper) or chromium (Debian)
    if pkg_installed chromium-browser || pkg_installed chromium; then
        echo "  Chromium already installed — skipping"
        BROWSER_INSTALLED=true
    else
        # Try chromium-browser first (Ubuntu), then chromium (Debian)
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chromium-browser 2>/dev/null; then
            echo "  chromium-browser installed"
            BROWSER_INSTALLED=true
        elif DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chromium 2>/dev/null; then
            echo "  chromium installed"
            BROWSER_INSTALLED=true
        else
            echo "  WARNING: Chromium not available in apt; falling back to Firefox"
        fi
    fi
fi

if ! $BROWSER_INSTALLED; then
    # Firefox fallback
    if pkg_installed firefox || pkg_installed firefox-esr; then
        echo "  Firefox already installed — skipping"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq firefox-esr
        echo "  firefox-esr installed"
    fi
fi

# --------------------------------------------------------------------------- #
# Step 4: Install TigerVNC
# §8.1: noVNC requires a VNC server. TigerVNC matches Lilith's proven pattern.
# tigervnc-standalone-server includes tigervncserver binary.
# --------------------------------------------------------------------------- #
echo "[STEP 4] TigerVNC"
if pkg_installed tigervnc-standalone-server; then
    echo "  TigerVNC already installed — skipping"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tigervnc-standalone-server
    echo "  TigerVNC installed"
fi

# --------------------------------------------------------------------------- #
# Step 5: Install noVNC + websockify
# §8.1: "noVNC — browser-accessible VNC for Prophit-side viewing"
# Lilith uses: websockify --web=/usr/share/novnc 127.0.0.1:6080 localhost:5901
# --------------------------------------------------------------------------- #
echo "[STEP 5] noVNC + websockify"
if pkg_installed novnc && pkg_installed websockify; then
    echo "  noVNC + websockify already installed — skipping"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq novnc websockify
    echo "  noVNC + websockify installed"
fi

# --------------------------------------------------------------------------- #
# Step 6: Configure VNC for the gawd user
# Creates ~/.vnc/xstartup that launches xfce4.
# Matches Lilith's proven xstartup exactly (gospel §8.4 pattern).
# --------------------------------------------------------------------------- #
echo "[STEP 6] configure VNC xstartup for $GAWD_USER"

VNC_DIR="$GAWD_HOME/.vnc"
XSTARTUP="$VNC_DIR/xstartup"

# Backup if xstartup already exists and differs from canonical
if [[ -f "$XSTARTUP" ]]; then
    EXISTING_HASH=$(sha256sum "$XSTARTUP" | cut -d' ' -f1)
    CANONICAL_CONTENT=$'#!/bin/bash\nunset SESSION_MANAGER\nunset DBUS_SESSION_BUS_ADDRESS\nvncconfig -nowin &\nexec startxfce4'
    CANONICAL_HASH=$(echo "$CANONICAL_CONTENT" | sha256sum | cut -d' ' -f1)
    if [[ "$EXISTING_HASH" != "$CANONICAL_HASH" ]]; then
        cp "$XSTARTUP" "${XSTARTUP}.bak.desktop-$(date +%Y%m%d)"
        echo "  backed up existing xstartup"
    else
        echo "  xstartup already canonical — skipping"
    fi
fi

mkdir -p "$VNC_DIR"

cat > "$XSTARTUP" <<'XSTARTUP_EOF'
#!/bin/bash
# Gawd VNC xstartup — launches xfce4
# Pattern from Lilith/Asgard (gospel §8.4)
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
vncconfig -nowin &
exec startxfce4
XSTARTUP_EOF

chmod 0755 "$XSTARTUP"
chown "$GAWD_USER:$GAWD_USER" "$XSTARTUP"
chown "$GAWD_USER:$GAWD_USER" "$VNC_DIR"
echo "  xstartup written"

# --------------------------------------------------------------------------- #
# Step 7: Create a VNC passwd file (no-auth mode — security via Tailscale)
# TigerVNC in SecurityTypes=None mode does not need a passwd file, but
# tigervncserver may create ~/.vnc/config if needed. No passwd file required.
# Security model: VNC listens localhost only; Tailscale Serve provides TLS.
# --------------------------------------------------------------------------- #
echo "[STEP 7] VNC no-auth config"
VNC_CONFIG="$VNC_DIR/config"
if [[ ! -f "$VNC_CONFIG" ]]; then
    cat > "$VNC_CONFIG" <<'VNC_CONFIG_EOF'
# Gawd VNC config — no-auth, localhost only
# Security is Tailscale Serve's TLS layer (configure-tailscale-serve.sh)
SecurityTypes=None
localhost=yes
geometry=1920x1080
VNC_CONFIG_EOF
    chown "$GAWD_USER:$GAWD_USER" "$VNC_CONFIG"
    echo "  VNC config written"
else
    echo "  VNC config already exists — skipping"
fi

# --------------------------------------------------------------------------- #
# Step 8: Install systemd units
# Copies from forge/desktop/systemd/ if present; otherwise installs inline.
# Uses SYSTEM units (not user units) so they start without a logged-in session.
# Matches Lilith's pattern: lilith-vnc.service + lilith-novnc.service in
# /etc/systemd/system/ with User=gawd.
# Note: spec §8.8 says "user-units (per Lilith pattern)" — but Lilith's ACTUAL
# units are SYSTEM units (User=gawd directive), not user units. The functional
# result is equivalent (runs as gawd, restarts on failure). System units are
# preferred here because user units require loginctl enable-linger AND a running
# dbus session which is unreliable on headless VPS at boot time.
# --------------------------------------------------------------------------- #
echo "[STEP 8] install systemd service units"

UNIT_SRC_DIR="$(dirname "$0")/systemd"
VNC_UNIT="/etc/systemd/system/gawd-vnc.service"
NOVNC_UNIT="/etc/systemd/system/gawd-novnc.service"

# --- gawd-vnc.service ---
if [[ -f "$UNIT_SRC_DIR/xfce4.service" ]]; then
    cp "$UNIT_SRC_DIR/xfce4.service" "$VNC_UNIT"
    echo "  installed gawd-vnc.service from forge/desktop/systemd/"
else
    # Inline fallback — same logic as the file in systemd/
    cat > "$VNC_UNIT" <<UNIT_EOF
[Unit]
Description=Gawd xfce4 TigerVNC desktop on display :1 (localhost only, Tailscale-fronted)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${GAWD_USER}
Group=${GAWD_USER}
PAMName=login
WorkingDirectory=${GAWD_HOME}
Environment=HOME=${GAWD_HOME}
ExecStartPre=-/usr/bin/tigervncserver -kill :1
ExecStart=/usr/bin/tigervncserver :1 -fg -localhost yes -geometry 1920x1080 -SecurityTypes None -xstartup ${GAWD_HOME}/.vnc/xstartup
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
    echo "  installed gawd-vnc.service (inline)"
fi

# --- gawd-novnc.service ---
if [[ -f "$UNIT_SRC_DIR/novnc.service" ]]; then
    cp "$UNIT_SRC_DIR/novnc.service" "$NOVNC_UNIT"
    echo "  installed gawd-novnc.service from forge/desktop/systemd/"
else
    cat > "$NOVNC_UNIT" <<'UNIT_EOF'
[Unit]
Description=Gawd noVNC HTML5 frontend on 127.0.0.1:6080 (Tailscale-fronted)
After=gawd-vnc.service
Requires=gawd-vnc.service

[Service]
Type=simple
User=gawd
Group=gawd
ExecStart=/usr/bin/websockify --web=/usr/share/novnc 127.0.0.1:6080 localhost:5901
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
    # Substitute GAWD_USER in the unit if it differs from "gawd"
    if [[ "$GAWD_USER" != "gawd" ]]; then
        sed -i "s/User=gawd/User=${GAWD_USER}/g; s/Group=gawd/Group=${GAWD_USER}/g" "$NOVNC_UNIT"
    fi
    echo "  installed gawd-novnc.service (inline)"
fi

# --------------------------------------------------------------------------- #
# Step 9: Enable + start services
# --------------------------------------------------------------------------- #
echo "[STEP 9] enable and start services"
systemctl daemon-reload

# Enable (idempotent)
systemctl enable gawd-vnc.service
systemctl enable gawd-novnc.service

# Start if not already running
if systemctl is-active --quiet gawd-vnc.service; then
    echo "  gawd-vnc.service already active"
else
    systemctl start gawd-vnc.service
    echo "  gawd-vnc.service started"
fi

# Brief pause — VNC needs a moment to bind before noVNC connects
sleep 3

if systemctl is-active --quiet gawd-novnc.service; then
    echo "  gawd-novnc.service already active"
else
    systemctl start gawd-novnc.service
    echo "  gawd-novnc.service started"
fi

# --------------------------------------------------------------------------- #
# Step 10: Verify
# --------------------------------------------------------------------------- #
echo "[STEP 10] verify"

VNC_ACTIVE=$(systemctl is-active gawd-vnc.service 2>/dev/null || echo "unknown")
NOVNC_ACTIVE=$(systemctl is-active gawd-novnc.service 2>/dev/null || echo "unknown")

echo "  gawd-vnc.service:   $VNC_ACTIVE"
echo "  gawd-novnc.service: $NOVNC_ACTIVE"

# Check noVNC port is listening
if ss -tlnp | grep -q ':6080'; then
    echo "  noVNC port 6080: LISTENING"
else
    echo "  WARNING: noVNC port 6080 not yet listening (may need a moment)"
fi

if [[ "$VNC_ACTIVE" == "active" && "$NOVNC_ACTIVE" == "active" ]]; then
    echo "[DONE] Desktop stack installed and running."
    echo "  Next: run configure-tailscale-serve.sh to front noVNC via HTTPS"
else
    echo "[WARN] One or more services not active. Check: journalctl -u gawd-vnc.service -u gawd-novnc.service"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %T')] install-desktop.sh complete"
