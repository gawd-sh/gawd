#!/usr/bin/env bash
# gate.sh — SIL → Prophit-Review Gate
#
# Per spec §15 + handoff E3 + architecture/sil-gate.md.
#
# This is the reference implementation of the SIL gate. SIL produces proposals
# for soul-touching changes (SOUL.md / IDENTITY.md / VOICE.md); the Gawd surfaces
# them to the Prophit; on Prophit accept, gawd-soul-apply writes the file; on
# reject or stale, the proposal archives.
#
# Subcommands:
#   draft   --target <file> --cycle <id> [--content-file <path>]
#                                        [--observed <text>] [--why <text>]
#                                        [--risk <text>]
#                                        — writes a new proposal to pending/
#   review  --proposal-id <id>           — emits the proposal markdown to stdout
#   list                                 — JSON-lines listing of all proposals
#                                          (pending + archived) with states
#   surface --proposal-id <id> [--no-telegram] [--no-desktop]
#                                        — sends Telegram + desktop notification
#   apply   --proposal-id <id> [--scripted-input <path>] [--apply-impl <path>]
#                                        — accepts the proposal:
#                                          extracts content, computes signature,
#                                          invokes gawd-soul-apply, archives.
#   reject  --proposal-id <id> [--scripted-input <path>] [--reason <text>]
#                                        — rejects the proposal:
#                                          moves to archived/<id>.rejected.md
#                                          with reason footer.
#   clear-pending [--scripted-input <path>]
#                                        — moves all pending/*.md to archived/
#                                          as rejected with reason "prophit-clear".
#   batch                                — invoked by E1 daily-reset.sh:
#                                          processes scripted-input events if a
#                                          batch queue file exists; otherwise no-op.
#
# Exit codes:
#   0  success
#   1  argument error
#   2  proposal file not found / malformed
#   3  signature mismatch (apply path)
#   4  schema validation failed (apply path)
#   5  budget exceeded (apply path)
#   6  archive move failed
#   7  apply-impl (gawd-soul-apply) missing or not executable
#   8  telegram send failed (surface)
#
# Exit-code coordination with gawd-soul-apply.sh:
#   gawd-soul-apply uses: 0 ok, 1 args, 2 missing, 3 sig, 4 schema, 5 budget, 6 write
#   gate.sh propagates these codes when invoking apply; gate.sh adds 7-8 for
#   gate-specific failures.

set -euo pipefail

# ── globals and defaults ───────────────────────────────────────────────────────

: "${GAWD_WORKSPACE:=${HOME}/.gawd/workspace}"
: "${GAWD_STATE_DIR:=${HOME}/.gawd/state}"
SIL_DIR="${GAWD_WORKSPACE}/sil"
PENDING_DIR="${SIL_DIR}/pending"
ARCHIVED_DIR="${SIL_DIR}/archived"
SILENT_SUMMARY_DIR="${SIL_DIR}/silent-summary"

APPLY_IMPL_DEFAULT="/usr/local/bin/gawd-soul-apply"
APPLY_IMPL=""

TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-${HOME}/.secrets/telegram.token}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

NEW_CONTENT_BEGIN="<<<NEW-CONTENT-BEGIN>>>"
NEW_CONTENT_END="<<<NEW-CONTENT-END>>>"

# Source the D3 observability logger if available; else fall back to stderr.
_LOGGER_PATH="/usr/local/lib/gawd/observability/logger.sh"
if [[ -r "$_LOGGER_PATH" ]]; then
    # shellcheck source=/usr/local/lib/gawd/observability/logger.sh
    source "$_LOGGER_PATH"
else
    log_info()  { printf '[INFO  sil-gate] %s\n' "$*" >&2; }
    log_warn()  { printf '[WARN  sil-gate] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR sil-gate] %s\n' "$*" >&2; }
fi

# Privacy hook (D3) — fires before any prophit-adjacent emit.
_PRIV_HOOK_PATH="/usr/local/lib/gawd/observability/privacy-hook.sh"
if [[ -r "$_PRIV_HOOK_PATH" ]]; then
    # shellcheck source=/usr/local/lib/gawd/observability/privacy-hook.sh
    source "$_PRIV_HOOK_PATH"
else
    privacy_hook() { return 0; }
fi

# Ensure directory layout exists.
mkdir -p "$PENDING_DIR" "$ARCHIVED_DIR" "$SILENT_SUMMARY_DIR"

