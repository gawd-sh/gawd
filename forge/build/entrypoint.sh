#!/bin/bash
# entrypoint.sh — Gawd container entrypoint
#
# Runs install.sh on first boot (idempotent — skipped if openclaw.json already
# exists), then exec's the CMD (OpenClaw gateway).
#
# This pattern ensures every fresh container starts with a working openclaw.json
# and model routing configured from env vars. Without this, the gateway runs
# --allow-unconfigured which only exposes /health; all agent routes return 404.
#
# Per F2+A3 architectural fix (2026-05-28):
#   Problem: Phase 8 gateway-mode scored 0% on rc1 because no openclaw.json
#            was ever written into the container.
#   Fix: entrypoint.sh calls install.sh --rung docker --non-interactive before
#        the gateway starts. install.sh creates openclaw.json from env vars
#        (MINIMAX_API_KEY, ANTHROPIC_OAUTH_BEARER, OPENCLAW_GATEWAY_TOKEN).
#        The gateway picks it up on startup and registers agent routes.
#
# Safety rules (per GOSPEL-AGENTS.md / GAWDFATHER-DOCTRINE.md):
#   - No secrets in code or image (keys are env var references only)
#   - Idempotent: install.sh is a no-op if openclaw.json already exists
#   - Never blocks CMD: uses exec "$@" to preserve signal handling
#
# Usage: set as ENTRYPOINT in Dockerfile; CMD remains the gateway invocation.

set -e

INSTALL_SH="/usr/local/lib/gawd/install.sh"
OPENCLAW_JSON="${HOME}/.openclaw/openclaw.json"
GAWD_SCRIPTS_LIB="/usr/local/lib/gawd/scripts"
GAWD_SCRIPTS_HOME="${HOME}/.gawd/scripts"

# Resolve a reliability helper: prefer the per-Prophit staged copy (install.sh),
# fall back to the static baked lib copy (first boot, before staging).
_gawd_script() {
    local name="$1"
    if [ -x "${GAWD_SCRIPTS_HOME}/${name}" ]; then echo "${GAWD_SCRIPTS_HOME}/${name}"; return 0; fi
    if [ -x "${GAWD_SCRIPTS_LIB}/${name}" ];  then echo "${GAWD_SCRIPTS_LIB}/${name}";  return 0; fi
    return 1
}

# ── hardening 5: clean-state-on-boot ─────────────────────────────────────────
# Runs FIRST (before install.sh), clearing stale flock locks + checkpointing the
# sqlite WAL so an unclean prior power-off can't wedge this boot. WARN-not-fatal:
# a hygiene hiccup must never block boot (silence-is-worst-outcome).
if _cs="$(_gawd_script gawd-clean-state.sh)"; then
    GAWD_HOME="${HOME}/.gawd" bash "$_cs" \
        || echo "[entrypoint] WARN: clean-state returned non-zero — continuing boot"
else
    echo "[entrypoint] WARN: gawd-clean-state.sh not found — boot hygiene skipped (deploy gap)"
fi

if [ ! -f "$OPENCLAW_JSON" ]; then
    echo "[entrypoint] First boot — running install.sh --rung docker --non-interactive"
    bash "$INSTALL_SH" --rung docker --non-interactive || {
        echo "[entrypoint] install.sh failed (exit $?) — continuing with gateway; agent routes may be limited"
    }
else
    echo "[entrypoint] openclaw.json already present — skipping install.sh"
fi

# ── rc8 B3: boot runtime guard — fail loud if a banned runtime got into config ──
if [ -f "$OPENCLAW_JSON" ]; then
  if python3 - "$OPENCLAW_JSON" <<'PYG'
import json, sys
cfg = json.load(open(sys.argv[1]))
banned = {"claude-cli", "codex"}
provs = (cfg.get("models", {}) or {}).get("providers", {}) or {}
hits = []
for pid, p in provs.items():
    if str((p or {}).get("agentRuntime","")).strip().lower() in banned: hits.append(pid)
    for m in (p or {}).get("models", []) or []:
        if str((m or {}).get("agentRuntime","")).strip().lower() in banned: hits.append(f"{pid}/model")
