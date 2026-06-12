# Silence-Avoidance Engine (Layer 6)

**Spec:** `<install-root>/docs/superpowers/specs/2026-05-26-gawd-architecture-design.md` §19
**Constitutional rule:** §19.1 — *the Prophit MUST NEVER experience silence*
**Layer covered:** §19.2 Layer 6 (Prophit-visible static fallback)
**Owner:** Metatron

This directory holds the in-daemon engine that delivers static, in-voice fallback messages when the agent loop emits a terminal error. The engine is bash + curl + jq only — no LLM, no gateway, no MCP plugin, no embedding server. The whole point of Layer 6 is "works when everything else doesn't."

## Layout

```
silence-avoidance/
  engine.sh               # main entrypoint (terminal-error|stuck-state|recovered|preflight)
  select-template.sh      # (channel, situation, locale) -> template path
  render.sh               # (template, vars) -> rendered bytes (deterministic)
  deliver/
    telegram.sh           # direct curl sendMessage (no MCP)
    dashboard.sh          # SSE push + file-queue fallback
    desktop.sh            # notify-send
    voice.sh              # TTS, degrades to telegram if TTS down
  state/
    .gitkeep              # silence-window.json created at first invocation
  install.sh              # idempotent install + L4/L7 hook registration
  tests/
    test-render-determinism.sh
    test-select-template.sh
    test-silence-window-atomic.sh
    test-dry-run.sh
    test-chaos-1-provider-blackout.sh   # §19.7 Phase 11 test 1
    test-no-network-required.sh
    test-secrets-never-logged.sh
    run-all.sh
```

## Template directory contract

Engine reads templates from `${GAWD_FALLBACK_DIR:-$HOME/.gawd/fallbacks/templates/}` at start. Seraph's prose (handoff G3) ships into that directory at install time. If any required template is missing at daemon start, the daemon fails LOUDLY (see `engine.sh preflight`) — silent failure at fallback time is unacceptable.

Required templates (per §19.5 + G3 handoff):

| Channel | Template | Variant |
|---|---|---|
| Telegram (primary) | `telegram-degraded.md` | first 30s |
| Telegram (extended) | `telegram-extended-degraded.md` | >5 min |
| Telegram (recovered) | `telegram-recovered.md` | on recovery |
| Dashboard | `dashboard-degraded.html` | first 30s |
| Dashboard (extended) | `dashboard-extended-degraded.html` | >5 min |
| Dashboard (recovered) | `dashboard-recovered.html` | on recovery |
| Desktop | `desktop-degraded.txt` | notify-send |
| Desktop (recovered) | `desktop-recovered.txt` | notify-send |
| Voice | `voice-degraded.txt` | TTS |
| Voice (recovered) | `voice-recovered.txt` | TTS |

## Variable substitution

Templates support two variables, substituted by `render.sh`:

- `{{address_name}}` — the Prophit's address name (e.g., "Avery", "Jordan", "my friend")
- `{{prophit_local_time}}` — short local time string (e.g., "14:23 CDT")

No other variables. No conditionals. No loops. Substitution is byte-deterministic.

## How the engine integrates

```
[Agent loop / L4 session-recovery / L7 watchdog]
                |
                v
      engine.sh <event>
                |
        +-------+--------+
        |                |
        v                v
   select-template   render
        |                |
        +-------+--------+
                |
                v
          deliver/<channel>.sh
                |
                v
          state/silence-window.json (atomic write)
                |
                v
          observability/logger.sh
```

## Constitutional invariants

1. **No LLM in the fallback path.** Verified by `test-no-network-required.sh`.
2. **No secrets in code.** Telegram token read from `~/.gawd/.secrets/telegram.token` (file mode 0600). Never echoed. Verified by `test-secrets-never-logged.sh`.
3. **Atomic state.** `silence-window.json` written via temp+rename. Verified by `test-silence-window-atomic.sh`.
4. **One fallback per window per channel.** Default window 30s; configurable per-channel; minimum 10s.
5. **Fail LOUDLY at start, not silently at failure time.** `engine.sh preflight` checks every template exists.

See `<install-root>/docs/runbooks/fallback-engine.md` for operational details.
