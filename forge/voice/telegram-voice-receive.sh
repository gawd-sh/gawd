#!/usr/bin/env bash
# telegram-voice-receive.sh — Telegram voice-note handler for the base Gawd.
#
# Spec reference: Architecture §9 (Voice Modality), §9.3 (Day-1 fallback shape)
# Handoff: HANDOFF-20260526-GAWDFATHER-METATRON-voice-relay-model-agnostic.md
#
# Pipeline:
#   Inbound voice-note (Telegram, Opus/OGG)
#     -> download via getFile + bot file URL
#     -> STT (configurable provider; default ElevenLabs)
#     -> LLM call via gawdfather-llm-call (model-agnostic; same chain as the daemon)
#     -> TTS (configurable provider; default ElevenLabs)
#     -> reply as voice-note + optional transcript
#
# This script is invoked by the Telegram channel plugin when a voice update
# arrives. It is NOT a standalone listener — it expects a single voice file
# path and a chat_id from the channel runtime.
#
# Contract (invocation):
#   telegram-voice-receive.sh <chat_id> <voice_file_path> <sender_telegram_id>
#
# Where:
#   chat_id            — Telegram chat to reply to
#   voice_file_path    — local path to the downloaded OGG/Opus blob
#   sender_telegram_id — Prophit identification for USER.md routing
#
# Exit codes:
#   0   success (reply sent)
#   1   fatal config or invocation error
#   64  invalid arguments
#   65  STT failed (per fail_graceful.on_stt_failure)
#   66  LLM failed
#   67  TTS failed (degrades to text per fail_graceful.on_tts_failure)
#
# Model-agnostic invariant: this script contains NO model name literals.
# The LLM call routes through gawdfather-llm-call with mode/tier/explicit
# resolved from ~/.gawd/state/voice.json. The test
# tests/test-no-hardwired-models.sh greps for forbidden provider/model
# patterns and must produce zero hits against this file.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

: "${GAWD_VOICE_CONFIG:=${HOME}/.gawd/state/voice.json}"
: "${GAWD_LLM_CALL_BIN:=<install-root>/bin/gawdfather-llm-call}"
: "${GAWD_WORKSPACE_ROOT:=${HOME}/.gawd/workspace}"
: "${GAWD_TG_TOKEN_FILE:=${HOME}/.secrets/telegram.token}"

LOG_PREFIX="[tg-voice]"
log() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
die() { log "FATAL: $*"; exit "${2:-1}"; }

# Forward-declared reply helpers — defined here (above first use) so the
# duration-check / STT-failure paths can fall back to text without an
# ordering bug. Telegram token is read from a file, never passed on argv.
send_text_reply() {
    local chat="$1"
    local text="$2"
    if [[ ! -r "$GAWD_TG_TOKEN_FILE" ]]; then
        log "cannot send text reply: telegram token unreadable"
        return 1
    fi
    local token
    token="$(cat "$GAWD_TG_TOKEN_FILE")"
    curl -sS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=${text}" \
        >/dev/null
    # Never echo $token; never log it.
    unset token
}

