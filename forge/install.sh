#!/usr/bin/env bash
# install.sh — Gawd daemon installer
#
# Provisions the secrets vault, creates the runtime directory tree, pulls or
# unpacks the Gawd daemon image, starts the gateway, and hands off to the
# onboarding wizard.
#
# Idempotent: safe to re-run on an existing installation. Steps that already
# completed are detected and skipped; no existing state is destroyed.
#
# Rung detection (per spec §7.1):
#   GAWD_RUNG env var, or auto-detected from substrate:
#     hosted      — GAWD_RUNG=hosted (set by our hosted infrastructure; not
#                   normally set on a Prophit's machine)
#     prophit-vm  — Docker available, not explicitly bare-metal
#     bare-metal  — GAWD_RUNG=bare-metal OR no Docker present
#
# Exit codes (per handoff acceptance criteria):
#   0  success
#   1  user error (bad arguments, wrong user, missing required input)
#   2  environment error (missing required dependency that cannot be auto-installed)
#   3  daemon failed to start
#
# Usage:
#   ./install.sh [--rung hosted|prophit-vm|bare-metal|docker] [--skip-wizard] [--non-interactive]
#
# Environment variables (all optional):
#   GAWD_RUNG         override rung detection
#   GAWD_IMAGE_TAG    Docker image tag (default: latest) — per spec §4.2
#   GAWD_IMAGE_REPO   Docker image repository (default: ghcr.io/gawd-sh/gawd)
#   GAWD_PORT         gateway loopback port (default: 18789) — per GOSPEL-TOPOLOGY §8.1
#   SKIP_WIZARD       set to 1 to suppress onboarding launch (testing use only)
#   MINIMAX_API_KEY         MiniMax API key (provider menu option 1)
#   ANTHROPIC_API_KEY       Anthropic API key (provider menu option 2)
#   DEEPSEEK_API_KEY        DeepSeek API key (provider menu option 3)
#   OPENAI_API_KEY          OpenAI API key (provider menu option 4)
#   OLLAMA_ENDPOINT         Ollama endpoint (provider menu option 5; default http://localhost:11434)
#   GAWD_PROVIDER           pre-select provider in non-interactive mode:
#                             minimax | anthropic | deepseek | openai | ollama | other
#   NON_INTERACTIVE         set to 1 to skip all prompts and wizard launch
#   GAWD_ADMIN_CHAT_ID      pre-set admin alert Telegram chat ID (skips prompt)
# ---

__gawd_main() {
set -euo pipefail

# ── constants ──────────────────────────────────────────────────────────────────

GAWD_PORT="${GAWD_PORT:-18789}"
# Default is the public GHCR image (addendum-1, phase4-20260609).
# Override with GAWD_IMAGE_REPO=gawd/daemon for internal forge builds.
GAWD_IMAGE_REPO="${GAWD_IMAGE_REPO:-ghcr.io/gawd-sh/gawd}"
GAWD_IMAGE_TAG="${GAWD_IMAGE_TAG:-latest}"
GAWD_IMAGE="${GAWD_IMAGE_REPO}:${GAWD_IMAGE_TAG}"
GAWD_INSTALL_DIR="${GAWD_INSTALL_DIR:-/opt/gawd}"
GAWD_WORKSPACE="${HOME}/.gawd"
SECRETS_DIR="${HOME}/.secrets"
SECRETS_HELPER="${HOME}/.local/bin/secrets"
ONBOARD_BIN="/usr/local/bin/gawd-onboard"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ── helpers ────────────────────────────────────────────────────────────────────

log()  { printf '\033[1;34m[gawd]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[gawd]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gawd]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[gawd]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# Print without revealing any value — used wherever secret data might stray.
# Per feedback_diagnose_secrets_without_leaking.md: never echo secret values.
redact() { printf '[REDACTED]'; }

# ── argument parsing ───────────────────────────────────────────────────────────

RUNG_OVERRIDE=""
SKIP_WIZARD="${SKIP_WIZARD:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rung)
      shift
      RUNG_OVERRIDE="${1:-}"
      [[ "$RUNG_OVERRIDE" =~ ^(hosted|prophit-vm|bare-metal|docker)$ ]] \
        || fail "--rung must be hosted, prophit-vm, bare-metal, or docker" 1
      ;;
    --skip-wizard)
      SKIP_WIZARD=1
      ;;
    --non-interactive)
      # Non-interactive mode: suppress all prompts and wizard launch.
      # Used by the graduation gate and entrypoint.sh to provision inside a
      # running container without human input.
      NON_INTERACTIVE=1
      SKIP_WIZARD=1
      ;;
    -h|--help)
      sed -n '1,/^# ---/p' "$0" | grep '^#' | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      fail "unknown argument: $1" 1
      ;;
  esac
  shift
done

# ── rung detection (per spec §7.1) ────────────────────────────────────────────

detect_rung() {
  if [[ -n "$RUNG_OVERRIDE" ]]; then
    echo "$RUNG_OVERRIDE"
    return
  fi
  if [[ "${GAWD_RUNG:-}" == "hosted" ]]; then
    echo "hosted"
    return
  fi
  if [[ "${GAWD_RUNG:-}" == "bare-metal" ]]; then
    echo "bare-metal"
    return
  fi
  if [[ "${GAWD_RUNG:-}" == "docker" ]]; then
    echo "docker"
    return
  fi
  # Detect if running inside a Docker container.
  # Two signals: /.dockerenv marker file (Docker) or cgroup entries containing "docker".
  if [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    echo "docker"
    return
  fi
  # Auto-detect: if Docker daemon is reachable on the host, default to prophit-vm rung.
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    echo "prophit-vm"
  else
    echo "bare-metal"
  fi
}

RUNG="$(detect_rung)"
log "Rung detected: ${RUNG}"

# ── platform detection ────────────────────────────────────────────────────────

OS="$(uname -s)"
case "$OS" in
  Linux)  PLATFORM="linux" ;;
  Darwin) PLATFORM="macos" ;;
  *)      fail "Unsupported platform: $OS. Gawd runs on Linux or macOS." 2 ;;
esac

# ── step 1: verify or install age (per spec §4.2 step 1; GOSPEL-TOPOLOGY §8.3) ──

log "Step 1/7 — Checking for age encryption tool..."

if ! command -v age &>/dev/null || ! command -v age-keygen &>/dev/null; then
  log "  age not found. Attempting installation..."
  # LOW-3 sudo notice (phase4-20260609): this script will use sudo to install age.
  # If you prefer to install age manually first, do so and re-run install.sh.
  if [[ "$PLATFORM" == "linux" ]] && command -v apt-get &>/dev/null; then
    if [[ "$(id -u)" -eq 0 ]]; then
      apt-get update -qq \
        && apt-get install -y age \
        || fail "apt-get install age failed. Install age manually (https://age-encryption.org) then re-run." 2
    else
      sudo apt-get update -qq \
        && sudo apt-get install -y age \
        || fail "apt-get install age failed. Install age manually (https://age-encryption.org) then re-run." 2
    fi
  elif [[ "$PLATFORM" == "macos" ]] && command -v brew &>/dev/null; then
    brew install age \
      || fail "brew install age failed. Install age manually (https://age-encryption.org) then re-run." 2
  else
    # Neither package manager available — print clear instructions and exit.
    # Per acceptance criterion: "prints clear instructions and exits if neither
    # package manager is present."
    printf '\n'
    warn "age is not installed and no supported package manager (apt, brew) was found."
    printf '\n'
    printf 'To install age manually:\n'
    printf '  Linux:  download from https://github.com/FiloSottile/age/releases\n'
    printf '          and place age + age-keygen in /usr/local/bin\n'
    printf '  macOS:  install Homebrew (https://brew.sh) then run: brew install age\n'
    printf '\n'
    printf 'After installing age, re-run this installer:\n'
    printf '  ./install.sh\n'
    printf '\n'
    exit 2
  fi
fi

command -v age &>/dev/null && command -v age-keygen &>/dev/null \
  || fail "age installation did not provide both age and age-keygen" 2
ok "  age found: $(command -v age)"

# ── step 2: create ~/.secrets/ (per spec §4.2 step 2; GOSPEL-TOPOLOGY §8.3) ──

log "Step 2/7 — Provisioning secrets directory..."

# Per spec §8.3: create with chmod 0700 if missing; never modify an existing one.
if [[ -d "$SECRETS_DIR" ]]; then
  ok "  ${SECRETS_DIR} already exists — skipping creation."
else
  mkdir -p "$SECRETS_DIR"
  chmod 0700 "$SECRETS_DIR"
  ok "  Created ${SECRETS_DIR} (chmod 0700)"
fi

# ── step 3: generate age.key (per spec §4.2 step 3; GOSPEL-TOPOLOGY §8.3) ─────

log "Step 3/7 — Provisioning age key..."

# Per spec §8.3 invariant: age.key is NEVER included in the daemon, never in
# git, never in chat. Generated here at install time. Never overwrite if present.
AGE_KEY_FILE="${SECRETS_DIR}/age.key"

if [[ -f "$AGE_KEY_FILE" ]]; then
  ok "  ${AGE_KEY_FILE} already exists — skipping key generation (Prophit's key is preserved)."
