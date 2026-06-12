#!/usr/bin/env bash
# sweep.sh — Periodic wedged-session sweeper.
#
# Iterates every session-key in the OpenClaw sessions index. For each
# wedged key, calls recover.sh. Designed to run as a 5-minute cron from
# E1's scheduler (belt-and-suspenders for cases where L7's 60-second
# watchdog missed a wedge). Also valid for manual invocation:
#
#   sweep.sh                # process every wedged session
#   sweep.sh --report-only  # list wedged sessions; do not recover
#   sweep.sh --dry-run      # show what would happen; touch nothing
#   sweep.sh --max <N>      # stop after recovering N sessions
#
# Output (stdout): one line per processed session, format:
#   <key> <session-id> <action> <outcome>
#   where action ∈ {recovered, refused, noop, error}
#         outcome ∈ {ok, error, noop}
#
# Exit codes:
#   0  sweep completed (any number of recoveries, including zero)
#   1  at least one recovery failed
#   2  infra error (index missing, jq missing)
#
# Spec: §19.2 Layer 4, §19.7 Phase 11 test #2.

set -uo pipefail

SR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SR_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
sweep.sh — process every wedged OpenClaw session.

USAGE:
  sweep.sh [--report-only] [--dry-run] [--max <N>]

EXIT CODES:
  0  sweep completed
  1  at least one recovery failed
  2  infra error
EOF
}

report_only=0
dry=0
max=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report-only) report_only=1; shift ;;
        --dry-run)     dry=1; export SR_DRY_RUN=1; shift ;;
        --max)         max="${2:-0}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    sr_log_error "jq not available — sweep cannot operate"
    exit 2
fi

if [[ ! -f "$SR_INDEX_FILE" ]]; then
    sr_log_warn "sessions index not present: ${SR_INDEX_FILE} — sweep no-op"
    exit 0
fi

processed=0
recovered=0
errors=0

while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    sr_is_session_wedged_by_key "$key"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        # Healthy or unknown — skip silently. Unknown is logged at debug
        # level by sr_is_session_wedged_by_key.
        continue
    fi

    sid="$(sr_index_session_id_for_key "$key")"
    sid="${sid:-unknown}"

    if [[ $report_only -eq 1 ]]; then
        printf '%s %s wedged report-only\n' "$key" "$sid"
        processed=$((processed + 1))
        continue
    fi

    recover_flags=("--session-key" "$key" "--force")
    if [[ $dry -eq 1 ]]; then
        recover_flags+=("--dry-run")
    fi

    if "${SR_DIR}/recover.sh" "${recover_flags[@]}" >/dev/null 2>&1; then
        printf '%s %s recovered ok\n' "$key" "$sid"
        recovered=$((recovered + 1))
    else
        child_rc=$?
        printf '%s %s recovered error rc=%d\n' "$key" "$sid" "$child_rc"
        errors=$((errors + 1))
    fi
    processed=$((processed + 1))

    if (( max > 0 )) && (( processed >= max )); then
        sr_log_info "sweep --max reached (${processed})"
        break
    fi
done < <(sr_index_keys)

sr_log_info "sweep complete: processed=${processed} recovered=${recovered} errors=${errors} report_only=${report_only} dry_run=${dry}"

if (( errors > 0 )); then
    exit 1
fi
exit 0
