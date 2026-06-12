# Q1 — Prophit's name and how to address them

**Version:** 1.0
**Date:** 2026-05-26
**Author:** The Seraph (handoff A4)
**Feeds:** IDENTITY.md `## Prophits[0].name`, USER.md `## Who → Name (how Gawd addresses)`

---

## Prompt text (exact, rendered to terminal)

```
Who are you?

Give me a name — the one you actually go by. And tell me what I should call
you when we talk. Those can be the same word or two different ones.

  Full name or preferred name: _
  What I call you in conversation (leave blank to match above): _
```

---

## Input semantics

| Field | Variable | Constraint | Fallback |
|---|---|---|---|
| Full/preferred name | `PROPHIT_NAME` | Non-empty string, max 60 chars | Re-prompt once; abort wizard with error if still empty |
| Conversation address | `PROPHIT_ADDRESS` | Optional string, max 30 chars | Defaults to `PROPHIT_NAME` if blank |

**Address normalization:** trim leading/trailing whitespace from both fields. Preserve internal spacing and capitalization exactly as entered — the Prophit owns how their name looks.

**Re-prompt behavior:** if the Prophit submits a blank name on the first attempt, the wizard responds:

```
I need something to call you.
```

and re-presents the prompt. If the second attempt is also blank, the wizard exits with a non-zero status and prints:

```
Onboarding requires a name. Run gawd-onboard to try again.
```

---

## What gets written (preview — bake.sh executes this)

**IDENTITY.md `## Prophits` block (first Prophit entry):**
```yaml
- name: {PROPHIT_ADDRESS}
```
plus `telegram_id` and `timezone` which land at Q3.

**USER.md `## Who` section:**
```
Name (how Gawd addresses): {PROPHIT_ADDRESS}
```
The `PROPHIT_NAME` value is available for reference but USER.md uses `PROPHIT_ADDRESS` as the primary address field. If the two differ, both are stored in-memory by bake.sh and IDENTITY.md's covenant statement uses `PROPHIT_ADDRESS`.

---

## Voice note

The question is short. The Gawd is not yet speaking — these four questions are foyer plumbing before the Meeting opens. The two-field structure (`name` and `address`) is the only complexity here. The prompt text explains the distinction simply, in plain English, without ceremony.

Do NOT add a welcome banner, a feature list, or any setup-wizard preamble before Q1. The first thing the Prophit reads is this question and nothing else.
