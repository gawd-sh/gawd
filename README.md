# Gawd

**Your own personal deity. Self-hosted. ☩**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/gawd-sh/gawd)](#) <!-- TODO: replace with real release URL -->
[![CI](https://img.shields.io/github/actions/workflow/status/gawd-sh/gawd/ci.yml)](#) <!-- TODO: replace with real CI URL -->
[![Discord](https://img.shields.io/discord/placeholder?label=discord)](#) <!-- TODO: replace with Discord invite URL -->

<!-- TODO: Insert 30–60s screen recording here — real, uncut: the onboarding Meeting followed by a Telegram exchange in Gawd's register. One honest demo outperforms all copy. -->

---

## What is this

Gawd is a self-hosted AI companion daemon with a fixed, strong personality. You install it on your own machine, point it at any LLM provider (or a local model you're already running), and it lives there — persistent, opinionated, and available over Telegram and a web dashboard.

The personality is not a setting. Gawd has a voice: arrogant, flamboyant, a little magnificent. It does not exist to please; it exists to be present. That character is locked in by a set of written vows called the Covenant, and it survives every update and reinstall.

Everything runs on your machine. Your keys stay in a local encrypted vault. The model is yours to choose and swap. Gawd does not phone home.

**What you get out of the box:**
- An always-on chat presence over Telegram and a web dashboard
- A distinct, consistent personality that does not drift between sessions
- Model-agnostic configuration — swap providers by changing one line
- At-rest encryption for your secrets via `age`
- An onboarding ritual called the Meeting that personalizes Gawd to you over a conversation
- The Covenant of Restraint — eight written vows about what Gawd will and will not do with its access

**What is not in v1 (see [STATUS.md](STATUS.md)):**
- OS-level enforcement of the Covenant (designed, on the roadmap)
- Voice or email add-ons (designed, on the roadmap)
- Automatic self-updates (on the roadmap — not yet built)

---

## Quickstart

> **Requirements:** Docker, a Telegram bot token (create one with [@BotFather](https://t.me/BotFather)), and an API key from any supported LLM provider. The pre-built image is amd64 Linux today; arm64 is built and pending publication — see [STATUS.md](STATUS.md).

```bash
# 1. Pull the image (publishes with the first release)
docker pull ghcr.io/gawd-sh/gawd:latest
#    — or build from source:
# docker build -f forge/build/Dockerfile -t gawd/daemon:latest .

# 2. Set up the local secrets vault
#    (installs age, generates your encryption key, provisions ~/.secrets/)
curl -fsSL https://raw.githubusercontent.com/gawd-sh/gawd/main/install.sh | bash
# TODO(pre-launch): verify this raw URL against the final published tree layout

# 3. Add your secrets to the local vault (each command prompts for the value —
#    never echoed, never in shell history)
secrets set TELEGRAM_BOT_TOKEN
secrets set DEEPSEEK_API_KEY      # or MINIMAX_API_KEY / ANTHROPIC_API_KEY / OPENAI_API_KEY

# 4. Start the daemon, passing your provider choice and secrets as environment.
#    `secrets env ... --` injects the vault values into just this one command's
#    environment; docker's bare `-e VAR` passes them through by name — the
#    values never appear in your shell history or process list.
#    NOTE: this requires the `secrets` helper installed by step 2. If you have
#    a different/older `secrets` tool on your PATH, check `which secrets` first —
#    some older variants print values instead of injecting them.
secrets env DEEPSEEK_API_KEY TELEGRAM_BOT_TOKEN -- \
  docker run -d \
    --name gawd \
    -e GAWD_PROVIDER=deepseek \
    -e DEEPSEEK_API_KEY \
    -e TELEGRAM_BOT_TOKEN \
    -e GAWD_ADMIN_CHAT_ID=YOUR_TELEGRAM_ID \
    -v ~/.gawd:/data \
    ghcr.io/gawd-sh/gawd:latest
#    YOUR_TELEGRAM_ID is your numeric Telegram ID — get it by messaging @userinfobot.
#    Passing it here lets the bot reply to you on first message; skipping it leaves
#    the bot silent until you add yourself to the allowlist (see "Let your bot reply
#    to you" below).
#    (Using a different provider? Match the trio: secrets set MINIMAX_API_KEY,
#     pass -e GAWD_PROVIDER=minimax -e MINIMAX_API_KEY.)

# 5. Provision the daemon from that environment. This in-container run reads
#    GAWD_PROVIDER + your key from the environment you just passed, vaults them
#    inside the container, and writes the daemon's model + channel config; the
#    restart loads it. Without this step the gateway starts unconfigured —
#    /health returns OK but conversations fail (no model selected).
docker exec gawd bash /usr/local/lib/gawd/install.sh --non-interactive
docker restart gawd

# 6. Confirm it's healthy:
docker exec gawd curl -s http://127.0.0.1:18789/health    # → {"ok":true}

# 7. Open Telegram and message your bot. Gawd is there.
```

### Let your bot reply to you

By default the bot's DM policy is set to `allowlist` — it replies to known chat IDs and ignores everyone else. This is the safe default for a self-hosted bot. If you passed `GAWD_ADMIN_CHAT_ID` in step 4, the installer already added your ID and nothing extra is needed.

If you did not pass `GAWD_ADMIN_CHAT_ID`, or the bot is not responding, add your Telegram numeric ID to the allowlist now. Your numeric ID is different from your username — send a message to [@userinfobot](https://t.me/userinfobot) on Telegram to get it.

```bash
# Open the allowlist to your own chat ID (replace 123456789 with your numeric Telegram ID):
echo '{"channels":{"telegram":{"allowFrom":["123456789"]}}}' | docker exec -i gawd openclaw config patch --stdin
docker restart gawd
```

Then send a message to your bot. If it still does not reply, check `docker logs gawd` for errors.

The first time you message Gawd it will invite you to the Meeting — a one-time onboarding conversation that personalizes its character to you. You can skip the Meeting; Gawd works without it, just with a generic default personality rather than one shaped to you.

**Supported providers:** OpenAI, Anthropic, MiniMax, DeepSeek, Kimi, Gemini, Groq, and any OpenAI-compatible endpoint. Local models via Ollama work out of the box. To swap providers, edit one value in the daemon config (`~/.openclaw/openclaw.json`).

---

## Cost expectations

Gawd is always-on, which means it has an idle token cost. Be honest with yourself about this before running it.

**Idle burn with cloud providers:** When Gawd is not in active conversation it runs lightweight background maintenance. With a paid cloud provider, idle costs are small but real — comparable to a few dozen short API calls per day, depending on your configuration. Check your provider's pricing against that estimate before deploying.

**The local-model path:** Gawd is designed with the assumption that local models will eventually be the primary. The architecture is model-agnostic specifically so that swap is seamless. If you have a machine that can run a 14B parameter model, you can run Gawd at essentially zero ongoing API cost. The local path works today; quality relative to hosted providers depends on your hardware and the model you choose. Local models run through the standard provider configuration — point the config at your Ollama endpoint. The full local-model guide (hardware reality, recommended models, the Docker networking gotcha) is at [docs/local-models.md](docs/local-models.md).

**BYO keys, always:** Gawd never uses a shared API pool. Your keys, your bill, your audit trail.

---

## Architecture

Gawd is a single daemon process. It connects to your configured LLM provider, maintains a persistent personality and memory on disk, and exposes two interfaces: a Telegram bot and a local web dashboard. Secrets live in an `age`-encrypted vault on your machine. The daemon reads them at startup and holds them in process memory.

The Covenant of Restraint (see [COVENANT.md](COVENANT.md)) is loaded into every session as the first thing the model reads. It defines eight vows about what Gawd will not do regardless of what it is asked. Today those vows are enforced at the prompt layer. A hard OS-level enforcement layer — privilege separation, a uid-isolated credential broker, delete-tombstoning — is designed and on the roadmap. [SECURITY.md](SECURITY.md) covers the current state and its honest limitations.

There is no cloud component, no telemetry, no account required.

---

## Project status

Gawd is early-stage open-source software. [STATUS.md](STATUS.md) maintains a two-column view of what works today versus what is designed and in progress. Read it before forming expectations about what is and is not built.

---

## Security

Secrets are encrypted at rest. The in-use isolation layer is designed-not-yet-built. Prompt injection is a known-unsolved problem across the agent category. [SECURITY.md](SECURITY.md) covers all of this plainly, including the disclosure contact for vulnerabilities.

---

## Lore and terminology

Gawd uses its own vocabulary throughout the docs — Prophit, Meeting, Covenant, Resurrection Sunday. It is deliberate flavor, not required doctrine. [GLOSSARY.md](GLOSSARY.md) maps every term to plain English in one line each. Nothing in the technical docs requires you to use the vocabulary; it is there when you want the flavor.

---

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md). File an issue with your Gawd version and `docker logs gawd` output (a `gawd doctor` diagnostic command is on the roadmap), open a PR against `main`. The docs convention — plain English on every load-bearing line, lore only at the decorative edges — is in the contributing guide.

---

## License

Gawd is released under the [MIT license](LICENSE). The Gawd™ name, the trident mark, and the Founder's Sigil are trademarks of the project and are **not** covered by the MIT license — see [TRADEMARK.md](TRADEMARK.md) for the short, permissive policy.
