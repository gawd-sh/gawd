#!/usr/bin/env bash
# local-dispatch.sh — AROUND-OpenClaw local-LLM dispatch wrapper for Gawd v1.
#
# Per spec §6.4 (local-DemiGawd dispatch path) and §17.8 (RESOLVED to AROUND
# for v1, 2026-05-26): this wrapper is the bypass-OpenClaw path for narrow,
# minimal-context tasks. It posts to a local llama-server (OpenAI-compat
# /v1/chat/completions) with:
#
#   * NO OpenClaw headers injected
#   * NO system-prompt injection (caller's prompt only)
#   * NO multi-turn context (single-shot, ephemeral)
#   * NO authentication (loopback llama-server has no auth)
#   * Model + endpoint controlled by config (model-agnostic — gospel §1)
#
# Installation target (Gawd-build artifact, per handoff C4):
#   /usr/local/bin/gawd-local-dispatch
# Source location (this file):
#   /usr/local/lib/gawd/runtime/local-dispatch.sh
#
# ---------------------------------------------------------------------------
# Input contract
# ---------------------------------------------------------------------------
#
# The prompt is read from STDIN by default, or from --prompt-file <path>.
# Prompts are NEVER passed on the command line (would leak via ps/proc-list).
#
# Usage:
#   gawd-local-dispatch [--model <name>] [--endpoint <url>] \
#                       [--max-tokens <n>] [--temperature <f>] \
#                       [--prompt-file <path>] [--timeout <seconds>] \
#                       [--telemetry-fd <fd>]
#
# Examples:
#   echo "Extract URLs from this HTML." | gawd-local-dispatch --model qwen3-7b
#   gawd-local-dispatch --prompt-file /tmp/p.txt --model qwen3-coder-30b
#
# ---------------------------------------------------------------------------
# Output contract
# ---------------------------------------------------------------------------
#
#   stdout = the model's response text (single string, trailing newline)
#   stderr = telemetry as a single JSON line on completion (success or failure)
#            + any human-readable error messages above that line
#   exit 0 = success
#   exit 1 = LLM-level error (HTTP non-2xx, empty response, parser fault)
#   exit 2 = wrapper-level error (bad args, prompt missing, endpoint unreachable,
#            timeout, jq/curl missing)
#
# Telemetry JSON line (always written to stderr at end, even on failure):
#   {
#     "ts":              "2026-05-27T13:00:00Z",
#     "model":           "qwen3-7b",
#     "endpoint":        "http://127.0.0.1:11434/v1/chat/completions",
#     "status":          "ok" | "llm_error" | "wrapper_error",
#     "exit_code":       0 | 1 | 2,
#     "latency_ms":      1234,
#     "http_status":     200,
#     "prompt_chars":    412,
#     "prompt_tokens":   97,
#     "completion_tokens": 158,
#     "total_tokens":    255,
#     "task_id":         "<env GAWD_TASK_ID or null>",
#     "tier":            "<env GAWD_DISPATCH_TIER or null>",
#     "task_class":      "<env GAWD_TASK_CLASS or null>"
#   }
#
# Token counts come from the llama-server response if present (`usage.*`).
# When the server doesn't return usage data, those fields are null. D3
# (observability) consumes this line — see <install-root>/docs/runbooks/
# local-dispatch.md §"Telemetry" for the collection pattern.
#
# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
#
# Endpoint default: http://127.0.0.1:11434/v1/chat/completions
#   Rationale: gospel §8 topology (GOSPEL-TOPOLOGY.md) is authoritative.
#   :11434 = qwen3-coder-30b chat-completions on Dasra/Pleroma.
#   :11436 = embeddings on ALL machines (Dasra, Nasatya, Asgard) — NEVER chat.
#   The old default of :11436 was wrong (the embeddings port); corrected to
#   :11434. Per-machine deployments still override via --endpoint or
#   GAWD_LOCAL_ENDPOINT.
#
# Model default: qwen3-7b  (Ordained tier per spec §6.5)
#
# Per-rung overrides are expected via env vars:
#   GAWD_LOCAL_ENDPOINT  — full URL incl. /v1/chat/completions
#   GAWD_LOCAL_MODEL     — default model when --model not supplied
#   GAWD_LOCAL_TIMEOUT   — connect/total timeout in seconds (default 60)

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants and defaults
# ---------------------------------------------------------------------------

