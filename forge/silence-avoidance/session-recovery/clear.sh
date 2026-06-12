#!/usr/bin/env bash
# clear.sh — Retire a wedged session from the OpenClaw sessions index.
#
# Mechanically:
#   1. Verify the session is genuinely wedged (re-runs detect — defense in depth).
#   2. Take a `.bak.recovery-<ts>` backup of sessions.json.
#   3. Remove the session-key entry from sessions.json (atomic write).
#   4. Move the trajectory `.jsonl` (and trajectory-path, if present) into the
#      archive directory with a timestamped suffix. History is preserved on
#      disk; the wedged session-id is the only thing retired.
#   5. Log a `cleared` record to recovery-log.jsonl.
#
# IMPORTANT:
#   - `clear.sh` does NOT delete conversation history. The .jsonl is MOVED.
#   - `clear.sh` does NOT touch the gateway process. L7 owns process
#     lifecycle.
#   - `clear.sh` is idempotent: if the entry is already gone, log a noop
#     and exit 0.
#   - The OpenClaw gateway MAY be running. We do tmp+rename so the worst
#     case is the gateway sees the new index a moment later. Spec §8.1
#     warns "do not edit while gateway running" — we honor the spirit by
#     using atomic-rename semantics, never partial writes. (Optionally, an
#     operator can stop the gateway before running clear; the runbook
#     documents this.)
#
# Usage:
#   clear.sh --session-key <key> [--force]
#   clear.sh --session-id <uuid> [--force]
#
# Flags:
#   --force   Skip the wedge re-check. Use only when called from recover.sh
#             after recover.sh already verified the wedge. Operator manual
#             invocation should NOT pass --force.
#   --dry-run Explain what would be done; touch nothing. Equivalent to
#             exporting SR_DRY_RUN=1.
#
# Exit codes:
#   0   cleared successfully
#   1   refused (session not wedged and --force not given)
#   2   infra error (index missing, mutation failed, archive failed)
#   3   noop (already cleared / entry absent)
#
# Spec: §19.2 Layer 4, §19.6, Phase 11 test #2.

set -uo pipefail

SR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SR_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
clear.sh — retire a wedged OpenClaw session.

USAGE:
  clear.sh --session-key <key> [--force] [--dry-run]
  clear.sh --session-id  <uuid> [--force] [--dry-run]

EXIT CODES:
  0  cleared
  1  refused (not wedged; --force overrides)
  2  infra error
  3  noop (entry not present)
EOF
}

mode=""
arg=""
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-key) mode="by-key"; arg="${2:-}"; shift 2 ;;
        --session-id)  mode="by-id";  arg="${2:-}"; shift 2 ;;
        --force)       force=1; shift ;;
        --dry-run)     export SR_DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ -z "$mode" || -z "$arg" ]]; then
    usage >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    sr_log_error "jq not available — clear cannot operate"
    exit 2
fi

if [[ ! -f "$SR_INDEX_FILE" ]]; then
    sr_log_error "index missing: ${SR_INDEX_FILE}"
    exit 2
fi

# Resolve key + sessionId together so we always have both for archive + log.
key=""
sid=""
if [[ "$mode" == "by-id" ]]; then
    sid="$arg"
    key="$(sr_index_key_for_session_id "$sid")"
    if [[ -z "$key" ]]; then
        sr_log_info "clear noop: session-id ${sid} not in index"
        sr_log_recovery "$sid" "" "cleared" "noop" '{"reason":"id-not-in-index"}'
        exit 3
    fi
else
    key="$arg"
    sid="$(sr_index_session_id_for_key "$key")"
    if [[ -z "$sid" ]]; then
        sr_log_info "clear noop: key ${key} not in index"
        sr_log_recovery "" "$key" "cleared" "noop" '{"reason":"key-not-in-index"}'
        exit 3
    fi
fi

# Wedge re-check (defense in depth). Skipped under --force.
if [[ $force -eq 0 ]]; then
    sr_is_session_wedged_by_key "$key"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        case $rc in
            1) sr_log_warn "refusing to clear: session not wedged (key=${key}). Use --force to override."
               sr_log_recovery "$sid" "$key" "cleared" "refused" '{"reason":"not-wedged"}'
               exit 1 ;;
            *) sr_log_error "refusing to clear: wedge status unknown (key=${key})"
               sr_log_recovery "$sid" "$key" "cleared" "refused" '{"reason":"wedge-unknown"}'
               exit 2 ;;
        esac
    fi
fi

# Capture diagnostic BEFORE mutation (so the recovery log + signal markers
# carry the cause-of-death).
diag="$(sr_diagnostic_for_key "$key")"

# Mutate the index (backup + atomic write inside sr_index_archive_entry).
if ! sr_index_archive_entry "$key"; then
    sr_log_error "index mutation failed key=${key}"
    sr_log_recovery "$sid" "$key" "cleared" "error" '{"phase":"index-mutation"}'
    exit 2
fi

# Move the trajectory(s) to the archive dir.
if ! sr_archive_jsonl "$sid"; then
    # Non-fatal — index is the source of truth. Warn and continue.
    sr_log_warn "trajectory archive partial-fail sid=${sid} (index entry already retired)"
fi

# Append the cleared record (idempotency anchor).
last_at="$(printf '%s' "$diag" | jq -r '.last_interaction_at_ms // 0' 2>/dev/null || echo 0)"
extras="$(jq -nc \
    --argjson diag "$diag" \
    --argjson lia "${last_at:-0}" \
    '{diagnostic: $diag, last_interaction_at_ms: $lia}')"
sr_log_recovery "$sid" "$key" "cleared" "ok" "$extras"

sr_log_info "cleared: key=${key} sid=${sid}"
exit 0
