#!/usr/bin/env bash
# engine.sh — Silence-avoidance Layer 6 entrypoint.
#
# Constitutional rule (spec §19.1):
#   The Prophit MUST NEVER experience silence. If Gawd cannot deliver a
#   model-generated reply within the silence-threshold window (default 30s),
#   the daemon delivers a STATIC FALLBACK MESSAGE in Gawd's voice via the
#   active surface.
#
# This engine is the enforcement mechanism. It runs without any LLM,
# without the OpenClaw gateway, without the Telegram MCP plugin, and
# without the embedding server. Bash + curl + jq + the template files.
#
# Invocation:
#   engine.sh terminal-error  --channel <ch> --prophit <id> [--reason <r>] [--dry-run]
#   engine.sh stuck-state     --channel <ch> --prophit <id> [--dry-run]
#   engine.sh recovered       --channel <ch> --prophit <id> [--dry-run]
#   engine.sh extended        --channel <ch> --prophit <id> [--dry-run]
#   engine.sh preflight                                                 # template check
#   engine.sh reset-window    --channel <ch> --prophit <id>            # on successful reply
#
# Exit codes:
#   0   delivered (or dry-run rendered)
#   10  suppressed (silence-window active for this Prophit+channel)
#   20  template missing (engine cannot fall back to no-op; emits error log)
#   30  delivery failed (channel layer returned non-zero)
#   31  delivery script MISSING (deploy bug) — last-resort attempted (§19-H5)
#   40  invalid invocation / missing required arg
#
# Sourced libs:
#   /usr/local/lib/gawd/observability/logger.sh    (structured logging)
#
# Spec refs:
#   §19.1 constitutional rule
#   §19.2 Layer 6
#   §19.3.2 infrastructure-separation principle (engine runs independently of LLM chain)
#   §19.5 template contract + per-channel routing
#   §19.6 failure-mode taxonomy
#   §19.7 Phase 11 chaos test #1

set -euo pipefail

# ── paths & configuration ──────────────────────────────────────────────────────

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK_DIR="${GAWD_FALLBACK_DIR:-${HOME}/.gawd/fallbacks/templates}"
STATE_DIR="${GAWD_FALLBACK_STATE_DIR:-${HOME}/.gawd/fallbacks/state}"
STATE_FILE="${STATE_DIR}/silence-window.json"
CONFIG_FILE="${GAWD_FALLBACK_CONFIG:-${HOME}/.gawd/fallbacks/config.json}"
MEMORY_MARKER_FILE="${GAWD_FALLBACK_MEMORY_MARKER:-${HOME}/.gawd/memory/fallback-markers.log}"

# Per-channel default window (seconds). Configurable via config.json.
# Minimum enforced at 10s (prevents spam — spec acceptance criteria).
DEFAULT_WINDOW_SEC=30
MIN_WINDOW_SEC=10

# ── observability ──────────────────────────────────────────────────────────────