DEFAULT_ENDPOINT="${GAWD_LOCAL_ENDPOINT:-http://127.0.0.1:11434/v1/chat/completions}"
DEFAULT_MODEL="${GAWD_LOCAL_MODEL:-qwen3-7b}"
DEFAULT_TIMEOUT="${GAWD_LOCAL_TIMEOUT:-60}"
DEFAULT_MAX_TOKENS="${GAWD_LOCAL_MAX_TOKENS:-1024}"
DEFAULT_TEMPERATURE="${GAWD_LOCAL_TEMPERATURE:-0.2}"

# Telemetry stream — default stderr (fd 2). D3 collectors can redirect a
# dedicated fd by exporting GAWD_TELEMETRY_FD before the call, or with
# --telemetry-fd.
DEFAULT_TELEMETRY_FD="${GAWD_TELEMETRY_FD:-2}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_err() {
    printf 'gawd-local-dispatch: %s\n' "$*" >&2
}

_usage() {
    sed -n '6,57p' "$0" | sed 's/^# \{0,1\}//' >&2
}

_require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        _err "missing required command: $cmd"
        return 2
    fi
}

# Emit one telemetry line to the configured fd. All fields are passed in via
# env-like variables in the caller's scope.
_emit_telemetry() {
    local ts model endpoint status exit_code latency_ms http_status
    local prompt_chars prompt_tokens completion_tokens total_tokens
    local task_id tier task_class

    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    model="${TELE_MODEL:-null}"
    endpoint="${TELE_ENDPOINT:-null}"
    status="${TELE_STATUS:-wrapper_error}"
    exit_code="${TELE_EXIT_CODE:-2}"
    latency_ms="${TELE_LATENCY_MS:-0}"
    http_status="${TELE_HTTP_STATUS:-0}"
    prompt_chars="${TELE_PROMPT_CHARS:-0}"
    prompt_tokens="${TELE_PROMPT_TOKENS:-null}"
    completion_tokens="${TELE_COMPLETION_TOKENS:-null}"
    total_tokens="${TELE_TOTAL_TOKENS:-null}"
    task_id="${GAWD_TASK_ID:-null}"
    tier="${GAWD_DISPATCH_TIER:-null}"
    task_class="${GAWD_TASK_CLASS:-null}"

    # Build the JSON. Numeric fields go through --argjson when non-null;
    # nullable numeric fields use a small case selector.
    local line
    line="$(
        jq -nc \
            --arg ts "$ts" \
            --arg model "$model" \
            --arg endpoint "$endpoint" \
            --arg status "$status" \
            --argjson exit_code "$exit_code" \
            --argjson latency_ms "$latency_ms" \
            --argjson http_status "$http_status" \
            --argjson prompt_chars "$prompt_chars" \
            --arg prompt_tokens "$prompt_tokens" \
            --arg completion_tokens "$completion_tokens" \
            --arg total_tokens "$total_tokens" \
            --arg task_id "$task_id" \
            --arg tier "$tier" \
            --arg task_class "$task_class" \
            '
            def numornull(s):
                if s == "null" or s == "" then null
                else (s | tonumber? // null)
                end;
            def strornull(s):
                if s == "null" or s == "" then null else s end;
            {
                ts: $ts,
                model: $model,
                endpoint: $endpoint,
                status: $status,
                exit_code: $exit_code,
                latency_ms: $latency_ms,
                http_status: $http_status,
                prompt_chars: $prompt_chars,
                prompt_tokens:     numornull($prompt_tokens),
                completion_tokens: numornull($completion_tokens),
                total_tokens:      numornull($total_tokens),
                task_id:    strornull($task_id),
                tier:       strornull($tier),
                task_class: strornull($task_class)
            }'
    )" || line='{"status":"wrapper_error","ts":"'"$ts"'","emit_failure":true}'

    # Write to the configured fd. If the fd isn't open, fall back to stderr.
    if ! { printf '%s\n' "$line" >&"$DEFAULT_TELEMETRY_FD"; } 2>/dev/null; then
        printf '%s\n' "$line" >&2
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

MODEL="$DEFAULT_MODEL"
ENDPOINT="$DEFAULT_ENDPOINT"
MAX_TOKENS="$DEFAULT_MAX_TOKENS"
TEMPERATURE="$DEFAULT_TEMPERATURE"
PROMPT_FILE=""
TIMEOUT="$DEFAULT_TIMEOUT"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)         MODEL="${2:?--model requires value}"; shift 2 ;;
        --endpoint)      ENDPOINT="${2:?--endpoint requires value}"; shift 2 ;;
        --max-tokens)    MAX_TOKENS="${2:?--max-tokens requires value}"; shift 2 ;;
        --temperature)   TEMPERATURE="${2:?--temperature requires value}"; shift 2 ;;
        --prompt-file)   PROMPT_FILE="${2:?--prompt-file requires value}"; shift 2 ;;
        --timeout)       TIMEOUT="${2:?--timeout requires value}"; shift 2 ;;
        --telemetry-fd)  DEFAULT_TELEMETRY_FD="${2:?--telemetry-fd requires value}"; shift 2 ;;
        -h|--help)       _usage; exit 0 ;;
        --)              shift; break ;;
        *)
            _err "unknown flag: $1"
            _usage
            TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
            exit 2
            ;;
    esac
