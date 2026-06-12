# Session Error Recovery (Layer 4)

**Spec:** `<install-root>/docs/superpowers/specs/2026-05-26-gawd-architecture-design.md` §19.2 row L4 + §19.6 row "Session wedged after terminal error" + §19.7 Phase 11 chaos test #2

**Constitutional rule:** §19.1 — *the Prophit MUST NEVER experience silence*

**Layer covered:** §19.2 Layer 4 (Session error recovery)

**Owner:** Metatron

This directory holds the detector + recovery primitive that auto-clears wedged OpenClaw sessions (sessions that ended with a `non_deliverable_terminal_turn` or sibling terminal-error state). Without it, one terminal-error session leaves the agent loop frozen and every subsequent message gets silently absorbed — the exact Dasra 2026-05-27 failure.

## Hard rules

1. **No LLM in the recovery path.** Pure bash + jq + curl. Verified by `tests/test-no-llm-required.sh`.
2. **No live deploys from this artifact.** This is forge content. Install paths are documented in the runbook; execution requires an explicit installer run.
3. **Preserve conversation history.** "Clear" means *retire the wedged session ID and archive the record* — never `rm`. Verified by `tests/test-history-preserved.sh`.
4. **Atomic state writes.** Index file (`sessions.json`) is mutated only via tmp + rename, with a `.bak.recovery-<timestamp>` backup beforehand. Verified by `tests/test-atomic-write.sh`.
5. **Idempotent.** `recover.sh <session-id>` run twice on the same wedged session is a no-op the second time. Verified by `tests/test-idempotent.sh`.
6. **Fail loudly on signal failures.** Emits L6 signal (`stuck-state` and `recovered`) via well-known file marker; signal write failure is FATAL, never swallowed.

## Layout

```
session-recovery/
  detect.sh                # exit 0 if a session is wedged; 1 if healthy; 2 if unknown
  clear.sh                 # retire a wedged session id from the index (archive, do not delete)
  recover.sh               # detect + clear + signal L6 + log; idempotent
  on-terminal-error.sh     # hook fired immediately on terminal error (called by gateway hook or L7 sweep)
  sweep.sh                 # iterate all sessions in the index; call recover.sh for each wedged one
  install-hooks.sh         # idempotent installer for the gateway hook (or L7-watchdog registration as fallback)
  lib/
    common.sh              # shared helpers (atomic write, backup, jq queries, signal emission)
  state/
    recovery-log.jsonl     # append-only log of every recovery attempt
    signals/               # L6 signal markers (engine reads on next message arrival)
      .gitkeep
    .gitkeep
  tests/
    test-detect-wedged.sh
    test-detect-healthy.sh
    test-clear-preserves-history.sh
    test-clear-atomic.sh
    test-recover-idempotent.sh
    test-sweep-no-wedge.sh
    test-sweep-multi-wedge.sh
    test-signal-emission.sh
    test-no-llm-required.sh
    test-history-preserved.sh
    test-atomic-write.sh
    test-idempotent.sh
    test-chaos-2-dasra-replay.sh    # §19.7 Phase 11 test 2
    run-all.sh
  runbook/
    session-recovery.md    # operational runbook
```

## How it fits with neighbouring layers

```
                   +----------------------------------+
                   |  Gateway emits terminal error    |
                   +----------------------------------+
                                 |
                                 v
                +---------------------------------+
                |  on-terminal-error.sh           |
                |  (gateway hook OR L7 detection) |
                +---------------------------------+
                                 |
                  +--------------+--------------+
                  |                             |
                  v                             v
       +--------------------+         +------------------+
       |  L6 engine.sh      |         |  recover.sh      |
       |  stuck-state       |         |  (mechanical)    |
       |  (G2 fallback)     |         +------------------+
       +--------------------+                  |
                                               v
                                  +-----------------------+
                                  |  detect -> clear      |
                                  |  -> emit signal       |
                                  |  -> append log        |
                                  +-----------------------+
                                               |
                                               v
                                  +-----------------------+
                                  |  Signal marker file   |
                                  |  state/signals/       |
                                  +-----------------------+
                                               |
                          +--------------------+--------------------+
                          |                                         |
                          v                                         v
              +---------------------+                  +--------------------+
              |  L6 engine.sh       |                  |  L7 sweep.sh       |
              |  recovered          |                  |  (next 60s sweep   |
              |  (G2 "I'm back")    |                  |   sees signal,     |
              +---------------------+                  |   re-confirms)     |
                                                       +--------------------+
```