# Source the structured logger if present; fall back to stderr line if not.
if [[ -f /usr/local/lib/gawd/observability/logger.sh ]]; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source /usr/local/lib/gawd/observability/logger.sh
else
    log_info()  { printf '[fallback-engine] [info]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_warn()  { printf '[fallback-engine] [warn]  %s: %s\n'  "${1:-}" "${*:2}" >&2; }
    log_error() { printf '[fallback-engine] [error] %s: %s\n'  "${1:-}" "${*:2}" >&2; }
fi

LOG_SRC="fallback-engine"

# ── helpers ────────────────────────────────────────────────────────────────────

die() {
    log_error "$LOG_SRC" "$*"
    exit 40
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

now_epoch() { date +%s; }

# Format Prophit-local time as a short string (e.g., "14:23 CDT").
# Reads tz from config; defaults to system tz.
prophit_local_time() {
    local tz t
    tz="$(get_config "prophit_timezone" "")"
    if [[ -n "$tz" ]]; then
        t="$(TZ="$tz" date +"%H:%M %Z" 2>/dev/null)"
    else
        t="$(date +"%H:%M %Z" 2>/dev/null)"
    fi
    printf '%s' "${t:-earlier}"
}

# get_config <key> <default>
# Reads top-level keys from config.json. Returns default if file or key missing.
get_config() {
    local key="$1" default="$2"
    [[ -f "$CONFIG_FILE" ]] || { printf '%s' "$default"; return 0; }
    local val
    val="$(jq -r --arg k "$key" '.[$k] // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -z "$val" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$val"
    fi
}

# get_window_for_channel <channel>
# Returns the effective silence-window in seconds for the given channel.
# Reads .windows.<channel>; falls back to .windows.default; falls back to DEFAULT_WINDOW_SEC.
# Enforces MIN_WINDOW_SEC floor.
get_window_for_channel() {
    local channel="$1"
    local val=""
    if [[ -f "$CONFIG_FILE" ]]; then
        val="$(jq -r --arg c "$channel" '
            (.windows[$c] // .windows.default // empty) | tostring
        ' "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "$val" || "$val" == "null" || "$val" == "empty" ]]; then
        val="$DEFAULT_WINDOW_SEC"
    fi
    # Enforce floor.
    if (( val < MIN_WINDOW_SEC )); then
        val=$MIN_WINDOW_SEC
    fi
    printf '%s' "$val"
}

# get_address_name <prophit_id>
# Reads .prophits.<id>.address_name from config; default "friend".
get_address_name() {
    local pid="$1"
    local name=""
    if [[ -f "$CONFIG_FILE" ]]; then
        name="$(jq -r --arg p "$pid" '.prophits[$p].address_name // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "$name" || "$name" == "null" ]]; then
        name="friend"
    fi
    printf '%s' "$name"
}

# ── state management (atomic) ──────────────────────────────────────────────────

# state_ensure
# Creates the state directory + empty state file if missing.
state_ensure() {
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"
    if [[ ! -f "$STATE_FILE" ]]; then
        printf '{"channels":{}}\n' > "$STATE_FILE"
        chmod 0600 "$STATE_FILE"
    fi
}

# state_last_fallback_at <channel> <prophit_id>
# Returns epoch seconds of last fallback for this (channel,prophit) pair, or 0.
state_last_fallback_at() {
    local channel="$1" pid="$2"
    state_ensure
    jq -r --arg c "$channel" --arg p "$pid" '
        .channels[$c][$p].last_fallback_at // 0
    ' "$STATE_FILE" 2>/dev/null || printf '0'
}

# state_record_fallback <channel> <prophit_id> <event_type>
# Atomic write: read, mutate, write to tmp, rename.
state_record_fallback() {
    local channel="$1" pid="$2" event="$3"
    state_ensure
    local tmp
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    jq --arg c "$channel" --arg p "$pid" --arg ev "$event" --arg ts "$(now_epoch)" '
        .channels[$c][$p].last_fallback_at = ($ts | tonumber) |
        .channels[$c][$p].last_event = $ev
    ' "$STATE_FILE" > "$tmp"
    # Sanity: tmp must be valid JSON before we rename.
    jq -e . "$tmp" >/dev/null 2>&1 || {
        rm -f "$tmp"
        die "state write produced invalid JSON; refusing to corrupt state"
    }
    chmod 0600 "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# state_reset_channel <channel> <prophit_id>
# Called on a successful model reply; clears this (channel,prophit) entry.
state_reset_channel() {
    local channel="$1" pid="$2"
    state_ensure
    local tmp
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    jq --arg c "$channel" --arg p "$pid" '
        if .channels[$c][$p] then
            del(.channels[$c][$p])
        else
            .
        end
    ' "$STATE_FILE" > "$tmp"
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "state reset produced invalid JSON"; }
    chmod 0600 "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# state_in_window <channel> <prophit_id>
# Returns 0 (true) if a fallback was sent within the window for this pair.
# Returns 1 (false) otherwise.
state_in_window() {
    local channel="$1" pid="$2"
    local last window now diff
    last="$(state_last_fallback_at "$channel" "$pid")"
    window="$(get_window_for_channel "$channel")"
    now="$(now_epoch)"
    if [[ "$last" == "0" || -z "$last" ]]; then
        return 1
    fi
    diff=$((now - last))
    if (( diff < window )); then
        return 0
    fi
    return 1
}

# ── preflight ──────────────────────────────────────────────────────────────────

# Required templates per §19.5 + G3 handoff.
REQUIRED_TEMPLATES=(
    "telegram-degraded.md"
    "telegram-extended-degraded.md"
    "telegram-recovered.md"
    "dashboard-degraded.html"
    "dashboard-extended-degraded.html"
    "dashboard-recovered.html"
    "desktop-degraded.txt"
    "desktop-recovered.txt"
    "voice-degraded.txt"
    "voice-recovered.txt"
)

# Delivery scripts that MUST be present + executable (§19-H6).
REQUIRED_DELIVER_SCRIPTS=(
    "telegram.sh"
    "dashboard.sh"
    "desktop.sh"
    "voice.sh"
)

cmd_preflight() {
    local missing=0
    log_info "$LOG_SRC" "preflight: checking templates in $FALLBACK_DIR"
    if [[ ! -d "$FALLBACK_DIR" ]]; then
        log_error "$LOG_SRC" "preflight FAIL: fallback template directory missing: $FALLBACK_DIR"
        return 20
    fi
    local t
    for t in "${REQUIRED_TEMPLATES[@]}"; do
        if [[ ! -s "$FALLBACK_DIR/$t" ]]; then
            log_error "$LOG_SRC" "preflight FAIL: missing or empty template: $t"
            missing=$((missing + 1))
        fi
    done
    if (( missing > 0 )); then
        log_error "$LOG_SRC" "preflight FAIL: $missing template(s) missing — daemon must not start"
        return 20
    fi
    # Sanity: Telegram primary <280 chars per spec §19.5
    local tg_len
    tg_len="$(wc -c < "$FALLBACK_DIR/telegram-degraded.md" || echo 0)"
    if (( tg_len > 280 )); then
        log_warn "$LOG_SRC" "preflight WARN: telegram-degraded.md is ${tg_len} bytes — spec §19.5 says <280"
    fi

    # ── §19-H6: the delivery surface must actually be able to work ───────────
    # (a) all 4 deliver/*.sh present + executable.
    local d
    for d in "${REQUIRED_DELIVER_SCRIPTS[@]}"; do
        if [[ ! -x "$ENGINE_DIR/deliver/$d" ]]; then
            log_error "$LOG_SRC" "preflight FAIL: delivery script missing or not executable: deliver/$d"
            missing=$((missing + 1))
        fi
    done
    if (( missing > 0 )); then
        log_error "$LOG_SRC" "preflight FAIL: $missing delivery script(s) unusable — daemon must not start"
        return 20
    fi

    # (b) config.json must be valid JSON (a malformed config silently breaks
    #     chat_id/window resolution at the worst possible moment).
    if [[ -f "$CONFIG_FILE" ]]; then
        if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
            log_error "$LOG_SRC" "preflight FAIL: config.json is not valid JSON: $CONFIG_FILE"
            return 20
        fi
    else
        log_warn "$LOG_SRC" "preflight WARN: config.json absent: $CONFIG_FILE (defaults will be used)"
    fi

    # (c) for the configured primary channel + Prophit, confirm the delivery
    #     surface is provisioned. For telegram (the constitutional primary
    #     surface), that means: chat_id resolves AND the token file exists and is
    #     non-empty. EXISTENCE ONLY — never read/log/echo the token value.
    local primary_channel primary_prophit
    primary_channel="${GAWD_PRIMARY_CHANNEL:-$(get_config "primary_channel" "telegram")}"
    primary_prophit="${GAWD_PROPHIT_ID:-$(get_config "primary_prophit" "")}"

    if [[ "$primary_channel" == "telegram" && -n "$primary_prophit" && "$primary_prophit" != "default" ]]; then
        local cid token_file
        cid=""
        if [[ -f "$CONFIG_FILE" ]]; then
            cid="$(jq -r --arg p "$primary_prophit" '.prophits[$p].telegram_chat_id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
        fi
        if [[ -z "$cid" || "$cid" == "null" ]]; then
            log_error "$LOG_SRC" "preflight FAIL: no telegram_chat_id for primary prophit=$primary_prophit — primary surface cannot deliver"
            return 20
        fi
        token_file="${GAWD_TELEGRAM_TOKEN_FILE:-${HOME}/.gawd/.secrets/telegram.token}"
        # Existence + non-empty only. Do NOT read the contents into any variable
        # that could be logged. `-s` tests size>0 without revealing the value.
        if [[ ! -s "$token_file" ]]; then
            log_error "$LOG_SRC" "preflight FAIL: telegram token file missing or empty (path elided) — primary surface cannot deliver"
            return 20
        fi
        log_info "$LOG_SRC" "preflight OK: primary surface telegram provisioned (chat_id resolved, token present)"
    else
        log_info "$LOG_SRC" "preflight: primary channel='${primary_channel}' prophit='${primary_prophit:-unset}' — skipping telegram-specific provisioning check"
    fi

    log_info "$LOG_SRC" "preflight OK: ${#REQUIRED_TEMPLATES[@]} templates + ${#REQUIRED_DELIVER_SCRIPTS[@]} delivery scripts present"
    return 0
}

# ── last-resort + secondary delivery (§19-H4/H5) ────────────────────────────────

# last_resort_telegram <prophit_id> <rendered_message>
# §19-H5: invoked when the normal deliver/<channel>.sh script is MISSING (a
# deploy bug). Bypasses all delivery scripts and hits the Telegram Bot API with
# a direct curl, reading the token from the file location deliver/telegram.sh
# uses. NEVER echoes/logs the token. Returns 0 on ok:true, 1 otherwise.
last_resort_telegram() {
    local pid="$1" msg="$2"
    local token_file="${GAWD_TELEGRAM_TOKEN_FILE:-${HOME}/.gawd/.secrets/telegram.token}"
    local chat_id="" tok=""

    [[ -f "$CONFIG_FILE" ]] || { log_error "$LOG_SRC" "last-resort: no config.json — cannot resolve chat_id"; return 1; }
    chat_id="$(jq -r --arg p "$pid" '.prophits[$p].telegram_chat_id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$chat_id" && "$chat_id" != "null" ]] || { log_error "$LOG_SRC" "last-resort: no telegram_chat_id for prophit=$pid"; return 1; }

    [[ -r "$token_file" ]] || { log_error "$LOG_SRC" "last-resort: token file unreadable (path elided)"; return 1; }
    tok="$(< "$token_file")"; tok="${tok%$'\n'}"; tok="${tok// /}"
    [[ -n "$tok" ]] || { log_error "$LOG_SRC" "last-resort: token file empty"; return 1; }

    local payload resp ok
    payload="$(jq -nc --arg cid "$chat_id" --arg txt "$msg" \
        '{chat_id: ($cid | tonumber? // $cid), text: $txt, disable_web_page_preview: true}')"
    resp="$(curl -sS --max-time 10 --connect-timeout 5 \
        -H 'Content-Type: application/json' -X POST \
        --data "$payload" \
        "https://api.telegram.org/bot${tok}/sendMessage" 2>&1)" || {
        unset tok
        log_error "$LOG_SRC" "last-resort: curl to api.telegram.org failed (transport)"
        return 1
    }
    unset tok
    ok="$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null || printf 'false')"
    [[ "$ok" == "true" ]] || { log_error "$LOG_SRC" "last-resort: Bot API did not return ok:true"; return 1; }
    log_info "$LOG_SRC" "last-resort direct-curl delivery succeeded prophit=$pid"
    return 0
}

# try_secondary_surface <prophit_id> <rendered_message> <primary_channel>
# §19-H4: when primary-channel delivery fails, attempt ONE configured secondary
# surface before recording delivery-failure. The secondary is read from
# config.json .secondary_channel (e.g. "desktop" or "dashboard"); it must differ
# from the primary and have an executable deliver script. Returns 0 on success.
try_secondary_surface() {
    local pid="$1" msg="$2" primary="$3"
    local secondary=""
    [[ -f "$CONFIG_FILE" ]] && \
        secondary="$(jq -r '.secondary_channel // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -z "$secondary" || "$secondary" == "null" || "$secondary" == "$primary" ]]; then
        return 1
    fi
    local script="$ENGINE_DIR/deliver/${secondary}.sh"
    if [[ ! -x "$script" ]]; then
        log_warn "$LOG_SRC" "secondary surface '${secondary}' has no executable deliver script; skipping"
        return 1
    fi
    log_info "$LOG_SRC" "primary delivery failed — attempting secondary surface=${secondary}"
    if "$script" "$pid" "$msg"; then
        log_info "$LOG_SRC" "secondary surface delivery succeeded surface=${secondary} prophit=$pid"
        return 0
    fi
    log_warn "$LOG_SRC" "secondary surface delivery also failed surface=${secondary}"
    return 1
}

# ── core dispatch ──────────────────────────────────────────────────────────────

# dispatch <event_type> <channel> <prophit_id> [--dry-run]
# event_type ∈ { degraded | extended | recovered | stuck-state }
dispatch() {
    local event="$1" channel="$2" pid="$3" dry="${4:-0}"

    [[ -n "$event"   ]] || die "dispatch: event required"
    [[ -n "$channel" ]] || die "dispatch: channel required"
    [[ -n "$pid"     ]] || die "dispatch: prophit-id required"

    # Suppression: one fallback per window per (channel,prophit).
    # Recovery messages are NEVER suppressed — they're the explicit signal
    # that degraded mode ended; they happen once per recovery, not per window.
    if [[ "$event" != "recovered" ]]; then
        if state_in_window "$channel" "$pid"; then
            log_info "$LOG_SRC" "suppressed (in silence-window) channel=$channel prophit=$pid event=$event"
            return 10
        fi
    fi

    # Map (event, channel) -> situation key for template selection.
    local situation
    case "$event" in
        degraded|stuck-state) situation="degraded" ;;
        extended)             situation="extended-degraded" ;;
        recovered)            situation="recovered" ;;
        *) die "dispatch: unknown event: $event" ;;
    esac

    # Select template.
    local template_path
    template_path="$("$ENGINE_DIR/select-template.sh" "$channel" "$situation")" || {
        log_error "$LOG_SRC" "template selection failed channel=$channel situation=$situation"
        return 20
    }
    if [[ ! -s "$template_path" ]]; then
        log_error "$LOG_SRC" "selected template empty or missing: $template_path"
        return 20
    fi

    # Render.
    local address_name local_time rendered
    address_name="$(get_address_name "$pid")"
    local_time="$(prophit_local_time)"

    rendered="$("$ENGINE_DIR/render.sh" "$template_path" "$address_name" "$local_time")" || {
        log_error "$LOG_SRC" "render failed for template: $template_path"
        return 20
    }

    # Dry-run: print rendered to stdout, do NOT deliver, do NOT touch state.
    if [[ "$dry" == "1" ]]; then
        printf '%s\n' "$rendered"
        log_info "$LOG_SRC" "dry-run: rendered $(wc -c <<<"$rendered") bytes channel=$channel event=$event prophit=$pid"
        return 0
    fi

    # Deliver via channel layer.
    local start_ts end_ts latency deliver_script
    start_ts="$(now_epoch)"
    deliver_script="$ENGINE_DIR/deliver/${channel}.sh"

    # §19-H5: the delivery script itself may be missing (a deploy/scrub bug).
    # The covenant ("never silence") demands we still try SOMETHING rather than
    # silently no-op. Log it loudly as a deploy bug, attempt a hardcoded
    # last-resort (direct-curl Telegram if a token file exists), and return a
    # distinct exit code (31) so the watchdog escalates.
    if [[ ! -x "$deliver_script" ]]; then
        log_error "$LOG_SRC" "delivery script MISSING — DEPLOY BUG: $deliver_script (channel=$channel)"
        if last_resort_telegram "$pid" "$rendered"; then
            end_ts="$(now_epoch)"
            latency=$((end_ts - start_ts))
            state_record_fallback "$channel" "$pid" "$event"
            write_memory_marker "$channel" "$pid" "$event"
            log_warn "$LOG_SRC" "delivered via LAST-RESORT direct-curl (deliver script was missing) channel=$channel prophit=$pid event=$event latency_s=$latency"
            return 0
        fi
        log_error "$LOG_SRC" "last-resort delivery also failed channel=$channel prophit=$pid event=$event"
        return 31
    fi

    if ! "$deliver_script" "$pid" "$rendered"; then
        log_error "$LOG_SRC" "primary delivery failed channel=$channel prophit=$pid event=$event"
        # §19-H4: try ONE configured secondary surface before declaring failure.
        if try_secondary_surface "$pid" "$rendered" "$channel"; then
            end_ts="$(now_epoch)"
            latency=$((end_ts - start_ts))
            state_record_fallback "$channel" "$pid" "$event"
            write_memory_marker "$channel" "$pid" "$event"
            log_warn "$LOG_SRC" "delivered via SECONDARY surface after primary failure primary=$channel prophit=$pid event=$event latency_s=$latency"
            return 0
        fi
        log_error "$LOG_SRC" "delivery failed on primary AND secondary channel=$channel prophit=$pid event=$event"
        return 30
    fi
    end_ts="$(now_epoch)"
    latency=$((end_ts - start_ts))

    # Record state (after delivery, so a failed delivery doesn't suppress retry).
    state_record_fallback "$channel" "$pid" "$event"

    # Memory marker: leave a one-line marker for the Gawd to acknowledge next session.
    # Per handoff context note + spec §3.2.
    write_memory_marker "$channel" "$pid" "$event"

    log_info "$LOG_SRC" "delivered channel=$channel prophit=$pid event=$event template=$(basename "$template_path") latency_s=$latency"
    return 0
}

