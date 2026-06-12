# Merge Contract — what E3 (SIL gate) and F1 (migration) must know

**Owner:** Metatron (handoff E2)
**Date:** 2026-05-26
**Status:** Stable interface for v1
**Consumers:** E3 (SIL gate / conflict-diff UX), F1 (migration mechanism), C1 (DemiGawd runtime — session-start hook reads conflict reports)

This document is the contract surface of the revelation merge engine. It defines what downstream handoffs may assume, what files exist where, what schemas are stable, and what behavior is guaranteed.

---

## 1. Files the engine owns

| Path | Purpose | Writer | Reader |
|---|---|---|---|
| `~/.gawd/state/pending-revelation.json` | Current Sunday's revelation offer + accept/decline state | offer.sh, check-pending.sh, merge.sh | E5 sermon channel (reads to publish acks), session-start hook (reads conflict state) |
| `~/.gawd/state/last-applied-base/SOUL.md` | Frozen snapshot of last-applied SOUL (input C) | merge.sh (rotates after success) | merge.sh (next cycle) |
| `~/.gawd/state/last-applied-base/IDENTITY.md` | Frozen snapshot of last-applied IDENTITY (input C) | merge.sh | merge.sh |
| `~/.gawd/state/last-applied-base/VOICE.md` | Frozen snapshot of last-applied VOICE (input C) | merge.sh | merge.sh |
| `~/.gawd/state/revelation-history/<ts>-<rev>.json` | Archived prior state files (audit trail) | offer.sh (on each new offer) | operators (forensics) |
| `~/.gawd/workspace/sil/conflicts/<rev>.md` | Conflict report for Prophit | merge.sh | session-start hook (C1), E3 (SIL gate UX) |
| `~/.gawd.merge-staging/` | Transient staging dir | merge.sh (creates, atomically renames away) | nobody — invisible to runtime |
| `~/.gawd.workspace.previous/` | Rollback window (24h) | merge.sh (creates), E1 daily-reset (deletes after window) | operators (manual rollback) |

---

## 2. State file schema — `pending-revelation.json`

JSON Schema: `/usr/local/lib/gawd/revelation/state-schema.json`

Stable fields E3, F1, C1 may read:

```json
{
  "schema_version": "1.0",                          // bump if breaking change
  "revelation_version": "0.4.2",                    // semver
  "revelation_bundle_path": "/abs/path/to/B/dir",   // where B lives on disk
  "offered_at": "<ISO-8601>",
  "prophit_response": "pending|accepted|declined|auto-declined",
  "response_at": "<ISO-8601>",                      // present once non-pending
  "applied": true|false,                            // merge.sh completed
  "applied_at": "<ISO-8601>",                       // present once applied
  "missed_offers_count": 0,
  "conflict_surfaced": true|false,                  // present if true
  "conflict_report_path": "/abs/path",              // present if conflict_surfaced
  "telegram_message_id": 87432                      // optional
}
```

**Backward-compatibility promise:** any new field added in future will be additive, never required. Consumers MUST tolerate unknown fields (per JSON Schema `additionalProperties: false` we MAY tighten later, but for v1 consumers should code defensively).

---

## 3. Merge contract guarantees (what E3, F1, C1 may assume)

### 3.1 Soul-anchor list source

The T0-anchor list is **read at runtime** from A1's update-authority table (`<install-root>/docs/architecture/persona-file-architecture.md` §5, rows marked `**Gated**`). It is not hardcoded.

**Implication for F1:** when F1 produces the `gawd-export` bundle, the `soul/` directory MUST contain every file that A1 marks as Gated. If A1 adds a new T0 anchor (e.g., `RELATIONS.md`), F1's export must include it and merge.sh will pick it up automatically.

**Implication for E3:** when E3 surfaces a SIL proposal for a T0 anchor, the proposal targets one of the files in A1's gated list. E3 must read A1's list at proposal time, not hardcode.

### 3.2 Adaptive files preserved verbatim (bit-for-bit)

Every file in A's workspace that is NOT in the T0-anchor list is preserved bit-for-bit through the merge. Specifically:

- `USER.md`, `users/`, `MEMORY.md`, `VOICE-ADAPTIVE.md`, `tuning.md`, `memory/`, `skills/learned/`, `sil/` (except `sil/conflicts/<thisrev>.md` which is written fresh)
- Anything else in workspace root, recursively

**Implication for E3:** SIL state files (`workspace/sil/state.json`, `workspace/sil/pending/*.md`) survive a merge unchanged. E3 may rely on this.

