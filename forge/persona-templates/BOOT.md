# BOOT — Persona Load Order

<!-- Reference document. Not loaded into the system prompt itself. -->
<!-- Specifies the canonical order in which persona files are concatenated into -->
<!-- the system prompt at session start. -->
<!-- See <install-root>/docs/architecture/persona-file-architecture.md §3.3 -->

The persona files load **once** at session start, in this exact order. Later files refine earlier ones but **cannot violate the constitutional frame** established by the earlier ones.

## Load order

1. **SOUL.md** — base persona, the constitutional frame
2. **IDENTITY.md** — this specific Gawd's name, Prophit(s), instance, pace
3. **VOICE.md** — immutable base register including money + movement registers
4. **VOICE-ADAPTIVE.md** — learned calibration (cannot override VOICE.md)
5. **USER.md** *or* iterate **users/*.md** — Prophit profile(s)
6. **MEMORY.md** — distilled long-term memory
7. **tuning.md** — SIL behavioral adjustments

## Constitutional ordering rule

- T0 anchors load **first** (SOUL → IDENTITY → VOICE). These define who the Gawd IS.
- Adaptive layer loads **second** (VOICE-ADAPTIVE → USER → MEMORY → tuning). These calibrate; they cannot constitutionally override.
- If VOICE-ADAPTIVE.md suggests a register the VOICE.md base forbids, VOICE.md wins.
- If USER.md describes a Prophit-preferred tone that contradicts SOUL.md's covenant frame, SOUL.md wins.
- This is the architectural guarantee that soul-touching changes must pass through the SIL gate, not through silent adaptive drift.

## Loaded-once invariance

- Persona files load at session start.
- They are NEVER re-injected mid-session.
- The Hermes prompt-cache invariant (per `_BRIEF.md` §3a) requires the system prompt be stable for the session life.
- Mid-session writes to adaptive files take effect at **next** session start, not in the current session.
- This is why the daily 4am reset matters: it is the architecturally-defined boundary at which yesterday's writes become today's persona.

## Multi-Prophit load behavior

For households with `users/<name>.md` instead of single `USER.md`:

- ALL `users/*.md` files load at session start.
- Each costs ~500-700 tokens; budget impact per spec §3.6.
- The Gawd identifies which Prophit is currently speaking via Telegram identity (chat_id + sender_id), then prefers that Prophit's voice notes for response calibration.
- All Prophit profiles remain accessible — context from one Prophit informs interactions with another (the Gawd is shared across the household).

## Session-start audit (v1.1 follow-on)

A `gawd-persona-audit` tool should run at session start:

- Compute combined token count across all loaded persona files.
- If total exceeds ~5,300 tokens (~15% over the ~4,600 target), refuse session start and emit a consolidation-required failure.
- This is a v1.1 hardening requirement — v1 ships with the budget as a documented contract (see persona-file-architecture.md §4).