done

# Validation
if ! [[ "$MAX_TOKENS" =~ ^[1-9][0-9]*$ ]]; then
    _err "--max-tokens must be a positive integer, got: $MAX_TOKENS"
    TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
    exit 2
fi
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    _err "--timeout must be a positive integer (seconds), got: $TIMEOUT"
    TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
    exit 2
fi
if ! [[ "$TEMPERATURE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    _err "--temperature must be a non-negative number, got: $TEMPERATURE"
    TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
    exit 2
fi

_require_cmd curl || { TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry; exit 2; }
_require_cmd jq   || { TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry; exit 2; }

# Set telemetry context now that endpoint/model are resolved.
TELE_MODEL="$MODEL"
TELE_ENDPOINT="$ENDPOINT"

# ---------------------------------------------------------------------------
# Read the prompt
# ---------------------------------------------------------------------------

if [[ -n "$PROMPT_FILE" ]]; then
    if [[ ! -r "$PROMPT_FILE" ]]; then
        _err "prompt file not readable: $PROMPT_FILE"
        TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
        exit 2
    fi
    PROMPT="$(cat -- "$PROMPT_FILE")"
else
    # Stdin path. Read everything; preserve bytes.
    if [[ -t 0 ]]; then
        _err "no --prompt-file given and stdin is a tty (no prompt available)"
        _usage
        TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
        exit 2
    fi
    PROMPT="$(cat)"
fi

if [[ -z "$PROMPT" ]]; then
    _err "prompt is empty"
    TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
    exit 2
fi

TELE_PROMPT_CHARS="${#PROMPT}"

# ---------------------------------------------------------------------------
# Build the request body (jq is the only safe way to embed arbitrary text)
# ---------------------------------------------------------------------------
#
# Schema is OpenAI-compatible chat-completions. NO system message. Single
# user turn only. This is the narrow-task, minimal-context contract.

REQUEST_BODY="$(
    jq -nc \
        --arg model "$MODEL" \
        --arg content "$PROMPT" \
        --argjson max "$MAX_TOKENS" \
        --argjson temp "$TEMPERATURE" \
        '{
            model: $model,
            messages: [
                { role: "user", content: $content }
            ],
            max_tokens: $max,
            temperature: $temp,
            stream: false
        }'
)" || {
    _err "failed to construct request body"
    TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
    exit 2
}

