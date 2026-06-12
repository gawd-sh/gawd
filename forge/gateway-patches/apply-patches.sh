#!/usr/bin/env bash
# apply-patches.sh — apply local gateway-patches to an installed OpenClaw
# ============================================================================
# Idempotent. Safe to re-run. Fails loudly if a patch cannot be applied
# (rather than silently leaving the bug in).
#
# Usage:
#   ./apply-patches.sh                          # patch the default path
#   ./apply-patches.sh /custom/openclaw/dist    # patch a custom path
#
# Exit codes:
#   0  All patches applied (or already applied; no-op)
#   1  Anchor not found (file structure changed; investigate)
#   2  Verify-after-apply failed (patch ran but text didn't change as expected)
#   3  OpenClaw install path missing
#   4  Filesystem write failed
#
# When to call:
#   - install.sh calls this AFTER `npm install -g openclaw@X` AND AFTER the
#     extensions-dir chown step (per feedback_extensions_dir_chown.md).
#   - On any future `openclaw update` (the npm install resets node_modules,
#     so the patch must be re-applied).
#
# Per Metatron hard rule: this script ONLY modifies files inside the
# OpenClaw install dir, never config, never secrets, never the agent's
# workspace. Backups (.bak.next-none-fix-v1) are written next to the
# original before any change.
# ============================================================================
set -euo pipefail

PATCH_ID="next-none-fix-v1"
DEFAULT_OPENCLAW_DIST="/usr/lib/node_modules/openclaw/dist"
TARGET_DIST="${1:-$DEFAULT_OPENCLAW_DIST}"

log()  { printf '[apply-patches] %s\n' "$*" >&2; }
fail() { log "FATAL: $*"; exit "${2:-1}"; }

[[ -d "$TARGET_DIST" ]] || fail "OpenClaw dist dir not found: $TARGET_DIST" 3

# Locate bundler-hashed files by glob — survives version drift.
# Each file contains exactly one function body that matches our anchors.
shopt -s nullglob
AGENT_SCOPE_CANDIDATES=( "$TARGET_DIST"/agent-scope-*.js )
AGENT_RUNNER_CANDIDATES=( "$TARGET_DIST"/agent-runner.runtime-*.js )
SELECTION_CANDIDATES=( "$TARGET_DIST"/selection-*.js )
shopt -u nullglob