# write_memory_marker <channel> <prophit_id> <event>
# Appends a single-line marker to the daily memory file so the Gawd
# can acknowledge in-conversation on next session.
write_memory_marker() {
    local channel="$1" pid="$2" event="$3"
    mkdir -p "$(dirname "$MEMORY_MARKER_FILE")" 2>/dev/null || true
    # If we can't write the marker, log but don't fail the delivery —
    # marker is a nice-to-have; covenant is preserved by the delivery itself.
    {
        printf '%s | channel=%s prophit=%s event=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$channel" "$pid" "$event" \
            >> "$MEMORY_MARKER_FILE"
    } 2>/dev/null || log_warn "$LOG_SRC" "memory marker write failed (non-fatal): $MEMORY_MARKER_FILE"
}

# ── command parsing ────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
engine.sh — Layer 6 silence-avoidance dispatcher.

USAGE:
  engine.sh terminal-error --channel <ch> --prophit <id> [--reason <r>] [--dry-run]
  engine.sh stuck-state    --channel <ch> --prophit <id> [--dry-run]
  engine.sh extended       --channel <ch> --prophit <id> [--dry-run]
  engine.sh recovered      --channel <ch> --prophit <id> [--dry-run]
  engine.sh reset-window   --channel <ch> --prophit <id>
  engine.sh preflight