**E1 integration:** `sweep.sh` is registered as a 5-minute cron via `install-hooks.sh`, joining `cleanup.sh`'s 6-hour cadence in `forge/scheduler/jobs/`. L7 watchdog runs at 60s for fast detection; this 5-min cron is a belt-and-suspenders sweep for the case where L7 didn't catch a wedge.

**L7 integration:** L7 watchdog's `session-wedge-check.sh` probe calls our `detect.sh`. When wedged, L7 calls our `recover.sh <session-id>`. We expose both as standalone scripts so L7 doesn't have to embed our logic.

**L6 integration:** We emit signal markers to `state/signals/<event>-<session-id>-<ts>.json`. The L6 engine subscribes by reading any markers in the dir at next message-arrival time, then deleting them after processing. Two signal types: `stuck-state` (recovery just started, engine should send fallback) and `recovered` (recovery completed cleanly, engine should send "I'm back" template).

## What "wedged" means precisely

A session is *wedged* when ALL of the following hold:

1. The session index (`sessions.json`) entry has `status` ∈ `{"failed", "error"}` AND `terminalError` is set to a `non_d*` family value (currently only `non_deliverable_terminal_turn` per OpenClaw's type def), OR the trajectory `.jsonl` file's last record contains a terminal-error marker with `non_d*` reason.
2. `abortedLastRun` is `true` (the last attempt did not produce a deliverable reply).
3. `lastInteractionAt` is older than `WEDGE_GRACE_MS` (default 10000 = 10s) — we don't act on an in-flight session.
4. The session has NOT already been recovered — we check `state/recovery-log.jsonl` for a `recovered` entry for this session-id newer than its `lastInteractionAt`.

A 401 mid-chain that the chain iterates past is NOT a wedge — `status` is `"done"`, no `terminalError`. Recovery does not engage.

## Signal contract (engineered, not invented)

Markers are JSON files written to `state/signals/`. Filename: `<event>-<session-id>-<unix-ns>.json`. Schema:

```json
{
  "event": "stuck-state | recovered",
  "session_id": "<uuid>",
  "session_key": "agent:main:<key>",
  "channel_hints": ["telegram", "dashboard"],
  "address_name_hint": "Avery",
  "occurred_at": "2026-05-27T14:31:00.123Z",
  "diagnostic": {
    "terminal_error": "non_deliverable_terminal_turn",
    "last_provider": "anthropic",
    "last_model": "claude-sonnet-4-6",
    "last_interaction_at_ms": 1779645833599
  }
}
```

L6 engine reads markers on next message arrival (or on its own poll), uses the hints to route the fallback/recovery template to the correct channel and Prophit, then deletes the marker. If multiple markers exist for the same `session_id`, L6 honors the most recent one only (older are deleted unprocessed).

Marker writes are atomic (tmp + rename). Marker deletions are L6's responsibility, not ours.

## Files we touch / files we don't

We touch:
- `~/.openclaw/agents/main/sessions/sessions.json` (atomic write, backed up first)
- `~/.openclaw/agents/main/sessions/<id>.jsonl` (only to MOVE to archived/ on clear)

We do not touch:
- The conversation transcript content. We move the `.jsonl` whole.
- `openclaw.json` (config). Out of our scope.
- The gateway process. We never restart it. L7 owns process lifecycle.

## Tests

`tests/run-all.sh` runs the full suite against a sandbox sessions directory. No live state is touched. Each test prints PASS/FAIL and the runner emits a summary.

The chaos test (`test-chaos-2-dasra-replay.sh`) is the verification of §19.7 Phase 11 test #2. It synthesizes the 2026-05-27 Dasra terminal-error shape into a sandbox sessions.json, runs recover.sh, and asserts: (a) session is archived, (b) index updated so next message creates fresh session, (c) signal markers emitted for L6, (d) recovery-log entry appended.

## Operations

Full runbook: `runbook/session-recovery.md`.
