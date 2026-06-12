# Local Models

Run Gawd against a model on your own hardware — no API key, no per-token cost, no conversation ever leaving your machine.

This is not a side feature. Gawd's architecture is model-agnostic specifically because the project's long-term bet is that local models become the primary. The hosted-provider path exists because frontier models currently give the strongest personality and instruction-following; the local path exists because it is where this is going.

**The honest tradeoff, up front:** a hosted frontier model will hold Gawd's register more firmly than a local model today. Local quality varies with your hardware and your model choice. A 27B-class model on a capable machine is genuinely good; a 7B on a thin laptop will give you a flatter, more forgetful Gawd. Both work. Know which one you're signing up for.

---

## Quickstart (Ollama)

Ollama exposes an OpenAI-compatible endpoint, which is exactly what Gawd's provider config expects. `install.sh` offers an Ollama option that prompts for the endpoint (default `http://localhost:11434`) and skips the key step entirely.

```bash
# 1. Install Ollama (Linux / macOS)
curl -fsSL https://ollama.com/install.sh | sh

# 2. Pull a model (see recommendations below)
ollama pull gemma4:12b

# 3. Point Gawd at it — ~/.openclaw/openclaw.json, models.providers:
```

```json
{
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://host.docker.internal:11434/v1",
        "api": "openai-completions",
        "apiKey": "ollama",
        "models": ["gemma4:12b"]
      }
    }
  }
}
```

The `apiKey` value is a placeholder — Ollama requires the field to exist but ignores its content. Nothing goes in the vault for this provider.

### The Docker networking gotcha (read this — it breaks everyone)

Gawd runs in a container; Ollama runs on your host. `localhost` inside the container is the container, not your machine, so `http://localhost:11434` will always fail with connection refused.

- **macOS / Windows (Docker Desktop):** use `http://host.docker.internal:11434/v1`. Works out of the box.
- **Linux:** `host.docker.internal` does not exist by default. Add it when you start the container:

  ```bash
  docker run -d --add-host=host.docker.internal:host-gateway ... ghcr.io/gawd-sh/gawd:latest
  ```

  (In compose: `extra_hosts: ["host.docker.internal:host-gateway"]`.)

- **Linux, second trap:** Ollama listens on `127.0.0.1` by default, so even with the host-gateway mapping the container's connection is refused. Make Ollama listen on all interfaces — for the systemd install, `systemctl edit ollama` and add:

  ```ini
  [Service]
  Environment="OLLAMA_HOST=0.0.0.0:11434"
  ```

  then `systemctl restart ollama`. Note this makes Ollama reachable from your local network, not just your machine — firewall accordingly.

---

## Hardware reality

Rule of thumb: a 4-bit-quantized model needs roughly 60% of its parameter count in GB of memory, plus a few GB of headroom for context. On Apple Silicon, unified memory is your "VRAM" — system RAM is the budget. On a PC with a discrete GPU, the model needs to fit in VRAM to run at full speed; spilling to system RAM works but is much slower. CPU-only is tolerable for the 7B class and painful above it.

| Model class | Memory needed (Q4) | 8GB machine | 16GB machine | 32GB+ machine |
|---|---|---|---|---|
| 7B–12B | ~5–8 GB | Usable | Smooth | Smooth |
| 14B–20B | ~9–13 GB | No | Usable | Smooth |
| 26B–32B | ~16–20 GB | No | No | Usable–smooth |

"Smooth" means conversational speed. "Usable" means you'll notice the pauses. Gawd is a chat presence, not a batch job — anything under ~10 tokens/second starts to feel like talking to someone underwater.

---

## Model recommendations (verified June 2026)

All of these exist in the Ollama library today and were chosen for instruction-following and chat quality — the things Gawd's personality lives or dies on.

| Model | Pull | Why |
|---|---|---|
| **Gemma 4 12B** | `ollama pull gemma4:12b` | The best balance for 16GB machines; strong instruction-following for its size. |
| **Gemma 4 26B** | `ollama pull gemma4:26b` | MoE with ~4B active parameters — near-flagship quality, runs lighter than its size suggests. |
| **Qwen 3.6 27B** | `ollama pull qwen3.6:27b` | Dense, the current community default for agentic work; the strongest register-holder in this range. |
| **gpt-oss 20B** | `ollama pull gpt-oss:20b` | MoE quantized to fit 16GB; good general chat. |
| **Qwen 3 14B** | `ollama pull qwen3:14b` | Dense fallback for 16GB machines if Gemma 4's style doesn't suit you. |

**The register caveat:** Gawd's character demands strong instruction-following — the Covenant, the voice, the refusal to drift are all instructions the model must keep honoring deep into a long conversation. Small models hold the persona less firmly: a 7B Gawd will sometimes slip into generic-assistant register, and that's a model limitation, not a bug you can configure away. The 26B–27B class holds character noticeably better than the 12B–14B class, which holds it noticeably better than anything smaller. This is the honest shape of the tradeoff, not a reason to skip local.

---

## Mixed mode: local primary, hosted fallback

The config's model setting accepts a chain — a primary plus an ordered fallback list — and the daemon cascades down it when the primary fails. A practical setup is your local model as primary with one hosted provider as fallback: day-to-day conversation costs nothing and stays on your machine, and if Ollama is down or the machine is loaded, Gawd degrades to the hosted key instead of going silent. The fallback provider's key lives in the vault like any other; nothing about mixed mode changes the secrets story.

---

## Troubleshooting

**Connection refused.** Almost always the networking gotcha above. In order: (1) you used `localhost` in the config instead of `host.docker.internal`; (2) on Linux, you didn't add `--add-host=host.docker.internal:host-gateway`; (3) on Linux, Ollama is still bound to `127.0.0.1` — set `OLLAMA_HOST=0.0.0.0:11434` and restart it. Verify from inside the container: `docker exec gawd curl -s http://host.docker.internal:11434/v1/models`.

**Model not found.** The model name in `openclaw.json` must exactly match a pulled model, tag included. `ollama list` shows what you actually have; `gemma4:12b` and `gemma4:latest` are different entries.

**Out of memory / model crawls.** The model doesn't fit your hardware. Symptoms: Ollama killed by the OOM reaper, or responses arriving at seconds-per-token because the model spilled out of GPU/unified memory. Drop a size class (26B → 12B) or a quantization level. The hardware table above is the honest budget — headroom for the OS and context window is part of it.

---

*Local models run through the same provider configuration as everything else — see [STATUS.md](STATUS.md) for what's exercised today. Ollama is what we test against; any OpenAI-compatible server (llama.cpp, LM Studio, vLLM) should work the same way, but we haven't gated releases on them.*