# ── helpers ────────────────────────────────────────────────────────────────────

die() {
    local code="${1:-1}"; shift
    log_error sil-gate "$@"
    exit "$code"
}

now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Extract the literal new-content section between the sentinels.
# Stdout = content (no sentinels); empty on failure.
extract_new_content() {
    local file="$1"
    awk -v begin="$NEW_CONTENT_BEGIN" -v end="$NEW_CONTENT_END" '
        $0 == begin { in_content=1; next }
        $0 == end   { in_content=0; exit }
        in_content  { print }
    ' "$file"
}

# Extract a front-matter field value.
# Front-matter is delimited by lines containing only "---" (first and second occurrences).
# Stdout = value (trimmed); empty if absent or malformed.
extract_frontmatter_field() {
    local file="$1" key="$2"
    awk -v key="$key" '
        /^---$/ { fm_count++; next }
        fm_count == 1 && $0 ~ "^" key ":" {
            sub("^" key ":[[:space:]]*", "", $0)
            # Strip trailing whitespace.
            sub("[[:space:]]+$", "", $0)
            print
            exit
        }
        fm_count >= 2 { exit }
    ' "$file"
}

# Validate a target is one of the gated T0 anchors.
validate_target() {
    local t="$1"
    case "$t" in
        SOUL.md|IDENTITY.md|VOICE.md) return 0 ;;
        *) return 1 ;;
    esac
}

# Find a proposal file by id (search pending first, then archived).
find_proposal() {
    local id="$1"
    if [[ -f "${PENDING_DIR}/${id}.md" ]]; then
        echo "${PENDING_DIR}/${id}.md"
        return 0
    fi
    for suffix in applied rejected; do
        if [[ -f "${ARCHIVED_DIR}/${id}.${suffix}.md" ]]; then
            echo "${ARCHIVED_DIR}/${id}.${suffix}.md"
            return 0
        fi
    done
    return 1
}

# Validate a proposal file is well-formed.
# Returns 0 if OK; non-zero if malformed (with reason on stderr).
validate_proposal_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_error sil-gate "proposal file not found: $file"
        return 2
    fi
    local id target
    id="$(extract_frontmatter_field "$file" "proposal_id")"
    target="$(extract_frontmatter_field "$file" "target")"
    if [[ -z "$id" ]]; then
        log_error sil-gate "proposal missing proposal_id"
        return 2
    fi
    if [[ -z "$target" ]]; then
        log_error sil-gate "proposal missing target"
        return 2
    fi
    if ! validate_target "$target"; then
        log_error sil-gate "proposal target not a T0 anchor: $target"
        return 2
    fi
    if ! grep -qF "$NEW_CONTENT_BEGIN" "$file"; then
        log_error sil-gate "proposal missing $NEW_CONTENT_BEGIN sentinel"
        return 2
    fi
    if ! grep -qF "$NEW_CONTENT_END" "$file"; then
        log_error sil-gate "proposal missing $NEW_CONTENT_END sentinel"
        return 2
    fi
    return 0
}

# Compute sha256 of the new-content section of a proposal file.
compute_signature() {
    local file="$1"
    extract_new_content "$file" | sha256sum | awk '{print $1}'
}

