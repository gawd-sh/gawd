# Gawd Dashboard (G6 — Prophit-Surface Architecture)

**Status**: v1 skeleton (forge artifact). NOT live-deployed.

This is the **load-bearing visual face** of Gawd for the non-technical Prophit. Owns the full Prophit lifecycle: install (hosted rung), onboarding, the Meeting (conversion event), daily chat, tithing, settings, status, and manual recovery.

## Tech stack (Q19a — locked)

- **HTMX** + **Tailwind** (CDN'd for v1; bundle locally at v2 for offline rung)
- **Flask** (Python 3.11+) server-rendered with Jinja2 templates
- **SSE** for heartbeat (one-way push, every 2s)
- **POST + HTMX swap** for chat (simpler than WebSocket for v1; upgrade later if latency demands)
- **No JS toolchain** — no npm, no webpack, no build step. Survives microVM (Firecracker) constraints.

## Auth (Q19b — locked)

Magic-link via Telegram. Prophit submits username on `/login`, dashboard generates a signed one-time token, Gawd's Telegram bot DMs the URL. Click → session cookie (30-day TTL). Per-Gawd-per-Prophit binding.

## Exposure (Q19e — locked, deploy-time choice)

Environment variable `GAWD_DASHBOARD_EXPOSURE`:

| Value | Behavior |
|---|---|
| `local` | Bind 127.0.0.1:8090; no external reachability. Bare-metal default. |
| `tailscale` | Bind 0.0.0.0:8090; install.sh provisions Tailscale Serve. Prophit-VM default. |
| `cloudflared` | Bind 127.0.0.1:8090; install.sh provisions cloudflared tunnel. Hosted-rung default. |

Chosen at deploy time, not build time.

## Infrastructure separation (§19.3.2 — LOAD-BEARING)

The dashboard runs in its OWN systemd unit. It does NOT depend on:

- OpenClaw gateway being up (chat panel degrades gracefully)
- Any cloud LLM being reachable (chat panel degrades; everything else functional)
- Any embedding server (memory views read raw files)

Heartbeat reads `~/.gawd/state/watchdog/last-sweep.json` directly (G5 contract). Inbound G2 fallback messages arrive via either SSE POST endpoint OR file-queue at `~/.gawd/dashboard/queue/`.

## Punt-to-desktop boundary

The dashboard renders: chat, status, simple media (images, audio clips ≤25MB), controls, onboarding, settings, Meeting, tithing tap, recovery button.

The dashboard DOES NOT render: video files, large streaming media, complex desktop apps. For those, the chat composer detects the content type and renders an "Open in Gawd's desktop" link that targets the configured noVNC URL.

Configuration: `GAWD_NOVNC_URL` env var (e.g., `https://your-machine.your-tailnet.ts.net/vnc.html`).

## File map

```
dashboard/
├── README.md                          this file
├── server/
│   ├── app.py                         Flask app factory + routes
│   ├── auth.py                        magic-link generation + verification
│   ├── heartbeat.py                   SSE endpoint + watchdog file reader
│   ├── chat.py                        chat POST + SSE inbound + gateway proxy
│   ├── fallback_ingest.py             G2 inbound (SSE POST + file-queue tail)
│   ├── tithe.py                       tithe-intent recorder
│   ├── settings.py                    USER.md / IDENTITY.md adaptive edits
│   ├── onboarding.py                  4-question wizard
│   ├── meeting.py                     5-movement modal renderer
│   ├── recovery.py                    restart-Gawd button handler
│   ├── punt.py                        punt-to-desktop affordance
│   ├── telegram_send.py               direct-curl Telegram DM (no MCP)
│   └── config.py                      env loader; secrets via ~/.gawd/.secrets/
├── templates/                         Jinja2 templates (HTMX-targeted)
│   ├── base.html
│   ├── _heartbeat.html                top-bar status (always-visible)
│   ├── _degraded_banner.html          conditional banner
│   ├── login.html
│   ├── onboarding/
│   ├── meeting/
│   ├── chat.html
│   ├── settings.html
│   └── (more)
├── static/
│   ├── htmx.min.js                    v1.9.10 (CDN fallback in base.html)
│   ├── tailwind.min.css               (CDN fallback in base.html)
│   └── gawd-glyph.svg
├── systemd/
│   └── gawd-dashboard.service         user unit, Restart=always
├── install.sh                         idempotent installer
└── tests/
    ├── test_auth.py
    ├── test_heartbeat.py
    ├── test_magic_link.py
    ├── test_fallback_ingest.py
    └── run-all.sh
```

## Runbook

See `<install-root>/docs/runbooks/dashboard.md`.

## Cross-handoff contracts honored

- **G2 (silence-avoidance/deliver/dashboard.sh)** — accepts inbound at `/api/fallback/ingest` (SSE POST, requires shared secret header) OR `~/.gawd/dashboard/queue/` file drop (tailed by `fallback_ingest.py`)
- **G5 (watchdog/state/last-sweep.json)** — `heartbeat.py` reads this file; never calls gateway or LLM
- **A1 (persona templates)** — onboarding writes IDENTITY.md/USER.md identically to A4 wizard
- **A4 (onboarding/wizard.sh)** — web form mirrors same 4 questions, same validation, same outputs
- **B1 (meeting/canonical.md)** — `meeting.py` renders this content with the SAME variable substitution rules as `meeting-playback.sh`
- **D1 (desktop/configure-novnc.sh)** — punt-to-desktop reads `GAWD_NOVNC_URL` set by D1 install
- **§15 (SIL gate)** — settings page restricts edits to USER.md adaptive section; SOUL.md/IDENTITY.md base sections gate through SIL

