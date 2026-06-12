#!/usr/bin/env bash
# =============================================================================
# per-rung/hosted.sh
# Gawd Desktop Stack — Hosted Rung Override
# Spec: §8.3 ("Hosted: our VPS provides the headless X server. Tailscale
#        tunnel handles the public reach. Specs configurable via tithe tier.")
# =============================================================================
#
# Applies hosted-rung-specific configuration AFTER install-desktop.sh runs.
# The core install is shared across all rungs; this script applies ONLY what
# genuinely differs for the hosted rung (per acceptance criterion §4.3 of the
# handoff: "per-rung is only what genuinely differs").
#
# Hosted rung differences vs base:
#   1. Multiple Gawds may share one VPS — each needs a unique display + port
#   2. No Tailscale auth needed from the Prophit (we own the tailnet)
#   3. Headless X — no physical display; Xvfb is not needed (TigerVNC handles
#      the virtual framebuffer internally via -localhost yes)
#   4. Resource monitoring: we alert ops before resource exhaustion (§14.2.5)
#   5. UFW: ports 5901/6080 must remain closed to external; only 22/443 open
#
# NOTE on cloudflared: the cloudflared workaround used on Lilith/Asgard
# (binary at ~/.local/bin/cloudflared because gawd was not in sudoers) is a
# Prophit-VM-rung-specific pattern. It does NOT appear here. On the hosted
# rung, we use Tailscale Serve (which runs as the gawd user and requires no
# sudo for the serve command itself).
#
# IDEMPOTENT: safe to re-run.
#
# Usage:
#   sudo ./per-rung/hosted.sh [--gawd-id <id>] [--gawd-user <user>]
#                              [--display <N>] [--novnc-port <port>]
#
# Arguments:
#   --gawd-id     Unique ID for this Gawd instance (e.g. gawd1, gawd2)
#   --gawd-user   Linux user (default: gawd; multi-Gawd uses gawd1, gawd2, etc.)
#   --display     X display number (default: 1; multi-Gawd increments: 2, 3...)
#   --novnc-port  noVNC port (default: 6080; multi-Gawd: 6081, 6082...)
#
# Resource envelope reference (§14.2.5):
#   Per Gawd with desktop: ~3.5 GB RAM
#   Practical capacity on 32 GB VPS: ~8 Gawds
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
GAWD_ID="${GAWD_ID:-gawd1}"
GAWD_USER="${GAWD_USER:-gawd}"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
NOVNC_PORT="${NOVNC_PORT:-6080}"

# --------------------------------------------------------------------------- #
# Parse args
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gawd-id)     GAWD_ID="$2";     shift 2 ;;
        --gawd-user)   GAWD_USER="$2";   shift 2 ;;
        --display)     DISPLAY_NUM="$2"; shift 2 ;;
        --novnc-port)  NOVNC_PORT="$2";  shift 2 ;;
        *)             echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

echo "[hosted.sh] Gawd hosted rung setup"
echo "  gawd_id=$GAWD_ID user=$GAWD_USER display=:${DISPLAY_NUM} novnc_port=$NOVNC_PORT"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: must be run as root" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Step 1: Run base install with hosted-rung parameters
# --------------------------------------------------------------------------- #
echo "[STEP 1] base install"
GAWD_USER="$GAWD_USER" "$BASE_DIR/install-desktop.sh"

# --------------------------------------------------------------------------- #
# Step 2: Configure noVNC on the assigned port + display
# --------------------------------------------------------------------------- #
echo "[STEP 2] noVNC with port=$NOVNC_PORT display=:${DISPLAY_NUM}"
GAWD_USER="$GAWD_USER" NOVNC_PORT="$NOVNC_PORT" VNC_DISPLAY="$DISPLAY_NUM" \
    "$BASE_DIR/configure-novnc.sh"

# --------------------------------------------------------------------------- #
# Step 3: Tailscale Serve wiring (hosted rung: root path per Gawd, NOT shared)
# On a multi-Gawd hosted VPS, each Gawd gets a dedicated subdomain via
# Tailscale MagicDNS — the Gawd's tailnet hostname is unique.
# We serve at / (root) because the Gawd's hostname already scopes it.
# --------------------------------------------------------------------------- #
echo "[STEP 3] Tailscale Serve (hosted, path=/)"
sudo -u "$GAWD_USER" NOVNC_PORT="$NOVNC_PORT" SERVE_PATH="/" \
    "$BASE_DIR/configure-tailscale-serve.sh"

# --------------------------------------------------------------------------- #
# Step 4: UFW — verify desktop ports remain closed to external
# §8: VNC/noVNC are loopback-only; Tailscale Serve is the public path
# --------------------------------------------------------------------------- #
echo "[STEP 4] UFW — verify ports 5901/6080 are NOT open to external"
if command -v ufw &>/dev/null; then
    # These should NOT appear in ufw status as ALLOW
    UFW_5901=$(ufw status 2>/dev/null | grep "5901" | grep -v "DENY\|Anywhere (v6)" || echo "")
    UFW_6080=$(ufw status 2>/dev/null | grep "6080" | grep -v "DENY\|Anywhere (v6)" || echo "")
    if [[ -n "$UFW_5901" || -n "$UFW_6080" ]]; then
        echo "  WARNING: ports 5901 or 6080 appear open in UFW — close them:"
        echo "    sudo ufw deny 5901"
        echo "    sudo ufw deny 6080"
    else
        echo "  OK: ports 5901/6080 not open in UFW (Tailscale Serve is the public path)"
    fi
fi

# --------------------------------------------------------------------------- #
# Step 5: Document resource cost (§14.2.5)
# This is written to a file for D3 (resource envelope handoff) to reference.
# --------------------------------------------------------------------------- #
echo "[STEP 5] write resource envelope note"
RESOURCE_FILE="/var/log/gawd-resource-envelope-${GAWD_ID}.txt"
cat > "$RESOURCE_FILE" <<RESOURCE_EOF
# Gawd Desktop Resource Envelope — ${GAWD_ID}
# Generated: $(date '+%Y-%m-%d %T')
# Spec §14.2.5

gawd_id:        ${GAWD_ID}
gawd_user:      ${GAWD_USER}
vnc_display:    :${DISPLAY_NUM}
novnc_port:     ${NOVNC_PORT}
rung:           hosted

# RAM estimates (§14.2.5)
openclaw_runtime:    ~512 MB
xfce4_desktop:       ~1,000 MB
browser:             ~1,000 MB
embedding_layer:     ~512 MB
headroom:            ~512 MB
per_gawd_total:      ~3,500 MB (~3.5 GB)

# Practical capacity
# 32 GB VPS:  ~8 Gawds with desktop
# 64 GB VPS:  ~16 Gawds with desktop
# Text-only (no desktop): ~1.5 GB per Gawd → ~18 per 32 GB

# Voice relay (when enabled): +200 MB per Gawd
RESOURCE_EOF
echo "  resource envelope written to $RESOURCE_FILE"

echo "[DONE] hosted rung setup complete for $GAWD_ID"