# Rewrite the front-matter of a proposal file in place, setting the named fields.
# Usage: rewrite_frontmatter <file> <key1> <val1> [<key2> <val2> ...]
#
# Implementation note: uses a temp file + sed-driven rewrite. We only need to
# update fields within the FIRST front-matter block (between the first two
# `---` fence lines). Pairs are written as "key: value\n"; if a key was not
# present in the original front-matter, it is appended just before the
# closing fence.
rewrite_frontmatter() {
    local file="$1"; shift
    local tmp
    tmp="$(mktemp "${file}.tmp.XXXXXX")"

    # Collect keys / values into parallel arrays.
    local -a keys=()
    local -a vals=()
    while [[ $# -gt 0 ]]; do
        keys+=("$1")
        vals+=("$2")
        shift 2
    done

    # Build a list of "key=value" pairs the awk can parse with a unique sep.
    local sep=$'\x1f'
    local pairs=""
    local i
    for ((i = 0; i < ${#keys[@]}; i++)); do
        pairs+="${keys[$i]}${sep}${vals[$i]}"$'\n'
    done

    awk -v pairs="$pairs" -v sep="$sep" '
        BEGIN {
            n = split(pairs, lines, "\n")
            for (i = 1; i <= n; i++) {
                if (length(lines[i]) == 0) continue
                p = index(lines[i], sep)
                k = substr(lines[i], 1, p - 1)
                v = substr(lines[i], p + 1)
                kv_keys[k] = 1
                kv_vals[k] = v
                kv_order[++kv_order_n] = k
            }
            in_fm = 0
            fm_count = 0
        }
        /^---[[:space:]]*$/ {
            fm_count++
            if (fm_count == 1) {
                in_fm = 1
                print
                next
            } else if (fm_count == 2 && in_fm == 1) {
                # Closing fence: emit any keys not yet seen, then the fence.
                for (i = 1; i <= kv_order_n; i++) {
                    k = kv_order[i]
                    if (!(k in kv_emitted)) {
                        print k ": " kv_vals[k]
                        kv_emitted[k] = 1
                    }
                }
                in_fm = 0
                print
                next
            } else {
                print
                next
            }
        }
        in_fm == 1 {
            # Extract the key (everything up to the first colon).
            p = index($0, ":")
            if (p > 0) {
                k = substr($0, 1, p - 1)
                if (k in kv_keys) {
                    print k ": " kv_vals[k]
                    kv_emitted[k] = 1
                    next
                }
            }
            print
            next
        }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# ── subcommand: draft ──────────────────────────────────────────────────────────
#
# Writes a new proposal file to pending/.

cmd_draft() {
    local target="" cycle="" content_file=""
    local observed="(no observed-text provided)"
    local why="(no why-now provided)"
    local risk="(no risk text provided)"
    local proposal_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) target="$2"; shift 2 ;;
            --cycle) cycle="$2"; shift 2 ;;
            --content-file) content_file="$2"; shift 2 ;;
            --observed) observed="$2"; shift 2 ;;
            --why) why="$2"; shift 2 ;;
            --risk) risk="$2"; shift 2 ;;
            --proposal-id) proposal_id="$2"; shift 2 ;;
            *) die 1 "unknown arg to draft: $1" ;;
        esac
    done

    [[ -n "$target" ]] || die 1 "draft requires --target"
    [[ -n "$cycle" ]]  || die 1 "draft requires --cycle"
    validate_target "$target" || die 1 "target not a T0 anchor: $target"
    [[ -n "$content_file" ]] || die 1 "draft requires --content-file"
    [[ -r "$content_file" ]] || die 2 "content file not readable: $content_file"

    # Default proposal id derived from cycle + sha8.
    if [[ -z "$proposal_id" ]]; then
        local sha8
        sha8="$(sha256sum "$content_file" | awk '{print substr($1,1,8)}')"
        proposal_id="${cycle}-${sha8}"
    fi

    local out_file="${PENDING_DIR}/${proposal_id}.md"
    if [[ -e "$out_file" ]]; then
        die 1 "proposal already exists at ${out_file} (refusing to overwrite)"
    fi

    # Build the proposal.
    local nowts; nowts="$(now_iso)"

    {
        printf -- '---\n'
        printf 'proposal_id: %s\n' "$proposal_id"
        printf 'target: %s\n' "$target"
        printf 'cycle: %s\n' "$cycle"
        printf 'generated_at: %s\n' "$nowts"
        printf 'generated_by: sil-sharpen\n'
        printf 'approved_by: \n'
        printf 'approved_at: \n'
        printf 'signature: \n'
        printf -- '---\n'
        printf '\n# SIL Proposal — %s\n\n' "$proposal_id"
        printf '**Date:** %s\n' "$(date +%Y-%m-%d)"
        printf '**Target file:** %s\n' "$target"
        printf '**Sharpen cycle:** %s\n\n' "$cycle"
        printf '## Observed\n%s\n\n' "$observed"
        printf '## Proposed change\n_See the new content section below for the literal replacement text._\n\n'
        printf '## Why now\n%s\n\n' "$why"
        printf '## Risk\n%s\n\n' "$risk"
        printf '## Acceptance\n- [ ] Prophit reviewed\n- [ ] Prophit accepted\n- [ ] Applied to file\n- [ ] Cron archived this proposal\n\n'
        printf -- '---\n'
        printf '%s\n' "$NEW_CONTENT_BEGIN"
        cat "$content_file"
        printf '\n%s\n' "$NEW_CONTENT_END"
    } > "$out_file"

    chmod 0644 "$out_file"

    if validate_proposal_file "$out_file"; then
        log_info sil-gate "drafted proposal id=${proposal_id} target=${target} cycle=${cycle}"
        printf '%s\n' "$out_file"
        return 0
    else
        rm -f "$out_file"
        die 2 "drafted proposal failed self-validation; refusing to leave malformed file"
    fi
}