send_voice_reply() {
    local chat="$1"
    local voice_path="$2"
    if [[ ! -r "$GAWD_TG_TOKEN_FILE" ]]; then
        log "cannot send voice reply: telegram token unreadable"
        return 1
    fi
    local token
    token="$(cat "$GAWD_TG_TOKEN_FILE")"
    curl -sS -X POST "https://api.telegram.org/bot${token}/sendVoice" \
        -F "chat_id=${chat}" \
        -F "voice=@${voice_path};type=audio/ogg" \
        >/dev/null
    unset token
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

if [[ $# -lt 3 ]]; then
    cat >&2 <<EOF
Usage: $0 <chat_id> <voice_file_path> <sender_telegram_id>

  chat_id            Telegram chat to reply in
  voice_file_path    Local OGG/Opus file (already downloaded by channel plugin)
  sender_telegram_id Stable Telegram user ID of the sender (for USER routing)
EOF
    exit 64
fi

CHAT_ID="$1"
VOICE_FILE="$2"
SENDER_ID="$3"

[[ -r "$VOICE_FILE" ]] || die "voice file not readable: $VOICE_FILE" 64
[[ -r "$GAWD_VOICE_CONFIG" ]] || die "voice config missing — voice is disabled" 1

# ---------------------------------------------------------------------------
# Load config + apply graceful-failure policies
# ---------------------------------------------------------------------------

cfg_get() {
    # cfg_get <jq-filter> — read voice.json with a default fallback.
    local filter="$1"
    local default="${2:-}"
    local val
    val="$(jq -r "$filter // empty" "$GAWD_VOICE_CONFIG" 2>/dev/null || true)"
    if [[ -z "$val" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$val"
    fi
}

ENABLED="$(cfg_get '.enabled' 'false')"
TG_ENABLED="$(cfg_get '.telegram_voice.enabled' 'true')"
AUTO_REPLY_FORMAT="$(cfg_get '.telegram_voice.auto_reply_format' 'voice')"
MAX_VOICE_SEC="$(cfg_get '.telegram_voice.max_voice_seconds' '120')"

if [[ "$ENABLED" != "true" ]]; then
    log "voice subsystem disabled in config — ignoring voice-note."
    exit 0
fi
if [[ "$TG_ENABLED" != "true" ]]; then
    log "telegram_voice disabled in config — ignoring voice-note."
    exit 0
fi

LLM_MODE="$(cfg_get '.llm.mode' 'chain')"
LLM_TIER="$(cfg_get '.llm.tier' '')"
LLM_MODEL_ID="$(cfg_get '.llm.model_id' '')"
LLM_MAX_TOKENS="$(cfg_get '.llm.max_tokens' '512')"

VOICE_ID="$(cfg_get '.voice_id' '')"
[[ -n "$VOICE_ID" ]] || die "voice_id missing from config (IDENTITY.md Voice section)" 1

STT_PROVIDER="$(cfg_get '.stt.provider' 'elevenlabs')"
STT_API_KEY_ENV="$(cfg_get '.stt.api_key_env' 'ELEVENLABS_API_KEY')"
STT_LANGUAGE="$(cfg_get '.stt.language' 'auto')"
STT_ENDPOINT_OVERRIDE="$(cfg_get '.stt.endpoint_override' '')"

TTS_PROVIDER="$(cfg_get '.tts.provider' 'elevenlabs')"
TTS_API_KEY_ENV="$(cfg_get '.tts.api_key_env' 'ELEVENLABS_API_KEY')"
TTS_FORMAT="$(cfg_get '.tts.format' 'ogg_opus')"
TTS_ENDPOINT_OVERRIDE="$(cfg_get '.tts.endpoint_override' '')"

ON_STT_FAIL="$(cfg_get '.fail_graceful.on_stt_failure' 'retry_once_then_text')"
ON_TTS_FAIL="$(cfg_get '.fail_graceful.on_tts_failure' 'retry_once_then_text')"
ON_MISSING_KEY="$(cfg_get '.fail_graceful.on_missing_api_key' 'disable_voice')"

# Preflight: API keys present?
require_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
        if [[ "$ON_MISSING_KEY" == "fail_daemon" ]]; then
            die "missing required env $var (policy=fail_daemon)" 1
        fi
        log "missing env $var — disabling voice for this turn."
        exit 0
    fi
}
if [[ "$STT_PROVIDER" != "mock" && "$STT_PROVIDER" != "local-whisper" ]]; then
    require_env "$STT_API_KEY_ENV"
fi
if [[ "$TTS_PROVIDER" != "mock" && "$TTS_PROVIDER" != "local-piper" ]]; then
    require_env "$TTS_API_KEY_ENV"
fi

# Telegram bot token (NOT echoed anywhere; only read from a file, never command line).
if [[ ! -r "$GAWD_TG_TOKEN_FILE" ]]; then
    die "telegram token file not readable: $GAWD_TG_TOKEN_FILE" 1
fi

# ---------------------------------------------------------------------------
# Duration check — refuse oversized voice-notes politely.
# ---------------------------------------------------------------------------

if command -v ffprobe >/dev/null 2>&1; then
    DURATION_SEC="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$VOICE_FILE" 2>/dev/null | awk '{printf "%d", $1}')"
    if [[ -n "$DURATION_SEC" && "$DURATION_SEC" -gt "$MAX_VOICE_SEC" ]]; then
        log "voice-note ${DURATION_SEC}s exceeds max ${MAX_VOICE_SEC}s — sending polite refusal."
        send_text_reply "$CHAT_ID" "That's a long voice-note — over ${MAX_VOICE_SEC} seconds. Could you send me a transcript or break it into shorter notes? My ears have limits, magnificent as they are."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# STT: transcribe the voice-note
# ---------------------------------------------------------------------------

stt_elevenlabs() {
    local audio_file="$1"
    local language="$2"
    local endpoint="${STT_ENDPOINT_OVERRIDE:-https://api.elevenlabs.io/v1/speech-to-text}"
    local args=(
        -sS
        -X POST "$endpoint"
        -H "xi-api-key: ${!STT_API_KEY_ENV}"
        -F "audio=@${audio_file};type=audio/ogg"
    )
    if [[ "$language" != "auto" ]]; then
        args+=(-F "language=${language}")
    fi
    curl "${args[@]}" | jq -r '.text // empty'
}

stt_local_whisper() {
    local audio_file="$1"
    local endpoint="${STT_ENDPOINT_OVERRIDE:-http://127.0.0.1:11437/stt}"
    curl -sS -X POST "$endpoint" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$audio_file" \
        | jq -r '.text // empty'
}

stt_mock() {
    printf '[mock transcription]'
}

transcribe() {
    case "$STT_PROVIDER" in
        elevenlabs) stt_elevenlabs "$VOICE_FILE" "$STT_LANGUAGE" ;;
        local-whisper) stt_local_whisper "$VOICE_FILE" ;;
        mock) stt_mock ;;
        *) die "unknown STT provider: $STT_PROVIDER" 1 ;;
    esac
}

