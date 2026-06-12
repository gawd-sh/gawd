#!/usr/bin/env bash
# skills/browser-vision/skill.sh — The Browser-Vision DemiGawd.
#
# Purpose: Navigate to a URL, take a screenshot, extract DOM summary via
#          Readability.js, answer a query using a local LLM. Lets the Gawd
#          see what it shows the Prophit.
#
# Contract (per demigawd-runtime.md §12 + spec §6.2):
#   $1 = TASK_ID           (required; assigned by spawn_demigawd)
#   $2 = TASK_DESCRIPTION  (required; must be a JSON object OR a simple string
#                            that is the query; see parsing below)
#   $3 = INJECTED_CONTEXT  (optional; additional instructions or context)
#
# TASK_DESCRIPTION is interpreted as JSON if it parses as such:
#   { "url": "<string>", "query": "<string>", "timeout_sec": <int> }
# Otherwise it is treated as a plain query string (no URL fetch — use for
# analyzing injected HTML in INJECTED_CONTEXT directly).
#
# Optional env vars:
#   GAWD_BV_URL          — URL to visit (overrides task_description.url)
#   GAWD_BV_QUERY        — query to answer (overrides task_description.query)
#   GAWD_BV_TIMEOUT_SEC  — page load timeout in seconds (default: 30)
#
# Tier: ordained (local 7B for query-answering; cloud fallback if local unavailable)
# Browser: Playwright (Chromium, preferred) → xdotool+ImageMagick (fallback)
#
# Screenshot path: ${GAWD_STATE_ROOT}/screenshots/${TASK_ID}.png
#
# Output: write_result_complete_obj → TASK_ID.result with:
#   {
#     "screenshot_path": "<absolute path or null>",
#     "dom_summary": "<Readability-extracted text or null>",
#     "query_answer": "<answer string or null>",
#     "success": true|false,
#     "error": "<string or null>"
#   }
#
# On failure, success=false, error=<reason>. screenshot_path and dom_summary
# may be partial (present even on failure if the step completed before the error).
#
# Failure mode validity matrix (per handoff acceptance criteria):
#   success=false, screenshot_path=null, dom_summary=null   → page never loaded
#   success=false, screenshot_path=<path>, dom_summary=null → screenshot ok, DOM failed
#   success=false, screenshot_path=<path>, dom_summary=<text> → DOM ok, query-answer failed
#   success=false, screenshot_path=null, dom_summary=<text> → DOM from injected context,
#                                                              no browser launch
#
# Do NOT modify T0 anchors. Do NOT call OpenClaw directly.

set -uo pipefail

TASK_ID="${1:?TASK_ID required}"
TASK_DESCRIPTION="${2:?TASK_DESCRIPTION required}"
INJECTED_CONTEXT="${3:-}"

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_LIB_DIR="${SKILL_DIR}/../../runtime/lib"

# shellcheck source=../../runtime/lib/json-result.sh
source "${RUNTIME_LIB_DIR}/json-result.sh"
# shellcheck source=../../runtime/lib/dispatch.sh
source "${RUNTIME_LIB_DIR}/dispatch.sh"

# ---------------------------------------------------------------------------
# Parse inputs
# ---------------------------------------------------------------------------

# Attempt to parse TASK_DESCRIPTION as JSON.
_BV_URL=""
_BV_QUERY=""
_BV_TIMEOUT_SEC=30

if printf '%s' "${TASK_DESCRIPTION}" | jq -e . >/dev/null 2>&1; then
    _BV_URL="$(printf '%s' "${TASK_DESCRIPTION}" | jq -r '.url // ""')"
    _BV_QUERY="$(printf '%s' "${TASK_DESCRIPTION}" | jq -r '.query // ""')"
    _BV_TIMEOUT_SEC="$(printf '%s' "${TASK_DESCRIPTION}" | jq -r '.timeout_sec // 30')"
else
    # Plain string — treat as the query; URL must come from env or injected context.
    _BV_QUERY="${TASK_DESCRIPTION}"
fi

# Env overrides take precedence.
BV_URL="${GAWD_BV_URL:-${_BV_URL}}"
BV_QUERY="${GAWD_BV_QUERY:-${_BV_QUERY}}"
BV_TIMEOUT_SEC="${GAWD_BV_TIMEOUT_SEC:-${_BV_TIMEOUT_SEC}}"

SCREENSHOT_DIR="${GAWD_STATE_ROOT}/screenshots"
mkdir -p "${SCREENSHOT_DIR}"
SCREENSHOT_PATH="${SCREENSHOT_DIR}/${TASK_ID}.png"

SCREENSHOT_RESULT=""
DOM_SUMMARY=""
QUERY_ANSWER=""
FAILURE_REASON=""

# ---------------------------------------------------------------------------
# Browser sub-script (Playwright primary, xdotool fallback)
# ---------------------------------------------------------------------------

# The browser work is delegated to an external Python helper (Playwright).
# This keeps skill.sh as shell and the browser I/O as Python — each does
# what it is good at.
BROWSER_SCRIPT="${SKILL_DIR}/browser-fetch.py"

_fetch_page() {
    local url="$1"
    local out_screenshot="$2"
    local out_dom="$3"
    local timeout_ms=$(( BV_TIMEOUT_SEC * 1000 ))

    if [[ ! -f "${BROWSER_SCRIPT}" ]]; then
        printf 'browser-vision: browser-fetch.py not found at %s\n' "${BROWSER_SCRIPT}" >&2
        return 1
    fi

    python3 "${BROWSER_SCRIPT}" \
        --url "${url}" \
        --screenshot "${out_screenshot}" \
        --dom-out "${out_dom}" \
        --timeout "${timeout_ms}" 2>&1
}

