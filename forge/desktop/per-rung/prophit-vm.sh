#!/usr/bin/env bash
# =============================================================================
# per-rung/prophit-vm.sh
# Gawd Desktop Stack — Prophit-VM Rung Override
# Spec: §8.3 ("Prophit-VM: runs in the same Docker container as the Gawd.
#        Tailnet must be set up by the Prophit (install.sh prompts).")
# =============================================================================
#
# Applies Prophit-VM-rung-specific configuration AFTER install-desktop.sh runs.
# The core install is shared; this script handles ONLY what genuinely differs.
#
# Prophit-VM rung differences vs base:
#   1. Runs inside Docker container on the Prophit's hardware
#   2. Tailscale auth is the PROPHIT'S TAILNET — install.sh (A3) prompts for
#      their auth key; we join their tailnet, not ours
#   3. Resource limits set by Docker (--memory 4g minimum; 8g recommended)
#   4. cloudflared workaround MAY be needed if Tailscale is unavailable on
#      their machine (e.g. corporate network blocking UDP). Documented here
#      as an escape hatch — not the default path.
#   5. Text-only mode available: Prophit can set GAWD_TEXT_ONLY=true in
#      docker-compose.yml to skip desktop entirely on low-memory hardware
#
# TAILSCALE AUTH NOTE: The TAILSCALE_AUTH_KEY placeholder must be filled by
# install.sh at setup time — never hardcoded. See install.sh (A3).
#
# IDEMPOTENT: safe to re-run.
#
# Usage:
#   ./per-rung/prophit-vm.sh [--gawd-user <user>] [--text-only]
#
# Arguments:
#   --gawd-user    Linux user inside the container (default: gawd)
#   --text-only    Skip desktop install (for low-memory Prophit hardware)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
GAWD_USER="${GAWD_USER:-gawd}"
TEXT_ONLY="${TEXT_ONLY:-false}"

# --------------------------------------------------------------------------- #
# Parse args
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gawd-user)  GAWD_USER="$2"; shift 2 ;;
        --text-only)  TEXT_ONLY="true"; shift ;;
        *)            echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

echo "[prophit-vm.sh] Gawd Prophit-VM rung setup"
echo "  user=$GAWD_USER text_only=$TEXT_ONLY"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: must be run as root (inside the container)" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Step 1: Text-only mode check
# §14.2.5: "Prophit may choose text-only mode to fit substrates with less
#            than 4 GB available"
# --------------------------------------------------------------------------- #
if [[ "$TEXT_ONLY" == "true" ]]; then
    echo "[INFO] Text-only mode requested — skipping desktop installation."
    echo "  The Gawd will operate via Telegram only (no noVNC, no browser-vision)."
    echo "  To enable desktop later: re-run without --text-only flag"
    exit 0
fi

# --------------------------------------------------------------------------- #
# Step 2: Run base install
# --------------------------------------------------------------------------- #
echo "[STEP 2] base install"
GAWD_USER="$GAWD_USER" "$BASE_DIR/install-desktop.sh"

# --------------------------------------------------------------------------- #
# Step 3: noVNC on default port 6080 (single Gawd in container)
# --------------------------------------------------------------------------- #
echo "[STEP 3] noVNC (default port 6080)"
GAWD_USER="$GAWD_USER" NOVNC_PORT="6080" VNC_DISPLAY="1" \
    "$BASE_DIR/configure-novnc.sh"

# --------------------------------------------------------------------------- #
# Step 4: Tailscale Serve wiring
# The Prophit's tailnet — auth key provided by install.sh at setup time.
# TAILSCALE_AUTH_KEY is expected in environment (injected by install.sh / A3).
# --------------------------------------------------------------------------- #
echo "[STEP 4] Tailscale check (Prophit's tailnet)"

if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    echo "ERROR: tailscaled not running. Install Tailscale first (install.sh / A3)." >&2
    exit 1
fi

TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" 2>/dev/null || echo "Unknown")

if [[ "$TS_STATE" == "Running" ]]; then
    echo "  Tailscale is Running — configuring Serve"
    sudo -u "$GAWD_USER" NOVNC_PORT="6080" SERVE_PATH="/" \
        "$BASE_DIR/configure-tailscale-serve.sh"
else
    echo "  WARNING: Tailscale state is '$TS_STATE'"
    echo "  This may mean the Prophit hasn't run 'tailscale up' yet."
    echo "  Once joined: sudo -u $GAWD_USER $BASE_DIR/configure-tailscale-serve.sh"
    echo ""
    echo "  FALLBACK: if Tailscale is blocked on this network, use cloudflared:"
    echo "  (See PROPHIT-VM CLOUDFLARED FALLBACK section in desktop-stack.md runbook)"
fi

# --------------------------------------------------------------------------- #
# Step 5: Docker memory limit recommendation
# §14.2.5: minimum 4 GB, recommended 8 GB for browser-heavy DemiGawd tasks
# --------------------------------------------------------------------------- #
echo ""
echo "[STEP 5] Docker memory recommendation"
echo "  Minimum container allocation:   4 GB  (--memory 4g)"
echo "  Recommended for browser vision: 8 GB  (--memory 8g)"
echo "  Current container memory limit: $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null | awk '{print int($1/1024/1024)" MB"}' || echo "unknown (not in cgroup v1)")"

echo "[DONE] Prophit-VM rung setup complete"
