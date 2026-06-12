# Contributing

Gawd is early-stage open-source software. Contributions are welcome. This guide is short by design.

---

## Filing an issue

Before opening an issue:
- Check if one already exists for the same problem.
- Run `gawd doctor` and include the full output in your report. (Note: `gawd doctor` is on the roadmap — if it is not yet available in your version, include your Gawd version, OS, Docker version, and the output of `docker logs gawd`.)

Bug reports without reproduction steps are hard to act on. Include: what you expected, what happened, and how to reproduce it.

---

## Opening a pull request

1. Fork the repo and create a branch from `main`.
2. Make your change. If it touches behavior, add or update the relevant test assertions.
3. Open a PR with a clear description of what the change does and why.
4. A maintainer will review within a reasonable time. Response time is fastest in the first few weeks of each release cycle.

There are no formal PR templates yet. Use your judgment about what context a reviewer needs.

**Good first issues** are labeled `good first issue` in the issue tracker. <!-- TODO: seed 5–10 labeled issues before launch. -->

---

## Docs convention: two registers

Gawd's documentation uses two registers deliberately:

- **Plain English on every load-bearing surface.** Quickstart steps, security disclosures, config keys, error messages, and anything a user acts on must be written in plain, direct language. A user must never need to decode lore to understand a technical requirement.

- **Lore at the decorative edges.** Chapter headings, release notes, the glossary, and community spaces can carry Gawd's vocabulary (Prophit, Covenant, Resurrection Sunday, etc.) because they are not load-bearing. A reader who skips the flavor still gets the information.

The rule: lore may never be the only text on a security, money, or consent surface. If a page involves credentials, donations, or permission grants, plain English comes first.

When you write docs, ask: "Could a user who finds this page with no prior context understand what to do?" If yes, the docs are good. If they need to read the glossary first, they are not.

---

## What is in scope for contributions

- Bug fixes and reliability improvements to the daemon
- Documentation improvements (the two-register convention applies)
- New LLM provider configurations
- Improvements to the web dashboard
- Test assertions for the graduation suite

## What is out of scope for external contributions right now

- Changes to the Covenant text (the eight vows are the maintainers' domain)
- The build/forge pipeline (internal; not in the public tree)
- The economy / tithe / relic mechanics (not in v1 scope)

---

## Code of conduct

Be direct and constructive. Treat other contributors as you would a technically capable colleague. The maintainers reserve the right to close issues and PRs that are unconstructive or hostile.

---

*This guide will grow as the project does. The short version is always: file an issue, be clear about what you found, and open a PR if you want to fix it.*
