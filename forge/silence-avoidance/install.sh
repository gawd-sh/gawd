#!/usr/bin/env bash
# install.sh — Silence-avoidance engine installer.
#
# Idempotent. Copies engine into the daemon workspace, sets permissions,
# stages template files, and registers with L4 (session-recovery) + L7
# (watchdog) hooks via well-known hook paths.
#
# Forge contract: runs at daemon-build time inside the forge container.
# Not a "live deploy" — this is the artifact-build step. The L4/L7 hooks
# it installs are bash files those handoffs source on startup.
#
# Usage:
#   install.sh [--dest <gawd_workspace>] [--templates-src <dir>] [--force]
#
# Defaults:
#   --dest          $HOME/.gawd
#   --templates-src /usr/local/lib/gawd/fallbacks/templates
#                   (the directory Seraph G3 produces into)
#
# What the installer creates:
#   <dest>/fallbacks/templates/    <- copied from --templates-src
#   <dest>/fallbacks/state/        <- empty (silence-window.json created at runtime)
#   <dest>/fallbacks/config.json   <- staged default if absent (operator edits)
#   <dest>/engine/silence-avoidance/  <- engine binaries (engine.sh etc) [CANONICAL lookup path]
#                                        watchdog/sweep.sh looks here for G2_ENGINE.
#   <dest>/hooks/l4-on-terminal-error.sh   <- L4 calls this
#   <dest>/hooks/l4-on-recovered.sh        <- L4 calls this
#   <dest>/hooks/l7-on-stuck-state.sh      <- L7 calls this
#
# Exit:
#   0  install succeeded
#   1  user error (bad arg, missing source)
#   2  filesystem error (cannot write)

set -euo pipefail

ENGINE_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEST="${HOME}/.gawd"
TEMPLATES_SRC="/usr/local/lib/gawd/fallbacks/templates"
# Canonical engine install dir is computed from $DEST AFTER arg parse so that
# --dest overrides flow through. An explicit --engine-dir still wins.
ENGINE_INSTALL_DIR=""
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)          shift; DEST="${1:-}";;
        --templates-src) shift; TEMPLATES_SRC="${1:-}";;
        --engine-dir)    shift; ENGINE_INSTALL_DIR="${1:-}";;
        --force)         FORCE=1;;
        -h|--help)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 1;;
    esac
    shift || true
done

# BLOCKER 10 (rc3): the L7 watchdog (watchdog/sweep.sh) looks for the engine at
#   ${GAWD_HOME}/engine/silence-avoidance/engine.sh
# where GAWD_HOME defaults to $HOME/.gawd == $DEST. The old default of
# /opt/gawd/silence-avoidance (or $DEST/engine) put the engine where NOTHING
# looked, so the safety net silently no-op'd. We now install to the canonical
# path the watchdog reads. An explicit --engine-dir still overrides for testing.
if [[ -z "$ENGINE_INSTALL_DIR" ]]; then
    ENGINE_INSTALL_DIR="${DEST}/engine/silence-avoidance"
fi

log()  { printf '[fb-install] %s\n' "$*"; }
warn() { printf '[fb-install] WARN: %s\n' "$*" >&2; }
fail() { printf '[fb-install] ERROR: %s\n' "$*" >&2; exit "${2:-2}"; }

[[ -d "$ENGINE_SRC_DIR" ]] || fail "engine source dir missing: $ENGINE_SRC_DIR" 1

# ── 1. Create destination directories ──────────────────────────────────────────

log "creating directory tree under $DEST"
mkdir -p "$DEST/fallbacks/templates" \
         "$DEST/fallbacks/state" \
         "$DEST/hooks" \
         "$DEST/memory" \
         "$DEST/.secrets"
chmod 0700 "$DEST/.secrets" "$DEST/fallbacks/state"