# ---------------------------------------------------------------------------
# Execute the HTTP call
# ---------------------------------------------------------------------------

HTTP_OUT="$(mktemp -t gawd-local-dispatch.body.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f -- '$HTTP_OUT'" EXIT

T_START_MS=$(( $(date +%s%N) / 1000000 ))

# We deliberately bound this with --max-time + --connect-timeout. A hung local
# llama-server should not stall a calling DemiGawd indefinitely.
HTTP_STATUS="$(
    curl -sS \
        --connect-timeout 5 \
        --max-time "$TIMEOUT" \
        -o "$HTTP_OUT" \
        -w '%{http_code}' \
        -X POST "$ENDPOINT" \
        -H 'Content-Type: application/json' \
        --data-binary "$REQUEST_BODY" \
    || echo '000'
)"

T_END_MS=$(( $(date +%s%N) / 1000000 ))
TELE_LATENCY_MS=$(( T_END_MS - T_START_MS ))
TELE_HTTP_STATUS="$HTTP_STATUS"

# ---------------------------------------------------------------------------
# Interpret response
# ---------------------------------------------------------------------------

if [[ "$HTTP_STATUS" == "000" ]]; then
    # Couldn't even establish the connection (timeout, refused, DNS, etc).
    _err "could not reach local llama-server at $ENDPOINT (connection failure or timeout >${TIMEOUT}s)"
    TELE_STATUS="wrapper_error" TELE_EXIT_CODE=2 _emit_telemetry
    exit 2
fi

if [[ "$HTTP_STATUS" != "2"* ]]; then
    BODY_PREVIEW="$(head -c 2000 "$HTTP_OUT" 2>/dev/null || true)"
    _err "HTTP $HTTP_STATUS from $ENDPOINT"
    printf 'response body (truncated):\n%s\n' "$BODY_PREVIEW" >&2
    TELE_STATUS="llm_error" TELE_EXIT_CODE=1 _emit_telemetry
    exit 1
fi

# Parse the response. OpenAI-compat path first, then fallbacks for shape drift.
RESPONSE_TEXT="$(
    jq -r '
        .choices[0].message.content
        // .choices[0].text
        // (.content[0].text? // empty)
        // empty
    ' < "$HTTP_OUT" 2>/dev/null || true
)"

if [[ -z "$RESPONSE_TEXT" ]]; then
    BODY_PREVIEW="$(head -c 2000 "$HTTP_OUT" 2>/dev/null || true)"
    _err "empty response from $ENDPOINT"
    printf 'response body (truncated):\n%s\n' "$BODY_PREVIEW" >&2
    TELE_STATUS="llm_error" TELE_EXIT_CODE=1 _emit_telemetry
    exit 1
fi

# Usage data — may be absent on llama-server depending on version.
TELE_PROMPT_TOKENS="$(jq -r '.usage.prompt_tokens // "null"' < "$HTTP_OUT" 2>/dev/null || echo null)"
TELE_COMPLETION_TOKENS="$(jq -r '.usage.completion_tokens // "null"' < "$HTTP_OUT" 2>/dev/null || echo null)"
TELE_TOTAL_TOKENS="$(jq -r '.usage.total_tokens // "null"' < "$HTTP_OUT" 2>/dev/null || echo null)"

TELE_STATUS="ok"
TELE_EXIT_CODE=0

# Emit response on stdout, telemetry on configured fd.
printf '%s\n' "$RESPONSE_TEXT"
_emit_telemetry
exit 0