[[ ${#AGENT_SCOPE_CANDIDATES[@]} -ge 1 ]]  || fail "no agent-scope-*.js bundle found in $TARGET_DIST"
[[ ${#AGENT_RUNNER_CANDIDATES[@]} -ge 1 ]] || fail "no agent-runner.runtime-*.js bundle found in $TARGET_DIST"
[[ ${#SELECTION_CANDIDATES[@]} -ge 1 ]]   || fail "no selection-*.js bundle found in $TARGET_DIST"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# patch_one <file> <patch-id> <old-text> <new-text>
# Returns:
#   0 if file already patched (idempotent no-op) or patched successfully
#   2 if this file does NOT carry the anchor (skip — a sibling glob match may)
#   non-zero (via fail) on a genuine write/verify error
#
# IMPORTANT (rc8.1): a single glob (e.g. agent-scope-*.js) now matches MULTIPLE
# bundler-hashed files, only ONE of which carries the anchor. A missing anchor in
# any one file is NOT fatal here — the CALLER aggregates across the glob and only
# fails if ZERO files carried the anchor (a genuinely-vanished anchor still fails
# loud). So patch_one returns rc=2 ("not in this file") instead of calling fail.
patch_one() {
	local file="$1" pid="$2" old_text="$3" new_text="$4"
	local marker="PATCHED $pid"

	# Idempotency MUST be keyed on THIS hunk's anchor, not a file-level marker.
	# A single file can carry MULTIPLE hunks for the same patch-id (the agent-runner
	# file has both the memory-flush-provider and memory-flush-bare hunks). A
	# file-level `grep -qF "$marker"` short-circuit would skip the SECOND hunk after
	# the first one landed the marker — leaving its `fallbacksOverride: []` intact.
	# So: decide per-anchor.
	#   - anchor (old_text) still present  → apply this hunk now.
	#   - anchor absent + marker present    → this hunk already applied → no-op (0).
	#   - anchor absent + marker absent     → anchor not in this file → sibling may
	#                                          carry it → return 2 (caller aggregates).
	if ! python3 - "$file" <<PY
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
old = $(printf '%s' "$old_text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
sys.exit(0 if old in text else 1)
PY
	then
		if grep -qF "$marker" "$file"; then
			log "$(basename "$file"): hunk already applied ($pid), skipping"
			return 0
		fi
		log "$(basename "$file"): anchor for $pid not in this file — skipping (a sibling glob file may carry it)"
		return 2
	fi

	# Backup once per (file, patch-id) — never overwrite an existing backup.
	local backup="${file}.bak.${pid}"
	if [[ ! -f "$backup" ]]; then
		cp -p "$file" "$backup" || fail "failed to back up $file" 4
		log "$(basename "$file"): backup → $(basename "$backup")"
	fi

	# Use Python for the substitution — sed/awk choke on multi-line literals
	# with special chars. Python's str.replace is safe and exact.
	python3 - "$file" <<PY || fail "substitution failed in $(basename "$file")" 4
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = $(printf '%s' "$old_text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
new = $(printf '%s' "$new_text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
if old not in text:
    sys.exit("anchor disappeared before write")
count = text.count(old)
if count != 1:
    sys.exit(f"anchor matched {count} times (expected exactly 1)")
path.write_text(text.replace(old, new))
PY

	# Verify the new marker landed and the EXACT (multi-line) old anchor is gone.
	# NOTE: do NOT use `grep -F` for the old-anchor check — a multi-line anchor
	# whose first line is preserved in $new_text (e.g. the agent-runner hunks keep
	# `if (overrideProvider && overrideModel) return {`) makes line-oriented grep
	# match that surviving line and false-positive "old anchor still present".
	# Use Python's exact substring test, mirroring the substitution above.
	if ! grep -qF "$marker" "$file"; then
		fail "post-write verify failed: marker not in $(basename "$file")" 2
	fi
	python3 - "$file" <<PY || fail "post-write verify failed: old anchor still in $(basename "$file")" 2
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
old = $(printf '%s' "$old_text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
sys.exit(1 if old in text else 0)
PY
	log "$(basename "$file"): patched ($pid)"
}

# patch_glob <patch-id> <hunk-label> <old-text> <new-text> <file...>
# Apply one hunk across every file matched by a glob. Succeeds if the patch
# landed (or was already present) in AT LEAST ONE file. Fails loud (exit 1)
# ONLY if ZERO files across the whole glob carried the anchor — that means the
# OpenClaw bundle shape genuinely changed and the patch must be re-anchored.
patch_glob() {
	local pid="$1" label="$2" old_text="$3" new_text="$4"; shift 4
	local matched=0 rc
	for f in "$@"; do
		# Disarm set -e for this one call so a rc=2 ("anchor not in this file")
		# does not abort the script — we aggregate across the glob instead.
		rc=0
		patch_one "$f" "$pid" "$old_text" "$new_text" || rc=$?
		case "$rc" in
			0) matched=1 ;;           # patched here, or already-patched
			2) : ;;                    # anchor not in this file — keep looking
			*) exit "$rc" ;;           # genuine write/verify failure → propagate
		esac
	done
	if [[ $matched -eq 0 ]]; then
		fail "[$label] anchor for $pid not found in ANY matched file — OpenClaw bundle shape changed; re-anchor the patch" 1
	fi
}

# ----------------------------------------------------------------------------
# Hunk 1 — agent-scope: stop returning [] for non-"auto" pins
# ----------------------------------------------------------------------------
AS_OLD='if (!(params.modelOverrideSource === "auto" || params.modelOverrideSource === void 0 && params.hasAutoFallbackProvenance === true)) return [];'
AS_NEW='/* PATCHED next-none-fix-v1: removed unconditional `return []` for non-auto pins. Honor pin as primary; let configured chain follow. */'

patch_glob "$PATCH_ID" "agent-scope" "$AS_OLD" "$AS_NEW" "${AGENT_SCOPE_CANDIDATES[@]}"

# ----------------------------------------------------------------------------
# Hunk 2a — agent-runner.runtime: memory-flush provider/model override
# ----------------------------------------------------------------------------
MFP_OLD='if (overrideProvider && overrideModel) return {
			...options,
			provider: overrideProvider,
			model: overrideModel,
			fallbacksOverride: []
		};'
MFP_NEW='if (overrideProvider && overrideModel) return {
			...options,
			provider: overrideProvider,
			model: overrideModel
			/* PATCHED next-none-fix-v1: removed `fallbacksOverride: []` so configured chain still applies after pin */
		};'

# ----------------------------------------------------------------------------
# Hunk 2b — agent-runner.runtime: memory-flush bare-model override
# ----------------------------------------------------------------------------
MFB_OLD='return {
		...options,
		model: override,
		fallbacksOverride: []
	};'
MFB_NEW='return {
		...options,
		model: override
		/* PATCHED next-none-fix-v1: removed `fallbacksOverride: []` so configured chain still applies after pin */
	};'

patch_glob "$PATCH_ID" "agent-runner/memory-flush-provider" "$MFP_OLD" "$MFP_NEW" "${AGENT_RUNNER_CANDIDATES[@]}"
patch_glob "$PATCH_ID" "agent-runner/memory-flush-bare"     "$MFB_OLD" "$MFB_NEW" "${AGENT_RUNNER_CANDIDATES[@]}"

# ----------------------------------------------------------------------------
# Hunk 3 — selection: bound the abort-cleanup disposes so the session-write-lock
# release (in cleanupEmbeddedAttemptResources' `finally`) is never starved by a
# hung MCP/LSP dispose. Fixes the mode-3 live .jsonl.lock self-deadlock
# ("session file locked ... pid=<gateway>").
#
# LOCK_OLD is the exact fresh-bundle text (tab-indented, no patch lines).
# LOCK_NEW adds 3s race-timeouts and the v2 marker comment.
# Idempotency: if v2 marker is already present and LOCK_OLD is absent,
# patch_one returns 0 (no-op) — re-runs on an already-patched live bundle
# succeed silently without touching the file.
# ----------------------------------------------------------------------------
LOCK_OLD='		try {
			await params.bundleMcpRuntime?.dispose();
		} catch {}
		try {
			await params.bundleLspRuntime?.dispose();
		} catch {}'
LOCK_NEW='		try {
			await Promise.race([Promise.resolve(params.bundleMcpRuntime?.dispose()), new Promise((r) => setTimeout(r, 3e3))]);
		} catch {}
		try {
			await Promise.race([Promise.resolve(params.bundleLspRuntime?.dispose()), new Promise((r) => setTimeout(r, 3e3))]);
		} catch {}
		/* PATCHED lock-release-on-abort-v2: bound cleanup disposes (3s) so the sessionLock.release() finally is never starved by a hung MCP/LSP dispose */'

patch_glob "lock-release-on-abort-v2" "selection/cleanup-dispose-bound" "$LOCK_OLD" "$LOCK_NEW" "${SELECTION_CANDIDATES[@]}"

# ----------------------------------------------------------------------------
# Hunk 4 — selection: bound `waitForRetainedLockIdle` so that
# `acquireForCleanup` / `disposeHeldLockAfterRetainedIdle` never hang
# indefinitely on in-flight tool-call transcript writes after a model-timeout
# abort. Fixes the SECOND session-lock-deadlock path (not covered by v2).
#
# Root cause: after a 180s model timeout + abort, a long-running tool call
# (e.g. image processing) can still be running and holding the "retained lock"
# use-count. `waitForRetainedLockIdle()` was an unbounded `await new Promise`
# keyed on the use-count reaching 0. Both `takeHeldLockAfterRetainedIdle` and
# `disposeHeldLockAfterRetainedIdle` call it, so the cleanup path can hang for
# the full remaining tool-call duration (observed: 62s+) → next turn hits the
# 60s acquire timeout → SessionWriteLockTimeoutError.
#
# Fix: add a 10s race-timeout to the unbounded Promise so cleanup is guaranteed
# to proceed within 10s even if a tool call is still running. The tool call
# eventually calls `releaseRetainedUse()` from `runWithRetainedLock`'s finally
# which harmlessly decrements the counter after the lock was already vacated.
#
# RETAIN_OLD is the exact fresh-bundle text (tab+4-space indent).
# RETAIN_NEW adds a 10s timeout race and the v3 marker comment.
# Idempotency: if v3 marker present + old anchor absent → patch_one returns 0.
# ----------------------------------------------------------------------------
RETAIN_OLD='async function waitForRetainedLockIdle() {
		if (retainedLockUseCount === 0) return true;
		if (activeWriteLock.getStore()?.active === true) return false;
		await new Promise((resolve) => {
			retainedLockIdleWaiters.add(resolve);
		});
		return true;
	}'
RETAIN_NEW='async function waitForRetainedLockIdle() {
		if (retainedLockUseCount === 0) return true;
		if (activeWriteLock.getStore()?.active === true) return false;
		/* PATCHED lock-release-on-abort-v3: bound the retained-lock-idle wait (10s) so cleanup never hangs indefinitely on in-flight tool-call transcript writes after a model-timeout abort. Previously an unbounded await here caused acquireForCleanup / disposeHeldLockAfterRetainedIdle to hang for the full tool-call duration (observed: 62s+), starving the session write lock and hitting SessionWriteLockTimeoutError on the next turn. */
		/* PATCHED lock-release-on-abort-v3-cleanup: capture resolver ref so timeout branch can remove stale entry from retainedLockIdleWaiters (prevents set accumulating stale resolved entries when timeout wins the race) */
		const RETAIN_IDLE_TIMEOUT_MS = 10000;
		let _retainedResolve;
		await Promise.race([new Promise((resolve) => {
			_retainedResolve = resolve;
			retainedLockIdleWaiters.add(resolve);
		}), new Promise((resolve) => setTimeout(() => { if (_retainedResolve) retainedLockIdleWaiters.delete(_retainedResolve); resolve(); }, RETAIN_IDLE_TIMEOUT_MS))]);
		return true;
	}'

patch_glob "lock-release-on-abort-v3" "selection/retain-idle-bound" "$RETAIN_OLD" "$RETAIN_NEW" "${SELECTION_CANDIDATES[@]}"

log "all patches applied (or already present) — patch-id: $PATCH_ID"
exit 0