CHANNELS:
  telegram | dashboard | desktop | voice

EXIT CODES:
  0  delivered or dry-run rendered
  10 suppressed (within silence-window)
  20 template missing or render failed
  30 delivery failed
  40 invalid invocation

EOF
}

main() {
    require_cmd jq
    require_cmd date

    local sub="${1:-}"; shift || true
    if [[ -z "$sub" ]]; then usage; exit 40; fi

    case "$sub" in
        preflight)
            cmd_preflight
            ;;
        terminal-error|stuck-state|degraded|extended|recovered|reset-window)
            local channel="" pid="" reason="" dry=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --channel) shift; channel="${1:-}";;
                    --prophit) shift; pid="${1:-}";;
                    --reason)  shift; reason="${1:-}";;
                    --dry-run) dry=1;;
                    *) die "unknown arg: $1";;
                esac
                shift || true
            done
            [[ -n "$channel" ]] || die "--channel required"
            [[ -n "$pid"     ]] || die "--prophit required"
            # Validate channel.
            case "$channel" in
                telegram|dashboard|desktop|voice) : ;;
                *) die "invalid channel: $channel (must be telegram|dashboard|desktop|voice)" ;;
            esac

            case "$sub" in
                terminal-error|stuck-state|degraded)
                    dispatch "degraded"  "$channel" "$pid" "$dry"
                    ;;
                extended)
                    dispatch "extended"  "$channel" "$pid" "$dry"
                    ;;
                recovered)
                    dispatch "recovered" "$channel" "$pid" "$dry"
                    ;;
                reset-window)
                    state_reset_channel "$channel" "$pid"
                    log_info "$LOG_SRC" "silence-window reset channel=$channel prophit=$pid"
                    ;;
            esac
            ;;
        -h|--help|help) usage ;;
        *) usage; exit 40 ;;
    esac
}

main "$@"
