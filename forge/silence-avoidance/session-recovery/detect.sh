#!/usr/bin/env bash
# detect.sh — Wedged-session detector.
#
# Reads the OpenClaw sessions index and reports whether a given session is
# wedged (terminal-error + aborted + outside grace window + not already
# recovered). The wedge definition lives in lib/common.sh
# (sr_is_session_wedged_by_key); this script is the CLI surface around it.
#
# Usage:
#   detect.sh --session-id <uuid>    # by trajectory UUID
#   detect.sh --session-key <key>    # by index key (e.g., agent:main:main)
#   detect.sh --any                  # scan whole index; print first wedged session-key
#   detect.sh --all                  # print every wedged session-key (newline-sep)
#
# Exit codes:
#   0  session is WEDGED (or at least one wedged session was found with --any/--all)
#   1  session is HEALTHY / in-flight (or no wedged sessions found)
#   2  UNKNOWN — index missing, key absent, malformed JSON, infra failure
#
# Spec: §19.2 Layer 4 + §19.6 row "Session wedged after terminal error".
# No LLM. No network beyond `jq` and the local filesystem.

set -uo pipefail

SR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SR_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
detect.sh — wedged-session detector.

USAGE:
  detect.sh --session-id <uuid>
  detect.sh --session-key <key>
  detect.sh --any
  detect.sh --all
  detect.sh -h | --help

EXIT CODES:
  0  wedged
  1  healthy / not-found-but-index-ok
  2  unknown (index missing, malformed, infra failure)
EOF
}

mode=""
arg=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id)  mode="by-id";  arg="${2:-}"; shift 2 ;;
        --session-key) mode="by-key"; arg="${2:-}"; shift 2 ;;
        --any)         mode="any";    shift ;;
        --all)         mode="all";    shift ;;
        -h|--help)     usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ -z "$mode" ]]; then
    usage >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    sr_log_error "jq not available — detector cannot operate"
    exit 2
fi

if [[ ! -f "$SR_INDEX_FILE" ]]; then
    sr_log_warn "sessions index not present: ${SR_INDEX_FILE}"
    exit 2
fi

case "$mode" in
    by-id)
        if [[ -z "$arg" ]]; then
            sr_log_error "detect.sh: --session-id requires a value"
            exit 2
        fi
        key="$(sr_index_key_for_session_id "$arg")"
        if [[ -z "$key" ]]; then
            sr_log_info "session-id ${arg} not in index (treating as unknown)"
            exit 2
        fi
        sr_is_session_wedged_by_key "$key"
        rc=$?
        case $rc in
            0) sr_log_info "wedged: key=${key} sid=${arg}"; exit 0 ;;
            1) sr_log_info "healthy/in-flight: key=${key} sid=${arg}"; exit 1 ;;
            *) exit 2 ;;
        esac
        ;;
    by-key)
        if [[ -z "$arg" ]]; then
            sr_log_error "detect.sh: --session-key requires a value"
            exit 2
        fi
        sr_is_session_wedged_by_key "$arg"
        rc=$?
        case $rc in
            0) sr_log_info "wedged: key=${arg}"; exit 0 ;;
            1) sr_log_info "healthy/in-flight: key=${arg}"; exit 1 ;;
            *) exit 2 ;;
        esac
        ;;
    any|all)
        found=0
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            sr_is_session_wedged_by_key "$k"
            rc=$?
            if [[ $rc -eq 0 ]]; then
                printf '%s\n' "$k"
                found=1
                if [[ "$mode" == "any" ]]; then
                    exit 0
                fi
            fi
        done < <(sr_index_keys)
        if [[ $found -eq 1 ]]; then
            exit 0
        else
            exit 1
        fi
        ;;
esac
