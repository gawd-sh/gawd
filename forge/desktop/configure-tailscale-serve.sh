#!/usr/bin/env bash
# =============================================================================
# configure-tailscale-serve.sh
# Gawd Desktop Stack — Phase 3: Tailscale Serve TLS Frontend
# Spec: §8.1 (Tailscale Serve), §8.3 (per-rung notes)
# =============================================================================
#
# Wires Tailscale Serve to front the noVNC port via HTTPS at the Gawd's
# tailnet hostname. After this runs, the VNC URL is:
#
#   https://<hostname>.tail<NET>.ts.net/vnc.html
#
# Tailscale Serve automatically provisions and renews the TLS cert via
# LetsEncrypt — no custom cert management required (per spec §8 Context note:
# "rely on Tailscale Serve's automatic LetsEncrypt; do NOT roll our own").
#
# SECURITY MODEL:
#   - VNC and noVNC listen on localhost only (127.0.0.1)
#   - Tailscale Serve provides HTTPS + tailnet membership gate
#   - No firewall rules needed for ports 5901/6080 (they never leave loopback)
#   - Tailscale Serve is the ONLY path to reach noVNC
#
# IDEMPOTENT: safe to re-run. Tailscale Serve add is idempotent.
#
# Usage:
#   ./configure-tailscale-serve.sh [--novnc-port <port>] [--path </vnc>]
#
# Arguments:
#   --novnc-port   Internal noVNC port (default: 6080)
#   --path         URL path at which to expose noVNC (default: /)
#                  Use a non-root path on hosted rung for multi-Gawd on one VPS
#                  e.g. --path /gawd1 exposes https://host.ts.net/gawd1/vnc.html
#
# Called by:
#   - install-desktop.sh (main orchestrator)
#   - per-rung/hosted.sh (which may pass multi-Gawd paths)
#   - per-rung/prophit-vm.sh (single path /)
#
# Requirements:
#   - tailscale is installed and logged in (tailscale status shows this node)
#   - Running as the gawd user (NOT root — Tailscale Serve is a per-user config)
#   - Tailscale daemon running (sudo systemctl is-active tailscaled)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
NOVNC_PORT="${NOVNC_PORT:-6080}"
SERVE_PATH="${SERVE_PATH:-/}"
LOGFILE="${HOME}/logs/gawd-desktop-install.log"

# --------------------------------------------------------------------------- #
# Parse args
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --novnc-port) NOVNC_PORT="$2"; shift 2 ;;
        --path)       SERVE_PATH="$2"; shift 2 ;;
        *)            echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1
echo "[$(date '+%Y-%m-%d %T')] configure-tailscale-serve.sh starting (port=$NOVNC_PORT, path=$SERVE_PATH)"

# --------------------------------------------------------------------------- #
# Verify NOT root (Tailscale Serve is user-scoped)
# --------------------------------------------------------------------------- #
if [[ "$(id -u)" -eq 0 ]]; then
    echo "ERROR: run as the gawd user, not root. Tailscale Serve is user-scoped." >&2
    echo "  sudo -u gawd ./configure-tailscale-serve.sh" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Step 1: Verify tailscale daemon is running
# --------------------------------------------------------------------------- #
echo "[STEP 1] verify tailscale daemon"

if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    echo "ERROR: tailscaled is not running. Install + start it first." >&2
    echo "  sudo systemctl start tailscaled" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Step 2: Verify tailscale is logged in
# --------------------------------------------------------------------------- #
echo "[STEP 2] verify tailscale login"

TS_STATUS=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" 2>/dev/null || echo "Unknown")

if [[ "$TS_STATUS" != "Running" ]]; then
    echo "ERROR: Tailscale backend state is '$TS_STATUS' (need 'Running')." >&2
    echo "  Run: sudo tailscale up --auth-key=<TAILSCALE_AUTH_KEY>" >&2
    echo "  The auth key is provisioned by install.sh (A3) at setup time." >&2
    exit 1
fi

TS_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); self=d.get('Self',{}); print(self.get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
echo "  Tailscale hostname: $TS_HOSTNAME"

# --------------------------------------------------------------------------- #
# Step 3: Verify noVNC is reachable on the internal port
# --------------------------------------------------------------------------- #
echo "[STEP 3] verify noVNC internal port $NOVNC_PORT"

if ! ss -tlnp 2>/dev/null | grep -q ":${NOVNC_PORT}"; then
    echo "ERROR: nothing is listening on port $NOVNC_PORT." >&2
    echo "  Run install-desktop.sh and configure-novnc.sh first." >&2
    exit 1
fi
echo "  port $NOVNC_PORT: LISTENING"

# --------------------------------------------------------------------------- #
# Step 4: Wire Tailscale Serve
# §8.1: "Tailscale Serve — TLS-fronted public reach via the Prophit's tailnet"
# Proven pattern (from `tailscale serve status` on a live Gawd machine):
#   https://your-machine.your-tailnet.ts.net  → proxy http://127.0.0.1:6080
# This matches: tailscale serve --bg http:/127.0.0.1:6080
# --------------------------------------------------------------------------- #
echo "[STEP 4] configure Tailscale Serve"

# Normalize path: ensure it starts with /
[[ "${SERVE_PATH}" != /* ]] && SERVE_PATH="/${SERVE_PATH}"

# Check if serve is already configured for this port
EXISTING=$(tailscale serve status 2>/dev/null || echo "")

if echo "$EXISTING" | grep -q "http://127.0.0.1:${NOVNC_PORT}"; then
    echo "  Tailscale Serve already configured for port $NOVNC_PORT — verifying"
else
    # Configure Tailscale Serve
    # --bg: background mode (persist across sessions)
    # serve https + path + proxy target
    if [[ "$SERVE_PATH" == "/" ]]; then
        tailscale serve --bg "http://127.0.0.1:${NOVNC_PORT}"
    else
        tailscale serve --bg "${SERVE_PATH}" "http://127.0.0.1:${NOVNC_PORT}"
    fi
    echo "  Tailscale Serve configured: $SERVE_PATH → http://127.0.0.1:${NOVNC_PORT}"
fi

# --------------------------------------------------------------------------- #
# Step 5: Show current Tailscale Serve status
# --------------------------------------------------------------------------- #
echo "[STEP 5] current Tailscale Serve status"
tailscale serve status 2>/dev/null || echo "  (tailscale serve status unavailable)"

# --------------------------------------------------------------------------- #
# Step 6: Output the final URL
# --------------------------------------------------------------------------- #
echo ""
echo "[DONE] Tailscale Serve configured."
echo ""
if [[ -n "$TS_HOSTNAME" ]]; then
    VNC_URL="https://${TS_HOSTNAME}${SERVE_PATH}vnc.html"
    # Clean double slashes
    VNC_URL=$(echo "$VNC_URL" | sed 's|//vnc.html|/vnc.html|')
    echo "  Prophit noVNC URL: ${VNC_URL}"
    echo "  (Accessible from any device on this tailnet)"
else
    echo "  Prophit noVNC URL: https://<hostname>.tail<NET>.ts.net${SERVE_PATH}vnc.html"
fi
echo ""
echo "  NOTE: If Tailscale is down, noVNC is unreachable."
echo "  This is expected: Tailscale Serve IS the public path."
echo "  The Gawd's Telegram channel remains operational independently."
echo ""
echo "[$(date '+%Y-%m-%d %T')] configure-tailscale-serve.sh complete"