TRANSCRIPT=""
if ! TRANSCRIPT="$(transcribe)" || [[ -z "$TRANSCRIPT" ]]; then
    log "STT failed (provider=$STT_PROVIDER); policy=$ON_STT_FAIL"
    case "$ON_STT_FAIL" in
        retry_once_then_text)
            sleep 1
            if ! TRANSCRIPT="$(transcribe)" || [[ -z "$TRANSCRIPT" ]]; then
                send_text_reply "$CHAT_ID" "I heard you trying to speak but my ears caught nothing. Try again, or send text?"
                exit 65
            fi
            ;;
        text_apology)
            send_text_reply "$CHAT_ID" "I heard you trying to speak but my ears caught nothing. Try again, or send text?"
            exit 65
            ;;
        silent_drop)
            exit 65
            ;;
    esac
fi

log "transcript ($(printf '%s' "$TRANSCRIPT" | wc -c) chars): $(printf '%s' "$TRANSCRIPT" | head -c 80)..."

# ---------------------------------------------------------------------------
# LLM: call gawdfather-llm-call with the transcript
# ---------------------------------------------------------------------------

PROMPT_FILE="$(mktemp -t gawd-voice-prompt.XXXXXX)"
trap 'rm -f -- "$PROMPT_FILE" "${REPLY_AUDIO_FILE:-}" "${REPLY_TEXT_FILE:-}"' EXIT

# We include the transcript verbatim plus a soft hint about voice-mode brevity.
# The Gawd's persona files (loaded by the daemon) already establish voice;
# we don't re-inject SOUL here. Keep this prompt narrow.
cat >"$PROMPT_FILE" <<EOF
[VOICE MODE — Prophit ${SENDER_ID} spoke this; reply naturally and briefly enough for spoken delivery.]

${TRANSCRIPT}
EOF

call_llm() {
    case "$LLM_MODE" in
        chain)
            # Empty model arg --> caller uses daemon primary chain.
            "$GAWD_LLM_CALL_BIN" "" "$PROMPT_FILE" "$LLM_MAX_TOKENS"
            ;;
        tier)
            [[ -n "$LLM_TIER" ]] || die "llm.mode=tier but llm.tier missing" 1
            # Source dispatch.sh and call the tier resolver directly.
            # shellcheck source=/usr/local/lib/gawd/runtime/lib/dispatch.sh
            source /usr/local/lib/gawd/runtime/lib/dispatch.sh
            dispatch_demigawd_call "$LLM_TIER" "$PROMPT_FILE" "$LLM_MAX_TOKENS"
            ;;
        explicit)
            [[ -n "$LLM_MODEL_ID" ]] || die "llm.mode=explicit but llm.model_id missing" 1
            log "DRIFT: explicit model pin in voice config ($LLM_MODEL_ID)"
            "$GAWD_LLM_CALL_BIN" "$LLM_MODEL_ID" "$PROMPT_FILE" "$LLM_MAX_TOKENS"
            ;;
        *)
            die "unknown llm.mode: $LLM_MODE" 1
            ;;
    esac
}

REPLY_TEXT_FILE="$(mktemp -t gawd-voice-reply.XXXXXX)"
if ! call_llm >"$REPLY_TEXT_FILE" 2>/dev/null; then
    log "LLM call failed (mode=$LLM_MODE)"
    send_text_reply "$CHAT_ID" "I heard you but my voice caught in my throat. One moment."
    exit 66
