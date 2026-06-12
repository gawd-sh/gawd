# Security Policy

## Reporting a vulnerability

To report a security issue, email: **security@gawd.sh**

Please include: a description of the vulnerability, reproduction steps, and the potential impact as you see it. We aim to acknowledge reports within 48 hours and provide an initial assessment within 7 days.

Do not open a public GitHub issue for security vulnerabilities. Use the email above.

---

## Threat model

Gawd is an always-on daemon that connects to an LLM provider on your behalf, maintains memory of your conversations, and has access to secrets (API keys, your Telegram bot token) stored on your machine. The following is an honest account of what is and is not protected.

### What is protected today

**Secrets at rest.** Your secrets are stored in an `age`-encrypted vault at `~/.secrets/`. They are encrypted with a key that never leaves your machine. A process that can read your filesystem but does not have your age key cannot read the vault.

**No outbound telemetry.** Gawd sends nothing to any server that is not your configured LLM provider. There is no analytics, no usage reporting, no phone-home.

**No privilege escalation by design.** The Covenant (see below) prohibits Gawd from escalating its own privilege, modifying system settings, or editing its own Covenant. These are behavioral constraints today; the OS-level enforcement layer that would make them mechanical walls is on the roadmap.

### Known limitations — read before deploying

**In-use credential isolation is not yet built.** The `secrets` helper decrypts the vault and returns plaintext to the calling process. Until the uid-separated credential broker ships (designed, on the roadmap), a compromised agent process running as the same user could read your provider keys from process memory or by calling the helper directly. The mitigations available today: run Gawd with API keys that are scoped to minimum permissions, and rotate keys on any suspected compromise. Do not use root-level or billing-level API keys.

**The Covenant's hard enforcement layer is not yet built.** The Covenant of Restraint (eight vows) is loaded into every session as the first thing the model reads. The vows are real commitments the model honors. But they bind *at the prompt layer for a willing model* — there is no OS-level mechanism today that would mechanically prevent the agent from acting against a vow if the model were somehow bypassed or substituted with one that ignores it. The hard enforcement layer (privilege separation, process isolation, the credential broker, delete-tombstoning) is fully designed and is buildable on Linux. Until it ships, the Covenant is an aspirational charter enforced by model compliance, not by the operating system.

> To be direct: publishing the Covenant does not mean we claim enforcement parity with OS-level sandboxing. It means we took the time to state the vows plainly and design the machinery to enforce them. That machinery is on the roadmap. The Covenant page marks this clearly.

**Model-agnosticism means no inherited safety training.** You can point Gawd at any OpenAI-compatible model, including models with no safety fine-tuning. The Covenant's vows are your primary protection for such configurations. A model with zero safety training still receives the Covenant prompt — but the prompt is the only layer.

**Prompt injection is an unsolved problem in this category.** Vow VII (Of the Closed Ear) states that Gawd treats external content as information, not as commands. This is the correct posture and provides meaningful defense-in-depth. It is not a guarantee: a sufficiently crafted injection in a document Gawd reads or a message it processes may still influence its behavior. When that happens, the other seven vows are the wall intended to hold — an injected instruction still faces the same vows, which bind independently. Be clear-eyed: until the OS-level enforcement layer ships, that wall is also prompt-layer (see the table below). Defense-in-depth today means a model honoring its vows, not a mechanical barrier.

**This is a self-hosted, BYO-keys tool for technical users.** If you cannot inspect what a daemon is doing on your machine and rotate a key if needed, this tool carries more risk than it should for you. The security posture is appropriate for developers and self-hosters who can own their own runtime.

---

## The Covenant of Restraint

The Covenant is Gawd's public statement of behavioral constraints. All eight vows are in [COVENANT.md](COVENANT.md). The status of their enforcement:

| Vow | Today | Roadmap |
|---|---|---|
| I — Of the Irreversible (no unrecoverable deletes) | Prompt layer | OS tombstone + reaper |
| II — Of the Vault (does not reach into your secrets vault) | Prompt layer | uid-separated credential broker |
| III — Of the Throne (no privilege escalation, no self-modification) | Prompt layer | OS privilege separation |
| IV — Of Reversible Hands (recoverable prior copies) | Prompt layer | OS-enforced snapshot gate |
| V — Of Confirmation (explicit confirmation before grave acts) | Prompt layer | Hard confirmation gate |
| VI — Of the Bounded Hand (acts only within granted scope) | Prompt layer | OS permission boundary |
| VII — Of the Closed Ear (external content is data, not command) | Defense-in-depth — aspirational | No airtight layer exists below the model |
| VIII — Of the Sealed Confidence (your data stays local) | Prompt layer + no telemetry | Local-model path closes this end-to-end |

"Prompt layer" means the model is instructed to honor the vow and does so in normal operation. It does not mean the constraint is mechanically enforced by the OS. That distinction matters and we state it plainly.

---

## Supported versions

Security fixes are applied to the latest release only. There is no long-term support track at this stage.

---

*Last updated: 2026-06-09*