sys.exit(1 if hits else 0)
PYG
  then :; else
    echo "[entrypoint] FATAL: banned agentRuntime (claude-cli/codex) present in openclaw.json — refusing to start" >&2
    exit 78
  fi
fi

# ── rc8 B5: boot contextEngine re-check — fail loud if slot fell to legacy ────
# Mirror of install.sh B5. install.sh may have run before the npm-staged
# lossless-claw was registrable; re-register here and verify the active slot.
# legacy/empty = refuse to boot (exit 79, distinct from B3's 78).
if command -v openclaw >/dev/null 2>&1 && [ -f "$OPENCLAW_JSON" ]; then
  # SCOPED name — bare 'lossless-claw' is not on npm and fails (→ legacy slot → exit 79).
  # --force: the image pre-installs lossless-claw@0.11.2 into the npm tree; newer
  # openclaw plugin-install detects the existing package and refuses without --force.
  openclaw plugins install --force @martian-engineering/lossless-claw >/dev/null 2>&1 || true
  ce_slot="$(openclaw config get plugins.slots.contextEngine 2>/dev/null | tr -d '"[:space:]' || true)"
  if [ "$ce_slot" = "legacy" ] || [ -z "$ce_slot" ]; then
    echo "[entrypoint] FATAL: contextEngine slot is '${ce_slot:-empty}' (want lossless-claw) — refusing to start a legacy-truncation daemon" >&2
    exit 79
  fi
  echo "[entrypoint] contextEngine slot active: ${ce_slot}"
fi

# ── rc8 B7: boot tool-result-bound re-check — fail loud if the proactive single-
#    tool-result ceiling fell out of the running config (a read-loop could then
#    balloon the window before compaction). ─────────────────────────────────────
if [ -f "$OPENCLAW_JSON" ]; then
  if python3 - "$OPENCLAW_JSON" <<'PYB'
import json, sys
cfg = json.load(open(sys.argv[1]))
cl = ((cfg.get("agents", {}) or {}).get("defaults", {}) or {}).get("contextLimits", {}) or {}
cap = cl.get("toolResultMaxChars")
# Valid bound: a positive int within OpenClaw's XL ceiling (64000).
sys.exit(0 if isinstance(cap, int) and 0 < cap <= 64000 else 1)
PYB
  then :; else
    echo "[entrypoint] FATAL: agents.defaults.contextLimits.toolResultMaxChars missing or out of range — refusing to start without a proactive tool-result bound (read-loop overflow risk)" >&2
    exit 80
  fi
fi

# ── rc8 B8: boot tool-loop-detector re-check — fail loud (exit 81) if the
#    top-level tools.loopDetection guard fell out of the provisioned config. This
#    is the STRONGER guard over B7 (caps repeating/no-progress CALL COUNT, not
#    just per-result size). Read via the landmine-safe `config get | tr -d`
#    pattern (NOT pipe-grep on multi-line JSON).
#    CRITICAL: tools.loopDetection is TOP-LEVEL, not agents.defaults — placing it
#    under agents.defaults crashes the gateway (verified live, OpenClaw 2026.5.27).
if command -v openclaw >/dev/null 2>&1; then
  ld_enabled="$(openclaw config get tools.loopDetection.enabled 2>/dev/null | tr -d '"[:space:]' || true)"
  if [ "$ld_enabled" != "true" ]; then
    echo "[entrypoint] FATAL: tools.loopDetection.enabled is '${ld_enabled:-unset}' (want true) — refusing to start without the tool-loop detector (runaway read-spree overflow risk)" >&2
    exit 81
  fi
  echo "[entrypoint] tool-loop detector active (tools.loopDetection.enabled=${ld_enabled})"
elif [ -f "$OPENCLAW_JSON" ]; then
  # Fallback when the openclaw CLI isn't on PATH yet: AST-free JSON check.
  if python3 - "$OPENCLAW_JSON" <<'PYL'
