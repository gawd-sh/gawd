#!/usr/bin/env bash
# =============================================================================
# per-rung/bare-metal.sh
# Gawd Desktop Stack — Bare-Metal Rung Override
# Spec: §8.3 ("Bare-metal: native xfce4 on the host or in a dedicated VM.
#        Highest performance.")
# =============================================================================
#
# Applies bare-metal-rung-specific configuration AFTER install-desktop.sh runs.
# The core install is shared; this script handles ONLY what genuinely differs.
#
# Bare-metal rung differences vs base:
#   1. Native xfce4 on the host (not in a container) — or in a dedicated VM
#   2. Physical or native GPU available (xfce4 can use it; noVNC still works)
#   3. Prophit owns the substrate — no upper resource bound enforced by daemon
#   4. Tailscale may already be installed (Prophit's machine) — check before
#      installing; do NOT clobber an existing tailscale config
#   5. No ops-side alerting (Prophit owns the hardware; daemon warns, not ops)
#   6. Prophit may want noVNC on a non-default port if they run other VNC
#      sessions on this machine
#
# IDEMPOTENT: safe to re-run.
#
# Usage:
#   sudo ./per-rung/bare-metal.sh [--gawd-user <user>] [--novnc-port <port>]
#                                  [--display <N>]
#
# Arguments:
#   --gawd-user    Linux user for the Gawd session (default: gawd)
#   --novnc-port   noVNC port to use (default: 6080)
#   --display      VNC display number (default: 1; increment if :1 is taken)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
GAWD_USER="${GAWD_USER:-gawd}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
DISPLAY_NUM="${DISPLAY_NUM:-1}"

# --------------------------------------------------------------------------- #
# Parse args
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gawd-user)  GAWD_USER="$2";   shift 2 ;;
        --novnc-port) NOVNC_PORT="$2";  shift 2 ;;
        --display)    DISPLAY_NUM="$2"; shift 2 ;;
        *)            echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

echo "[bare-metal.sh] Gawd bare-metal rung setup"
echo "  user=$GAWD_USER novnc_port=$NOVNC_PORT display=:${DISPLAY_NUM}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: must be run as root" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Step 1: Check if display :N is already in use
# --------------------------------------------------------------------------- #
echo "[STEP 1] display conflict check"

VNC_PORT=$((5900 + DISPLAY_NUM))
if ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT}"; then
    echo "  WARNING: port $VNC_PORT (display :${DISPLAY_NUM}) already in use."
    echo "  Increment --display if another VNC session is on :${DISPLAY_NUM}"
    echo "  Continuing — install-desktop.sh will handle the conflict if any"
fi

if ss -tlnp 2>/dev/null | grep -q ":${NOVNC_PORT}"; then
    echo "  WARNING: port $NOVNC_PORT already in use."
    echo "  Use --novnc-port to choose a different port."
fi

# --------------------------------------------------------------------------- #
# Step 2: Run base install
# --------------------------------------------------------------------------- #
echo "[STEP 2] base install"
GAWD_USER="$GAWD_USER" "$BASE_DIR/install-desktop.sh"

# --------------------------------------------------------------------------- #
# Step 3: noVNC with the specified display + port
# --------------------------------------------------------------------------- #
echo "[STEP 3] noVNC (port=$NOVNC_PORT display=:${DISPLAY_NUM})"
GAWD_USER="$GAWD_USER" NOVNC_PORT="$NOVNC_PORT" VNC_DISPLAY="$DISPLAY_NUM" \
    "$BASE_DIR/configure-novnc.sh"

# --------------------------------------------------------------------------- #
# Step 4: Tailscale Serve
# Check if Tailscale is already installed/running (Prophit's machine may have
# it); do NOT clobber an existing tailscale login.
# --------------------------------------------------------------------------- #
echo "[STEP 4] Tailscale check"

if ! command -v tailscale &>/dev/null; then
    echo "  Tailscale not installed. Install it before wiring Tailscale Serve."
    echo "  https://tailscale.com/download"
    echo "  Then run: sudo -u $GAWD_USER $BASE_DIR/configure-tailscale-serve.sh --novnc-port $NOVNC_PORT"
    echo "  Skipping Tailscale Serve configuration for now."
elif ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    echo "  tailscaled is installed but not running."
    echo "  Start it: sudo systemctl start tailscaled && sudo tailscale up"
    echo "  Then run: sudo -u $GAWD_USER $BASE_DIR/configure-tailscale-serve.sh --novnc-port $NOVNC_PORT"
else
    TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" 2>/dev/null || echo "Unknown")
    if [[ "$TS_STATE" == "Running" ]]; then
        echo "  Tailscale Running — configuring Serve"
        sudo -u "$GAWD_USER" NOVNC_PORT="$NOVNC_PORT" SERVE_PATH="/" \
            "$BASE_DIR/configure-tailscale-serve.sh"
    else
        echo "  WARNING: Tailscale state is '$TS_STATE'."
        echo "  Ensure the Prophit runs: sudo tailscale up"
        echo "  Then: sudo -u $GAWD_USER $BASE_DIR/configure-tailscale-serve.sh --novnc-port $NOVNC_PORT"
    fi
fi

# --------------------------------------------------------------------------- #
# Step 5: Resource note — bare-metal has no cap
# §14.2.5: "No upper bound enforced by the daemon on bare-metal rung."
# --------------------------------------------------------------------------- #
echo ""
echo "[STEP 5] Resource note"
echo "  Bare-metal rung: no daemon-enforced resource cap."
echo "  Prophit owns the substrate. Recommended minimum if running multiple"
echo "  Gawds in a household: 8 GB total RAM (§14.2.5)."
echo ""
echo "[DONE] Bare-metal rung setup complete"
