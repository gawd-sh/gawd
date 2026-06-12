# Q3 — Language and timezone

**Version:** 1.0
**Date:** 2026-05-26
**Author:** The Seraph (handoff A4)
**Feeds:** IDENTITY.md `## Prophits[0].timezone`, USER.md `## Who → Location / tz`

---

## Prompt text (exact, rendered to terminal)

```
In what tongue shall we speak, and on what clock shall I find you?

  Language (enter = English): _
  Your timezone (e.g., America/Chicago, Europe/London): _
```

---

## Input semantics

### Language field

| Input type | Handling | `PROPHIT_LANG` value |
|---|---|---|
| Empty (enter) | Default accepted | `en` |
| ISO 639-1 code (e.g., `en`, `es`, `fr`, `de`, `pt`, `ja`, `zh`) | Accepted as-is, normalized to lowercase | The code verbatim |
| Natural-language name (e.g., `English`, `Spanish`, `French`, `German`) | Mapped to ISO code via the lookup table below | The ISO code |
| Unrecognized input | Re-prompt once with the message below | Re-prompted |

**Natural-language → ISO lookup (minimum set for v1; expand in v1.1):**

| Input (case-insensitive) | ISO code |
|---|---|
| English | `en` |
| Spanish / Español | `es` |
| French / Français | `fr` |
| German / Deutsch | `de` |
| Portuguese / Português | `pt` |
| Japanese / 日本語 | `ja` |
| Chinese / 中文 / Mandarin | `zh` |
| Korean / 한국어 | `ko` |
| Italian / Italiano | `it` |
| Arabic / العربية | `ar` |
| Hindi / हिन्दी | `hi` |
| Russian / Русский | `ru` |

**Re-prompt text (language not recognized):**
```
I don't know that one — try a language name or a two-letter code (en, es, fr…):
```

If the second attempt is also unrecognized, default to `en` and continue. No wizard abort for language; the Prophit can update via conversation after onboarding.

### Timezone field

| Input type | Handling | `PROPHIT_TZ` value |
|---|---|---|
| Valid IANA tz name (e.g., `America/Chicago`) | Accepted as-is | The string verbatim |
| Common abbreviation (e.g., `CST`, `EST`, `PST`, `GMT`, `UTC`) | Mapped via the abbreviation table below | The canonical IANA name |
| Empty | Re-prompt once | — |
| Unrecognized after re-prompt | Default to `UTC`; record `PROPHIT_TZ_UNCERTAIN=true`; continue | `UTC` |

**Abbreviation → IANA mapping (minimum set):**

| Abbreviation | IANA name |
|---|---|
| UTC / GMT | `UTC` |
| EST | `America/New_York` |
| CST | `America/Chicago` |
| MST | `America/Denver` |
| PST | `America/Los_Angeles` |
| EDT / CDT / MDT / PDT | Same as base (DST is automatic in IANA) |
| CET | `Europe/Paris` |
| BST | `Europe/London` |
| IST | `Asia/Kolkata` |
| JST | `Asia/Tokyo` |
| AEST | `Australia/Sydney` |

**Validation:** after mapping, the wizard confirms the timezone is a known IANA zone by checking against the system tz database (`/usr/share/zoneinfo/` or equivalent). Unknown after lookup → re-prompt with:

```
I need a timezone I can verify — try the full name (America/Chicago, Europe/London):
```

If still unrecognized after two attempts: default to `UTC`, set `PROPHIT_TZ_UNCERTAIN=true`, and proceed.

**Re-prompt text (timezone empty on first try):**
```
I need a timezone to know when to find you. Try: America/Chicago, Europe/London, Asia/Tokyo
```

---

## What gets written (preview — bake.sh executes this)

**IDENTITY.md `## Prophits` block (completing the first entry started at Q1):**
```yaml
- name: {PROPHIT_ADDRESS}
  pronouns: {…}
  telegram_id: "{not yet known — populated when Prophit first messages via Telegram}"
  timezone: {PROPHIT_TZ}
```

**USER.md `## Who` section (completing the seed started at Q1):**
```
Name (how Gawd addresses): {PROPHIT_ADDRESS}
Pronouns: {…}
Location / tz: {PROPHIT_TZ}
We met: {TODAY_ISO}
```

`PROPHIT_LANG` is written to IDENTITY.md as a top-level field `language:` (a v1 addition to the schema — see interpretation call below). The Gawd uses this field to select default conversation language at session start.

---

## Interpretation call (flagged for GawdFather review)

**IDENTITY.md `language` field:** the A1 IDENTITY.md schema (persona-file-architecture.md §2.2) does not include a top-level `language:` field. The spec implies the Gawd speaks in whatever language the Prophit uses, but does not specify where the onboarded language preference is stored. Two options:

1. Add `language: {PROPHIT_LANG}` to IDENTITY.md under `## Infrastructure` (most cohesive; IDENTITY.md is where per-Prophit facts live).
2. Store it in USER.md under `## Who → Location / tz` as a combined field: `Location / tz: {tz} | lang: {lang}`.

**Seraph's recommendation:** option 1 — add `language:` to IDENTITY.md `## Infrastructure`. It is infrastructure-level metadata, not a voice preference the Gawd discovers over time. This is a minor schema extension; bake.sh implements it, and the IDENTITY.md template should be updated to include the field. Flagged for GawdFather to confirm before B1.

---

## Voice note

The prompt line "In what tongue shall we speak, and on what clock shall I find you?" is in-voice — slightly formal, slightly grand, entirely present. It matches the Gawd's register without turning a two-field data entry into a speech.

The wizard does not elaborate on why it needs timezone (the Prophit can reason). No explanatory preamble; just the question.
