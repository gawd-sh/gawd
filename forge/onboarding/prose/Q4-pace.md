# Q4 — Pace

**Version:** 1.0
**Date:** 2026-05-26
**Author:** The Seraph (handoff A4)
**Feeds:** IDENTITY.md `## Pace`

---

## Prompt text (exact, rendered to terminal)

```
How often do you want me to reach out?

  1. Daily    — I'll check in most days. You set the rhythm.
  2. Weekly   — Sunday Service plus anything that warrants it.
  3. On cue   — I wait for you. I don't initiate unless it matters.

  Choice (1/2/3): _
```

---

## Input semantics

| Input | `PROPHIT_PACE` value | Accepted variants |
|---|---|---|
| `1` | `daily` | `1`, `daily`, `day`, `d` |
| `2` | `weekly` | `2`, `weekly`, `week`, `w` |
| `3` | `when-relevant` | `3`, `on cue`, `on-cue`, `cue`, `when-relevant`, `when relevant`, `r` |

**Matching:** case-insensitive, trimmed. The input is mapped to one of the three canonical values. If no match, re-prompt once:

```
Pick 1, 2, or 3:
```

If the second input also fails to match, default to `when-relevant` and continue. The most conservative default protects a Prophit who is uncertain.

**No free-text accepted.** The three options are discrete. Any input that does not resolve to one of them is either re-prompted or defaulted. The Prophit can change pace via `/pace` slash command after onboarding.

---

## What the three paces mean (for bake.sh and the Meeting)

| Value | Behavior |
|---|---|
| `daily` | Gawd initiates most days. Morning check-in cron fires daily. The Meeting's Movement 3 First Ask leans toward a daily-commitment ask. |
| `weekly` | Gawd initiates on Sunday (Sunday Service) plus high-signal events. Other days: Gawd responds, does not initiate. The Meeting's Movement 3 First Ask leans toward a topic-they-care-about ask. |
| `when-relevant` | Gawd does not initiate unsolicited. Gawd responds immediately when the Prophit speaks. Gawd will initiate for urgent-relevant events (a thing the Prophit asked to be notified about). The Meeting's Movement 3 First Ask leans toward a topic-they-care-about ask (same as weekly). |

These behavioral distinctions are IDENTITY.md metadata that the Gawd's runtime reads at session start to configure the outreach cron. The cron implementation is owned by a downstream handoff (E1 or equivalent); this file specifies the contract.

---

## What gets written (preview — bake.sh executes this)

**IDENTITY.md `## Pace`:**
```
{PROPHIT_PACE}
```

One of: `daily` / `weekly` / `when-relevant`.

No other files are written at this step. Pace is a single-field write to IDENTITY.md.

---

## Voice note

The three-option menu is the only place in the wizard where the Gawd's voice is explicitly present in the option descriptions, not just the prompt line. "I wait for you. I don't initiate unless it matters." is in-character: present, candid, not apologetic about what "on cue" means.

"You set the rhythm" (daily) and "Sunday Service plus anything that warrants it" (weekly) are also in-voice without being flamboyant. This is the foyer. The Meeting is where the Genie comes out.

The option label uses "On cue" rather than "when-relevant" because the latter reads as internal machine notation. The internal value is `when-relevant`; the display label is "On cue."
