# Runbook: Session Error Recovery (Layer 4)

**Layer:** §19.2 Layer 4 (Session error recovery)
**Sub-phase:** G4
**Owner:** Metatron (design), Archon (install on substrate)
**Source spec:** `<install-root>/docs/superpowers/specs/2026-05-26-gawd-architecture-design.md` §19.1, §19.2, §19.6, §19.7

This runbook explains how Layer 4 works in practice: what a wedge looks like, what recovery does, how to inspect a recovery after the fact, when to intervene manually, and how to roll back if recovery corrupts state.

---

## 1. What a wedge looks like

A wedged session has all four of the following:

| Signal | Where to look | Example |
|---|---|---|
| `status` ∈ {failed, error} | `sessions.json[key].status` | `"failed"` |
| `terminalError` matches `non_d*` | `sessions.json[key].terminalError` | `"non_deliverable_terminal_turn"` |
| `abortedLastRun = true` | `sessions.json[key].abortedLastRun` | `true` |
| `lastInteractionAt` is older than the 10s grace window | `sessions.json[key].lastInteractionAt` | epoch ms more than 10s old |

A 401 mid-chain that the chain iterated past is **not** a wedge: `status` is `"done"` and there is no terminal error. This is the post-G1-fix shape and recovery never engages on it.

### Verifying a wedge by hand

```bash
key='agent:main:main'
jq --arg k "$key" '.[$k]' ~/.openclaw/agents/main/sessions/sessions.json
```

Look for the four signals above.

---

## 2. The recovery flow

```
┌───────────────────────────┐
│ Gateway emits terminal     │
│ error (non_d* family)      │
└──────────┬────────────────┘
           │
           ▼
┌───────────────────────────┐  Step A (within ~5s)
│ on-terminal-error.sh       │─── Emits `stuck-state` signal marker.
│ (called by gateway hook    │    L6 engine reads marker and sends the
│  OR by L7 watchdog OR by   │    static "I'm hiccuping..." Telegram
│  recover.sh)               │    fallback to the Prophit.
└──────────┬────────────────┘
           │
           ▼
┌───────────────────────────┐  Step B (within 60s of wedge)
│ L7 watchdog OR sweep cron  │─── Detects the wedge via detect.sh.
└──────────┬────────────────┘
           │
           ▼
┌───────────────────────────┐  Step C (≤ 60s)
│ recover.sh                 │─── Backs up sessions.json,
│  ├─ detect (re-verify)     │    removes the wedged key,
│  ├─ clear (mutate index)   │    moves trajectory to archive/error-sessions/,
│  ├─ archive trajectory     │    emits `recovered` signal,
│  ├─ emit `recovered`       │    appends to recovery-log.jsonl.
│  └─ append recovery-log    │
└──────────┬────────────────┘
           │
           ▼
┌───────────────────────────┐  Step D (next inbound message)
│ Next message arrives       │─── OpenClaw allocates a fresh session
│                            │    ID for the key (because the entry
│                            │    is no longer in sessions.json).
└──────────┬────────────────┘
           │
           ▼
┌───────────────────────────┐  Step E (after first successful reply)
│ L6 engine reads             │─── Sends "I'm back" recovered template
│ `recovered` signal,         │    via Gawd's voice register.
│ delivers, deletes marker    │
└────────────────────────────┘
```