# ---------------------------------------------------------------------------
# xdotool fallback: capture current screen via ImageMagick import
# ---------------------------------------------------------------------------
_xdotool_screenshot() {
    local out="$1"
    if command -v import >/dev/null 2>&1; then
        DISPLAY="${DISPLAY:-:0}" import -window root "${out}" 2>&1 && return 0
    fi
    if command -v scrot >/dev/null 2>&1; then
        DISPLAY="${DISPLAY:-:0}" scrot "${out}" 2>&1 && return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

# Step 1: Fetch the page (if URL provided)
if [[ -n "${BV_URL}" ]]; then
    DOM_TMP="$(mktemp "${GAWD_STATE_ROOT}/bv-dom-XXXXXX.txt")"
    trap 'rm -f -- "${DOM_TMP}"' EXIT

    FETCH_OUTPUT="$(_fetch_page "${BV_URL}" "${SCREENSHOT_PATH}" "${DOM_TMP}" 2>&1)" || true

    if [[ -f "${SCREENSHOT_PATH}" ]] && [[ -s "${SCREENSHOT_PATH}" ]]; then
        SCREENSHOT_RESULT="${SCREENSHOT_PATH}"
    else
        # Playwright failed; try xdotool fallback for current-screen screenshot.
        if _xdotool_screenshot "${SCREENSHOT_PATH}" 2>/dev/null; then
            SCREENSHOT_RESULT="${SCREENSHOT_PATH}"
            FAILURE_REASON="playwright fetch failed; screenshot is current screen (xdotool fallback)"
        fi
    fi

    if [[ -f "${DOM_TMP}" ]] && [[ -s "${DOM_TMP}" ]]; then
        DOM_SUMMARY="$(cat "${DOM_TMP}")"
    else
        if [[ -z "${FAILURE_REASON}" ]]; then
            FAILURE_REASON="DOM extraction failed: ${FETCH_OUTPUT}"
        fi
    fi
elif [[ -n "${INJECTED_CONTEXT}" ]]; then
    # No URL — query is against injected HTML/text directly.
    DOM_SUMMARY="${INJECTED_CONTEXT}"
fi

# Step 2: Answer the query against the DOM summary using a local LLM.
if [[ -n "${BV_QUERY}" ]] && [[ -n "${DOM_SUMMARY}" ]]; then
    QA_PROMPT_FILE="$(mktemp "${GAWD_STATE_ROOT}/bv-qa-prompt-XXXXXX.txt")"
    trap 'rm -f -- "${QA_PROMPT_FILE}"' EXIT

    # Truncate DOM summary to ~6000 chars to stay within local model budget.
    DOM_TRUNCATED="${DOM_SUMMARY:0:6000}"
    if [[ "${#DOM_SUMMARY}" -gt 6000 ]]; then
        DOM_TRUNCATED="${DOM_TRUNCATED}
[... truncated at 6000 chars ...]"
    fi

    {
        printf 'You are answering a question about a web page. Answer directly and concisely.\n\n'
        printf '## Page Content (extracted text)\n\n%s\n\n' "${DOM_TRUNCATED}"
        printf '## Question\n\n%s\n\n' "${BV_QUERY}"
        printf 'Answer the question using only information from the page content above.\n'
        printf 'If the answer is not present, say so directly.\n'
    } > "${QA_PROMPT_FILE}"

    # Try ordained (local 7B) first; cloud fallback if local unavailable.
    QA_RESPONSE="$(dispatch_demigawd_call "ordained" "${QA_PROMPT_FILE}" 400 2>/dev/null)" || {
        # Local failed — fall back to blessed (cloud fast-tier).
        # Per handoff: explicit cloud fallback is permitted; silent fallback is not.
        printf 'browser-vision: ordained (local) unavailable; falling back to blessed (cloud)\n' >&2
        QA_RESPONSE="$(dispatch_demigawd_call "blessed" "${QA_PROMPT_FILE}" 400 2>/dev/null)" || {
            QA_RESPONSE=""
            if [[ -z "${FAILURE_REASON}" ]]; then
                FAILURE_REASON="query-answer dispatch failed (ordained and blessed both unavailable)"
            fi
        }
    }

    QUERY_ANSWER="${QA_RESPONSE}"
fi

# ---------------------------------------------------------------------------
# Write result
# ---------------------------------------------------------------------------

# Determine success: we succeeded if we got at least a query answer, or at
# minimum the DOM summary (query might be empty).
SUCCESS="true"
if [[ -z "${DOM_SUMMARY}" ]] && [[ -z "${SCREENSHOT_RESULT}" ]]; then
    SUCCESS="false"
    if [[ -z "${FAILURE_REASON}" ]]; then
        FAILURE_REASON="no URL provided and no injected context; nothing to process"
    fi
fi
if [[ -n "${BV_QUERY}" ]] && [[ -z "${QUERY_ANSWER}" ]]; then
    SUCCESS="false"
    if [[ -z "${FAILURE_REASON}" ]]; then
        FAILURE_REASON="query-answer step failed; see per-task log for detail"
    fi
fi

RESULT_OBJ="$(jq -nc \
    --argjson success "${SUCCESS}" \
    --arg screenshot "${SCREENSHOT_RESULT}" \
    --arg dom "${DOM_SUMMARY:0:2000}" \
    --arg answer "${QUERY_ANSWER}" \
    --arg error_val "${FAILURE_REASON}" \
    '{
        screenshot_path: (if $screenshot == "" then null else $screenshot end),
        dom_summary: (if $dom == "" then null else $dom end),
        query_answer: (if $answer == "" then null else $answer end),
        success: $success,
        error: (if $error_val == "" then null else $error_val end)
    }')"

write_result_complete_obj "${TASK_ID}" "${RESULT_OBJ}"
exit 0