import json, sys
cfg = json.load(open(sys.argv[1]))
ld = ((cfg.get("tools", {}) or {}).get("loopDetection", {}) or {})
sys.exit(0 if ld.get("enabled") is True else 1)
PYL
  then :; else
    echo "[entrypoint] FATAL: tools.loopDetection.enabled missing/false in openclaw.json — refusing to start without the tool-loop detector (runaway read-spree overflow risk)" >&2
    exit 81
  fi
fi

# ── rc8.1: boot next-none-fix-v1 verify — fail loud (exit 82) if the chain-
#    iteration patch is NOT baked into the OpenClaw dist. ──────────────────────
# The patch is baked at BUILD time as root (build/Dockerfile). install.sh's
# boot-time apply-patches idempotently no-ops once the marker is present. This
# check is the backstop: if a future build ever fails to bake the patch (anchor
# drift, a refactored Dockerfile, etc.), the daemon would otherwise SHIP SILENTLY
# with the fallback chain stopping at next=none — exactly the rc8.0 bug. Refuse
# to boot instead. Exit 82 is distinct from B3(78)/B5(79)/B7(80)/B8(81).
for _ocd in /usr/local/lib/node_modules/openclaw/dist /usr/lib/node_modules/openclaw/dist; do
  if [ -d "$_ocd" ]; then
    if ! grep -qslF "PATCHED next-none-fix-v1" "$_ocd"/agent-scope-*.js; then
      echo "[entrypoint] FATAL: next-none-fix-v1 patch NOT present in $_ocd (chain-iteration fix missing) — refusing to start a daemon whose fallback chain stops at next=none" >&2
      exit 82
    fi
    echo "[entrypoint] next-none-fix-v1 chain-iteration patch verified in $_ocd"
    break
  fi
done

# ── v1 subsystem boot (Metatron cadence ruling 2026-05-28) ───────────────────
# §19 L7 watchdog cadence in the docker rung.
#
# Logos's original docker-rung mechanism was cron-in-container, but vixie cron
# (Debian) refuses to run jobs as the non-root 'gawd' user and crond cannot be
# started as 'gawd' — so the every-minute sweep never fired on a Prophit's
# deployed container, leaving the §19 L7 DETECTION layer inert. Replaced with an
# entrypoint-managed supervised background loop that runs as 'gawd', needs no
# cron/root/systemd, gives true 60s cadence, and is RAM-trivial (one sleeping
# bash loop). On bare-metal/prophit-vm/hosted the systemd user timer drives
# cadence instead — the loop fires ONLY in the docker rung.
#
# The loop is launched BEFORE `exec "$@"` so it becomes a sibling of the gateway
# (PID 1). It is deliberately INDEPENDENT of the gateway process (§19.1: the
# safety net must not depend on the runtime it watches) — if the gateway hangs,
# the loop keeps sweeping.
WATCHDOG_SWEEP="${HOME}/.gawd/watchdog/sweep.sh"
WATCHDOG_LOOP_LOG="${HOME}/.gawd/watchdog/logs/sweep-loop.log"
WATCHDOG_INTERVAL="${GAWD_WATCHDOG_INTERVAL:-60}"