fi

REPLY_TEXT="$(cat "$REPLY_TEXT_FILE")"
if [[ -z "$REPLY_TEXT" ]]; then
    send_text_reply "$CHAT_ID" "I heard you but the words I tried to send back were empty. One moment."
    exit 66
fi

log "reply ($(printf '%s' "$REPLY_TEXT" | wc -c) chars): $(printf '%s' "$REPLY_TEXT" | head -c 80)..."

# ---------------------------------------------------------------------------
# TTS: synthesize the reply
# ---------------------------------------------------------------------------

tts_elevenlabs() {
    local text="$1"
    local out_file="$2"
    local endpoint="${TTS_ENDPOINT_OVERRIDE:-https://api.elevenlabs.io/v1/text-to-speech}"
    local accept
    case "$TTS_FORMAT" in
        ogg_opus) accept="audio/ogg" ;;
        pcm_16000) accept="audio/pcm" ;;
        *) accept="audio/mpeg" ;;
    esac
    local body
    body="$(jq -nc --arg text "$text" \
        --argjson stab "$(cfg_get '.tts.stability' '0.5')" \
        --argjson sim  "$(cfg_get '.tts.similarity_boost' '0.75')" \
        '{text:$text, voice_settings:{stability:$stab, similarity_boost:$sim}}')"
    curl -sS -X POST "${endpoint}/${VOICE_ID}" \
        -H "xi-api-key: ${!TTS_API_KEY_ENV}" \
        -H "Content-Type: application/json" \
        -H "Accept: ${accept}" \
        -d "$body" \
        -o "$out_file"
    [[ -s "$out_file" ]]
}

tts_local_piper() {
    local text="$1"
    local out_file="$2"
    local endpoint="${TTS_ENDPOINT_OVERRIDE:-http://127.0.0.1:11438/tts}"
    curl -sS -X POST "$endpoint" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg t "$text" --arg v "$VOICE_ID" '{text:$t, voice_id:$v}')" \
        -o "$out_file"
    [[ -s "$out_file" ]]
}

tts_mock() {
    printf 'MOCK_AUDIO' >"$2"
}

synthesize() {
    local text="$1"
    local out_file="$2"
    case "$TTS_PROVIDER" in
        elevenlabs) tts_elevenlabs "$text" "$out_file" ;;
        local-piper) tts_local_piper "$text" "$out_file" ;;
        mock) tts_mock "$text" "$out_file" ;;
        *) die "unknown TTS provider: $TTS_PROVIDER" 1 ;;
    esac
}

REPLY_AUDIO_FILE="$(mktemp -t gawd-voice-out.XXXXXX.ogg)"
if ! synthesize "$REPLY_TEXT" "$REPLY_AUDIO_FILE"; then
    log "TTS failed (provider=$TTS_PROVIDER); policy=$ON_TTS_FAIL"
    # Both policies degrade the same way: send text.
    send_text_reply "$CHAT_ID" "$REPLY_TEXT"
    exit 67
fi

# ---------------------------------------------------------------------------
# Send reply via Telegram
# ---------------------------------------------------------------------------

# (send_text_reply / send_voice_reply defined at top of file)

case "$AUTO_REPLY_FORMAT" in
    voice)
        send_voice_reply "$CHAT_ID" "$REPLY_AUDIO_FILE"
        ;;
    text+voice)
        send_text_reply "$CHAT_ID" "$REPLY_TEXT"
        send_voice_reply "$CHAT_ID" "$REPLY_AUDIO_FILE"
        ;;
    text)
        send_text_reply "$CHAT_ID" "$REPLY_TEXT"
        ;;
    *)
        die "unknown auto_reply_format: $AUTO_REPLY_FORMAT" 1
        ;;
esac

# Append the exchange to the daily memory file (lightweight).
DAILY_FILE="${GAWD_WORKSPACE_ROOT}/memory/$(date +%Y-%m-%d).md"
mkdir -p -- "$(dirname -- "$DAILY_FILE")"
{
    printf '\n## Voice exchange (%s)\n' "$(date -Is)"
    printf '**Prophit (%s):** %s\n\n' "$SENDER_ID" "$TRANSCRIPT"
    printf '**Gawd:** %s\n' "$REPLY_TEXT"
} >>"$DAILY_FILE"

log "voice-note exchange complete."
exit 0
