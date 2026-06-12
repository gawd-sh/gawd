# Project Status

> Gawd is an early open-source AI-companion daemon. The core — a personalized, persistent presence over chat — works today. The safety-enforcement layer, self-update, and add-on capabilities are designed and in progress; this document marks clearly what is live versus what is planned.

This document is kept honest deliberately. If it says "works today," a fresh install can reproduce it. If it says "on the roadmap," no code exists yet, or the code exists but is not wired in a way that makes the claim true end-to-end.

---

## Works today

| Capability | Notes |
|---|---|
| Daemon over Telegram | Always-on bot responds in your messenger. |
| Web dashboard | Local dashboard accessible on your machine while the daemon runs. |
| Fixed personality and register | The personality does not drift between sessions or across reinstalls. The Covenant anchors it at the prompt layer on every startup. |
| Model-agnostic configuration | Swap LLM providers by changing one value in the daemon config (`~/.openclaw/openclaw.json`). Supports any OpenAI-compatible endpoint; exercised in development with MiniMax, DeepSeek, Kimi, Gemini, Anthropic, and Ollama (local models). |
| At-rest secret encryption | Secrets stored in an `age`-encrypted local vault. The `secrets` helper manages vault access. |
| Onboarding Meeting | A one-time onboarding conversation that personalizes Gawd's character to you. Optional — Gawd is functional without it. |
| Covenant of Restraint | Eight written vows loaded into every session defining what Gawd will not do. See [COVENANT.md](COVENANT.md). |
| install.sh | One-command setup: installs `age`, provisions the `~/.secrets/` vault, generates your encryption key, installs the `secrets` helper, and captures the admin chat ID for watchdog alerts. |
| Graduation-gated releases | Every release must pass a 12-assertion suite before it ships. Ten assertions are deterministically graded by substring match; the two register-quality assertions are graded by an independent LLM judge — a different provider from the model under test, fail-closed on judge error, with an offline determinism probe validating the judge before it counts. Pass threshold: ≥80% median over 5 serial runs, both modes. Current release (v1, MiniMax as model-under-test): gateway-mode median 91.7%, direct-mode median 83.3% — full per-release gate results, including the exact run distributions and the provider scored, are published with each release. |
| amd64 Linux support | The pre-built image runs on amd64 Linux. |

---

## Designed / on the roadmap

| Capability | Status |
|---|---|
| **OS-level Covenant enforcement** | Designed. The hard enforcement layer — privilege separation (uid-separated processes), a credential broker that prevents the agent process from ever holding a plaintext key, delete-tombstoning, and a reaper that terminates the agent on Covenant breach — is fully specified and buildable-now on Linux. Not yet built. Until it is, the Covenant's vows bind at the prompt layer for a willing model. See [SECURITY.md](SECURITY.md). |
| **arm64 / Apple Silicon support** | The arm64 daemon image is built and validated. The multi-architecture manifest and GHCR publication are pending a credential setup step. |
| **Voice and email add-ons** | Designed as a capability socket — Gawd's architecture has a defined extension point for BYO voice (your ElevenLabs key, your self-hosted TTS) and BYO email (a reply-to relay you provide). No socket code in the base daemon yet. |
| **Self-update / Resurrection Sunday** | The weekly release cadence is the intent and the lore — Resurrection Sunday as a public, visible release rhythm. The autonomous update channel that would let an installed Gawd receive those releases is greenfield; it does not exist. An installed Gawd does not self-update today. |
| **In-field self-improvement (SIL sharpen)** | The human-in-the-loop machinery ships: a Gawd can draft proposals to evolve its own `SOUL.md`/`IDENTITY.md`/`VOICE.md`, surface them to you on Telegram, and apply them **only on your approval** (signed, schema-validated, budget-capped — never a silent self-edit). What is roadmap: the automatic proposer that drafts those proposals from observed interactions (a stub at first ship), and the eval-scored loop that would grade proposed changes against the fixed-test-suite before surfacing them. So today this is **human-curated soul evolution**, not autonomous self-tuning. The fixed-test-suite eval currently gates *releases* (see "Works today"), not in-field learning. |
| **Gawd Doctor** | A diagnostic command (`gawd doctor`) that prints system state for bug reports. Designed, not yet built. |
| **Tithe / economy / relics** | Optional donation mechanics and cosmetic collectibles. Designed, not in scope for v1. Will never gate capability — the Covenant's vow against paywalling applies unconditionally. |

---

*Last updated: 2026-06-09. This document is updated with each release.*