**Implication for F1:** the import staging pattern in F1 mirrors merge.sh's pattern (copy adaptive wholesale, overwrite T0 anchors). E3 and F1 may share helpers if useful.

### 3.3 Atomic at session boundary

merge.sh only runs at the 4am Prophit-local boundary, called by check-pending.sh, called by E1's daily-reset.sh. **It is forbidden to invoke merge.sh from a live OpenClaw session.**

**Implication for E3:** SIL proposals for T0-anchor changes get applied via the same atomic boundary if they involve a base-replace flow. Otherwise SIL writes adaptive files directly (no merge needed).

### 3.4 Idempotent

Re-invoking merge.sh with the same inputs (same A, same B, same C, same revelation_version) yields the same output. If `applied: true` is already set for that revelation_version in the state file, merge.sh exits 0 immediately without touching the workspace.

**Implication for E3:** if a session-start hook detects a stuck conflict-report state and re-triggers the merge for diagnostic purposes, the merge will safely no-op.

### 3.5 Conflict report path is stable

If a conflict was surfaced, the report lives at `~/.gawd/workspace/sil/conflicts/<revelation_version>.md`. The filename is exactly the revelation_version (as appears in the state file). Reports persist indefinitely — they are not deleted by future merges (only the prior revelation's stale reports are pruned during build_staging).

**Implication for C1's session-start hook:** scan `~/.gawd/workspace/sil/conflicts/` for files newer than last-session-end timestamp; surface each one once and then mark as "shown" (mechanism TBD by C1).

**Implication for E3:** SIL gate UX may want to render conflict reports as accept/dismiss cards in the desktop UI. The markdown format is structured (header, per-file diff sections) and machine-parseable enough.

---

## 4. Failure-mode contract

| merge.sh exit code | What downstream may assume |
|---|---|
| 0 | Merge applied OR was already applied. State file `applied=true`. Workspace = new. |
| 1 | Argument error. Invocation bug, not a runtime concern. |
| 2 | Input dir missing. Sermon channel broken or bundle path stale. |
| 3 | B failed schema validation. Live workspace untouched. Bundle is bad. |
| 4 | Staged result failed schema validation. Live workspace untouched. |
| 5 | Atomic-rename failed. Workspace may be in an inconsistent state — see runbook §11.3. |
| 6 | `--strict-conflict` and a conflict was detected. Operator-only mode. |

**E3, F1, C1 may rely on:**
- Exit code 0 means it's safe to read the new workspace immediately.
- Non-zero exit means the workspace is either at the prior version (exits 2-4, 6) or potentially broken (exit 5).
- Exit code 5 should trigger an operator page; the others are recoverable via the runbook.

---

## 5. Engine entry points (for F1's symmetric-pattern reuse)

If F1 wants to reuse the atomic-rename + staging pattern (recommended — same shape solves the same problem):

| Helper concept | Where it lives | Notes for F1 reuse |
|---|---|---|
| Staging dir pattern | `~/.gawd.merge-staging/` (sibling of `~/.gawd/`) | F1 uses `~/.gawd.import-staging/` — same sibling pattern |
| Atomic rename | `mv live → previous && mv staging → live` | Identical sequence; F1 may copy the function inline |
| Previous retention | E1's daily-reset.sh prunes after ~24h | F1's previous = `~/.gawd.previous/`; uses the same E1 path |
| Schema validation pre-rename | `validate-schema.sh` from persona-templates | F1 reuses this directly |

We deliberately did **not** factor these into a shared library for v1 — the duplication is small and the failure modes are distinct enough that a shared lib would obscure rather than clarify. Revisit at v1.1 if both grow more complex.

---

## 6. Versioning and stability

This contract is **v1.0**. Breaking changes (renaming files, removing schema fields, changing the conflict-report format) require a corresponding bump in `schema_version` and a coordinated update with E3, F1, and C1.

Additive changes (new optional state-file fields, new exit codes for new failure modes, new conflict-report sections) do NOT require coordination; consumers must tolerate unknown fields.

---

## 7. Open questions surfaced to GawdFather

None blocking. The contract is consumable as-is by E3 and F1.

Possible v1.1 improvements (track but don't block):
- A `--reason` argument to offer.sh that gets included in the Telegram body (operator can attach release notes).
- A `--dry-run` argument to check-pending.sh (parallels merge.sh).
- A daemon-side "conflict-shown" marker file so the session-start hook doesn't surface the same conflict twice.

---

*End of contract. Updated by E2's owner (Metatron) when the engine evolves.*