# Engine binaries directory — canonical path under $DEST that the L7 watchdog
# (watchdog/sweep.sh) reads as ${GAWD_HOME}/engine/silence-avoidance.
mkdir -p "$ENGINE_INSTALL_DIR" \
    || fail "cannot create engine install dir: $ENGINE_INSTALL_DIR" 2
mkdir -p "$ENGINE_INSTALL_DIR/deliver"
log "engine install dir: $ENGINE_INSTALL_DIR"

# ── 2. Copy engine binaries ────────────────────────────────────────────────────

log "installing engine binaries to $ENGINE_INSTALL_DIR"
install -m 0755 "$ENGINE_SRC_DIR/engine.sh"          "$ENGINE_INSTALL_DIR/engine.sh"
install -m 0755 "$ENGINE_SRC_DIR/select-template.sh" "$ENGINE_INSTALL_DIR/select-template.sh"
install -m 0755 "$ENGINE_SRC_DIR/render.sh"          "$ENGINE_INSTALL_DIR/render.sh"
install -m 0755 "$ENGINE_SRC_DIR/deliver/telegram.sh"  "$ENGINE_INSTALL_DIR/deliver/telegram.sh"
install -m 0755 "$ENGINE_SRC_DIR/deliver/dashboard.sh" "$ENGINE_INSTALL_DIR/deliver/dashboard.sh"
install -m 0755 "$ENGINE_SRC_DIR/deliver/desktop.sh"   "$ENGINE_INSTALL_DIR/deliver/desktop.sh"
install -m 0755 "$ENGINE_SRC_DIR/deliver/voice.sh"     "$ENGINE_INSTALL_DIR/deliver/voice.sh"

# ── 3. Stage templates ─────────────────────────────────────────────────────────