# ── subcommand: review ─────────────────────────────────────────────────────────
#
# Emits the proposal markdown to stdout.

cmd_review() {
    local id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proposal-id) id="$2"; shift 2 ;;
            *) die 1 "unknown arg to review: $1" ;;
        esac
    done
    [[ -n "$id" ]] || die 1 "review requires --proposal-id"

    local file
    file="$(find_proposal "$id")" || die 2 "proposal not found: $id"
    validate_proposal_file "$file" || die 2 "proposal malformed: $id"

    privacy_hook "sil_proposal_review" "prophit_adjacent" || true
    cat "$file"
}

# ── subcommand: list ───────────────────────────────────────────────────────────
#
# Emits JSON-lines listing of all proposals.

cmd_list() {
    local file id target state generated_at
    for file in "${PENDING_DIR}"/*.md; do
        [[ -e "$file" ]] || continue
        id="$(extract_frontmatter_field "$file" "proposal_id")"
        target="$(extract_frontmatter_field "$file" "target")"
        generated_at="$(extract_frontmatter_field "$file" "generated_at")"
        state="pending"
        printf '{"proposal_id":"%s","target":"%s","state":"%s","generated_at":"%s","path":"%s"}\n' \
            "$id" "$target" "$state" "$generated_at" "$file"
    done
    for file in "${ARCHIVED_DIR}"/*.applied.md; do
        [[ -e "$file" ]] || continue
        id="$(extract_frontmatter_field "$file" "proposal_id")"
        target="$(extract_frontmatter_field "$file" "target")"
        generated_at="$(extract_frontmatter_field "$file" "generated_at")"
        state="applied"
        printf '{"proposal_id":"%s","target":"%s","state":"%s","generated_at":"%s","path":"%s"}\n' \
            "$id" "$target" "$state" "$generated_at" "$file"
    done
    for file in "${ARCHIVED_DIR}"/*.rejected.md; do
        [[ -e "$file" ]] || continue
        id="$(extract_frontmatter_field "$file" "proposal_id")"
        target="$(extract_frontmatter_field "$file" "target")"
        generated_at="$(extract_frontmatter_field "$file" "generated_at")"
        state="rejected"
        printf '{"proposal_id":"%s","target":"%s","state":"%s","generated_at":"%s","path":"%s"}\n' \
            "$id" "$target" "$state" "$generated_at" "$file"
    done
}

# ── subcommand: surface ────────────────────────────────────────────────────────
#
# Sends Telegram message + desktop notification. Mirrors revelation/offer.sh.

cmd_surface() {
    local id=""
    local no_telegram=0
    local no_desktop=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proposal-id) id="$2"; shift 2 ;;
            --no-telegram) no_telegram=1; shift ;;
            --no-desktop)  no_desktop=1; shift ;;
            *) die 1 "unknown arg to surface: $1" ;;
        esac
    done
    [[ -n "$id" ]] || die 1 "surface requires --proposal-id"

    local file
    file="$(find_proposal "$id")" || die 2 "proposal not found: $id"
    validate_proposal_file "$file" || die 2 "proposal malformed: $id"

    local target observed_oneline
    target="$(extract_frontmatter_field "$file" "target")"
    # First-line snippet from the Observed section for the Telegram preview.
    observed_oneline="$(awk '/^## Observed$/{flag=1; next} /^##/{flag=0} flag && NF{print; exit}' "$file" 2>/dev/null || true)"
    [[ -n "$observed_oneline" ]] || observed_oneline="(no preview available)"

    privacy_hook "sil_proposal_surface" "prophit_adjacent" || true

    # ── Telegram ──────────────────────────────────────────────────────────────
    if [[ $no_telegram -eq 0 ]]; then
        if [[ ! -r "$TELEGRAM_TOKEN_FILE" ]]; then
            log_warn sil-gate "telegram token file not readable: $TELEGRAM_TOKEN_FILE — skipping telegram"
        elif [[ -z "$TELEGRAM_CHAT_ID" ]]; then
            log_warn sil-gate "telegram chat id not set — skipping telegram"
        else
            local token msg response
            token="$(cat "$TELEGRAM_TOKEN_FILE")"
            msg="A SIL proposal awaits your review.

Target: ${target}
Proposal: ${id}

Observed: ${observed_oneline}

Read the full proposal: /sil-show ${id}"

            response=$(curl -sf -X POST "https://api.telegram.org/bot${token}/sendMessage" \
                -d chat_id="${TELEGRAM_CHAT_ID}" \
                -d text="${msg}" \
                -d reply_markup='{
                    "inline_keyboard": [[
                        {"text": "Accept", "callback_data": "sil_accept_'"${id}"'"},
                        {"text": "Reject", "callback_data": "sil_reject_'"${id}"'"},
                        {"text": "Read first", "callback_data": "sil_show_'"${id}"'"}
                    ]]
                }' 2>&1) || {
                log_warn sil-gate "telegram send failed; proposal remains pending"
                return 8
            }
            log_info sil-gate "telegram surfaced proposal_id=${id}"
            unset token
        fi
    fi

    # ── Desktop notification ─────────────────────────────────────────────────
    if [[ $no_desktop -eq 0 ]]; then
        if command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
            notify-send -u critical -t 0 \
                "SIL proposal: ${target}" \
                "Respond on Telegram. Proposal stays pending until you decide." || true
            log_info sil-gate "desktop notification posted proposal_id=${id}"
        else
            log_info sil-gate "desktop notification skipped (no DISPLAY or notify-send)"
        fi
    fi

    return 0
}

# ── subcommand: apply ──────────────────────────────────────────────────────────
#
# Prophit accepted (button or /sil-accept). Extract content, sign, apply, archive.

cmd_apply() {
    local id=""
    local scripted_input=""
    local approved_by="${SIL_PROPHIT_USER_ID:-prophit}"
    APPLY_IMPL=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proposal-id) id="$2"; shift 2 ;;
            --scripted-input) scripted_input="$2"; shift 2 ;;
            --apply-impl) APPLY_IMPL="$2"; shift 2 ;;
            --approved-by) approved_by="$2"; shift 2 ;;
            *) die 1 "unknown arg to apply: $1" ;;
        esac
    done

    # ── Scripted-Prophit mode (F3 integration) ───────────────────────────────
    if [[ -n "$scripted_input" ]]; then
        run_scripted_events "$scripted_input"
        return 0
    fi

    [[ -n "$id" ]] || die 1 "apply requires --proposal-id (or --scripted-input)"

    local file
    file="${PENDING_DIR}/${id}.md"
    [[ -f "$file" ]] || die 2 "pending proposal not found: $id (already archived?)"
    validate_proposal_file "$file" || die 2 "proposal malformed: $id"

    # Choose apply impl: explicit override > default path > error.
    local impl
    if [[ -n "$APPLY_IMPL" ]]; then
        impl="$APPLY_IMPL"
    else
        impl="$APPLY_IMPL_DEFAULT"
    fi

    if [[ ! -x "$impl" ]]; then
        log_error sil-gate "gawd-soul-apply not executable at: $impl"
        log_error sil-gate "proposal remains pending; install per A2 runbook §4 then retry"
        return 7
    fi

    # ── Compute signature, write approval metadata into proposal ─────────────
    local sig nowts
    sig="$(compute_signature "$file")"
    nowts="$(now_iso)"
    rewrite_frontmatter "$file" \
        "approved_by" "$approved_by" \
        "approved_at" "$nowts" \
        "signature" "$sig"

    log_info sil-gate "apply: proposal_id=${id} signature=${sig} approved_by=${approved_by}"

    # ── Invoke gawd-soul-apply ───────────────────────────────────────────────
    local target target_path
    target="$(extract_frontmatter_field "$file" "target")"
    target_path="${GAWD_WORKSPACE}/${target}"

    set +e
    "$impl" "$file" "$target_path"
    local rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        # Apply failed. Reset the approval fields (the apply did not happen).
        rewrite_frontmatter "$file" \
            "approved_by" "" \
            "approved_at" "" \
            "signature" ""
        log_error sil-gate "apply failed: exit=${rc} proposal_id=${id} target=${target}"
        case "$rc" in
            3) log_error sil-gate "  → signature mismatch (proposal may have been edited mid-apply)" ;;
            4) log_error sil-gate "  → schema validation failed (missing required section)" ;;
            5) log_error sil-gate "  → token budget exceeded" ;;
            6) log_error sil-gate "  → target write failed" ;;
        esac
        return "$rc"
    fi

    # ── Archive with applied footer ──────────────────────────────────────────
    local archived="${ARCHIVED_DIR}/${id}.applied.md"
    {
        cat "$file"
        printf '\n---\n'
        printf '%s\n' "<<<APPLY-FOOTER-BEGIN>>>"
        printf 'applied_at: %s\n' "$(now_iso)"
        printf 'applied_by: gawd-soul-apply\n'
        printf 'gawd_soul_apply_exit: 0\n'
        printf 'target_path: %s\n' "$target_path"
        printf '%s\n' "<<<APPLY-FOOTER-END>>>"
    } > "$archived"
    chmod 0644 "$archived"

    if ! rm -f "$file"; then
        log_error sil-gate "archived applied proposal but failed to remove pending file"
        return 6
    fi

    log_info sil-gate "applied + archived proposal_id=${id} target=${target}"
    return 0
}

# ── subcommand: reject ─────────────────────────────────────────────────────────
#
# Prophit rejected (button, slash command, or auto). Move pending → archived/rejected.

cmd_reject() {
    local id=""
    local reason="telegram-button"
    local scripted_input=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proposal-id) id="$2"; shift 2 ;;
            --reason) reason="$2"; shift 2 ;;
            --scripted-input) scripted_input="$2"; shift 2 ;;
            *) die 1 "unknown arg to reject: $1" ;;
        esac
    done

    if [[ -n "$scripted_input" ]]; then
        run_scripted_events "$scripted_input"
        return 0
    fi

    [[ -n "$id" ]] || die 1 "reject requires --proposal-id"

    local file="${PENDING_DIR}/${id}.md"
    [[ -f "$file" ]] || die 2 "pending proposal not found: $id"
    validate_proposal_file "$file" || die 2 "proposal malformed: $id"

    local archived="${ARCHIVED_DIR}/${id}.rejected.md"
    {
        cat "$file"
        printf '\n---\n'
        printf '%s\n' "<<<REJECT-FOOTER-BEGIN>>>"
        printf 'rejected_at: %s\n' "$(now_iso)"
        printf 'rejected_by: %s\n' "${SIL_PROPHIT_USER_ID:-prophit}"
        printf 'reason: %s\n' "$reason"
        printf '%s\n' "<<<REJECT-FOOTER-END>>>"
    } > "$archived"
    chmod 0644 "$archived"

    rm -f "$file" || die 6 "archived rejected proposal but failed to remove pending file"

    log_info sil-gate "rejected + archived proposal_id=${id} reason=${reason}"
    return 0
}

# ── subcommand: clear-pending ──────────────────────────────────────────────────

cmd_clear_pending() {
    local scripted_input=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scripted-input) scripted_input="$2"; shift 2 ;;
            *) die 1 "unknown arg to clear-pending: $1" ;;
        esac
    done

    if [[ -n "$scripted_input" ]]; then
        run_scripted_events "$scripted_input"
        return 0
    fi

    local file id count=0
    for file in "${PENDING_DIR}"/*.md; do
        [[ -e "$file" ]] || continue
        id="$(extract_frontmatter_field "$file" "proposal_id")"
        cmd_reject --proposal-id "$id" --reason "prophit-clear" || {
            log_warn sil-gate "failed to clear-archive proposal_id=${id}"
            continue
        }
        count=$((count + 1))
    done
    log_info sil-gate "clear-pending: archived ${count} proposals as rejected (reason=prophit-clear)"
    return 0
}

# ── subcommand: batch ──────────────────────────────────────────────────────────
#
# Invoked by E1's daily-reset.sh via the apply-or-archive.sh shim.
# Reads pending events from ${GAWD_STATE_DIR}/sil-batch-queue.jsonl if it exists,
# applies them in order, then truncates the queue.
#
# Also: if any pending proposal is older than SIL_AUTO_STALE_DAYS (default: never
# expire; set env to opt in), no action is taken in v1 — per spec §15 "no
# auto-decline for SIL". The batch step exists so future v1.1 can add stale-sweep
# behavior in one place.

cmd_batch() {
    local queue="${GAWD_STATE_DIR}/sil-batch-queue.jsonl"
    if [[ -f "$queue" ]]; then
        log_info sil-gate "processing batch queue: $queue"
        run_scripted_events "$queue"
        : > "$queue"  # truncate after processing
    else
        log_info sil-gate "no batch queue; nothing to do"
    fi
    # v1 explicitly DOES NOT auto-archive stale proposals (spec §15: no auto-decline for SIL).
    return 0
}

# ── helper: run_scripted_events ────────────────────────────────────────────────
#
# Consume a JSONL stream of events and dispatch each to the appropriate cmd.
# Used by --scripted-input on apply/reject/clear-pending and by batch mode.
#
# Each line: {"event": "accept|reject|show|clear|surface", "proposal_id": "...", ...}

run_scripted_events() {
    local source="$1"
    [[ -r "$source" ]] || die 2 "scripted input not readable: $source"

    if ! command -v jq >/dev/null 2>&1; then
        die 1 "scripted-input mode requires jq"
    fi

    local line event pid reason user_id
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        event=$(echo "$line" | jq -r '.event // empty')
        pid=$(echo "$line" | jq -r '.proposal_id // empty')
        reason=$(echo "$line" | jq -r '.reason // empty')
        user_id=$(echo "$line" | jq -r '.user_id // "scripted-prophit"')

        SIL_PROPHIT_USER_ID="$user_id"
        export SIL_PROPHIT_USER_ID

        case "$event" in
            accept)
                [[ -n "$pid" ]] || { log_warn sil-gate "scripted accept missing proposal_id"; continue; }
                log_info sil-gate "scripted: accept proposal_id=${pid}"
                cmd_apply --proposal-id "$pid" --approved-by "$user_id" || log_warn sil-gate "scripted accept failed: $pid"
                ;;
            reject)
                [[ -n "$pid" ]] || { log_warn sil-gate "scripted reject missing proposal_id"; continue; }
                local r="${reason:-telegram-button}"
                log_info sil-gate "scripted: reject proposal_id=${pid} reason=${r}"
                cmd_reject --proposal-id "$pid" --reason "$r" || log_warn sil-gate "scripted reject failed: $pid"
                ;;
            show)
                [[ -n "$pid" ]] || { log_warn sil-gate "scripted show missing proposal_id"; continue; }
                log_info sil-gate "scripted: show proposal_id=${pid}"
                cmd_review --proposal-id "$pid" >/dev/null || log_warn sil-gate "scripted show failed: $pid"
                ;;
            surface)
                [[ -n "$pid" ]] || { log_warn sil-gate "scripted surface missing proposal_id"; continue; }
                log_info sil-gate "scripted: surface proposal_id=${pid}"
                cmd_surface --proposal-id "$pid" --no-telegram --no-desktop || log_warn sil-gate "scripted surface failed: $pid"
                ;;
            clear)
                log_info sil-gate "scripted: clear-pending"
                local f i
                for f in "${PENDING_DIR}"/*.md; do
                    [[ -e "$f" ]] || continue
                    i="$(extract_frontmatter_field "$f" "proposal_id")"
                    cmd_reject --proposal-id "$i" --reason "prophit-clear" || true
                done
                ;;
            *)
                log_warn sil-gate "scripted: unknown event kind: $event"
                ;;
        esac
    done < "$source"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <subcommand> [options]

Subcommands:
  draft   --target SOUL.md|IDENTITY.md|VOICE.md --cycle <id> --content-file <path>
          [--observed <text>] [--why <text>] [--risk <text>] [--proposal-id <id>]

  review  --proposal-id <id>
  list
  surface --proposal-id <id> [--no-telegram] [--no-desktop]
  apply   --proposal-id <id> [--apply-impl <path>] [--approved-by <user-id>]
          OR
          --scripted-input <path>
  reject  --proposal-id <id> [--reason <text>]
          OR
          --scripted-input <path>
  clear-pending [--scripted-input <path>]
  batch

See <install-root>/docs/architecture/sil-gate.md for the full spec.
EOF
    exit 1
}

main() {
    [[ $# -ge 1 ]] || usage
    local sub="$1"; shift
    case "$sub" in
        draft)         cmd_draft "$@" ;;
        review)        cmd_review "$@" ;;
        list)          cmd_list "$@" ;;
        surface)       cmd_surface "$@" ;;
        apply)         cmd_apply "$@" ;;
        reject)        cmd_reject "$@" ;;
        clear-pending) cmd_clear_pending "$@" ;;
        batch)         cmd_batch "$@" ;;
        -h|--help)     usage ;;
        *)             usage ;;
    esac
}

main "$@"