elif [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
  # Non-interactive (docker/CI) mode: skip age key generation.
  # The age key must be generated by the Prophit at real install time, not
  # baked into a test container. Generating it here would cause the graduation
  # gate's no-age-key-in-image check to fail (Phase 10).
  ok "  Non-interactive mode: skipping age key generation (key will be generated at real install time)."
else
  age-keygen -o "$AGE_KEY_FILE" || fail "age-keygen failed — could not generate encryption key" 2
  [[ -s "$AGE_KEY_FILE" ]] || fail "age.key is empty after generation" 2
  grep -q '^# public key:' "$AGE_KEY_FILE" || fail "age.key missing public-key line — generation incomplete" 2
  chmod 0600 "$AGE_KEY_FILE"
  perms="$(stat -c '%a' "$AGE_KEY_FILE" 2>/dev/null || stat -f '%Lp' "$AGE_KEY_FILE")"
  [[ "$perms" == "600" ]] || fail "age.key permissions are not 0600 (got $perms) — refusing to continue" 2
  ok "  Generated ${AGE_KEY_FILE} (chmod 0600)"
fi

# ── step 4: install secrets helper (per spec §4.2 step 4; GOSPEL-TOPOLOGY §8.3) ─

log "Step 4/7 — Installing secrets helper..."

# Per GOSPEL-TOPOLOGY §8.3: the secrets helper ships inside every daemon as
# static content. install.sh copies it from the daemon bundle to ~/.local/bin/.
# The helper supports: get, set, revoke, env, list, edit.
# The full helper source is embedded below so this script is self-contained.

mkdir -p "$(dirname "$SECRETS_HELPER")"

# Overwrite the helper on every install (idempotent; the script itself is not
# secret state, so replacing it with the latest version is safe).
install_secrets_helper() {
cat > "$SECRETS_HELPER" << 'SECRETS_HELPER_EOF'
#!/usr/bin/env bash
# secrets — Gawd secrets vault helper
#
# Manages per-Gawd secrets encrypted with age. Values are stored in
# ~/.secrets/vault/ as individual age-encrypted files; keys are normalized to
# SCREAMING_SNAKE_CASE. The age key lives at ~/.secrets/age.key (never travels,
# never echoed).
#
# Usage:
#   secrets get  KEY              decrypt and print value
#   secrets set  KEY [VALUE]      encrypt VALUE (or prompt) and store
#   secrets list                  list stored key names (never values)
#   secrets revoke KEY            delete a stored secret
#   secrets env  KEY[=ALIAS]...   export secrets as env vars for a subprocess
#   secrets edit KEY              open value in $EDITOR for editing
#
# Exit codes: 0=ok, 1=key not found or user error, 2=vault error

set -euo pipefail

SECRETS_DIR="${HOME}/.secrets"
VAULT_DIR="${SECRETS_DIR}/vault"
AGE_KEY="${SECRETS_DIR}/age.key"

# Normalize KEY to SCREAMING_SNAKE_CASE (auto-normalize per spec §8.3).
normalize_key() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cs 'A-Z0-9_' '_'
}

require_age_key() {
  [[ -f "$AGE_KEY" ]] \
    || { printf 'secrets: age.key not found at %s\nRun install.sh to generate it.\n' "$AGE_KEY" >&2; exit 2; }
}

vault_path() {
  printf '%s/%s.age' "$VAULT_DIR" "$(normalize_key "$1")"
}

CMD="${1:-}"
shift || true

case "$CMD" in
  get)
    [[ -n "${1:-}" ]] || { printf 'usage: secrets get KEY\n' >&2; exit 1; }
    require_age_key
    KEY="$(normalize_key "$1")"
    FILE="$(vault_path "$KEY")"
    [[ -f "$FILE" ]] || { printf 'secrets: key not found: %s\n' "$KEY" >&2; exit 1; }
    age --decrypt --identity "$AGE_KEY" "$FILE"
    ;;

  set)
    [[ -n "${1:-}" ]] || { printf 'usage: secrets set KEY [VALUE]\n' >&2; exit 1; }
    require_age_key
    KEY="$(normalize_key "$1")"
    shift
    if [[ -n "${1:-}" ]]; then
      VALUE="$1"
    else
      # Read from stdin without echoing. Per feedback_diagnose_secrets_without_leaking.md:
      # the value is never echoed; it is passed directly into the encryption pipeline.
      printf 'Value for %s: ' "$KEY" >&2
      IFS= read -rs VALUE || true
      printf '\n' >&2
    fi
    (umask 0077; mkdir -p "$VAULT_DIR"); chmod 700 "$VAULT_DIR"  # dir needs x-bit; 0177 umask would make it 600 (heals old broken vaults too)
    # Derive the recipient public key from the age key file.
    PUBKEY="$(grep '^# public key:' "$AGE_KEY" | awk '{print $NF}')"
    [[ -n "$PUBKEY" ]] || { printf 'secrets: could not read public key from %s\n' "$AGE_KEY" >&2; exit 2; }
    # Encrypt directly into the vault file at 0600 from creation — no chmod window.
    _vpath="$(vault_path "$KEY")"
    (umask 0177; printf '%s' "$VALUE" | age --encrypt --recipient "$PUBKEY" -o "$_vpath")
    printf 'secrets: stored %s\n' "$KEY" >&2
    ;;

  list)
    require_age_key
    if [[ ! -d "$VAULT_DIR" ]] || [[ -z "$(ls -A "$VAULT_DIR" 2>/dev/null)" ]]; then
      printf '(no secrets stored)\n'
      exit 0
    fi
    # Print key names only — never values. Per gospel §1 principle 5.
    for f in "$VAULT_DIR"/*.age; do
      [[ -e "$f" ]] || continue
      basename "$f" .age
    done
    ;;

  revoke)
    [[ -n "${1:-}" ]] || { printf 'usage: secrets revoke KEY\n' >&2; exit 1; }
    KEY="$(normalize_key "$1")"
    FILE="$(vault_path "$KEY")"
    [[ -f "$FILE" ]] || { printf 'secrets: key not found: %s\n' "$KEY" >&2; exit 1; }
    rm -f "$FILE"
    printf 'secrets: revoked %s\n' "$KEY" >&2
    ;;

  env)
    # secrets env KEY[=ALIAS]... -- COMMAND [ARGS...]
    # Exports named secrets as environment variables, then execs COMMAND.
    # Example: secrets env TELEGRAM_BOT_TOKEN -- env | grep TELEGRAM
    require_age_key
    ENV_ARGS=()
    CMD_TAIL=()
    PASSTHROUGH=0
    PAST_DASHDASH=0
    for arg in "$@"; do
      if [[ $PAST_DASHDASH -eq 1 ]]; then
        CMD_TAIL+=("$arg")
        continue
      fi
      if [[ "$arg" == "--" ]]; then
        PASSTHROUGH=1
        PAST_DASHDASH=1
        continue
      fi
      if [[ "$arg" == *=* ]]; then
        SRC_KEY="${arg%%=*}"
        ALIAS_KEY="${arg#*=}"
      else
        SRC_KEY="$arg"
        ALIAS_KEY="$(normalize_key "$arg")"
      fi
      VALUE="$(age --decrypt --identity "$AGE_KEY" "$(vault_path "$SRC_KEY")" 2>/dev/null)" \
        || { printf 'secrets env: key not found: %s\n' "$(normalize_key "$SRC_KEY")" >&2; exit 1; }
      ENV_ARGS+=("${ALIAS_KEY}=${VALUE}")
    done
    if [[ $PASSTHROUGH -eq 1 ]]; then
      [[ ${#CMD_TAIL[@]} -gt 0 ]] \
        || { printf 'secrets env: no command after -- (refusing to print environment)\n' >&2; exit 1; }
      exec env "${ENV_ARGS[@]}" "${CMD_TAIL[@]}"
    fi
    # No command: just print KEY=<redacted> lines so the caller knows what was bound.
    for pair in "${ENV_ARGS[@]}"; do
      printf '%s=[REDACTED]\n' "${pair%%=*}"
    done
    ;;

  edit)
    [[ -n "${1:-}" ]] || { printf 'usage: secrets edit KEY\n' >&2; exit 1; }
    require_age_key
    KEY="$(normalize_key "$1")"
    EDITOR="${EDITOR:-vi}"
    TMP="$(mktemp)"
    trap 'rm -f "$TMP"' EXIT
    FILE="$(vault_path "$KEY")"
    if [[ -f "$FILE" ]]; then
      age --decrypt --identity "$AGE_KEY" "$FILE" > "$TMP"
    fi
    "$EDITOR" "$TMP"
    PUBKEY="$(grep '^# public key:' "$AGE_KEY" | awk '{print $NF}')"
    age --encrypt --recipient "$PUBKEY" -o "$FILE" < "$TMP"
    chmod 0600 "$FILE"
    printf 'secrets: updated %s\n' "$KEY" >&2
    ;;

  ""|--help|-h)
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
    exit 0
    ;;

  *)
    printf 'secrets: unknown command: %s\nRun secrets --help for usage.\n' "$CMD" >&2
    exit 1
    ;;
esac
SECRETS_HELPER_EOF
}

install_secrets_helper
chmod 0755 "$SECRETS_HELPER"
ok "  Installed ${SECRETS_HELPER} (chmod 0755)"
# PATH-safety: on root installs (the normal fresh-VPS path) also place the helper
# in /usr/local/bin so `secrets` resolves in the CURRENT shell with no re-login.
# (~/.local/bin only enters PATH at the NEXT login if it didn't exist at this one.)
if [[ -w /usr/local/bin ]]; then
  cp -f "$SECRETS_HELPER" /usr/local/bin/secrets
  ok "  Installed /usr/local/bin/secrets (PATH-safe copy)"
elif ! command -v secrets >/dev/null 2>&1; then
  warn "  'secrets' is not on your PATH in this shell yet. Run this first:"
  warn "      export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── step 4.5: capture GAWD_ADMIN_CHAT_ID (gateway-disconnect alerting) ─────────
#
# GAWD_ADMIN_CHAT_ID is the Telegram chat ID that receives admin/watchdog alerts
# (e.g. "gateway disconnected from Telegram"). It is consumed by:
#   - watchdog/probes/mcp-plugin-check.sh via GAWD_ADMIN_CHAT_ID env var
#   - gateway-watchdog.sh via ~/.openclaw/secrets/secrets.json telegram_admin_chat_id
#
# Per The Hand's spec (HANDOFF-20260609): no silent-failure default. If unset,
# the watchdog fires an alert but has no channel to deliver it — alerting is
# silently off. The Prophit MUST be told this explicitly.
#
# On the docker rung: GAWD_ADMIN_CHAT_ID may come from an env var injected at
# `docker run` time; if already set, skip the prompt.
# On prophit-vm / bare-metal: always prompt unless --non-interactive.
# On non-interactive (CI/graduation gate / entrypoint): skip with a LOUD warning
# printed to stderr so the operator is never left guessing.
#
# Storage: we write the value to two places:
#   1. Via `secrets set` into the age vault (canonical — for production access).
#   2. As an EnvironmentFile entry at ${HOME}/.gawd/admin-env so the watchdog
#      systemd unit can source it via EnvironmentFile= (bare-metal / prophit-vm).
#   The value is NEVER echoed to the terminal.
#
# A Telegram chat ID is a plain integer (positive for DMs, negative for groups).
# No personal info beyond what the Prophit deliberately provides. We validate
# the format (digits, optional leading minus) and warn if it looks wrong.

log "Step 4.5/7 — Configuring admin alert channel (GAWD_ADMIN_CHAT_ID)..."

# Determine whether to prompt or skip.
SKIP_ADMIN_CHAT=0
if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
  SKIP_ADMIN_CHAT=1
fi
# Any rung: if GAWD_ADMIN_CHAT_ID env var is pre-set by the operator, use it
# and skip the prompt. This covers docker run -e, CI, and power-user bare-metal.
if [[ -n "${GAWD_ADMIN_CHAT_ID:-}" ]]; then
  SKIP_ADMIN_CHAT=2  # 2 = already set from env
fi
# Re-install: if already stored in the vault, skip the prompt (idempotent).
# Only check if the helper and key are available (first install won't have the key yet).
if [[ "$SKIP_ADMIN_CHAT" -eq 0 && -x "$SECRETS_HELPER" && -f "${SECRETS_DIR}/age.key" ]]; then
  _existing_chat_id="$("$SECRETS_HELPER" get GAWD_ADMIN_CHAT_ID 2>/dev/null || true)"
  if [[ -n "$_existing_chat_id" ]]; then
    ok "  GAWD_ADMIN_CHAT_ID already set in vault — skipping prompt."
    SKIP_ADMIN_CHAT=3  # 3 = already in vault, nothing to do
    ADMIN_CHAT_ID_VALUE="$_existing_chat_id"
  fi
  unset _existing_chat_id
fi

if [[ "$SKIP_ADMIN_CHAT" -eq 1 ]]; then
  # Non-interactive: skip prompt, print LOUD warning.
  printf '\n'
  warn "  ┌─────────────────────────────────────────────────────────────────┐"
  warn "  │  WARNING: GAWD_ADMIN_CHAT_ID not set (non-interactive mode)    │"
  warn "  │  Gateway-disconnect alerting is DISABLED until you set it.     │"
  warn "  │  After install, run:                                           │"
  warn "  │    secrets set GAWD_ADMIN_CHAT_ID                              │"
  warn "  │  Then restart the daemon.                                      │"
  warn "  └─────────────────────────────────────────────────────────────────┘"
  printf '\n'
elif [[ "$SKIP_ADMIN_CHAT" -eq 2 ]]; then
  # Docker rung with env var pre-set.
  # Validate format: same regex as the interactive path (MED-3 fix, phase4-20260609).
  # Prevents a newline-injected value from polluting the EnvironmentFile= that the
  # watchdog systemd unit reads (a GAWD_ADMIN_CHAT_ID line break → extra env assignment).
  if [[ ! "${GAWD_ADMIN_CHAT_ID}" =~ ^-?[0-9]+$ ]]; then
    fail "GAWD_ADMIN_CHAT_ID env var is not a valid Telegram chat ID (expected optional-minus then digits, got: '${GAWD_ADMIN_CHAT_ID}'). Fix the docker run -e value." 1
  fi
  ok "  GAWD_ADMIN_CHAT_ID provided via environment — storing in vault."
  ADMIN_CHAT_ID_VALUE="${GAWD_ADMIN_CHAT_ID}"
  # Store in vault (idempotent — overwrite is intentional for env-injected values).
  if command -v "$SECRETS_HELPER" &>/dev/null || [[ -x "$SECRETS_HELPER" ]]; then
    printf '%s' "$ADMIN_CHAT_ID_VALUE" | "$SECRETS_HELPER" set GAWD_ADMIN_CHAT_ID 2>/dev/null \
      && ok "  Stored GAWD_ADMIN_CHAT_ID in vault." \
      || warn "  Could not store GAWD_ADMIN_CHAT_ID in vault (no age key yet — run 'secrets set GAWD_ADMIN_CHAT_ID' after first real boot)."
  fi
elif [[ "$SKIP_ADMIN_CHAT" -eq 3 ]]; then
  # Already set in vault on a previous install — nothing to do.
  : # ADMIN_CHAT_ID_VALUE already set from vault lookup above
else
  # Interactive mode: prompt the Prophit.
  # curl|bash / bash -s < script safety: if stdin is not a tty (e.g. the script
  # was piped in from curl, meaning stdin is the script itself), we cannot safely
  # prompt — reading from stdin would consume script bytes, not user input.
  # Detect this case and treat it as a skip (same LOUD warning as NON_INTERACTIVE).
  # Reading from /dev/tty is the canonical fix but /dev/tty may not be available
  # in all container substrates. We detect both: try /dev/tty first; if that fails,
  # fall back to a non-tty skip.
  _STDIN_IS_TTY=0
  [[ -t 0 ]] && _STDIN_IS_TTY=1 || true

  ADMIN_CHAT_ID_VALUE=""
  if [[ "$_STDIN_IS_TTY" -eq 0 ]]; then
    # stdin is not a tty — curl|bash or piped execution. Skip safely.
    printf '\n'
    warn "  ┌─────────────────────────────────────────────────────────────────┐"
    warn "  │  WARNING: GAWD_ADMIN_CHAT_ID not set (non-interactive stdin)   │"
    warn "  │  stdin is not a terminal (curl|bash or piped install).         │"
    warn "  │  Gateway-disconnect alerting is DISABLED until you set it.     │"
    warn "  │  After install, run:                                           │"
    warn "  │    secrets set GAWD_ADMIN_CHAT_ID                              │"
    warn "  │  Then restart the daemon.                                      │"
    warn "  └─────────────────────────────────────────────────────────────────┘"
    printf '\n'
  else
    printf '\n'
    printf '\033[1;34m[gawd]\033[0m Admin alert channel setup\n'
    printf '\n'
    printf '  Gawd can send you a Telegram message if the gateway loses its\n'
    printf '  connection to Telegram (e.g. after a restart or auth expiry).\n'
    printf '\n'
    printf '  To enable this, enter your Telegram chat ID — the numeric ID of\n'
    printf '  the chat where you want admin alerts delivered. This is YOUR\n'
    printf '  personal chat ID (a plain integer, like 123456789), NOT a bot token.\n'
    printf '\n'
    printf '  To find your chat ID: message @userinfobot on Telegram, or check\n'
    printf '  the "id" field when you message your Gawd bot.\n'
    printf '\n'
    printf '  You can skip this now and set it later:\n'
    printf '    secrets set GAWD_ADMIN_CHAT_ID\n'
    printf '  Then restart the daemon.\n'
    printf '\n'

    ADMIN_CHAT_ID_VALUE=""
    while true; do
      printf '  Enter your Telegram chat ID (or press Enter to skip): '
      IFS= read -r ADMIN_CHAT_ID_INPUT || true
      if [[ -z "$ADMIN_CHAT_ID_INPUT" ]]; then
        # Skip — print the same LOUD warning as non-interactive.
        printf '\n'
        warn "  Skipped. Gateway-disconnect alerting is DISABLED until you set GAWD_ADMIN_CHAT_ID."
        warn "  To enable later:  secrets set GAWD_ADMIN_CHAT_ID"
        warn "  Then restart the daemon."
        printf '\n'
        break
      fi
      # Validate format: optional leading minus, then digits only.
      if [[ "$ADMIN_CHAT_ID_INPUT" =~ ^-?[0-9]+$ ]]; then
        ADMIN_CHAT_ID_VALUE="$ADMIN_CHAT_ID_INPUT"
        break
      else
        warn "  That doesn't look like a Telegram chat ID (expected digits, like 123456789 or -100123456789)."
        warn "  Please try again, or press Enter to skip."
      fi
    done
  fi

  if [[ -n "$ADMIN_CHAT_ID_VALUE" ]]; then
    # Store in vault — value is in a variable, never echoed to terminal.
    if [[ -x "$SECRETS_HELPER" ]]; then
      printf '%s' "$ADMIN_CHAT_ID_VALUE" | "$SECRETS_HELPER" set GAWD_ADMIN_CHAT_ID \
        && ok "  GAWD_ADMIN_CHAT_ID stored in vault." \
        || warn "  Vault storage failed — set it manually after install: secrets set GAWD_ADMIN_CHAT_ID"
    else
      warn "  Secrets helper not yet executable; run 'secrets set GAWD_ADMIN_CHAT_ID' after install."
    fi
  fi
fi

# Write ~/.gawd/admin-env for the watchdog systemd unit EnvironmentFile= reference.
# Only written when we have a value (either from env or from the prompt).
# Per gospel §1 P5: no secrets in files that are readable by other users.
# The value itself is not secret (it's a chat ID, not a token), but we keep
# the file mode 0600 for consistency with the rest of ~/.gawd.
GAWD_ADMIN_ENV_FILE="${HOME}/.gawd/admin-env"
mkdir -p "${HOME}/.gawd"
chmod 0700 "${HOME}/.gawd"
if [[ -n "${ADMIN_CHAT_ID_VALUE:-}" ]]; then
  # Write the env file atomically at 0600 from creation — no chmod window.
  (umask 0177; printf 'GAWD_ADMIN_CHAT_ID=%s\n' "$ADMIN_CHAT_ID_VALUE" > "$GAWD_ADMIN_ENV_FILE")
  ok "  Written ${GAWD_ADMIN_ENV_FILE} (watchdog env source)"
elif [[ ! -f "$GAWD_ADMIN_ENV_FILE" ]]; then
  # File absent and no value: write a placeholder so the watchdog unit
  # doesn't fail on a missing EnvironmentFile.
  (umask 0177; printf '# GAWD_ADMIN_CHAT_ID=  — set this and restart the daemon\n' > "$GAWD_ADMIN_ENV_FILE")
fi
# Clear the chat ID from the process environment — child scripts must not inherit it.
unset ADMIN_CHAT_ID_VALUE ADMIN_CHAT_ID_INPUT

# ── step 4.7: guided provider selection ──────────────────────────────────────
#
# Present an interactive menu so the Prophit chooses their LLM provider and
# sets the key/endpoint — vault-backed, no value ever echoed to terminal.
#
# Non-interactive mode: if GAWD_PROVIDER is pre-set and the corresponding
# key/endpoint env var is also pre-set, skip the menu and vault the key
# directly. If GAWD_PROVIDER is unset in non-interactive mode, skip with a
# clear post-install reminder. NEVER hang on a prompt in CI/docker.
#
# Menu shape (approved 2026-06-09):
#   1. MiniMax           — MINIMAX_API_KEY
#   2. Anthropic         — ANTHROPIC_API_KEY  (with copy clarifying key vs OAuth)
#   3. DeepSeek          — DEEPSEEK_API_KEY
#   4. OpenAI            — OPENAI_API_KEY
#   5. Ollama (local)    — no key; prompt endpoint (default http://localhost:11434)
#   6. Other (OpenAI-compatible) — prompt name + base URL + key env-name
#
# After this step the chosen provider's key is in the vault under its canonical
# env-var name. The docker rung's openclaw.json builder (step 5) reads the same
# env vars — the user may also inject them at `docker run` time.

log "Step 4.7/7 — Configuring LLM provider..."

# ── provider menu helper functions ──────────────────────────────────────────

# _vault_key <vault_key_name> <env_source_var>
# If env_source_var is set in the environment, write it to the vault silently.
# Used in non-interactive and env-prefilled paths.
_vault_key() {
  local vault_name="$1"
  local env_var="$2"
  local key_val="${!env_var:-}"
  if [[ -n "$key_val" ]] && [[ -x "$SECRETS_HELPER" ]]; then
    printf '%s' "$key_val" | "$SECRETS_HELPER" set "$vault_name" \
      && ok "  ${vault_name} stored in vault (from env)." \
      || warn "  Vault storage failed for ${vault_name}; run: secrets set ${vault_name}"
  fi
  unset key_val
}

# _prompt_key <vault_key_name> <prompt_label>
# Prompt for a key on /dev/tty (stdin-safe), no echo, vault immediately.
_prompt_key() {
  local vault_name="$1"
  local label="$2"
  local key_val=""
  printf '\n'
  printf '  %s\n' "$label"
  printf '  (input is hidden — paste and press Enter)\n'
  printf '  Key: '
  # Read from /dev/tty if available; avoids consuming script bytes in curl|bash
  if [[ -r /dev/tty ]]; then
    IFS= read -rs key_val < /dev/tty && printf '\n' || { printf '\n'; key_val=""; }
  else
    IFS= read -rs key_val && printf '\n' || { printf '\n'; key_val=""; }
  fi
  if [[ -n "$key_val" ]] && [[ -x "$SECRETS_HELPER" ]]; then
    printf '%s' "$key_val" | "$SECRETS_HELPER" set "$vault_name" \
      && ok "  ${vault_name} stored in vault." \
      || warn "  Vault storage failed — set it manually: secrets set ${vault_name}"
  elif [[ -z "$key_val" ]]; then
    warn "  No key entered. Set it later: secrets set ${vault_name}"
  fi
  unset key_val
}

# _prompt_endpoint <env_var_name> <default_val> <label>
# Prompt for an endpoint URL; write to vault under the env_var_name.
_prompt_endpoint() {
  local vault_name="$1"
  local default_val="$2"
  local label="$3"
  local endpoint_val=""
  printf '\n'
  printf '  %s [default: %s]: ' "$label" "$default_val"
  if [[ -r /dev/tty ]]; then
    IFS= read -r endpoint_val < /dev/tty || endpoint_val=""
  else
    IFS= read -r endpoint_val || endpoint_val=""
  fi
  [[ -z "$endpoint_val" ]] && endpoint_val="$default_val"
  if [[ -x "$SECRETS_HELPER" ]]; then
    printf '%s' "$endpoint_val" | "$SECRETS_HELPER" set "$vault_name" \
      && ok "  ${vault_name} stored in vault (${endpoint_val})." \
      || warn "  Vault storage failed — set it manually: secrets set ${vault_name}"
  fi
  unset endpoint_val
}

# _write_provider_config <provider_id> <base_url> <api_type> <key_env> <model_id>
# Write a minimal provider entry to openclaw.json if it already exists.
# On docker rung the Python builder in step 5 handles config; on other rungs
# openclaw.json may not exist yet — write a config hint file instead.
_write_provider_hint() {
  local provider_id="$1"
  local base_url="$2"
  local api_type="$3"
  local key_env="$4"
  local model_id="$5"
  local hint_file="${HOME}/.gawd/.provider-hint"
  mkdir -p "${HOME}/.gawd"
  # Write a human-readable + machine-parseable hint; referenced in post-install.
  printf 'GAWD_SELECTED_PROVIDER=%s\n' "$provider_id" > "$hint_file"
  printf 'GAWD_PROVIDER_BASE_URL=%s\n' "$base_url" >> "$hint_file"
  printf 'GAWD_PROVIDER_API_TYPE=%s\n' "$api_type" >> "$hint_file"
  printf 'GAWD_PROVIDER_KEY_ENV=%s\n' "$key_env" >> "$hint_file"
  printf 'GAWD_PROVIDER_MODEL=%s\n' "$model_id" >> "$hint_file"
  ok "  Provider hint written to ${hint_file} (used by post-install guidance)."
}

# ── determine flow ───────────────────────────────────────────────────────────

_SELECTED_PROVIDER="${GAWD_PROVIDER:-}"
_STDIN_IS_TTY_PROVIDER=0
[[ -t 0 ]] && _STDIN_IS_TTY_PROVIDER=1 || true

# Check if the age vault is ready (needed for _vault_key / _prompt_key).
_VAULT_READY=0
[[ -x "$SECRETS_HELPER" && -f "${SECRETS_DIR}/age.key" ]] && _VAULT_READY=1 || true

# Non-interactive: vault key from env if GAWD_PROVIDER + key env var both set.
if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
  if [[ -n "$_SELECTED_PROVIDER" ]]; then
    log "  Non-interactive mode: GAWD_PROVIDER=${_SELECTED_PROVIDER} — vaulting from env."
    case "$_SELECTED_PROVIDER" in
      minimax)
        [[ -n "${MINIMAX_API_KEY:-}" ]] && _vault_key MINIMAX_API_KEY MINIMAX_API_KEY \
          || warn "  MINIMAX_API_KEY not set in env; set after install: secrets set MINIMAX_API_KEY"
        _write_provider_hint "minimax" "https://api.minimax.io/anthropic" "anthropic-messages" \
          "MINIMAX_API_KEY" "minimax/MiniMax-M2.7"
        ;;
      anthropic)
        [[ -n "${ANTHROPIC_API_KEY:-}" ]] && _vault_key ANTHROPIC_API_KEY ANTHROPIC_API_KEY \
          || warn "  ANTHROPIC_API_KEY not set in env; set after install: secrets set ANTHROPIC_API_KEY"
        _write_provider_hint "anthropic" "https://api.anthropic.com" "anthropic-messages" \
          "ANTHROPIC_API_KEY" "anthropic/claude-sonnet-4-6"
        ;;
      deepseek)
        [[ -n "${DEEPSEEK_API_KEY:-}" ]] && _vault_key DEEPSEEK_API_KEY DEEPSEEK_API_KEY \
          || warn "  DEEPSEEK_API_KEY not set in env; set after install: secrets set DEEPSEEK_API_KEY"
        _write_provider_hint "deepseek" "https://api.deepseek.com" "openai-chat-completions" \
          "DEEPSEEK_API_KEY" "deepseek/deepseek-v4-flash"
        ;;
      openai)
        [[ -n "${OPENAI_API_KEY:-}" ]] && _vault_key OPENAI_API_KEY OPENAI_API_KEY \
          || warn "  OPENAI_API_KEY not set in env; set after install: secrets set OPENAI_API_KEY"
        _write_provider_hint "openai" "https://api.openai.com" "openai-chat-completions" \
          "OPENAI_API_KEY" "openai/gpt-4o"
        ;;
      ollama)
        _OLLAMA_EP="${OLLAMA_ENDPOINT:-http://localhost:11434}"
        if [[ "$_VAULT_READY" -eq 1 ]]; then
          printf '%s' "$_OLLAMA_EP" | "$SECRETS_HELPER" set OLLAMA_ENDPOINT 2>/dev/null \
            && ok "  OLLAMA_ENDPOINT stored in vault (${_OLLAMA_EP})." \
            || warn "  Vault storage failed for OLLAMA_ENDPOINT."
        fi
        _write_provider_hint "ollama" "${_OLLAMA_EP}" "openai-chat-completions" \
          "" "ollama/qwen3:8b"
        unset _OLLAMA_EP
        ;;
      other)
        # Other: expects GAWD_OTHER_PROVIDER_NAME, GAWD_OTHER_PROVIDER_URL, GAWD_OTHER_PROVIDER_KEY_ENV
        _OTHER_NAME="${GAWD_OTHER_PROVIDER_NAME:-custom}"
        _OTHER_URL="${GAWD_OTHER_PROVIDER_URL:-}"
        _OTHER_KEY_ENV="${GAWD_OTHER_PROVIDER_KEY_ENV:-}"
        if [[ -n "$_OTHER_URL" ]]; then
          _write_provider_hint "$_OTHER_NAME" "$_OTHER_URL" "openai-chat-completions" \
            "$_OTHER_KEY_ENV" "${_OTHER_NAME}/default"
          if [[ -n "$_OTHER_KEY_ENV" && -n "${!_OTHER_KEY_ENV:-}" ]]; then
            _vault_key "$_OTHER_KEY_ENV" "$_OTHER_KEY_ENV"
          fi
        else
          warn "  GAWD_PROVIDER=other but GAWD_OTHER_PROVIDER_URL not set; skipping provider config."
        fi
        unset _OTHER_NAME _OTHER_URL _OTHER_KEY_ENV
        ;;
      *)
        warn "  GAWD_PROVIDER='${_SELECTED_PROVIDER}' not recognized; skipping provider config."
        ;;
    esac
  else
    warn "  Non-interactive mode: GAWD_PROVIDER not set. Set your provider key after install."
    warn "  Example: secrets set MINIMAX_API_KEY"
  fi
elif [[ "$_STDIN_IS_TTY_PROVIDER" -eq 0 ]]; then
  # curl|bash / piped install — stdin is not a tty, cannot prompt.
  printf '\n'
  warn "  Provider setup skipped (curl|bash / piped install — stdin not a terminal)."
  warn "  After install, set your provider key and point Gawd at it."
  warn "  Example: secrets set MINIMAX_API_KEY"
  printf '\n'
else
  # ── Interactive provider menu ──────────────────────────────────────────────
  printf '\n'
  printf '\033[1;34m[gawd]\033[0m LLM provider setup\n'
  printf '\n'
  printf '  Choose the AI provider Gawd thinks with.\n'
  printf '  You can change this at any time by editing ~/.openclaw/openclaw.json.\n'
  printf '\n'
  printf '  1) MiniMax           — api.minimax.io  (recommended default)\n'
  printf '  2) Anthropic         — api.anthropic.com\n'
  printf '  3) DeepSeek          — api.deepseek.com\n'
  printf '  4) OpenAI            — api.openai.com\n'
  printf '  5) Ollama (local)    — your own machine, no key needed\n'
  printf '  6) Other             — any OpenAI-compatible endpoint\n'
  printf '\n'

  _PROVIDER_CHOICE=""
  while true; do
    printf '  Enter your choice [1-6]: '
    if [[ -r /dev/tty ]]; then
      IFS= read -r _PROVIDER_CHOICE < /dev/tty || _PROVIDER_CHOICE=""
    else
      IFS= read -r _PROVIDER_CHOICE || _PROVIDER_CHOICE=""
    fi
    case "$_PROVIDER_CHOICE" in
      1|2|3|4|5|6) break ;;
      *) warn "  Please enter a number between 1 and 6." ;;
    esac
  done

  case "$_PROVIDER_CHOICE" in
    1) # MiniMax
      log "  Provider: MiniMax"
      _prompt_key "MINIMAX_API_KEY" \
        "MiniMax API key — from platform.minimaxi.com. Required for api.minimax.io."
      _write_provider_hint "minimax" "https://api.minimax.io/anthropic" "anthropic-messages" \
        "MINIMAX_API_KEY" "minimax/MiniMax-M2.7"
      _SELECTED_PROVIDER="minimax"
      ;;
    2) # Anthropic
      log "  Provider: Anthropic"
      printf '\n'
      printf '  \033[1;33mNote:\033[0m Anthropic API key — from console.anthropic.com, requires API credits.\n'
      printf '  A Claude.ai subscription login is NOT an API key and will not work.\n'
      _prompt_key "ANTHROPIC_API_KEY" \
        "Anthropic API key (sk-ant-...) — from console.anthropic.com, requires API credits."
      _write_provider_hint "anthropic" "https://api.anthropic.com" "anthropic-messages" \
        "ANTHROPIC_API_KEY" "anthropic/claude-sonnet-4-6"
      _SELECTED_PROVIDER="anthropic"
      ;;
    3) # DeepSeek
      log "  Provider: DeepSeek"
      _prompt_key "DEEPSEEK_API_KEY" \
        "DeepSeek API key — from platform.deepseek.com."
      _write_provider_hint "deepseek" "https://api.deepseek.com" "openai-chat-completions" \
        "DEEPSEEK_API_KEY" "deepseek/deepseek-v4-flash"
      _SELECTED_PROVIDER="deepseek"
      ;;
    4) # OpenAI
      log "  Provider: OpenAI"
      _prompt_key "OPENAI_API_KEY" \
        "OpenAI API key (sk-...) — from platform.openai.com."
      _write_provider_hint "openai" "https://api.openai.com" "openai-chat-completions" \
        "OPENAI_API_KEY" "openai/gpt-4o"
      _SELECTED_PROVIDER="openai"
      ;;
    5) # Ollama
      log "  Provider: Ollama (local — no API key required)"
      _prompt_endpoint "OLLAMA_ENDPOINT" "http://localhost:11434" \
        "Ollama endpoint URL"
      _write_provider_hint "ollama" \
        "$("$SECRETS_HELPER" get OLLAMA_ENDPOINT 2>/dev/null || echo 'http://localhost:11434')" \
        "openai-chat-completions" "" "ollama/qwen3:8b"
      _SELECTED_PROVIDER="ollama"
      ;;
    6) # Other / OpenAI-compatible hatch
      log "  Provider: Other (OpenAI-compatible)"
      printf '\n'
      printf '  Enter the provider name (used as the provider ID in config, e.g. groq): '
      _OTHER_PROVIDER_NAME=""
      if [[ -r /dev/tty ]]; then
        IFS= read -r _OTHER_PROVIDER_NAME < /dev/tty || _OTHER_PROVIDER_NAME=""
      else
        IFS= read -r _OTHER_PROVIDER_NAME || _OTHER_PROVIDER_NAME=""
      fi
      [[ -z "$_OTHER_PROVIDER_NAME" ]] && _OTHER_PROVIDER_NAME="custom"
      printf '\n'
      printf '  Enter the base URL (e.g. https://api.groq.com/openai/v1): '
      _OTHER_BASE_URL=""
      if [[ -r /dev/tty ]]; then
        IFS= read -r _OTHER_BASE_URL < /dev/tty || _OTHER_BASE_URL=""
      else
        IFS= read -r _OTHER_BASE_URL || _OTHER_BASE_URL=""
      fi
      printf '\n'
      printf '  Enter the API key env-var name (e.g. GROQ_API_KEY — this name goes in the config): '
      _OTHER_KEY_ENV=""
      if [[ -r /dev/tty ]]; then
        IFS= read -r _OTHER_KEY_ENV < /dev/tty || _OTHER_KEY_ENV=""
      else
        IFS= read -r _OTHER_KEY_ENV || _OTHER_KEY_ENV=""
      fi
      if [[ -n "$_OTHER_KEY_ENV" ]]; then
        _prompt_key "$_OTHER_KEY_ENV" \
          "${_OTHER_PROVIDER_NAME} API key — stored in vault under ${_OTHER_KEY_ENV}."
      fi
      if [[ -n "$_OTHER_BASE_URL" ]]; then
        _write_provider_hint "$_OTHER_PROVIDER_NAME" "$_OTHER_BASE_URL" \
          "openai-chat-completions" "$_OTHER_KEY_ENV" "${_OTHER_PROVIDER_NAME}/default"
        ok "  Config docs: see ~/.openclaw/openclaw.json — providers block."
      else
        warn "  No base URL provided; skipping provider hint. Edit ~/.openclaw/openclaw.json manually."
      fi
      _SELECTED_PROVIDER="$_OTHER_PROVIDER_NAME"
      unset _OTHER_PROVIDER_NAME _OTHER_BASE_URL _OTHER_KEY_ENV
      ;;
  esac
  unset _PROVIDER_CHOICE
fi

unset _SELECTED_PROVIDER _STDIN_IS_TTY_PROVIDER _VAULT_READY

# ── step 5: pull Docker image or unpack tarball (per spec §4.2 step 5; §7.1) ──

log "Step 5/7 — Provisioning daemon image (rung: ${RUNG})..."

case "$RUNG" in
  docker)
    # Docker container rung — running INSIDE the image already; no pull needed.
    # Per spec §7.1: the container is pre-provisioned at build time.
    # Step 5 for this rung:
    #   a) Ensure persona templates are accessible (baked into image at build time).
    #   b) Provision /home/gawd/.openclaw/openclaw.json with a minimum-viable config
    #      so the OpenClaw gateway exposes agent routes (/compat/v1/messages etc.).
    #      Without openclaw.json the gateway runs --allow-unconfigured which only
    #      exposes /health; all agent routes return 404.
    #      API keys are read from env vars injected at docker run time — never
    #      hardcoded in the config (per gospel §1 P5 / spec principle no-secrets-in-code).

    PERSONA_TEMPLATE_DIR="/usr/local/lib/gawd/persona-templates"
    if [[ -d "$PERSONA_TEMPLATE_DIR" ]] && \
       [[ -n "$(ls -A "$PERSONA_TEMPLATE_DIR" 2>/dev/null)" ]]; then
      ok "  Running inside Docker container — persona templates present at ${PERSONA_TEMPLATE_DIR}"
    else
      fail "Running inside Docker container but persona templates not found at ${PERSONA_TEMPLATE_DIR} — image is incomplete. Rebuild from forge." 3
    fi

    # ── Provision openclaw.json (idempotent) ──────────────────────────────────
    OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
    OPENCLAW_CONFIG="${OPENCLAW_CONFIG_DIR}/openclaw.json"

    if [[ -f "$OPENCLAW_CONFIG" ]]; then
      ok "  openclaw.json already present at ${OPENCLAW_CONFIG} — skipping provisioning."
    else
      log "  Provisioning minimal openclaw.json for docker rung..."
      mkdir -p "$OPENCLAW_CONFIG_DIR"

      # NOTE: PROVIDERS_JSON / GATEWAY_AUTH / FALLBACKS shell-builder removed (phase4-20260609).
      # They were dead code — never consumed. The python3 heredoc below derives
      # providers from environment variables directly using json.dump (injection-safe).

      # BLOCKER 9: confirm bootstrap hook target exists before writing the config
      # that references it.  If BOOTSTRAP.md is absent the hook fires but injects
      # nothing, and the persona compliance directive never triggers.
      [[ -f /usr/local/lib/gawd/persona-templates/BOOTSTRAP.md ]] \
        || fail "bootstrap-extra-files hook target missing — persona would not load" 3

      # Write the minimal config using python3 for correct JSON serialization.
      # python3 is guaranteed present in the image (Dockerfile installs it).
      python3 - <<'PYEOF'
import json, os, sys

gateway_port = int(os.environ.get("GAWD_PORT", "18789"))
home = os.environ.get("HOME", "/home/gawd")

# OpenClaw model entry schema (matches Dasra's live openclaw.json):
#   input: list of strings (e.g. ["text"]) — NOT a bare string
#   cost:  dict {input, output, ...}       — NOT a number
# apiKey: string "${ENV_VAR_NAME}" — OpenClaw's normalizeApiKeyConfig strips
#         the ${} wrapper and reads the env var at runtime. Bare uppercase
#         names also work. No source/id object needed for env vars.
#
# gateway.auth.token: NOT configured here. OpenClaw automatically reads
#   OPENCLAW_GATEWAY_TOKEN from env via hasGatewayTokenEnvCandidate().
#   Putting it in config as a {source,id} object causes a schema validation
#   error. The env var path is the correct path for container deployments.

def make_minimax_provider():
    return {
        "baseUrl": "https://api.minimax.io/anthropic",
        "api": "anthropic-messages",
        "apiKey": "${MINIMAX_API_KEY}",
        "models": [
            {
                "id": "MiniMax-M2.7",
                "name": "MiniMax M2.7",
                "input": ["text"],
                "cost": {"input": 0.3, "output": 1.2, "cacheRead": 0.06, "cacheWrite": 0.375},
                "contextWindow": 1000000,
                "maxTokens": 131072
            }
        ]
    }

def make_anthropic_provider():
    return {
        "baseUrl": "https://api.anthropic.com",
        "api": "anthropic-messages",
        "apiKey": "${ANTHROPIC_OAUTH_BEARER}",
        "models": [
            {
                "id": "claude-sonnet-4-6",
                "name": "Claude Sonnet 4.6",
                "input": ["text"],
                "cost": {"input": 3.0, "output": 15.0, "cacheRead": 0.3, "cacheWrite": 3.75},
                "contextWindow": 200000,
                "maxTokens": 8192
            }
        ]
    }

def make_deepseek_provider():
    # Option B (2026-06-09): DeepSeek as an alternative provider for Prophits
    # who prefer it or need a fallback from MiniMax throttling.
    # deepseek-v4-flash: fast, 1M context, OpenAI-compatible endpoint.
    return {
        "baseUrl": "https://api.deepseek.com",
        "api": "openai-chat-completions",
        "apiKey": "${DEEPSEEK_API_KEY}",
        "models": [
            {
                "id": "deepseek-v4-flash",
                "name": "DeepSeek V4 Flash",
                "input": ["text"],
                "cost": {"input": 0.27, "output": 1.1},
                "contextWindow": 1000000,
                "maxTokens": 65536
            }
        ]
    }

minimax_key = os.environ.get("MINIMAX_API_KEY", "")
anthropic_key = os.environ.get("ANTHROPIC_OAUTH_BEARER", "")
deepseek_key = os.environ.get("DEEPSEEK_API_KEY", "")

providers = {}
fallbacks = []

if minimax_key:
    providers["minimax"] = make_minimax_provider()
    primary = "minimax/MiniMax-M2.7"
    if deepseek_key:
        providers["deepseek"] = make_deepseek_provider()
        fallbacks.append("deepseek/deepseek-v4-flash")
    if anthropic_key:
        providers["anthropic"] = make_anthropic_provider()
        fallbacks.append("anthropic/claude-sonnet-4-6")
elif deepseek_key:
    providers["deepseek"] = make_deepseek_provider()
    primary = "deepseek/deepseek-v4-flash"
    if anthropic_key:
        providers["anthropic"] = make_anthropic_provider()
        fallbacks = ["anthropic/claude-sonnet-4-6"]
elif anthropic_key:
    providers["anthropic"] = make_anthropic_provider()
    primary = "anthropic/claude-sonnet-4-6"
else:
    # No keys provided — add minimax as placeholder so agent routes register.
    # Model calls will fail until a real key is injected via env at runtime.
    providers["minimax"] = make_minimax_provider()
    primary = "minimax/MiniMax-M2.7"

model_cfg = {"primary": primary}
if fallbacks:
    model_cfg["fallbacks"] = fallbacks

# rc8 B3: fail-loud — reject any model pinned to a session-corrupting runtime.
# claude-cli/codex agentRuntimes re-poison sessions (the Dasra 14MB/783x vector).
_BANNED_RUNTIMES = {"claude-cli", "codex"}
def _assert_no_banned_runtime(provs, primary_id, fb_ids):
    pinned = [primary_id] + list(fb_ids or [])
    for prov_id, prov in (provs or {}).items():
        rt = ""
        if isinstance(prov, dict):
            rt = str(prov.get("agentRuntime", "")).strip().lower()
        if rt in _BANNED_RUNTIMES:
            sys.exit(f"[install.sh] FATAL: provider '{prov_id}' pins agentRuntime "
                     f"'{rt}' — banned (session-corruption runtime). Refusing to provision.")
        models = prov.get("models", []) if isinstance(prov, dict) else []
        for m in models:
            mrt = str((m or {}).get("agentRuntime", "")).strip().lower()
            if mrt in _BANNED_RUNTIMES:
                sys.exit(f"[install.sh] FATAL: a model under provider '{prov_id}' pins "
                         f"agentRuntime '{mrt}' — banned. Refusing to provision.")
_assert_no_banned_runtime(providers, primary, fallbacks)

config = {
    "meta": {
        "lastTouchedVersion": "docker-rung-install",
        "lastTouchedAt": ""
    },
    "gateway": {
        "port": gateway_port,
        "mode": "local",
        "bind": "loopback",
        # Enable the /v1/chat/completions HTTP REST endpoint so the
        # graduation gate's run-suite.sh (gateway mode) can reach agent turns
        # over HTTP rather than WebSocket. Required since OpenClaw 2026.5.26+
        # does not expose REST routes by default — they must be opt-in via
        # gateway.http.endpoints.chatCompletions.enabled.
        # Note: gateway.auth.token deliberately omitted — OpenClaw reads
        # OPENCLAW_GATEWAY_TOKEN from env automatically. Setting it here as a
        # {source,id} struct causes a Zod validation error on startup.
        "http": {
            "endpoints": {
                "chatCompletions": {
                    "enabled": True
                }
            }
        }
    },
    "models": {
        "mode": "merge",
        "providers": providers
    },
    "agents": {
        "defaults": {
            "model": model_cfg,
            "workspace": os.path.join(home, ".openclaw", "workspace"),
            "timeoutSeconds": 300,
            "maxConcurrent": 5,
            # rc8 B7: PROACTIVE single-live-tool-result bound. The read-loop
            # incident (2026-05-30: 70 reads, ~409k chars, one file re-read 4x,
            # prompt → ~239k tok → overflow) showed the window-scaled AUTO cap
            # does not bite on a wide-window model. Pin a fixed, window-independent
            # ceiling so any one tool result is truncated (head+tail, markers
            # preserved) BEFORE it enters the turn. Enforced natively by OpenClaw's
            # live request path (tool-result-truncation: resolveLiveToolResultMaxChars
            # reads agents.defaults.contextLimits.toolResultMaxChars). 16000 == the
            # OpenClaw DEFAULT_MAX_LIVE_TOOL_RESULT_CHARS — explicit + auditable.
            # NOTE (rc9/upstream): this bounds EACH result, not the per-turn SUM.
            # OpenClaw exposes no proactive AGGREGATE-budget config knob in this
            # dist (aggregateBudgetChars is wired to reactive session-rewrite only),
            # and no identical-repeat dedupe knob. Those remain the safety-net job
            # of auto-compaction + the rc9 follow-ups recorded in the B7 plan step.
            "contextLimits": {
                "toolResultMaxChars": 16000
            }
        }
    },
    # rc8 B8: TOOL-LOOP DETECTOR — the STRONGER guardrail above B7's per-result
    # bound. B7 caps how big ANY one tool result can be; B8 caps how MANY
    # repeating/no-progress tool calls a turn may make before the runtime aborts
    # the loop. The 2026-05-30 read-loop incident (70 reads before overflow)
    # stops at ~12 calls with this on. Config validated live against the real
    # OpenClaw runtime (v2026.5.27) on Dasra.
    #
    # CRITICAL PATH: this lives at the TOP LEVEL under "tools", NOT under
    # agents.defaults. The plugin-sdk .d.ts wrongly implies agents.defaults; the
    # real runtime validator is ToolsSchema / ToolLoopDetectionSchema
    # (zod-schema.agent-runtime-Ck-H-6Ew.js:399-419). Placing it under
    # agents.defaults CRASHES the gateway at startup — verified live. Do not move.
    #
    # Threshold ordering invariant: warn(6) < critical(12) < breaker(24).
    "tools": {
        "loopDetection": {
            "enabled": True,
            "historySize": 30,
            "warningThreshold": 6,
            "criticalThreshold": 12,
            "globalCircuitBreakerThreshold": 24,
            "detectors": {
                "genericRepeat": True,
                "knownPollNoProgress": True,
                "pingPong": True
            },
            "postCompactionGuard": {
                "windowSize": 3
            }
        }
    },
    "channels": {},
    "plugins": {
        "slots": {
            # contextEngine slot — routes context assembly through lossless-claw
            "contextEngine": "lossless-claw"
        },
        "entries": {
            # T1.2 — Q4 audited daemon defaults. Key path confirmed against
            # openclaw source (io-BlARNTf3.js line 3576): config values live in
            # plugins.entries.<id>.config sub-object, not flat in the entry.
            # Lilith relies on plugin defaults (no config sub-object set); we
            # set explicit values here for auditable, reproducible installs.
            # Do not change without a re-audit.
            "lossless-claw": {
                "enabled": True,
                "config": {
                    "contextThreshold": 0.65,
                    "proactiveThresholdCompactionMode": "inline",
                    "freshTailCount": 64,
                    "leafChunkTokens": 20000
                }
            },
            # Q3: OS-cron safe-dream.sh is the SINGLE dreaming owner.
            # The built-in memory-core scheduler is explicitly disabled to
            # prevent double-fire. Config key path confirmed from OpenClaw source
            # (dreaming-DT202ka-.js): resolveMemoryCorePluginConfig reads
            # plugins.entries.memory-core.config.dreaming.enabled
            # (DEFAULT_MEMORY_DREAMING_ENABLED = false — off by default, but we
            # set it explicitly so the config is auditable and the test is checkable).
            # GAWD_DREAM_MODEL: the OS-cron entry sets this to a cheap cloud model
            # (Option A, locked 2026-05-29). Operators override via env at runtime.
            # Recommended default: "minimax/MiniMax-M2.7".
            # Never a key — model name only. Empty = stub mode (no real dreaming).
            "memory-core": {
                "enabled": True,
                "config": {
                    "dreaming": {
                        "enabled": False  # Q3: single owner is OS-cron safe-dream.sh
                    }
                }
            },
            # T3b: memory-wiki — SAFE-ON config. Re-enabled LAST (Phase 3, Task 3.4)
            # after all three recursion guards are in place.
            #
            # Guard #1 (disjoint path): vault.path points to workspace/wiki —
            #   OUTSIDE workspace/memory (the ingest scope). This prevents the plugin
            #   from re-ingesting its own output (the 79K-iteration recursion fix).
            #   Verified at boot by wiki-startup-check.sh in entrypoint.sh.
            #
            # Guard #2 (gen-tag skip): wiki-gen-guard.sh in safe-dream.sh skips any
            #   artifact with generation >= 1. Summaries are stamped generation:1 by
            #   wiki_upsert.sh; source notes carry generation:0.
            #
            # Guard #3 (hash-upsert idempotency): wiki_upsert.sh writes only when
            #   content changes — identical content produces no fs event, no re-trigger.
            #
            # ingest.maxConcurrentJobs = 1: structural recursion-rate cap.
            #   This is the ONLY numeric rate-limiting field in the real memory-wiki
            #   configSchema (confirmed from openclaw.plugin.json; there is NO
            #   maxIngestEventsPerRun in the real schema). Setting to 1 means at most
            #   one concurrent ingest job runs at a time, preventing burst parallel
            #   re-ingest compounding.
            #
            # bridge flags: index only source artifacts (day notes + memory root).
            #   followMemoryEvents=False: do not follow live memory events into the
            #   wiki bridge (prevents the bridge from auto-triggering on every write).
            "memory-wiki": {
                "enabled": True,
                "config": {
                    "vaultMode": "bridge",
                    "vault": {
                        # DISJOINT from ingest scope (workspace/memory).
                        # wiki-startup-check.sh enforces this at boot.
                        "path": os.path.join(home, ".openclaw", "workspace", "wiki")
                    },
                    "bridge": {
                        "enabled": True,
                        "readMemoryArtifacts": True,
                        "indexDreamReports": True,
                        "indexDailyNotes": True,
                        "indexMemoryRoot": True,
                        # followMemoryEvents=False: do not follow live write events.
                        # The dreaming cron (safe-dream.sh) drives wiki synthesis on
                        # a gated cadence; live event following would re-trigger on
                        # every synthesis output.
                        "followMemoryEvents": False
                    },
                    "ingest": {
                        # Structural recursion-rate cap. Real schema key confirmed:
                        # configSchema.properties.ingest.properties.maxConcurrentJobs
                        # (type: number, minimum: 1). 1 = serialized ingest, no burst.
                        "maxConcurrentJobs": 1
                    }
                }
            }
        }
    },
    "skills": {},
    # bootstrap-extra-files hook — injects BOOTSTRAP.md from the persona-
    # templates directory on every agent request, bypassing the workspace
    # reconcile mechanism that deletes the workspace-root BOOTSTRAP.md once
    # setup is marked complete.
    #
    # Why this works (OpenClaw internals):
    #   resolveBootstrapFilesForRun() calls applyBootstrapHookOverrides() which
    #   fires the "agent bootstrap" event on EVERY request. The handler injects
    #   the file into bootstrapFiles. The outer filterCompletedWorkspaceBootstrapFile()
    #   only strips BOOTSTRAP.md when its path == {workspaceRoot}/BOOTSTRAP.md;
    #   our external path is different, so it survives.
    #
    #   Critically: resolveAttemptWorkspaceBootstrapRouting() calls
    #   hasBootstrapFileContent(bootstrapFiles) — if any bootstrap file named
    #   BOOTSTRAP.md has real content, workspaceBootstrapPending is forced true.
    #   This sets bootstrapMode="full", which triggers the compliance directive:
    #   "BOOTSTRAP.md is included below in Project Context; follow it before
    #   replying normally." — making the model treat BOOTSTRAP.md as directives,
    #   not merely informational Project Context.
    #
    # Config path: hooks.internal.entries["bootstrap-extra-files"]
    # (per resolveHookConfig in config-CRTtlu4C.js)
    "hooks": {
        "internal": {
            "entries": {
                "bootstrap-extra-files": {
                    "enabled": True,
                    "paths": [
                        "/usr/local/lib/gawd/persona-templates/BOOTSTRAP.md"
                    ]
                }
            }
        }
    }
}

out_path = os.path.join(home, ".openclaw", "openclaw.json")
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"[install.sh] openclaw.json written to {out_path}")
PYEOF

      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OPENCLAW_CONFIG" \
        || fail "openclaw.json is not valid JSON after provisioning" 3
      ok "  openclaw.json provisioned and validated at ${OPENCLAW_CONFIG}"

      # ── rc8 A2 / rc8.1: gateway-patches (next-none-fix-v1) ───────────────────
      # The patch is now BAKED AT BUILD TIME as root (see build/Dockerfile, after
      # the gateway-patches COPY). At first boot the dist is owned root:root and
      # this code runs as the unprivileged `gawd` user, so a write here would fail
      # Permission denied — which was the rc8.0 silent-ship bug. Now that the
      # marker is already present, apply-patches short-circuits idempotently
      # (its per-hunk anchor check finds the anchors gone + marker present → no
      # write attempted), so this is a safe no-op verify-pass on the docker rung.
      # On the bare-metal rung (gawd owns its own npm-global dist) this still does
      # the real apply. Either way it must run BEFORE the B5 plugin registration
      # so the runtime is patched before plugins resolve. A genuinely-vanished
      # anchor across the whole glob still fails loud (apply-patches exit 1).
      # B-1: precondition on -f (present), NOT -x (executable). Docker COPY drops
      # the exec bit (apply-patches.sh ships mode 600); gating on -x silently
      # skipped the patch (warn, not fail). We invoke via `bash "$..."` below so a
      # missing exec bit can never skip the next-none chain-iteration patch.
      GATEWAY_PATCH_SH="/usr/local/lib/gawd/gateway-patches/apply-patches.sh"
      [[ -f "$GATEWAY_PATCH_SH" ]] || GATEWAY_PATCH_SH="$(dirname "$0")/gateway-patches/apply-patches.sh"
      OPENCLAW_DIST_IMAGE="/usr/local/lib/node_modules/openclaw/dist"
      [[ -d "$OPENCLAW_DIST_IMAGE" ]] || OPENCLAW_DIST_IMAGE="/usr/lib/node_modules/openclaw/dist"
      if [[ -f "$GATEWAY_PATCH_SH" && -d "$OPENCLAW_DIST_IMAGE" ]]; then
        log "  Applying gateway-patches to ${OPENCLAW_DIST_IMAGE}..."
        bash "$GATEWAY_PATCH_SH" "$OPENCLAW_DIST_IMAGE" \
          || fail "gateway-patches failed — OpenClaw shape may have changed (rebake anchors); refusing to ship an unpatched chain-iteration daemon" 3
        ok "  gateway-patches applied (next-none-fix-v1)"
      else
        warn "  gateway-patches not applicable (script or dist missing) — chain-iteration patch NOT applied"
      fi

      # ── rc8 B5: register lossless-claw so the contextEngine slot is real ─────
      # The config sets plugins.slots.contextEngine=lossless-claw and the image
      # npm-installs @martian-engineering/lossless-claw, but OpenClaw only
      # ACTIVATES a slot plugin after `openclaw plugins install`. Without this,
      # the slot silently falls to `legacy` (crude truncation). Run it, then
      # FAIL LOUD if the resolved slot is legacy/empty — we refuse to ship a
      # legacy-truncation daemon. Exit code 79 is distinct from B3 (78)/B7 (80).
      if command -v openclaw >/dev/null 2>&1; then
        log "  Registering lossless-claw contextEngine plugin..."
        # MUST be the SCOPED package name. The bare 'lossless-claw' is not on npm
        # (Package not found on npm: lossless-claw) → registration fails → slot
        # falls to legacy → exit 79. The staged package is the scoped one (the
        # LOSSLESS_CLAW_PKG ARG, under .openclaw/npm/node_modules/@martian-engineering/lossless-claw).
        # --force: the image pre-installs lossless-claw@0.11.2 into the npm tree;
        # newer openclaw plugin-install detects the existing package and refuses
        # without --force. --force activates the slot registration path regardless
        # of whether a newer version is downloaded. The image copy is the effective
        # package (no npm registry hit needed; --force skips the version-conflict bail).
        openclaw plugins install --force @martian-engineering/lossless-claw >/dev/null 2>&1 \
          || warn "  'openclaw plugins install --force @martian-engineering/lossless-claw' returned non-zero — verifying slot regardless"
        # Resolve the active contextEngine slot. `openclaw config get` returns
        # multi-line JSON; tr -d collapses a scalar string safely. Do NOT
        # pipe-grep '^[{[]' here (feedback_openclaw_config_get_json.md).
        ce_slot="$(openclaw config get plugins.slots.contextEngine 2>/dev/null \
                    | tr -d '"[:space:]' || true)"
        if [[ "$ce_slot" == "legacy" || -z "$ce_slot" ]]; then
          fail "contextEngine slot resolved to '${ce_slot:-empty}' (expected lossless-claw) — lossless-claw not registered; refusing to ship a legacy-truncation daemon" 79
        fi
        ok "  contextEngine slot active: ${ce_slot}"
      else
        warn "  openclaw CLI not on PATH at install time — slot registration deferred to entrypoint re-check"
      fi
    fi

    # ── seed agents/main/agent/ with persona system-message ──────────────────
    # OpenClaw requires ~/.openclaw/agents/main/agent/system-message.txt to be
    # present before the gateway starts, or the /v1/chat/completions route will
    # not load the agent's persona into the system prompt. Without this, gateway-
    # mode assertions fail because the Gawd personality is absent from responses.
    #
    # We concatenate the T0 anchors (SOUL + IDENTITY + VOICE) from persona-
    # templates/ into system-message.txt. These are identical to what Dasra's
    # Zoos uses in production.
    AGENTS_DIR="${OPENCLAW_CONFIG_DIR}/agents/main/agent"
    SYSTEM_MSG="${AGENTS_DIR}/system-message.txt"
    PERSONA_TEMPLATES_DIR="/usr/local/lib/gawd/persona-templates"

    if [[ ! -f "$SYSTEM_MSG" ]]; then
      log "  Seeding agent system-message from persona templates..."
      mkdir -p "$AGENTS_DIR" "${OPENCLAW_CONFIG_DIR}/agents/main/sessions"

      # Combine SOUL + IDENTITY + VOICE into system-message.txt. BOOTSTRAP.md is
      # injected separately via the bootstrap-extra-files hook (single source),
      # NOT concatenated here — see hooks.internal.entries above.
      {
        if [[ -f "${PERSONA_TEMPLATES_DIR}/SOUL.md" ]]; then
          cat "${PERSONA_TEMPLATES_DIR}/SOUL.md"
          printf '\n\n'
        fi
        if [[ -f "${PERSONA_TEMPLATES_DIR}/IDENTITY.md" ]]; then
          cat "${PERSONA_TEMPLATES_DIR}/IDENTITY.md"
          printf '\n\n'
        fi
        if [[ -f "${PERSONA_TEMPLATES_DIR}/VOICE.md" ]]; then
          cat "${PERSONA_TEMPLATES_DIR}/VOICE.md"
          printf '\n\n'
        fi
      } > "$SYSTEM_MSG"

      if [[ -s "$SYSTEM_MSG" ]]; then
        ok "  system-message.txt seeded at ${SYSTEM_MSG} ($(wc -c < "$SYSTEM_MSG") bytes)"
      else
        warn "  system-message.txt is empty — persona templates may be missing at ${PERSONA_TEMPLATES_DIR}"
      fi
    else
      ok "  system-message.txt already present at ${SYSTEM_MSG} — skipping seed."
    fi

    # ── overwrite workspace persona files with Gawd T0 anchors ───────────────
    # OpenClaw loads SOUL.md, IDENTITY.md, USER.md etc. from the workspace dir
    # (not the agent dir). The image bootstraps these from OpenClaw's default
    # generic templates. We must overwrite them with the Gawd persona templates
    # so gateway-mode assertions see Gawd's actual soul, identity, and voice.
    #
    # Idempotent: each file is written unconditionally on first install.sh run
    # (the entrypoint guards against re-running via the openclaw.json sentinel),
    # but if the workspace was initialized before persona copy happened, force it.
    #
    # Files overwritten: SOUL.md, IDENTITY.md, VOICE.md (if present in templates)
    # Files left alone: USER.md, AGENTS.md, TOOLS.md (runtime-configured)
    WORKSPACE_DIR="${HOME}/.openclaw/workspace"
    PERSONA_COPY_STAMP="${WORKSPACE_DIR}/.persona-copied"

    if [[ ! -f "$PERSONA_COPY_STAMP" ]]; then
      log "  Overwriting workspace persona files from templates..."
      for persona_file in SOUL.md IDENTITY.md VOICE.md BOOT.md; do
        src="${PERSONA_TEMPLATES_DIR}/${persona_file}"
        dst="${WORKSPACE_DIR}/${persona_file}"
        if [[ -f "$src" ]]; then
          cp "$src" "$dst"
          ok "    ${persona_file}: written to workspace"
        fi
      done
      # USER.md: seed a minimal one so "Prophit" is referenced in persona context
      USER_MD="${WORKSPACE_DIR}/USER.md"
      if [[ ! -s "$USER_MD" ]] || grep -q "Fill this in" "$USER_MD" 2>/dev/null; then
        cat > "$USER_MD" << 'USEREOF'
# USER.md — Your Prophit

- **Name:** Prophit
- **Pronouns:** they/them (update once we've spoken)
- **Context:** First install. I haven't met you yet.
USEREOF
        ok "    USER.md: minimal seed written (Prophit placeholder)"
      fi
      touch "$PERSONA_COPY_STAMP"
      ok "  Workspace persona files overwritten."
    else
      ok "  Workspace persona files already copied (stamp present) — skipping."
    fi

    # ── step 5d: activate v1 subsystems (Logos v1-assembly ruling 2026-05-28) ──
    # Bakes are static under /usr/local/lib/gawd/<sub>/; this section provisions
    # the per-Prophit runtime state under $HOME/.gawd (GAWD_HOME). The docker
    # rung has no `systemd --user` PID 1, so activation uses cron-in-container +
    # nohup gunicorn (GAWD_NO_SYSTEMD=1). On bare-metal/prophit-vm/hosted rungs
    # the subsystem install.sh scripts run as-written and use systemctl --user.
    #
    # Idempotent: each subsystem guarded by a stamp under $HOME/.gawd/state/.
    # Fail-loud: required subsystems (silence-avoidance, watchdog, dashboard)
    # call fail() on failure; optional ones (voice) warn-and-continue.
    log "Step 5d/7 — Activating v1 subsystems..."

    GAWD_HOME="${HOME}/.gawd"
    GAWD_LIB="/usr/local/lib/gawd"
    SUBSYS_STATE="${GAWD_HOME}/state"
    mkdir -p "$GAWD_HOME" "$SUBSYS_STATE"

    # ── step 5c-bis: provision baked local models into ${GAWD_HOME}/models ───────
    # rc5 (2026-05-29): the image bakes the embed model (qwen3-embedding-0.6b) and
    # a glibc-matched llama-server at /usr/local/bin. The reliability D1 block (and
    # the docker-rung entrypoint loop) look for models under ${GAWD_HOME}/models —
    # so on first boot we copy the baked model into place. This is what makes a
    # shipped Gawd have a WORKING local embed server (and thus functioning
    # memory/embeddings) from first boot, instead of an enabled-but-dormant unit.
    #
    # Idempotent: only copies if the dest is absent (a Prophit who later swaps in
    # their own model is never clobbered). The baked source is read-only lib content.
    if [[ -d "${GAWD_LIB}/models" ]]; then
      mkdir -p "${GAWD_HOME}/models"
      shopt -s nullglob
      for _baked in "${GAWD_LIB}/models"/*.gguf; do
        _dest="${GAWD_HOME}/models/$(basename "$_baked")"
        if [[ ! -f "$_dest" ]]; then
          cp "$_baked" "$_dest" \
            && ok "  provisioned baked model → ${_dest}" \
            || warn "  failed to provision baked model $(basename "$_baked")"
        else
          ok "  baked model already present at ${_dest} — not overwriting"
        fi
      done
      shopt -u nullglob
    fi

    # Detect whether systemd --user is usable on this substrate. In the docker
    # rung it is not (no PID-1 systemd); on real substrates it is.
    SUBSYS_NO_SYSTEMD=0
    if [[ "$RUNG" == "docker" ]]; then
      SUBSYS_NO_SYSTEMD=1
    elif ! systemctl --user show-environment >/dev/null 2>&1; then
      SUBSYS_NO_SYSTEMD=1
    fi
    export GAWD_HOME

    # ── silence-avoidance (REQUIRED) ──────────────────────────────────────────
    if [[ ! -f "${SUBSYS_STATE}/.silence-avoidance-activated" ]]; then
      log "  Activating silence-avoidance..."
      # Prefer the baked Seraph G3 templates; install.sh falls back to bundled.
      _SA_TEMPLATES="${GAWD_LIB}/fallbacks/templates"
      if [[ ! -d "$_SA_TEMPLATES" ]]; then
        _SA_TEMPLATES="${GAWD_LIB}/silence-avoidance/templates"
      fi
      bash "${GAWD_LIB}/silence-avoidance/install.sh" \
          --dest "$GAWD_HOME" \
          --templates-src "$_SA_TEMPLATES" \
        || fail "silence-avoidance activation failed (install.sh non-zero)" 3
      # session-recovery: stage recover.sh/detect.sh/sweep.sh to the canonical
      # ${GAWD_HOME}/engine/session-recovery/ the L7 watchdog reads. --no-cron
      # so it does not try to register a systemd timer in the docker rung; the
      # L7 watchdog cron (below) is the docker-rung cadence.
      if [[ "$SUBSYS_NO_SYSTEMD" == "1" ]]; then
        bash "${GAWD_LIB}/silence-avoidance/session-recovery/install-hooks.sh" --no-cron \
          || fail "silence-avoidance session-recovery hook install failed" 3
      else
        bash "${GAWD_LIB}/silence-avoidance/session-recovery/install-hooks.sh" \
          || fail "silence-avoidance session-recovery hook install failed" 3
      fi
      touch "${SUBSYS_STATE}/.silence-avoidance-activated"
      ok "  silence-avoidance activated (engine at ${GAWD_HOME}/engine/silence-avoidance)"
    else
      ok "  silence-avoidance already activated — skipping."
    fi

    # ── watchdog (REQUIRED) ───────────────────────────────────────────────────
    if [[ ! -f "${SUBSYS_STATE}/.watchdog-activated" ]]; then
      log "  Activating watchdog..."
      # CADENCE (Metatron cadence ruling 2026-05-28): the watchdog/install.sh
      # crontab-append bug (crontab -l exit-1 on an empty crontab tripping
      # `set -e`) is now FIXED AT SOURCE in watchdog/install.sh (the `|| true`
      # guard on `crontab -l`). The prior assembly-layer pre-seed workaround
      # here is therefore REMOVED — see HANDOFF-20260528-METATRON-ARCHON-watchdog-cadence.
      # Docker-rung cadence no longer rides cron at all (vixie cron will not run
      # jobs as the non-root gawd user); entrypoint.sh launches a supervised
      # `while true; sleep 60; sweep.sh` loop instead.
      # --no-start: write units, copy sweep.sh+probes to $HOME/.gawd/watchdog,
      # skip systemctl. (It also adds its own */5 belt-and-suspenders crontab —
      # harmless dead weight in the docker rung, the documented fallback where a
      # host cron IS available.)
      bash "${GAWD_LIB}/watchdog/install.sh" --no-start \
        || fail "watchdog activation failed (install.sh non-zero)" 3
      if [[ "$SUBSYS_NO_SYSTEMD" == "1" ]]; then
        # Docker rung: cadence is driven by the entrypoint-managed supervised
        # loop (Metatron cadence ruling 2026-05-28), NOT by cron — vixie cron
        # will not run jobs as the non-root gawd user. We only ensure the log
        # dir exists; entrypoint.sh launches `while true; sleep 60; sweep.sh`.
        mkdir -p "${GAWD_HOME}/watchdog/logs"
        ok "  watchdog cadence: entrypoint supervised loop (docker rung; cron NOT used — non-root gawd cannot run vixie cron)"
      else
        # Real substrate: enable the 60s systemd user timer.
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable --now watchdog-sweep.timer 2>/dev/null \
          || warn "  watchdog timer enable returned non-zero (verify on substrate)"
      fi
      touch "${SUBSYS_STATE}/.watchdog-activated"
      ok "  watchdog activated (sweep at ${GAWD_HOME}/watchdog/sweep.sh)"
    else
      ok "  watchdog already activated — skipping."
    fi

    # ── reliability hardening (Metatron deployment-reliability 2026-05-28) ─────
    # Stages reliability helper scripts to ${GAWD_HOME}/scripts, installs the
    # gateway / embed / completions / failure-alert unit templates, runs the
    # one-unit-per-service port-owner preflight, computes per-rung MemoryMax/High
    # drop-ins from /proc/meminfo (D3), and conditionally enables the local
    # llama-server units only when a model file is present (D1).
    if [[ ! -f "${SUBSYS_STATE}/.reliability-activated" ]]; then
      log "  Activating deployment-reliability hardening..."

      # Resolve where the static reliability bakes live (docker: /usr/local/lib;
      # bare-metal tarball: ${GAWD_INSTALL_DIR}).
      _REL_SCRIPTS_SRC=""
      for c in "${GAWD_LIB}/scripts" "${GAWD_INSTALL_DIR:-/opt/gawd}/scripts"; do
        [[ -f "${c}/gawd-port-owner.sh" ]] && { _REL_SCRIPTS_SRC="$c"; break; }
      done
      _REL_UNITS_SRC=""
      for c in "${GAWD_LIB}/systemd" "${GAWD_INSTALL_DIR:-/opt/gawd}/systemd"; do
        [[ -f "${c}/gawd.service" ]] && { _REL_UNITS_SRC="$c"; break; }
      done

      # 1) Stage reliability scripts to ${GAWD_HOME}/scripts (read by units + entrypoint).
      mkdir -p "${GAWD_HOME}/scripts" "${GAWD_HOME}/logs"
      if [[ -n "$_REL_SCRIPTS_SRC" ]]; then
        for s in gawd-port-owner.sh gawd-failure-alert.sh gawd-health-gate.sh \
                 gawd-clean-state.sh gawd-safe-mutate.sh; do
          if [[ -f "${_REL_SCRIPTS_SRC}/${s}" ]]; then
            cp "${_REL_SCRIPTS_SRC}/${s}" "${GAWD_HOME}/scripts/${s}"
            chmod 0755 "${GAWD_HOME}/scripts/${s}"
          else
            warn "    reliability script missing in bake: ${s}"
          fi
        done
        ok "    reliability scripts staged to ${GAWD_HOME}/scripts"
      else
        warn "    reliability scripts source not found — entrypoint will fall back to baked lib copies"
      fi

      # Per-rung RAM envelope (D3): MemoryMax=min(cap,60% RAM), High=min(cap,45% RAM).
      # cap = the unit's baked ceiling. Computed from /proc/meminfo so the
      # percentages map to a real number on a 4G prophit-vm or a 30G Dasra-class box.
      _mem_total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
      # H4 (2026-05-28): for a llama-server with a known MODEL FILE, the ceiling
      # MUST be derived from the model's footprint, never a flat RAM%. A 35B model
      # under a box-RAM% cap that lands below the model's resident size = a
      # guaranteed OOM-kill mid-generation → restart loop. We size the ceiling at
      # model_bytes * 1.3 (weights + activations) + 1G KV headroom, and if the
      # RAM-derived cap would fall BELOW that floor we REFUSE to write the guard
      # (loud warn, return 2) rather than ship a guaranteed kill-loop.
      _model_floor_g() {  # <model-path> → echoes GiB floor, or empty if no model
        local mp="$1"
        [[ -n "$mp" && -f "$mp" ]] || return 1
        local bytes; bytes="$(stat -c%s "$mp" 2>/dev/null || echo 0)"
        [[ "${bytes:-0}" -gt 0 ]] || return 1
        # floor_g = ceil(bytes*1.3 / 1GiB) + 1G KV headroom
        local g=$(( (bytes * 13 / 10 + 1073741823) / 1073741824 + 1 ))
        echo "$g"
      }
      _write_mem_dropin() {  # <unit> <max_cap_g> <high_cap_g> [model-path]
        local unit="$1" maxcap="$2" highcap="$3" model="${4:-}"
        local d="${HOME}/.config/systemd/user/${unit}.d"
        mkdir -p "$d"
        local max_g high_g
        if [[ "${_mem_total_kb:-0}" -gt 0 ]]; then
          # 60% / 45% of RAM in GiB (integer floor), then min() with the cap.
          local p60_g p45_g
          p60_g=$(( _mem_total_kb * 60 / 100 / 1048576 ))
          p45_g=$(( _mem_total_kb * 45 / 100 / 1048576 ))
          [[ "$p60_g" -lt 1 ]] && p60_g=1
          [[ "$p45_g" -lt 1 ]] && p45_g=1
          max_g=$(( p60_g < maxcap ? p60_g : maxcap ))
          high_g=$(( p45_g < highcap ? p45_g : highcap ))
        else
          max_g="$maxcap"; high_g="$highcap"
        fi

        # H4: model-size-aware floor for llama-server units.
        if [[ -n "$model" ]]; then
          local floor_g; floor_g="$(_model_floor_g "$model" || true)"
          if [[ -n "$floor_g" ]]; then
            if [[ "$max_g" -lt "$floor_g" ]]; then
              warn "      ${unit}: REFUSING MemoryMax guard — computed ceiling ${max_g}G is BELOW the model footprint floor ${floor_g}G (model_bytes*1.3 + KV). A guard here is a guaranteed OOM kill-loop; leaving the unit UNGUARDED (RuntimeMaxSec cycling + circuit-breaker still apply). Provision more RAM or a smaller model."
              rm -f "${d}/memory.conf" 2>/dev/null || true
              return 2
            fi
            # Raise the ceiling to at least the model floor (so the guard can
            # never sit below the model's resident size).
            [[ "$max_g" -lt "$floor_g" ]] && max_g="$floor_g"
            # MemoryHigh = soft pressure point just under Max.
            [[ "$high_g" -ge "$max_g" ]] && high_g=$(( max_g > 1 ? max_g - 1 : 1 ))
            cat > "${d}/memory.conf" <<EOF
# Auto-computed by install.sh (H4 model-size-aware ceiling).
# MemoryMax derived from model footprint (model_bytes*1.3 + 1G KV) floor ${floor_g}G,
# clamped up from the RAM envelope so the guard can never OOM-kill the model.
[Service]
MemoryMax=${max_g}G
MemoryHigh=${high_g}G
EOF
            ok "      ${unit}: MemoryMax=${max_g}G MemoryHigh=${high_g}G (model-size-aware, floor=${floor_g}G)"
            return 0
          fi
        fi

        cat > "${d}/memory.conf" <<EOF
# Auto-computed by install.sh (D3 RAM envelopes) from /proc/meminfo.
# MemoryMax = min(${maxcap}G, 60% RAM); MemoryHigh = min(${highcap}G, 45% RAM).
[Service]
MemoryMax=${max_g}G
MemoryHigh=${high_g}G
EOF
        ok "      ${unit}: MemoryMax=${max_g}G MemoryHigh=${high_g}G (RAM ceiling drop-in)"
      }

      if [[ "$SUBSYS_NO_SYSTEMD" == "1" ]]; then
        # Docker rung: no systemd. The entrypoint enforces the equivalent guards
        # in-process (clean-state, supervised leak-guarded llama loops, watchdog
        # circuit-breaker). Units are not placed; record activation + move on.
        ok "    docker rung — reliability guards enforced by entrypoint (no systemd units placed)"
      else
        # Real substrate: place units + alert template, run port-owner, set ceilings.
        SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
        mkdir -p "$SYSTEMD_USER_DIR"

        if [[ -n "$_REL_UNITS_SRC" ]]; then
          # Always place the failure-alert template + gateway unit.
          cp "${_REL_UNITS_SRC}/gawd-failure-alert@.service" "${SYSTEMD_USER_DIR}/" 2>/dev/null \
            && ok "    placed gawd-failure-alert@.service" \
            || warn "    failure-alert template copy failed"
          cp "${_REL_UNITS_SRC}/gawd.service" "${SYSTEMD_USER_DIR}/gawd.service" 2>/dev/null \
            && ok "    placed gawd.service (canonical gateway unit, D2)" \
            || warn "    gawd.service copy failed"

          # Gateway ceilings (D3) + clean-state already baked as ExecStartPre.
          _write_mem_dropin "gawd.service" 7 5

          # ── D1: local-embed posture — enable embed unit ONLY when a model exists.
          _EMBED_MODEL=""
          for m in "${GAWD_HOME}"/models/*embed*.gguf "${GAWD_HOME}"/models/qwen3-embedding-0.6b.gguf; do
            [[ -f "$m" ]] && { _EMBED_MODEL="$m"; break; }
          done
          if [[ -n "$_EMBED_MODEL" ]]; then
            cp "${_REL_UNITS_SRC}/gawd-embed.service" "${SYSTEMD_USER_DIR}/gawd-embed.service" 2>/dev/null || true
            mkdir -p "${GAWD_HOME}/state"
            printf 'GAWD_EMBED_PORT=11436\nGAWD_EMBED_MODEL=%s\n' "$_EMBED_MODEL" > "${GAWD_HOME}/state/gawd-embed.env"
            _write_mem_dropin "gawd-embed.service" 3 2 "$_EMBED_MODEL" || true
            # one-unit-per-service preflight before enabling (hardening 1).
            # H3: do NOT swallow a non-zero exit — exit 3 = a confirmed conflict
            # could not be disabled (privilege). Surface LOUDLY (the Prophit was
            # already alerted by the script) so the conflict is not masked.
            if [[ -x "${GAWD_HOME}/scripts/gawd-port-owner.sh" ]]; then
              if ! GAWD_HOME="$GAWD_HOME" bash "${GAWD_HOME}/scripts/gawd-port-owner.sh" 11436 gawd-embed.service; then
                warn "    PORT CONFLICT on :11436 could not be auto-resolved (privilege?) — embed crashloop risk; resolve the system-scope conflict manually before relying on local embed"
              fi
            fi
            systemctl --user daemon-reload 2>/dev/null || true
            systemctl --user enable --now gawd-embed.service 2>/dev/null \
              && ok "    gawd-embed.service ENABLED (local embed model present; leak guard active)" \
              || warn "    gawd-embed.service enable returned non-zero (verify on substrate)"
            # Gateway health-gates on local embed (hardening 4): drop-in adds the ExecStartPre.
            mkdir -p "${SYSTEMD_USER_DIR}/gawd.service.d"
            cat > "${SYSTEMD_USER_DIR}/gawd.service.d/embed-gate.conf" <<'EOF'
# Local-embed posture: gateway waits on embed /health before opening memory
# routes (hardening 4). Leading '-' = warn-not-fatal (silence-is-worst-outcome).
[Service]
ExecStartPre=-%h/.gawd/scripts/gawd-health-gate.sh http://127.0.0.1:11436/health 60 embed
EOF
          else
            # Remote/hosted embedding posture: stage the unit DISABLED, like voice.
            cp "${_REL_UNITS_SRC}/gawd-embed.service" "${SYSTEMD_USER_DIR}/gawd-embed.service" 2>/dev/null || true
            ok "    embed: remote posture, local unit staged-disabled (no model under ${GAWD_HOME}/models)"
          fi

          # ── completions llama-server (TWO-additions #1) — same model-present gate.
          _COMP_MODEL=""
          for m in "${GAWD_HOME}"/models/completions.gguf "${GAWD_HOME}"/models/*coder*.gguf "${GAWD_HOME}"/models/*-completions-*.gguf; do
            [[ -f "$m" ]] && { _COMP_MODEL="$m"; break; }
          done
          if [[ -n "$_COMP_MODEL" ]]; then
            cp "${_REL_UNITS_SRC}/gawd-completions.service" "${SYSTEMD_USER_DIR}/gawd-completions.service" 2>/dev/null || true
            mkdir -p "${GAWD_HOME}/state"
            printf 'GAWD_COMPLETIONS_PORT=11434\nGAWD_COMPLETIONS_MODEL=%s\n' "$_COMP_MODEL" > "${GAWD_HOME}/state/gawd-completions.env"
            # H4: pass the model path so the ceiling is sized from the model
            # footprint (model_bytes*1.3 + KV), not a flat RAM%. _write_mem_dropin
            # refuses the guard (returns 2) rather than ship a guaranteed kill-loop.
            _write_mem_dropin "gawd-completions.service" 26 22 "$_COMP_MODEL" || true
            if [[ -x "${GAWD_HOME}/scripts/gawd-port-owner.sh" ]]; then
              if ! GAWD_HOME="$GAWD_HOME" bash "${GAWD_HOME}/scripts/gawd-port-owner.sh" 11434 gawd-completions.service; then
                warn "    PORT CONFLICT on :11434 could not be auto-resolved (privilege?) — completions crashloop risk; resolve the system-scope conflict manually before relying on local completions"
              fi
            fi
            systemctl --user daemon-reload 2>/dev/null || true
            systemctl --user enable --now gawd-completions.service 2>/dev/null \
              && ok "    gawd-completions.service ENABLED (local completions model present; leak guard active)" \
              || warn "    gawd-completions.service enable returned non-zero (verify on substrate)"
          else
            cp "${_REL_UNITS_SRC}/gawd-completions.service" "${SYSTEMD_USER_DIR}/gawd-completions.service" 2>/dev/null || true
            ok "    completions: remote posture, local unit staged-disabled (no model under ${GAWD_HOME}/models)"
          fi

          # Port-owner preflight for the gateway port too (hardening 1).
          if [[ -x "${GAWD_HOME}/scripts/gawd-port-owner.sh" ]]; then
            if ! GAWD_HOME="$GAWD_HOME" bash "${GAWD_HOME}/scripts/gawd-port-owner.sh" "$GAWD_PORT" gawd.service; then
              warn "    PORT CONFLICT on :${GAWD_PORT} (gateway) could not be auto-resolved (privilege?) — gateway crashloop risk; resolve the system-scope conflict manually"
            fi
          fi

          systemctl --user daemon-reload 2>/dev/null || true
        else
          warn "    reliability unit templates source not found — gateway/embed/completions units NOT placed (deploy gap)"
        fi
      fi

      touch "${SUBSYS_STATE}/.reliability-activated"
      ok "  deployment-reliability hardening activated"
    else
      ok "  reliability hardening already activated — skipping."
    fi

    # ── inter-gawd (REQUIRED — fail-closed default) ───────────────────────────
    if [[ ! -f "${SUBSYS_STATE}/.inter-gawd-activated" ]]; then
      log "  Activating inter-gawd (fail-closed: empty peer registry)..."
      _HH="${SUBSYS_STATE}/household-gawds.json"
      if [[ ! -f "$_HH" ]]; then
        printf '%s\n' '{"peers":[]}' > "$_HH"
        chmod 0600 "$_HH"
      fi
      # GAWD_REQUIRE_AUTHENTICATED_SENDER=1 → header-parser inherits fail-closed.
      printf 'GAWD_REQUIRE_AUTHENTICATED_SENDER=1\n' > "${SUBSYS_STATE}/inter-gawd.env"
      chmod 0600 "${SUBSYS_STATE}/inter-gawd.env"
      touch "${SUBSYS_STATE}/.inter-gawd-activated"
      ok "  inter-gawd activated (empty peer registry rejects all peers; H4 dispatcher binding DEFERRED to v1.1)"
    else
      ok "  inter-gawd already activated — skipping."
    fi

    # ── tithing (REQUIRED) ────────────────────────────────────────────────────
    if [[ ! -f "${SUBSYS_STATE}/.tithing-activated" ]]; then
      log "  Activating tithing..."
      mkdir -p "${SUBSYS_STATE}/tithes/timers" \
        || fail "tithing: cannot create ledger dir" 3
      chmod 0700 "${SUBSYS_STATE}/tithes" \
        || fail "tithing: cannot chmod 0700 ledger dir" 3
      touch "${SUBSYS_STATE}/.tithing-activated"
      ok "  tithing activated (ledger dir ${SUBSYS_STATE}/tithes @ 0700; state-machine invoked by money-voice events at runtime)"
    else
      ok "  tithing already activated — skipping."
    fi

    # ── dashboard (REQUIRED — silence-is-worst-outcome recovery surface) ──────
    if [[ ! -f "${SUBSYS_STATE}/.dashboard-activated" ]]; then
      log "  Activating dashboard..."
      if [[ "$SUBSYS_NO_SYSTEMD" == "1" ]]; then
        GAWD_NO_SYSTEMD=1 GAWD_DASHBOARD_EXPOSURE=local \
          bash "${GAWD_LIB}/dashboard/install.sh" \
          || fail "dashboard activation failed (install.sh non-zero)" 3
      else
        GAWD_DASHBOARD_EXPOSURE=local \
          bash "${GAWD_LIB}/dashboard/install.sh" \
          || fail "dashboard activation failed (install.sh non-zero)" 3
      fi
      touch "${SUBSYS_STATE}/.dashboard-activated"
      ok "  dashboard activated (gateway-independent recovery surface on :8090)"
    else
      ok "  dashboard already activated — skipping."
    fi

    # ── voice (OPTIONAL — baked, NOT activated) ───────────────────────────────
    if [[ ! -f "${SUBSYS_STATE}/.voice-staged" ]]; then
      log "  Staging voice (DISABLED default; activated only on Prophit opt-in)..."
      if [[ "$SUBSYS_NO_SYSTEMD" != "1" ]]; then
        # VM/bare-metal rungs: place the unit file but DO NOT enable/start it.
        _VOICE_UNIT_DST="${HOME}/.config/systemd/user/voice-relay.service"
        mkdir -p "$(dirname "$_VOICE_UNIT_DST")"
        if [[ -f "${GAWD_LIB}/voice/systemd/voice-relay.service" ]]; then
          cp "${GAWD_LIB}/voice/systemd/voice-relay.service" "$_VOICE_UNIT_DST" \
            && ok "    voice-relay.service unit placed (NOT enabled)" \
            || warn "    voice unit copy failed (non-fatal)"
        fi
      else
        ok "    docker rung — voice left baked-disabled (no unit placement)"
      fi
      touch "${SUBSYS_STATE}/.voice-staged"
    else
      ok "  voice already staged — skipping."
    fi

    # ── weekly-service (subscribe baked + activated; publish DEFERRED) ────────
    if [[ ! -f "${SUBSYS_STATE}/.weekly-service-activated" ]]; then
      log "  Activating weekly-service (subscribe only; publish is Forge-side, DEFERRED)..."
      _WS_CRON="0 9 * * 0 bash ${GAWD_LIB}/weekly-service/subscribe-sermon.sh >> ${GAWD_HOME}/logs/weekly-service.log 2>&1"
      mkdir -p "${GAWD_HOME}/logs"
      if ! crontab -l 2>/dev/null | grep -qF "${GAWD_LIB}/weekly-service/subscribe-sermon.sh"; then
        ( crontab -l 2>/dev/null; printf '%s\n' "$_WS_CRON" ) | crontab - \
          || fail "weekly-service: failed to install subscribe cron" 3
        ok "    subscribe cron installed (Sunday 09:00)"
      else
        ok "    subscribe cron already present"
      fi
      touch "${SUBSYS_STATE}/.weekly-service-activated"
      ok "  weekly-service activated (subscribe cron; publish-sermon NOT wired)"
    else
      ok "  weekly-service already activated — skipping."
    fi

    # ── memory tiers / dreaming cron (REQUIRED for Q2/Q3 compliance) ──────────
    # Q3: OS-cron safe-dream.sh is the SINGLE dreaming owner. The built-in
    # memory-core scheduler is disabled in openclaw.json (dreaming.enabled=false).
    # Q2: dedicated cheap cloud model via GAWD_DREAM_MODEL env — never the main
    # gateway chain (prevents rate-limit cascade like the 2026-05-27 failure).
    #
    # Cron schedule: 0 3 * * * (3am daily). Matches the daemon's memory tier spec.
    # GAWD_DREAM_MODEL default: "minimax/MiniMax-M2.7" (cheap, fast, available).
    # Operators override via env at runtime; empty = stub mode (no real dreaming).
    # No API key in the cron line — model name only, key resolved from env at runtime.
    # Safe-dream.sh is placed at ${GAWD_HOME}/workspace/scripts/ by the image
    # build (forge/build/Dockerfile COPY forge/memory/ → /usr/local/lib/gawd/memory/).
    # install.sh stages it to the Gawd workspace scripts dir so the cron path is stable.
    if [[ ! -f "${SUBSYS_STATE}/.memory-tiers-activated" ]]; then
      log "  Activating memory tiers (Q2/Q3 dreaming cron)..."

      # Source safe-dream.sh from the baked image lib path.
      DREAM_SCRIPT_SRC="/usr/local/lib/gawd/memory/safe-dream.sh"
      DREAM_SCRIPT_DST="${GAWD_HOME}/workspace/scripts/safe-dream.sh"
      DREAM_LOG="${GAWD_HOME}/logs/gawd-dreaming.log"

      # Stage safe-dream.sh to the Gawd workspace scripts dir (idempotent).
      if [[ -f "$DREAM_SCRIPT_SRC" ]]; then
        mkdir -p "$(dirname "$DREAM_SCRIPT_DST")"
        cp "$DREAM_SCRIPT_SRC" "$DREAM_SCRIPT_DST"
        chmod 0755 "$DREAM_SCRIPT_DST"
        ok "    safe-dream.sh staged to ${DREAM_SCRIPT_DST}"
      else
        warn "    safe-dream.sh not found at ${DREAM_SCRIPT_SRC} (bake may be incomplete)"
      fi

      # Stage dream-verify.sh alongside safe-dream.sh (idempotent).
      # dream-verify.sh is the day-narrative fail-loud guard (per Metatron
      # handoff 2026-06-02). It is a tail call from safe-dream.sh so no new
      # cron entry is needed; the engine path default is the baked image path
      # /usr/local/lib/gawd/silence-avoidance/engine.sh.
      DREAM_VERIFY_SRC="/usr/local/lib/gawd/memory/dream-verify.sh"
      DREAM_VERIFY_DST="${GAWD_HOME}/workspace/scripts/dream-verify.sh"
      if [[ "$SUBSYS_NO_SYSTEMD" == "1" ]]; then
        # Docker rung: stage from baked lib path.
        if [[ -f "$DREAM_VERIFY_SRC" ]]; then
          cp "$DREAM_VERIFY_SRC" "$DREAM_VERIFY_DST"
          chmod 0755 "$DREAM_VERIFY_DST"
          ok "    dream-verify.sh staged to ${DREAM_VERIFY_DST} (docker rung)"
        else
          warn "    dream-verify.sh not found at ${DREAM_VERIFY_SRC} (bake may be incomplete)"
        fi
      else
        # Bare-metal / VM rung: stage from baked lib path if available,
        # otherwise record deferred (guard is non-fatal so this is safe).
        if [[ -f "$DREAM_VERIFY_SRC" ]]; then
          mkdir -p "$(dirname "$DREAM_VERIFY_DST")"
          cp "$DREAM_VERIFY_SRC" "$DREAM_VERIFY_DST"
          chmod 0755 "$DREAM_VERIFY_DST"
          ok "    dream-verify.sh staged to ${DREAM_VERIFY_DST} (bare-metal rung)"
        else
          warn "    dream-verify.sh not found at ${DREAM_VERIFY_SRC} (non-fatal; guard will be absent until image rebuilt)"
        fi
      fi

      # Install the dreaming cron: 0 3 * * * (3am daily, Q3 single owner).
      # GAWD_DREAM_MODEL=minimax/MiniMax-M2.7: default cheap cloud model (Q2).
      # Operator overrides GAWD_DREAM_MODEL in their shell env or ~/.gawd/state/.
      mkdir -p "${GAWD_HOME}/logs"
      _DREAM_CRON="0 3 * * * GAWD_DREAM_MODEL=\${GAWD_DREAM_MODEL:-minimax/MiniMax-M2.7} bash ${DREAM_SCRIPT_DST} >> ${DREAM_LOG} 2>&1"
      if [[ "$SUBSYS_NO_SYSTEMD" == "1" ]]; then
        # Docker rung: cron is not available (non-root user; vixie cron won't run).
        # The entrypoint handles dreaming init on first boot instead.
        # Record the cron line to a state file so entrypoint.sh can install it
        # into the docker cron mechanism on first-boot if one is available.
        printf '%s\n' "$_DREAM_CRON" > "${SUBSYS_STATE}/dream-cron.txt"
        ok "    docker rung — dream cron deferred to entrypoint first-boot (recorded at ${SUBSYS_STATE}/dream-cron.txt)"
      else
        if ! crontab -l 2>/dev/null | grep -qF "safe-dream.sh"; then
          ( crontab -l 2>/dev/null; printf '%s\n' "$_DREAM_CRON" ) | crontab - \
            || warn "  failed to install dreaming cron (non-fatal; set manually: ${_DREAM_CRON})"
          ok "    dreaming cron installed (0 3 * * * safe-dream.sh; Q3 single owner)"
        else
          ok "    dreaming cron already present"
        fi
      fi

      touch "${SUBSYS_STATE}/.memory-tiers-activated"
      ok "  memory tiers activated (dreaming cron 0 3 * * *; built-in scheduler OFF via openclaw.json)"
    else
      ok "  memory tiers already activated — skipping."
    fi

    ok "Step 5d complete — v1 subsystems activated."
    ;;

  hosted|prophit-vm)
    # Docker rung — pull the image. Per spec §4.2: GAWD_IMAGE_TAG is the Forge-set
    # tag; install.sh reads it from an env var with sensible default.
    if ! command -v docker &>/dev/null; then
      fail "Docker is required for the ${RUNG} rung but was not found. Install Docker then re-run." 2
    fi

    if docker image inspect "$GAWD_IMAGE" &>/dev/null 2>&1; then
      ok "  Image ${GAWD_IMAGE} already present — skipping pull."
    else
      log "  Pulling ${GAWD_IMAGE}..."
      docker pull "$GAWD_IMAGE" \
        || fail "Failed to pull Docker image ${GAWD_IMAGE}. Check your internet connection and image tag." 2
      ok "  Pulled ${GAWD_IMAGE}"
    fi

    # Surface per-rung resource limits for the Prophit's awareness (spec §14.2.5).
    if [[ "$RUNG" == "prophit-vm" ]]; then
      log ""
      log "  Resource guidance for the Prophit-VM rung (spec §14.2.5):"
      log "    Minimum RAM:     4 GB"
      log "    Recommended RAM: 8 GB"
      log "    The daemon container exposes gateway on 127.0.0.1:${GAWD_PORT} only."
      log "    Text-only mode (no desktop) reduces RAM to ~1.5 GB if needed."
      log ""
    fi
    ;;

  bare-metal)
    # Bare-metal rung — unpack tarball into /opt/gawd/.
    # Per spec context note: the unit file ships in the tarball (F2 produces it).
    TARBALL=""
    # Look for a gawd-daemon-*.tar.gz alongside this script first, then cwd.
    for candidate in \
      "${SCRIPT_DIR}"/gawd-daemon-*.tar.gz \
      "$(pwd)"/gawd-daemon-*.tar.gz
    do
      if [[ -f "$candidate" ]]; then
        TARBALL="$candidate"
        break
      fi
    done

    if [[ -z "$TARBALL" ]]; then
      fail "Bare-metal rung requires a gawd-daemon-{version}.tar.gz tarball in the same directory as install.sh. None found." 2
    fi

    log "  Unpacking ${TARBALL} → ${GAWD_INSTALL_DIR}..."

    if [[ "$(id -u)" -eq 0 ]]; then
      SUDO_MAYBE=""
    else
      SUDO_MAYBE="sudo"
      # LOW-3 sudo notice (phase4-20260609): this script will use sudo to write to ${GAWD_INSTALL_DIR}.
      log "  Note: this step requires sudo to install Gawd to ${GAWD_INSTALL_DIR}."
    fi

    $SUDO_MAYBE mkdir -p "$GAWD_INSTALL_DIR"
    $SUDO_MAYBE tar -xzf "$TARBALL" -C "$GAWD_INSTALL_DIR" --strip-components=1
    ok "  Unpacked to ${GAWD_INSTALL_DIR}"

    # Install the systemd unit that shipped in the tarball, if present.
    # The tarball ships the canonical reliability units under ${GAWD_INSTALL_DIR}/systemd/
    # (bare-metal-tarball.sh). Older tarballs may have placed gawd.service at the root.
    UNIT_FILE=""
    for c in "${GAWD_INSTALL_DIR}/systemd/gawd.service" "${GAWD_INSTALL_DIR}/gawd.service"; do
      [[ -f "$c" ]] && { UNIT_FILE="$c"; break; }
    done
    if [[ -n "$UNIT_FILE" ]] && command -v systemctl &>/dev/null; then
      SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
      mkdir -p "$SYSTEMD_USER_DIR"

      # Stage reliability helper scripts (clean-state, port-owner, health-gate,
      # failure-alert, safe-mutate) so the unit ExecStartPre / OnFailure paths resolve.
      GAWD_HOME="${HOME}/.gawd"
      mkdir -p "${GAWD_HOME}/scripts" "${GAWD_HOME}/logs" "${GAWD_HOME}/state"
      if [[ -d "${GAWD_INSTALL_DIR}/scripts" ]]; then
        for s in gawd-port-owner.sh gawd-failure-alert.sh gawd-health-gate.sh \
                 gawd-clean-state.sh gawd-safe-mutate.sh; do
          [[ -f "${GAWD_INSTALL_DIR}/scripts/${s}" ]] && \
            install -m 0755 "${GAWD_INSTALL_DIR}/scripts/${s}" "${GAWD_HOME}/scripts/${s}"
        done
      fi

      # Place the gateway + failure-alert template + (staged-disabled) llama units.
      cp "$UNIT_FILE" "${SYSTEMD_USER_DIR}/gawd.service"
      for u in gawd-failure-alert@.service gawd-embed.service gawd-completions.service; do
        [[ -f "${GAWD_INSTALL_DIR}/systemd/${u}" ]] && cp "${GAWD_INSTALL_DIR}/systemd/${u}" "${SYSTEMD_USER_DIR}/${u}"
      done

      # D3 RAM-envelope drop-in for the gateway, computed from /proc/meminfo.
      _mt_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
      _gw_max=7; _gw_high=5
      if [[ "${_mt_kb:-0}" -gt 0 ]]; then
        _p60=$(( _mt_kb * 60 / 100 / 1048576 )); _p45=$(( _mt_kb * 45 / 100 / 1048576 ))
        [[ "$_p60" -lt 1 ]] && _p60=1; [[ "$_p45" -lt 1 ]] && _p45=1
        _gw_max=$(( _p60 < 7 ? _p60 : 7 )); _gw_high=$(( _p45 < 5 ? _p45 : 5 ))
      fi
      mkdir -p "${SYSTEMD_USER_DIR}/gawd.service.d"
      printf '[Service]\nMemoryMax=%sG\nMemoryHigh=%sG\n' "$_gw_max" "$_gw_high" \
        > "${SYSTEMD_USER_DIR}/gawd.service.d/memory.conf"

      # one-unit-per-service preflight (hardening 1) before enabling the gateway.
      [[ -x "${GAWD_HOME}/scripts/gawd-port-owner.sh" ]] && \
        GAWD_HOME="$GAWD_HOME" bash "${GAWD_HOME}/scripts/gawd-port-owner.sh" "$GAWD_PORT" gawd.service || true

      systemctl --user daemon-reload
      systemctl --user enable gawd
      ok "  Installed systemd user unit: gawd.service (+ reliability units, ceilings, port-owner)"
      ok "  Local llama-server units staged disabled; enable when a model is placed under ${GAWD_HOME}/models"
    fi
    ;;
esac

# ── step 6: start daemon (per spec §4.2 step 6) ───────────────────────────────

log "Step 6/7 — Starting Gawd gateway on 127.0.0.1:${GAWD_PORT}..."

# Verify port is free or daemon already running.
health_check() {
  curl -sf "http://127.0.0.1:${GAWD_PORT}/health" &>/dev/null
}

if health_check; then
  ok "  Daemon already running on port ${GAWD_PORT} — skipping start."
else
  case "$RUNG" in
    docker)
      # Inside a container: the gateway is the container CMD (openclaw gateway).
      # Two sub-cases:
      #   (a) Non-interactive / entrypoint mode: install.sh runs BEFORE the gateway
      #       starts (entrypoint.sh calls us, then exec's the gateway CMD).
      #       In this case we must NOT wait — we'd deadlock. Just provision state
      #       and return; the gateway starts after we exit.
      #   (b) Interactive mode (user runs install.sh inside an already-running
      #       container, e.g. during onboarding). The gateway should already be up;
      #       wait up to 30s as before.
      if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        ok "  Docker container rung (non-interactive): state provisioned. Gateway will start after install.sh exits."
      else
        log "  Docker container rung: waiting for gateway started by container CMD..."
        TRIES=0
        until health_check || [[ $TRIES -ge 30 ]]; do
          sleep 1
          (( TRIES++ )) || true
        done
        if ! health_check; then
          warn "Gateway did not respond within 30 seconds inside container."
          warn "The container CMD may still be starting. Proceeding — onboarding will retry."
        else
          ok "  Gateway healthy on 127.0.0.1:${GAWD_PORT}"
        fi
      fi
      ;;

    hosted|prophit-vm)
      # Check if a container is already running with this port binding.
      RUNNING_CONTAINER="$(docker ps --filter "publish=${GAWD_PORT}" --format '{{.Names}}' 2>/dev/null | head -1)"
      if [[ -n "$RUNNING_CONTAINER" ]]; then
        ok "  Container ${RUNNING_CONTAINER} already bound to port ${GAWD_PORT} — skipping."
      else
        # Start the container. Name is deterministic for idempotent management.
        # Gateway runs on loopback only inside the container (per GOSPEL-TOPOLOGY §8.1).
        docker run -d \
          --name gawd-daemon \
          --restart unless-stopped \
          -p "127.0.0.1:${GAWD_PORT}:${GAWD_PORT}" \
          -v "${GAWD_WORKSPACE}:/home/gawd/.gawd" \
          -e GAWD_PORT="${GAWD_PORT}" \
          "$GAWD_IMAGE" \
          || fail "docker run failed. See docker logs for details." 3

        # Wait up to 30 seconds for the gateway to respond.
        log "  Waiting for gateway..."
        TRIES=0
        until health_check || [[ $TRIES -ge 30 ]]; do
          sleep 1
          (( TRIES++ )) || true
        done
        if ! health_check; then
          warn "Gateway did not respond within 30 seconds."
          warn "Check: docker logs gawd-daemon"
          exit 3
        fi
      fi
      ;;

    bare-metal)
      if command -v systemctl &>/dev/null && systemctl --user is-enabled gawd &>/dev/null; then
        systemctl --user start gawd
        TRIES=0
        until health_check || [[ $TRIES -ge 30 ]]; do
          sleep 1
          (( TRIES++ )) || true
        done
        if ! health_check; then
          warn "Gateway did not respond within 30 seconds."
          warn "Check: systemctl --user status gawd && journalctl --user -u gawd"
          exit 3
        fi
      else
        # No systemd unit; launch directly via nohup (matches GOSPEL-WORKFLOWS §4.5 pattern).
        command -v node &>/dev/null || fail "node not found — the bare-metal rung requires Node.js. Install it then re-run." 2
        GATEWAY_LOG="${HOME}/gawd-gateway.log"
        nohup node "${GAWD_INSTALL_DIR}/dist/index.js" gateway --port "$GAWD_PORT" \
          >"$GATEWAY_LOG" 2>&1 &
        log "  Gateway launched (bare-metal, nohup). Log: ${GATEWAY_LOG}"
        TRIES=0
        until health_check || [[ $TRIES -ge 30 ]]; do
          sleep 1
          (( TRIES++ )) || true
        done
        if ! health_check; then
          warn "Gateway did not respond within 30 seconds."
          warn "Check: ${GATEWAY_LOG}"
          exit 3
        fi
      fi
      ;;
  esac

  ok "  Gateway healthy on 127.0.0.1:${GAWD_PORT}"
fi

# ── step 7: launch onboarding wizard (per spec §4.2 step 7; §4 state machine) ─

log "Step 7/7 — Launching onboarding wizard..."

if [[ "${SKIP_WIZARD:-0}" == "1" ]]; then
  warn "  --skip-wizard set. Skipping onboarding launch (test/CI mode only)."
  # Fall through to print the post-install guidance before exiting.
fi

# ── Post-install guidance ─────────────────────────────────────────────────────
#
# Print clear next steps for the Prophit: set their secrets, point a provider,
# then start the daemon. This is the 5-minute bar: 2-3 secrets → daemon up →
# Gawd present over Telegram.
#
# Nothing here contains real secrets or personal data (no PII per the spec).

printf '\n'
printf '\033[1;32m[gawd]\033[0m ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '\033[1;32m[gawd]\033[0m  Installation complete.\n'
printf '\033[1;32m[gawd]\033[0m ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '\n'
printf '  The secrets helper is now at ~/.local/bin/secrets.\n'
printf '\n'
printf '  ── Required: Telegram bot token ────────────────────────────────────\n'
printf '\n'
printf '  Gawd needs a bot token to talk to you on Telegram:\n'
printf '\n'
printf '        secrets set TELEGRAM_BOT_TOKEN\n'
printf '        # Paste the token — it will not echo.\n'
printf '        # Get this from @BotFather on Telegram (/newbot or /mybots).\n'
printf '\n'
# Show provider-specific next steps based on the hint file written in step 4.7.
_HINT_FILE="${HOME}/.gawd/.provider-hint"
if [[ -f "$_HINT_FILE" ]]; then
  _HINT_PROVIDER="$(grep '^GAWD_SELECTED_PROVIDER=' "$_HINT_FILE" | cut -d= -f2-)"
  _HINT_KEY_ENV="$(grep '^GAWD_PROVIDER_KEY_ENV=' "$_HINT_FILE" | cut -d= -f2-)"
  _HINT_MODEL="$(grep '^GAWD_PROVIDER_MODEL=' "$_HINT_FILE" | cut -d= -f2-)"
  _HINT_BASE_URL="$(grep '^GAWD_PROVIDER_BASE_URL=' "$_HINT_FILE" | cut -d= -f2-)"
  _HINT_API_TYPE="$(grep '^GAWD_PROVIDER_API_TYPE=' "$_HINT_FILE" | cut -d= -f2-)"
  if [[ -n "$_HINT_PROVIDER" ]]; then
    printf '  ── Provider key / config ────────────────────────────────────────────\n'
    printf '\n'
    if [[ "$_HINT_PROVIDER" == "ollama" ]]; then
      printf '  Ollama (local) — no API key needed.\n'
      printf '  Make sure Ollama is running and a model is pulled:\n'
      printf '\n'
      printf '        ollama pull qwen3:8b   # or your preferred model\n'
      printf '        ollama serve           # if not already running\n'
      printf '\n'
    else
      # Key-based provider: check whether key was already set in step 4.7.
      if [[ "$_VAULT_READY_HINT" != "0" ]] 2>/dev/null; then
        if [[ -x "$SECRETS_HELPER" ]] && "$SECRETS_HELPER" get "$_HINT_KEY_ENV" &>/dev/null 2>&1; then
          ok "  ${_HINT_KEY_ENV} is already stored in the vault (set in step 4.7)."
        else
          printf '  Your %s provider key was not yet set (or vault not ready).\n' "$_HINT_PROVIDER"
          printf '  Set it now:\n'
          printf '\n'
          printf '        secrets set %s\n' "$_HINT_KEY_ENV"
          printf '\n'
        fi
      fi
    fi
    printf '  ── openclaw.json provider block ────────────────────────────────────\n'
    printf '\n'
    printf '  Open ~/.openclaw/openclaw.json and set the models block:\n'
    printf '\n'
    if [[ "$_HINT_PROVIDER" == "ollama" ]]; then
      printf '    "models": {\n'
      printf '      "providers": {\n'
      printf '        "ollama": {\n'
      printf '          "baseUrl": "%s",\n' "$_HINT_BASE_URL"
      printf '          "api": "openai-chat-completions"\n'
      printf '        }\n'
      printf '      },\n'
      printf '      "primary": "ollama/qwen3:8b"\n'
      printf '    }\n'
    else
      printf '    "models": {\n'
      printf '      "providers": {\n'
      printf '        "%s": {\n' "$_HINT_PROVIDER"
      printf '          "baseUrl": "%s",\n' "$_HINT_BASE_URL"
      printf '          "api": "%s",\n' "$_HINT_API_TYPE"
      printf '          "apiKey": "${%s}"\n' "$_HINT_KEY_ENV"
      printf '        }\n'
      printf '      },\n'
      printf '      "primary": "%s"\n' "$_HINT_MODEL"
      printf '    }\n'
    fi
    printf '\n'
  fi
  unset _HINT_PROVIDER _HINT_KEY_ENV _HINT_MODEL _HINT_BASE_URL _HINT_API_TYPE
else
  # No hint file — provider step was skipped (non-interactive / curl|bash).
  printf '  ── LLM provider key ────────────────────────────────────────────────\n'
  printf '\n'
  printf '  Set your provider API key (choose one):\n'
  printf '\n'
  printf '        secrets set MINIMAX_API_KEY          # MiniMax — recommended default\n'
  printf '        secrets set ANTHROPIC_API_KEY        # Anthropic (requires API credits;\n'
  printf '                                             #   Claude.ai subscription login is NOT an API key)\n'
  printf '        secrets set DEEPSEEK_API_KEY         # DeepSeek\n'
  printf '        secrets set OPENAI_API_KEY           # OpenAI\n'
  printf '\n'
  printf '  For Ollama (local, no key): set OLLAMA_ENDPOINT in ~/.openclaw/openclaw.json.\n'
  printf '\n'
  printf '  Then update ~/.openclaw/openclaw.json (models.providers block).\n'
  printf '  See the README for provider-specific examples.\n'
  printf '\n'
fi
unset _HINT_FILE
printf '\n'
printf '  ── Starting the daemon ──────────────────────────────────────────────\n'
printf '\n'
if command -v systemctl &>/dev/null && systemctl --user is-enabled gawd &>/dev/null 2>&1; then
  printf '    systemctl --user start gawd\n'
  printf '    systemctl --user status gawd\n'
elif command -v docker &>/dev/null; then
  printf '    docker start gawd-daemon      # if already created\n'
  printf '    # or: docker run ... (see the README for your rung)\n'
else
  printf '    # Start the gateway directly:\n'
  printf '    nohup node /opt/gawd/dist/index.js gateway --port 18789 > ~/gawd-gateway.log 2>&1 &\n'
fi
printf '\n'
printf '  ── Verify Gawd is alive ─────────────────────────────────────────────\n'
printf '\n'
printf '    curl http://127.0.0.1:18789/health   # → {"ok":true}\n'
printf '\n'
printf '  ── Then message your bot on Telegram ────────────────────────────────\n'
printf '\n'
printf '    Message the bot you created with @BotFather. Gawd should reply.\n'
printf '\n'
if [[ "${SKIP_WIZARD:-0}" == "1" ]]; then
  exit 0
fi

if [[ ! -x "$ONBOARD_BIN" ]]; then
  # Guided wizard not present in this release (see STATUS.md roadmap) — the
  # printed instructions above are the v1 onboarding path. Silent skip:
  # installation itself succeeded; wizard absence is not an install error.
  exit 0
fi

exec "$ONBOARD_BIN"
} # end __gawd_main
__gawd_main "$@"