if [[ -d "$TEMPLATES_SRC" ]]; then
    log "copying templates from $TEMPLATES_SRC"
    # Preserve any operator-customised templates already in dest if --force not given.
    if [[ "$FORCE" == "1" ]]; then
        cp -f "$TEMPLATES_SRC"/* "$DEST/fallbacks/templates/" 2>/dev/null || true
    else
        # Copy only missing files; leave existing ones alone (idempotency).
        for f in "$TEMPLATES_SRC"/*; do
            [[ -e "$f" ]] || continue
            base="$(basename "$f")"
            if [[ ! -e "$DEST/fallbacks/templates/$base" ]]; then
                cp "$f" "$DEST/fallbacks/templates/$base"
                log "  staged: $base"
            else
                log "  kept existing: $base"
            fi
        done
    fi
else
    warn "templates source dir absent: $TEMPLATES_SRC"
    warn "Seraph G3 has not produced prose yet; using engine's bundled placeholders"
    # Bundle our placeholder set (in this engine repo).
    if [[ -d "$ENGINE_SRC_DIR/templates" ]]; then
        for f in "$ENGINE_SRC_DIR/templates"/*; do
            [[ -e "$f" ]] || continue
            base="$(basename "$f")"
            if [[ ! -e "$DEST/fallbacks/templates/$base" ]]; then
                cp "$f" "$DEST/fallbacks/templates/$base"
                log "  staged placeholder: $base"
            fi
        done
    fi
fi
chmod 0644 "$DEST/fallbacks/templates"/* 2>/dev/null || true

# ── 4. Stage default config.json if absent ─────────────────────────────────────

CONFIG="$DEST/fallbacks/config.json"
if [[ ! -e "$CONFIG" ]]; then
    log "staging default config: $CONFIG"
    cat > "$CONFIG" <<'EOF'
{
  "windows": {
    "default":   30,
    "telegram":  30,
    "dashboard": 30,
    "desktop":   30,
    "voice":     30
  },
  "prophit_timezone": "",
  "prophits": {},
  "dashboard": {
    "sse_url": ""
  },
  "voice": {
    "tts_endpoint":   "",
    "tts_voice_id":   "",
    "tts_token_file": ""
  }
}
EOF
    chmod 0600 "$CONFIG"
else
    log "config already present: $CONFIG (kept)"
fi

# ── 5. Install L4/L7 hook scripts ──────────────────────────────────────────────

log "installing L4/L7 hook scripts under $DEST/hooks/"

cat > "$DEST/hooks/l4-on-terminal-error.sh" <<EOF
#!/usr/bin/env bash
# L4 hook: called by session-recovery (G4) when a session emits a terminal error.
# Args: <channel> <prophit_id> [reason]
set -euo pipefail
channel="\${1:-telegram}"
prophit_id="\${2:?prophit_id required}"
reason="\${3:-non_deliverable_terminal_turn}"
exec "$ENGINE_INSTALL_DIR/engine.sh" terminal-error \\
    --channel "\$channel" \\
    --prophit "\$prophit_id" \\
    --reason "\$reason"
EOF
chmod 0755 "$DEST/hooks/l4-on-terminal-error.sh"

cat > "$DEST/hooks/l4-on-recovered.sh" <<EOF
#!/usr/bin/env bash
# L4 hook: called by session-recovery (G4) when a wedged session is healed.
# Args: <channel> <prophit_id>
set -euo pipefail
channel="\${1:-telegram}"
prophit_id="\${2:?prophit_id required}"
exec "$ENGINE_INSTALL_DIR/engine.sh" recovered \\
    --channel "\$channel" \\
    --prophit "\$prophit_id"
EOF
chmod 0755 "$DEST/hooks/l4-on-recovered.sh"

cat > "$DEST/hooks/l7-on-stuck-state.sh" <<EOF
#!/usr/bin/env bash
# L7 hook: called by healing watchdog (G5) when stuck-state is detected.
# Args: <channel> <prophit_id>
set -euo pipefail
channel="\${1:-telegram}"
prophit_id="\${2:?prophit_id required}"
exec "$ENGINE_INSTALL_DIR/engine.sh" stuck-state \\
    --channel "\$channel" \\
    --prophit "\$prophit_id"
EOF
chmod 0755 "$DEST/hooks/l7-on-stuck-state.sh"

cat > "$DEST/hooks/l7-on-extended-degraded.sh" <<EOF
#!/usr/bin/env bash
# L7 hook: called by watchdog when degraded mode persists >5 min.
# Args: <channel> <prophit_id>
set -euo pipefail
channel="\${1:-telegram}"
prophit_id="\${2:?prophit_id required}"
exec "$ENGINE_INSTALL_DIR/engine.sh" extended \\
    --channel "\$channel" \\
    --prophit "\$prophit_id"
EOF
chmod 0755 "$DEST/hooks/l7-on-extended-degraded.sh"

cat > "$DEST/hooks/on-successful-reply.sh" <<EOF
#!/usr/bin/env bash
# Agent loop hook: called when a real model reply succeeds (after any
# fallback was previously sent). Resets the silence-window so future
# degradations can fire fresh.
# Args: <channel> <prophit_id>
set -euo pipefail
channel="\${1:-telegram}"
prophit_id="\${2:?prophit_id required}"
exec "$ENGINE_INSTALL_DIR/engine.sh" reset-window \\
    --channel "\$channel" \\
    --prophit "\$prophit_id"
EOF
chmod 0755 "$DEST/hooks/on-successful-reply.sh"

# ── 6. Run preflight ───────────────────────────────────────────────────────────

log "running preflight check"
if GAWD_FALLBACK_DIR="$DEST/fallbacks/templates" \
   GAWD_FALLBACK_STATE_DIR="$DEST/fallbacks/state" \
   GAWD_FALLBACK_CONFIG="$CONFIG" \
   "$ENGINE_INSTALL_DIR/engine.sh" preflight
then
    log "preflight OK — installation complete"
else
    warn "preflight reported missing templates; daemon will not pass start-time check"
    warn "ensure Seraph G3 templates land at: $DEST/fallbacks/templates/"
    exit 2
fi

log "DONE"
exit 0