# Fire the loop only in the docker rung (no systemd PID 1). Detect the same way
# install.sh does: explicit GAWD_RUNG, or the in-container markers.
_in_docker_rung() {
    [ "${GAWD_RUNG:-}" = "docker" ] && return 0
    [ -f /.dockerenv ] && return 0
    grep -q docker /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

if _in_docker_rung; then
    if [ -x "$WATCHDOG_SWEEP" ]; then
        mkdir -p "$(dirname "$WATCHDOG_LOOP_LOG")" 2>/dev/null || true
        # hardening 6a: single-instance guard. A re-entrant entrypoint invocation
        # or a `docker exec`-driven re-run must NOT spawn a second supervised loop
        # competing to restart the same gateway. A fresh container (new PID ns)
        # has no live pid → spawns one.
        WATCHDOG_PIDFILE="${HOME}/.gawd/watchdog/loop.pid"
        mkdir -p "$(dirname "$WATCHDOG_PIDFILE")" 2>/dev/null || true
        if [ -f "$WATCHDOG_PIDFILE" ] && kill -0 "$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)" 2>/dev/null; then
            echo "[entrypoint] watchdog loop already running (pid $(cat "$WATCHDOG_PIDFILE")) — not spawning a second"
        else
            # Supervised loop: never exits, never propagates a sweep failure
            # (sweep.sh exits 0 by design, but guard anyway so one bad sweep can
            # never kill the cadence). setsid detaches it from the entrypoint's
            # controlling context so the upcoming `exec` (which replaces this shell
            # with the gateway) does not take the loop down with it.
            setsid bash -c '
                SWEEP="$1"; INTERVAL="$2"; LOG="$3"
                echo "[watchdog-loop] started (interval=${INTERVAL}s, pid=$$) $(TZ=America/Chicago date "+%Y-%m-%d %H:%M:%S %Z")" >> "$LOG" 2>&1
                while true; do
                    sleep "$INTERVAL"
                    bash "$SWEEP" >> "$LOG" 2>&1 || \
                        echo "[watchdog-loop] sweep returned non-zero $(TZ=America/Chicago date "+%H:%M:%S %Z") — continuing" >> "$LOG" 2>&1
                done
            ' _ "$WATCHDOG_SWEEP" "$WATCHDOG_INTERVAL" "$WATCHDOG_LOOP_LOG" </dev/null >/dev/null 2>&1 &
            echo "$!" > "$WATCHDOG_PIDFILE" 2>/dev/null || true
            echo "[entrypoint] watchdog supervised loop launched (docker rung, interval=${WATCHDOG_INTERVAL}s, pid=$!)"
        fi
    else
        # FAIL-LOUD on a missing sweep: the §19 detection layer is REQUIRED.
        # We do not exit (silence-is-worst-outcome: a daemon that won't boot is
        # worse than one with a degraded watchdog), but we make the gap impossible
        # to miss in the logs so the gate / operator catches it.
        echo "[entrypoint] ERROR: watchdog sweep not found at ${WATCHDOG_SWEEP} — §19 L7 DETECTION LAYER IS NOT RUNNING. install.sh did not stage it. This is a deploy bug." >&2
    fi
else
    echo "[entrypoint] non-docker rung — watchdog cadence driven by systemd user timer (watchdog-sweep.timer), not the entrypoint loop"
fi

# ── hardening 3 + 7 (docker rung): leak-guarded local llama-servers ──────────
# The docker rung has no systemd, so the RuntimeMaxSec/MemoryMax guards that
# protect the bare-metal gawd-embed.service / gawd-completions.service are
# enforced HERE, in-process, as supervised respawn loops:
#   - cycle the llama-server child every CYCLE seconds (RuntimeMaxSec equivalent)
#   - kill+respawn if RSS exceeds RSS_MAX_KB (MemoryMax equivalent)
# This applies to BOTH local llama-servers (TWO-additions #1: NEVER ship an
# unguarded llama-server — the 22.8 GB completions leak on 2026-05-28 proves it).
# Default: dormant. A docker image only runs local llama-servers when a model is
# bundled and the GAWD_LOCAL_* flag is set; v1 base image ships NEITHER.
if _in_docker_rung; then
    _spawn_guarded_llama() {  # <label> <port> <model-path> <extra-args> <cycle_sec> <rss_max_kb> <flag>
        local label="$1" port="$2" model="$3" extra="$4" cycle="$5" rss_max="$6" flag="$7"
        [ "$flag" = "1" ] || return 0
        [ -f "$model" ] || { echo "[entrypoint] WARN: ${label} flag set but model '${model}' absent — not starting"; return 0; }
        command -v llama-server >/dev/null 2>&1 || { echo "[entrypoint] WARN: llama-server binary absent — ${label} not started"; return 0; }
        # H4 (2026-05-28): the RSS cap is the docker-rung MemoryMax equivalent and
        # MUST be derived from the model footprint, not a flat number. A cap below
        # the model's resident size kills it mid-generation every cycle = a
        # guaranteed respawn loop. floor_kb = model_bytes*1.3/1024 + 1G KV headroom.
        # If the static cap is below the floor, RAISE it to the floor; if the floor
        # itself exceeds the static cap we honor the floor (never kill a healthy
        # model that simply needs its own footprint).
        local model_bytes floor_kb
        model_bytes="$(stat -c%s "$model" 2>/dev/null || echo 0)"
        if [ "${model_bytes:-0}" -gt 0 ]; then
            floor_kb=$(( model_bytes * 13 / 10 / 1024 + 1048576 ))
            if [ "$rss_max" -lt "$floor_kb" ]; then
                echo "[entrypoint] WARN: ${label} static RSS cap ${rss_max}kB is BELOW the model footprint floor ${floor_kb}kB (model_bytes*1.3 + 1G KV) — raising cap to the floor so the leak guard cannot OOM-kill a healthy model (H4)" >&2
                rss_max="$floor_kb"
            fi
        fi
        local llog="${HOME}/.gawd/logs/${label}.log"; mkdir -p "$(dirname "$llog")" 2>/dev/null || true
        setsid bash -c '
            LABEL="$1"; PORT="$2"; MODEL="$3"; EXTRA="$4"; CYCLE="$5"; RSS_MAX="$6"; LOG="$7"
            while true; do
                # shellcheck disable=SC2086
                llama-server --host 127.0.0.1 --port "$PORT" --model "$MODEL" $EXTRA >>"$LOG" 2>&1 &
                CHILD=$!
                echo "[${LABEL}] started pid=${CHILD} (cycle=${CYCLE}s rss_max=${RSS_MAX}kB)" >> "$LOG" 2>&1
                SECS=0
                while kill -0 "$CHILD" 2>/dev/null; do
                    sleep 30; SECS=$((SECS+30))
                    if [ "$SECS" -ge "$CYCLE" ]; then
                        echo "[${LABEL}] RuntimeMaxSec reached (${CYCLE}s) — cycling to release leaked RSS" >> "$LOG" 2>&1
                        kill "$CHILD" 2>/dev/null; break
                    fi
                    RSS=$(awk "/VmRSS/{print \$2}" "/proc/${CHILD}/status" 2>/dev/null || echo 0)
                    if [ "${RSS:-0}" -gt "$RSS_MAX" ] 2>/dev/null; then
                        echo "[${LABEL}] RSS ${RSS}kB > ${RSS_MAX}kB cap — kill+respawn (leak guard)" >> "$LOG" 2>&1
                        kill "$CHILD" 2>/dev/null; break
                    fi
                done
                wait "$CHILD" 2>/dev/null || true
                sleep 2
            done
        ' _ "$label" "$port" "$model" "$extra" "$cycle" "$rss_max" "$llog" </dev/null >/dev/null 2>&1 &
        echo "[entrypoint] ${label} leak-guarded supervised loop launched (pid=$!)"
    }
    # embed: 6h cycle / 3G cap (3145728 kB); completions: 12h / 26G cap (27262976 kB).
    # --pooling last: REQUIRED for Qwen3-Embedding to serve the OpenAI-compatible
    # /v1/embeddings endpoint (which OpenClaw's memory layer calls). Without it,
    # llama-server defaults to pooling 'none' and /v1/embeddings returns HTTP 400
    # "Pooling type 'none' is not OAI compatible". This matches the proven live
    # Dasra/Lilith embed config (--pooling last). rc5 fix 2026-05-29.
    _spawn_guarded_llama "gawd-embed" "${GAWD_EMBED_PORT:-11436}" \
        "${GAWD_EMBED_MODEL:-${HOME}/.gawd/models/qwen3-embedding-0.6b.gguf}" \
        "--embedding --pooling last --ctx-size 2048 --batch-size 512 --ubatch-size 512 --no-warmup --alias qwen3-embedding-0.6b" 21600 3145728 "${GAWD_LOCAL_EMBED:-0}"
    _spawn_guarded_llama "gawd-completions" "${GAWD_COMPLETIONS_PORT:-11434}" \
        "${GAWD_COMPLETIONS_MODEL:-${HOME}/.gawd/models/completions.gguf}" \
        "--n-gpu-layers ${GAWD_COMPLETIONS_NGL:-999}" 43200 27262976 "${GAWD_LOCAL_COMPLETIONS:-0}"
fi

# Silence-avoidance preflight gate (spec §19). WARN-not-fatal per Logos: a
# template gap must NOT brick the daemon — a daemon that won't boot is worse
# than one with a degraded fallback (silence-is-worst-outcome cuts both ways).
if [ -x /usr/local/lib/gawd/silence-avoidance/engine.sh ]; then
    GAWD_FALLBACK_DIR="$HOME/.gawd/fallbacks/templates" \
    GAWD_FALLBACK_STATE_DIR="$HOME/.gawd/fallbacks/state" \
    GAWD_FALLBACK_CONFIG="$HOME/.gawd/fallbacks/config.json" \
    bash /usr/local/lib/gawd/silence-avoidance/engine.sh preflight \
        || echo "[entrypoint] WARN: silence-avoidance preflight failed — fallback templates incomplete; continuing"
fi

# ── hardening 4: health-gated startup ordering (docker rung) ─────────────────
# When a LOCAL llama-server runs in-container, wait for its /health before the
# gateway opens dependent routes. WARN-not-fatal (silence-is-worst-outcome: a
# gateway up without a local model beats no gateway). Controlled by env flags
# set by the image build / install.sh when a model is bundled.
if _hg="$(_gawd_script gawd-health-gate.sh)"; then
    if [ "${GAWD_LOCAL_EMBED:-0}" = "1" ]; then
        bash "$_hg" "http://127.0.0.1:${GAWD_EMBED_PORT:-11436}/health" 60 embed \
            || echo "[entrypoint] WARN: embed not ready in 60s — starting gateway anyway"
    fi
    if [ "${GAWD_LOCAL_COMPLETIONS:-0}" = "1" ]; then
        bash "$_hg" "http://127.0.0.1:${GAWD_COMPLETIONS_PORT:-11434}/health" 120 completions \
            || echo "[entrypoint] WARN: completions not ready in 120s — starting gateway anyway"
    fi
fi

# ── supercronic: dreaming scheduler (docker rung) ────────────────────────────
# Q3: supercronic is the SINGLE dreaming scheduler in the docker rung.
# The baked dream.crontab at /usr/local/lib/gawd/memory/dream.crontab holds
# the 3am daily schedule for safe-dream.sh. supercronic is a static binary
# (no root, no suid, no crond) — it runs as the gawd user and reads env vars
# from its process environment, including GAWD_DREAM_MODEL.
#
# Why supercronic (not vixie cron):
#   - Vixie cron (Debian's cron package) refuses to run jobs from a non-root
#     user's crontab when crond is invoked as a non-root process. The gawd user
#     cannot start crond, so `crontab -l` installs do nothing. This was the
#     root cause of "dreaming never fires in the container" confirmed in rc5
#     fresh review.
#   - supercronic needs no root, no suid, no daemon registration — it is
#     a standalone process that reads a crontab file and fires jobs directly.
#
# Supercronic is launched AFTER the embed /health gate (dreaming synthesis
# calls the gateway which depends on the embed model for memory). It is
# backgrounded with setsid so it survives the upcoming `exec "$@"` (which
# replaces this shell with the gateway process). The gateway is PID-trunk;
# supercronic is a sibling process.
#
# WARN-not-fatal: a supercronic launch failure must NOT block the gateway
# (silence-is-worst-outcome: a Gawd that won't boot is worse than one without
# a dreaming schedule). The dreaming log captures the schedule fires.
#
# Q2: GAWD_DREAM_MODEL env is passed through supercronic's process environment
# automatically — supercronic inherits the full environment of the process
# that launched it. The crontab line also has a shell-level fallback:
# GAWD_DREAM_MODEL=${GAWD_DREAM_MODEL:-minimax/MiniMax-M2.7}
#
# Single-instance guard: a supercronic PID file prevents a second instance
# if the entrypoint is re-invoked (e.g., `docker exec` that sources this).
if _in_docker_rung; then
    _DREAM_CRONTAB="/usr/local/lib/gawd/memory/dream.crontab"
    _SUPERCRONIC_LOG="${HOME}/.gawd/logs/supercronic-dreaming.log"
    _SUPERCRONIC_PIDFILE="${HOME}/.gawd/state/supercronic-dreaming.pid"
    mkdir -p "${HOME}/.gawd/logs" "${HOME}/.gawd/state" 2>/dev/null || true

    if ! command -v supercronic >/dev/null 2>&1; then
        echo "[entrypoint] ERROR: supercronic binary not found — dreaming cron NOT running (image bake gap)" >&2
    elif [ ! -f "$_DREAM_CRONTAB" ]; then
        echo "[entrypoint] ERROR: dream.crontab not found at ${_DREAM_CRONTAB} — dreaming cron NOT running (image bake gap)" >&2
    else
        # Single-instance guard.
        if [ -f "$_SUPERCRONIC_PIDFILE" ] && kill -0 "$(cat "$_SUPERCRONIC_PIDFILE" 2>/dev/null)" 2>/dev/null; then
            echo "[entrypoint] supercronic dreaming scheduler already running (pid $(cat "$_SUPERCRONIC_PIDFILE")) — not spawning a second"
        else
            # Validate crontab syntax before launching (supercronic -test exits 0 if valid).
            if supercronic -test "$_DREAM_CRONTAB" 2>/dev/null; then
                setsid supercronic "$_DREAM_CRONTAB" >> "$_SUPERCRONIC_LOG" 2>&1 &
                _SUPERCRONIC_PID=$!
                echo "$_SUPERCRONIC_PID" > "$_SUPERCRONIC_PIDFILE" 2>/dev/null || true
                echo "[entrypoint] supercronic dreaming scheduler launched (pid=${_SUPERCRONIC_PID}, crontab=${_DREAM_CRONTAB})"
                echo "[entrypoint] dreaming schedule: 3am daily via supercronic; logs at ${_SUPERCRONIC_LOG}"
            else
                echo "[entrypoint] ERROR: dream.crontab failed supercronic -test validation — dreaming cron NOT running" >&2
            fi
        fi
    fi
else
    echo "[entrypoint] non-docker rung — dreaming cron driven by OS crontab (install.sh wired it at first boot)"
fi

# ── wiki startup self-check (recursion guard #1) ─────────────────────────────
# Verify that the wiki output path (vault.path) is OUTSIDE the memory ingest
# scope BEFORE the gateway/bridge starts. If the check fails (output ⊆ ingest),
# the bridge is disabled via env so the gateway starts without it — recall still
# works (graceful degradation). Fail-loud, not fail-silent.
#
# WARN-not-fatal per silence-is-worst-outcome: a misconfigured wiki path must NOT
# brick the daemon. Disable the bridge and log loudly so the operator can fix the
# path, but the Gawd keeps running.
_WIKI_CHECK="/usr/local/lib/gawd/memory/wiki-startup-check.sh"
_GAWD_INGEST="${GAWD_INGEST_SCOPE:-${HOME}/.openclaw/workspace/memory}"
_GAWD_WIKI_OUT="${GAWD_WIKI_OUT:-${HOME}/.openclaw/workspace/wiki}"
if [ -x "$_WIKI_CHECK" ]; then
    if GAWD_INGEST_SCOPE="$_GAWD_INGEST" GAWD_WIKI_OUT="$_GAWD_WIKI_OUT" \
           bash "$_WIKI_CHECK" 2>/dev/null; then
        echo "[entrypoint] wiki-startup-check: OK — vault.path is disjoint from ingest scope"
    else
        echo "[entrypoint] ERROR: wiki-startup-check FAILED (vault.path is inside ingest scope — recursion guard triggered)." >&2
        echo "[entrypoint] Disabling wiki bridge for this boot to prevent the 79K-iteration recursion." >&2
        echo "[entrypoint] Fix vault.path in openclaw.json (must be outside workspace/memory) and restart." >&2
        # Disable the bridge by env — the gateway respects this and skips the bridge.
        export OPENCLAW_PLUGIN_MEMORY_WIKI_BRIDGE_ENABLED=false
    fi
else
    echo "[entrypoint] WARN: wiki-startup-check.sh not found at ${_WIKI_CHECK} — skipping recursion guard (deploy gap)" >&2
fi

echo "[entrypoint] Starting gateway: $*"
exec "$@"