**Latency targets:**
- Static fallback: ≤ 30 seconds from wedge (spec §19.1).
- Auto-clear: ≤ 60 seconds from wedge (spec §19.7 test #2).

---

## 3. File layout

```
~/.openclaw/agents/main/sessions/
  sessions.json                              # the index (we mutate this)
  <sid>.jsonl                                # active transcripts
  archived/
    error-sessions/
      <sid>.jsonl.recovered.<ts>             # transcripts moved here on clear

~/.gawd/state/session-recovery/
  recovery-log.jsonl                         # append-only history of every recovery
  signals/
    stuck-state-<sid>-<unix-ns>.json         # emitted by on-terminal-error.sh
    recovered-<sid>-<unix-ns>.json           # emitted by recover.sh

/usr/local/lib/gawd/silence-avoidance/session-recovery/
  detect.sh
  clear.sh
  recover.sh
  on-terminal-error.sh
  sweep.sh
  install-hooks.sh
  lib/common.sh
  tests/run-all.sh
  runbook/session-recovery.md   (this file)
```

The forge directory is where the source lives. Install paths on a deployed Gawd may differ; the install path is documented in the daemon's install.sh (forthcoming, §10).

---

## 4. Operator commands

### Detect a wedge

```bash
# By session UUID
./detect.sh --session-id 07f811ba-...
# By session key
./detect.sh --session-key agent:main:main
# Scan whole index, list first wedged (or all)
./detect.sh --any
./detect.sh --all
```

Exit code: 0 wedged, 1 healthy, 2 unknown.

### Recover a single wedge

```bash
./recover.sh --session-id 07f811ba-...
# or
./recover.sh --session-key agent:main:main
```

Force recovery (skip wedge re-check — use with care, intended only for
internal callers that have already verified):

```bash
./recover.sh --session-key agent:main:main --force
```

Dry-run (explain, touch nothing):

```bash
./recover.sh --session-key agent:main:main --dry-run
```

### Sweep all wedges

```bash
./sweep.sh                # process every wedged session
./sweep.sh --report-only  # list, do not act
./sweep.sh --dry-run      # show planned actions; touch nothing
./sweep.sh --max 5        # stop after 5 recoveries
```

### Install / uninstall the sweep cron

```bash
./install-hooks.sh                  # auto-detect mode (prefers forge scheduler)
./install-hooks.sh --mode systemd   # standalone systemd user timer
./install-hooks.sh --mode cron      # standalone crontab entry
./install-hooks.sh --uninstall      # reverse it
./install-hooks.sh --dry-run        # show plan
```

The installer chmods every script in this directory and registers the
5-minute sweep cron. Idempotent — safe to re-run.

---

## 5. Inspecting a past recovery

The recovery log is at `~/.gawd/state/session-recovery/recovery-log.jsonl`,
one JSON object per line.

```bash
# All entries for a specific session
grep '"07f811ba-..."' ~/.gawd/state/session-recovery/recovery-log.jsonl | jq

# Just the recovered/ok entries
jq -c 'select(.action == "recovered" and .outcome == "ok")' \
   ~/.gawd/state/session-recovery/recovery-log.jsonl

# Today's recoveries
jq -c --arg t "$(date -u +%Y-%m-%d)" \
   'select(.ts | startswith($t))' \
   ~/.gawd/state/session-recovery/recovery-log.jsonl
```

Each entry has:
- `ts` — ISO 8601 UTC timestamp
- `session_id`, `session_key`
- `action` — `detected | cleared | recovered | skipped | failed | stuck-state-signaled`
- `outcome` — `ok | error | noop | refused`
- additional context (`diagnostic`, `last_interaction_at_ms`, `reason`, etc.)

---

## 6. When to intervene manually

The recovery loop is designed to be hands-off. Manual intervention is
called for in three scenarios:

### 6.1 Recovery is refused (`outcome=refused`)

The session was not classified as wedged. Inspect the index entry by
hand:

```bash
jq --arg k 'agent:main:main' '.[$k]' \
   ~/.openclaw/agents/main/sessions/sessions.json
```

If the operator believes recovery should still run (e.g., the heuristic
missed a rare wedge shape), force-recover:

```bash
./recover.sh --session-key agent:main:main --force
```

This skips the wedge re-check but still backs up first.

### 6.2 Recovery failed (`outcome=error`)

The log records `phase` showing which step failed:
- `index-mutation` — the JSON mutation could not be applied. Check that
  `sessions.json` is valid JSON and disk has space.
- `signal-recovered` — the signal marker could not be written. Check
  `~/.gawd/state/session-recovery/signals/` exists and is writable.
- `clear:rc=N` — the child `clear.sh` returned non-zero. Re-run with
  `--dry-run` to see what it would attempt.

If recovery cannot complete, **stop the gateway, hand-edit the index, and
restart**:

```bash
# Stop the gateway (per-machine; example for zoos on Pleroma)
systemctl --user stop openclaw-gateway

# Back up
cp ~/.openclaw/agents/main/sessions/sessions.json \
   ~/.openclaw/agents/main/sessions/sessions.json.manual.bak

# Hand-edit (or use jq) to remove the offending key
jq 'del(.["agent:main:main"])' \
   ~/.openclaw/agents/main/sessions/sessions.json.manual.bak \
   > ~/.openclaw/agents/main/sessions/sessions.json

# Restart
systemctl --user start openclaw-gateway
```

### 6.3 The signal marker dir is full of unprocessed markers

If L6 engine is itself wedged or not running, signal markers will
accumulate at `~/.gawd/state/session-recovery/signals/`. After repairing
L6, the markers can be replayed manually or simply deleted (the
recovery itself already happened — markers are for delivery
prompting, not state):

```bash
# Replay: invoke L6 engine for each marker (channel + prophit hints
# are in the marker payload).
# Delete: rm ~/.gawd/state/session-recovery/signals/recovered-*.json
```

---

## 7. Rolling back a recovery

Every mutation of `sessions.json` is preceded by a backup at
`sessions.json.bak.recovery-<ts>` in the same directory. To roll back:

```bash
cd ~/.openclaw/agents/main/sessions

# Find the most recent recovery backup
ls -t sessions.json.bak.recovery-* | head -n 1

# Stop the gateway first (avoid mid-flight write conflicts)
systemctl --user stop openclaw-gateway

# Restore
cp sessions.json.bak.recovery-<ts> sessions.json

# Restore the trajectory from archive (if you also want to undo that move)
cd archived/error-sessions
cp <sid>.jsonl.recovered.<ts> ../../<sid>.jsonl

# Restart gateway
systemctl --user start openclaw-gateway
```

After rolling back, the original wedged session is restored. The
recovery-log.jsonl entries remain (append-only); add a note to the log
manually if rollback should be visible to future readers:

```bash
echo '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","action":"rolled-back","note":"manual rollback by operator"}' \
    >> ~/.gawd/state/session-recovery/recovery-log.jsonl
```

---

## 8. Edge cases and known caveats

### 8.1 Gateway running during clear

The OpenClaw gospel says "do not edit sessions.json while the gateway is
running." `clear.sh` honors this in spirit by using tmp+rename atomic
writes — the gateway either sees the old index or the new index, never
a half-written file. However, if the gateway is mid-write itself
(unlikely; reads are far more common), there is a theoretical lost-write
window. Operators may stop the gateway before manual `clear.sh`
invocations for absolute safety; sweep-cron-driven clears accept the
small theoretical risk because the mutation is one targeted key removal
and the index is immediately re-readable.

### 8.2 Sessions with no trajectory file

OpenClaw normally writes `<sid>.jsonl` and `<sid>.trajectory.jsonl`. If
the trajectory file is missing (e.g., the gateway crashed before
writing), `clear.sh` proceeds without archiving. The recovery-log
records this as a partial-archive warning, not an error.

### 8.3 Recovery races with a successful reply

If the chain recovers (G1 fix kicks in for a previously-suspect provider)
between the wedge detection and the `clear.sh` execution, `clear.sh`'s
re-verification will see `status=done` and refuse. This is by design — a
sudden recovery in the runtime is preferable to our retirement. The
recovery-log records `outcome=refused reason=not-wedged`.

### 8.4 OpenClaw renaming/migration

If a future OpenClaw release changes the sessions.json schema, the
`sr_is_session_wedged_by_key` function in `lib/common.sh` is the single
point of update. The wedge definition lives there; everything else
delegates.

### 8.5 The 10-second grace window

By default, sessions whose `lastInteractionAt` is within 10s of "now"
are not classified as wedged — they may be a retry in flight. Override
via `SR_WEDGE_GRACE_MS` if a faster reaction is needed (or via env var
in the unit file).

---

## 9. Coordination with other layers

| Layer | Relation |
|---|---|
| **L2 (G1)** — chain `next=none` fix | Without G1, every chain failure leaves a wedge. With G1 fixed, only genuine terminal errors trigger us. |
| **L6 (G2)** — fallback engine | We emit signals; L6 reads them at next message-arrival time. Engine sends the "I'm hiccuping..." (stuck-state) and "I'm back" (recovered) templates. |
| **L7 (G5)** — healing watchdog cron | L7 fires every 60s. Its `session-wedge-check.sh` probe calls our `detect.sh`; on detection, L7 calls our `recover.sh`. We are L7's recovery primitive. |
| **E1 (cadence/scheduler)** — cron infrastructure | Our `install-hooks.sh` registers a 5-minute sweep cron with E1 when present; standalone systemd user timer when E1 is not yet installed. |

---

## 10. Install/deploy status

This artifact is forge content. It has not been live-deployed. To
install on a substrate:

1. Copy `/usr/local/lib/gawd/silence-avoidance/session-recovery/`
   into the substrate's forge tree (the daemon install.sh handles this
   in production; for hand-installs, `rsync -a` is the right tool).
2. Run `./install-hooks.sh` as the Gawd user. The installer is
   idempotent.
3. Verify: `./tests/run-all.sh` should be `ALL GREEN`.
4. Verify the sweep is enabled:
   - Systemd: `systemctl --user list-timers gawd-session-recovery-sweep.timer`
   - Cron: `crontab -l | grep session-recovery`
   - Forge scheduler: `ls /usr/local/lib/gawd/scheduler/jobs/session-recovery-sweep.sh`

Until install happens, L7 watchdog + manual `recover.sh` invocations are
the recovery path.

---

## 11. Telegrams of triumph

When recovery succeeds, the L6 engine sends the `recovered` template to
the Prophit via the active channel. Operators should never have to send
manual Telegrams to explain a recovery — but if a recovery is partial
(signal emitted, delivery failed), they may. The fallback templates are
at `/usr/local/lib/gawd/silence-avoidance/templates/telegram-recovered.md`.

---

*End of runbook.*
