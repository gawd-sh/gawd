#!/usr/bin/env node
// browser-relay.mjs — Model-agnostic voice-relay for the base Gawd.
//
// Spec reference: Architecture §9 (Voice Modality)
// Gospel reference: §8.4 (Lilith voice-relay reference architecture, model-agnostic gap closed here)
// Handoff: HANDOFF-20260526-GAWDFATHER-METATRON-voice-relay-model-agnostic.md
//
// Architecture (when wired, per spec §9.1):
//   Browser mic --> WebSocket --> this relay (port 8080 loopback)
//                                   |
//                                   |--> STT provider (pluggable; default ElevenLabs)
//                                   |--> LLM via gawdfather-llm-call (chain/tier/explicit; NEVER hardwired)
//                                   |--> TTS provider (pluggable; default ElevenLabs)
//                                   |
//                                   --> WebSocket --> browser speaker
//   Tunnel: <gawd>.gawd.sh --> 127.0.0.1:8080 via cloudflared (Prophit-VM, bare-metal)
//   Tunnel: Tailscale Serve --> 127.0.0.1:8080 (hosted rung)
//
// Model-agnosticism contract (gospel §1 principle 1, acceptance criterion 2):
//   - No model names appear as string literals in this file.
//   - LLM resolution flows through resolveLlm() which calls the same chain
//     used by the rest of the daemon (gawdfather-llm-call binary).
//   - STT/TTS providers are loaded by name from config; the relay code does
//     not know which provider is active.
//   - grep guards (see voice-relay tests) verify the no-literal-models rule.
//
// Background-by-default (gospel §1 principle 8): the relay itself is a
// process; per-session handling is event-driven (no setInterval polling).
//
// Graceful degradation (acceptance criterion 8): if config.enabled === false
// or required API keys are missing, this process exits 0 with a clear log
// line. The systemd unit honors Restart=on-failure, NOT Restart=always —
// disabled voice should stay disabled, not restart-loop.

import { createServer } from 'node:http';
import { WebSocketServer } from 'ws';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { randomUUID, createHmac, timingSafeEqual } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { existsSync, readFileSync } from 'node:fs';

// ---------------------------------------------------------------------------
// Configuration loading
// ---------------------------------------------------------------------------

const CONFIG_PATH = process.env.GAWD_VOICE_CONFIG
    || join(process.env.HOME || '/home/gawd', '.gawd', 'state', 'voice.json');

// Self-locating paths: prefer env override, then install-relative sibling bin/,
// then canonical container install path. This replaces <install-root>/ hardcodes
// which do not exist on a Prophit's machine. (H-2 fix, phase4-20260609)
const _RELAY_DIR = new URL('.', import.meta.url).pathname;
const _GAWD_LIB   = join(_RELAY_DIR, '..', '..'); // forge/voice/../../ = forge/ ; in-image = /usr/local/lib/gawd/
const _GAWD_BIN_SIBLING = join(_RELAY_DIR, '..', 'bin'); // sibling bin/ if present

const LLM_CALL_BIN = process.env.GAWD_LLM_CALL_BIN
    || join(_GAWD_BIN_SIBLING, 'gawdfather-llm-call');

const SCHEMA_PATH = process.env.GAWD_VOICE_SCHEMA
    || join(_RELAY_DIR, 'config-schema.json');

async function loadConfig() {
    try {
        const raw = await readFile(CONFIG_PATH, 'utf8');
        return JSON.parse(raw);
    } catch (err) {
        if (err.code === 'ENOENT') {
            console.log(`[voice-relay] config not found at ${CONFIG_PATH} — voice disabled.`);
            return null;
        }
        throw err;
    }
}

function checkEnvKey(envName) {
    const v = process.env[envName];
    return typeof v === 'string' && v.length > 0;
}

// ---------------------------------------------------------------------------
// BLOCKER 4: WebSocket upgrade authentication
// ---------------------------------------------------------------------------
//
// The browser voice WebSocket previously had ZERO auth — anyone who could reach
// the URL could drive paid STT/LLM/TTS without limit. We now require, at
// upgrade time:
//   1. A short-lived signed TICKET minted by the authenticated dashboard
//      session (auth.py:issue_voice_ticket), verified here with the SAME
//      dashboard_signing.key via portable HMAC-SHA256.
//   2. An Origin header on the request matching a configured allowlist.
// Reject the upgrade if either is missing/invalid.
//
// Ticket format (must match auth.py): b64url(payloadJson).b64url(hmacSha256)
// payload = {"aud":"voice-relay","cid":<chat_id>,"exp":<unix_ts>}

const VOICE_TICKET_AUD = 'voice-relay';

// Where the dashboard writes its signing key (config.py SECRETS_DIR).
const SIGNING_KEY_PATH = process.env.GAWD_DASHBOARD_SIGNING_KEY_PATH
    || join(process.env.HOME || '/home/gawd', '.gawd', '.secrets', 'dashboard_signing.key');

function loadSigningKey() {
    try {
        const k = readFileSync(SIGNING_KEY_PATH, 'utf8').trim();
        return k || null;
    } catch {
        return null; // missing key → all tickets fail closed (deny)
    }
}

function b64urlDecode(s) {
    const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
    return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/') + pad, 'base64');
}

function constantTimeEqualStr(a, b) {
    const ab = Buffer.from(a, 'utf8');
    const bb = Buffer.from(b, 'utf8');
    if (ab.length !== bb.length) return false;
    return timingSafeEqual(ab, bb);
}

// Verify a voice ticket. Returns the chat_id (number) if valid, else null.
// NEVER logs the signing key or the ticket signature.
function verifyVoiceTicket(ticket, signingKey) {
    if (!ticket || !signingKey) return null;
    const parts = String(ticket).split('.');
    if (parts.length !== 2) return null;
    const [p64, sig64] = parts;
    const expectedSig = createHmac('sha256', signingKey).update(p64).digest();
    let providedSig;
    try { providedSig = b64urlDecode(sig64); } catch { return null; }
    if (providedSig.length !== expectedSig.length) return null;
    if (!timingSafeEqual(providedSig, expectedSig)) return null;
    let payload;
    try { payload = JSON.parse(b64urlDecode(p64).toString('utf8')); }
    catch { return null; }
    if (!payload || payload.aud !== VOICE_TICKET_AUD) return null;
    if (typeof payload.exp !== 'number' || payload.exp < Math.floor(Date.now() / 1000)) return null;
    if (typeof payload.cid !== 'number') return null;
    return payload.cid;
}

// Build the Origin allowlist from config. If browser_relay.allowed_origins is
// set, use it verbatim; otherwise derive from cloudflared_hostname. Empty list
// means "deny all browser origins" (fail closed) — the operator must opt in.
function buildOriginAllowlist(config) {
    const br = config.browser_relay || {};
    if (Array.isArray(br.allowed_origins) && br.allowed_origins.length) {
        return br.allowed_origins.map((o) => String(o).replace(/\/+$/, ''));
    }
    if (br.cloudflared_hostname) {
        return [`https://${br.cloudflared_hostname}`];
    }
    return [];
}

function originAllowed(origin, allowlist) {
    if (!origin) return false;
    const norm = String(origin).replace(/\/+$/, '');
    return allowlist.includes(norm);
}

// Extract the ticket from either ?ticket= query param or the
// Sec-WebSocket-Protocol header (the only header a browser WebSocket can set).
function extractTicket(req) {
    try {
        const url = new URL(req.url, 'http://localhost');
        const q = url.searchParams.get('ticket');
        if (q) return q;
    } catch { /* fall through */ }
    const proto = req.headers['sec-websocket-protocol'];
    if (proto) {
        // Browsers send a comma-separated list; we look for "ticket.<value>".
        for (const raw of String(proto).split(',')) {
            const p = raw.trim();
            if (p.startsWith('ticket.')) return p.slice('ticket.'.length);
        }
    }
    return null;
}

// verifyClient for the ws WebSocketServer. Returns true to accept the upgrade,
// false to reject. Closes BLOCKER 4: no ticket / bad ticket / bad origin → deny.
function makeVerifyClient(config) {
    const allowlist = buildOriginAllowlist(config);
    return (info) => {
        const req = info.req;
        const signingKey = loadSigningKey();
        if (!signingKey) {
            console.warn('[voice-relay] upgrade denied: signing key unavailable (fail closed)');
            return false;
        }
        if (!originAllowed(req.headers.origin, allowlist)) {
            console.warn(`[voice-relay] upgrade denied: origin not allowed (${req.headers.origin || 'none'})`);
            return false;
        }
        const ticket = extractTicket(req);
        const cid = verifyVoiceTicket(ticket, signingKey);
        if (cid === null) {
            console.warn('[voice-relay] upgrade denied: missing/invalid ticket');
            return false;
        }
        // Stash for the session handler (logging only — never the ticket itself).
        req.gawdVoiceChatId = cid;
        return true;
    };
}

// ---------------------------------------------------------------------------
// Provider interface — every STT/TTS provider implements these contracts.
// ---------------------------------------------------------------------------
//
// STT provider:
//   async transcribe(audioBytes: Buffer, opts: { language?: string }) -> string
//
// TTS provider:
//   async synthesize(text: string, opts: { voiceId: string, format: string }) -> Buffer
//
// Loaded by name. Mock providers are used for tests; real providers gated on
// their respective API key env var. NEVER hardcode an API key value here.

function loadSttProvider(sttConfig) {
    const { provider, api_key_env, endpoint_override } = sttConfig;
    switch (provider) {
        case 'mock':
            return {
                transcribe: async () => '[mock transcription]',
            };
        case 'elevenlabs':
            return makeElevenLabsStt({ apiKeyEnv: api_key_env, endpoint: endpoint_override });
        case 'openai-whisper-api':
            return makeOpenAiWhisperStt({ apiKeyEnv: api_key_env, endpoint: endpoint_override });
        case 'local-whisper':
            return makeLocalWhisperStt({ endpoint: endpoint_override });
        default:
            throw new Error(`[voice-relay] unknown STT provider: ${provider}`);
    }
}

function loadTtsProvider(ttsConfig) {
    const { provider, api_key_env, endpoint_override } = ttsConfig;
    switch (provider) {
        case 'mock':
            return {
                synthesize: async () => Buffer.from('MOCK_AUDIO'),
            };
        case 'elevenlabs':
            return makeElevenLabsTts({ apiKeyEnv: api_key_env, endpoint: endpoint_override, opts: ttsConfig });
        case 'openai-tts':
            return makeOpenAiTts({ apiKeyEnv: api_key_env, endpoint: endpoint_override, opts: ttsConfig });
        case 'local-piper':
            return makeLocalPiperTts({ endpoint: endpoint_override, opts: ttsConfig });
        default:
            throw new Error(`[voice-relay] unknown TTS provider: ${provider}`);
    }
}

// ElevenLabs STT — implementation behind the interface.
function makeElevenLabsStt({ apiKeyEnv, endpoint }) {
    const url = endpoint || 'https://api.elevenlabs.io/v1/speech-to-text';
    return {
        async transcribe(audioBytes, opts = {}) {
            const apiKey = process.env[apiKeyEnv];
            if (!apiKey) throw new Error(`STT env var ${apiKeyEnv} not set`);
            const form = new FormData();
            form.append('audio', new Blob([audioBytes]), 'audio.ogg');
            if (opts.language && opts.language !== 'auto') {
                form.append('language', opts.language);
            }
            const res = await fetch(url, {
                method: 'POST',
                headers: { 'xi-api-key': apiKey },
                body: form,
            });
            if (!res.ok) {
                throw new Error(`STT API error ${res.status}: ${await res.text()}`);
            }
            const json = await res.json();
            return json.text || '';
        },
    };
}

// ElevenLabs TTS — implementation behind the interface.
function makeElevenLabsTts({ apiKeyEnv, endpoint, opts }) {
    const base = endpoint || 'https://api.elevenlabs.io/v1/text-to-speech';
    return {
        async synthesize(text, callOpts) {
            const apiKey = process.env[apiKeyEnv];
            if (!apiKey) throw new Error(`TTS env var ${apiKeyEnv} not set`);
            const voiceId = callOpts.voiceId;
            if (!voiceId) throw new Error('TTS voiceId required');
            const url = `${base}/${voiceId}`;
            const body = {
                text,
                voice_settings: {
                    stability: opts.stability ?? 0.5,
                    similarity_boost: opts.similarity_boost ?? 0.75,
                },
            };
            const acceptHeader = callOpts.format === 'ogg_opus'
                ? 'audio/ogg'
                : callOpts.format === 'pcm_16000'
                    ? 'audio/pcm'
                    : 'audio/mpeg';
            const res = await fetch(url, {
                method: 'POST',
                headers: {
                    'xi-api-key': apiKey,
                    'Content-Type': 'application/json',
                    'Accept': acceptHeader,
                },
                body: JSON.stringify(body),
            });
            if (!res.ok) {
                throw new Error(`TTS API error ${res.status}: ${await res.text()}`);
            }
            return Buffer.from(await res.arrayBuffer());
        },
    };
}

// OpenAI Whisper / TTS — stub: real implementation follows the same pattern.
function makeOpenAiWhisperStt({ apiKeyEnv, endpoint }) {
    return {
        async transcribe() {
            const apiKey = process.env[apiKeyEnv];
            if (!apiKey) throw new Error(`STT env var ${apiKeyEnv} not set`);
            throw new Error('openai-whisper-api STT: implementation pending — see runbook §4');
        },
    };
}
function makeOpenAiTts({ apiKeyEnv }) {
    return {
        async synthesize() {
            const apiKey = process.env[apiKeyEnv];
            if (!apiKey) throw new Error(`TTS env var ${apiKeyEnv} not set`);
            throw new Error('openai-tts: implementation pending — see runbook §4');
        },
    };
}

// Local-Whisper / Local-Piper — for privacy-preserving rungs.
function makeLocalWhisperStt({ endpoint }) {
    const url = endpoint || 'http://127.0.0.1:11437/stt';
    return {
        async transcribe(audioBytes, opts = {}) {
            const res = await fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/octet-stream' },
                body: audioBytes,
            });
            if (!res.ok) {
                throw new Error(`local-whisper error ${res.status}`);
            }
            const json = await res.json();
            return json.text || '';
        },
    };
}
function makeLocalPiperTts({ endpoint, opts }) {
    const url = endpoint || 'http://127.0.0.1:11438/tts';
    return {
        async synthesize(text, callOpts) {
            const res = await fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ text, voice_id: callOpts.voiceId }),
            });
            if (!res.ok) {
                throw new Error(`local-piper error ${res.status}`);
            }
            return Buffer.from(await res.arrayBuffer());
        },
    };
}

// ---------------------------------------------------------------------------
// LLM resolution — routes through gawdfather-llm-call. Same chain the rest
// of the daemon uses. THIS IS THE MODEL-AGNOSTIC PIVOT.
// ---------------------------------------------------------------------------

async function resolveLlm(llmConfig, transcript) {
    // Write the prompt to a temp file (the llm-call binary contract).
    const tmpDir = await mkdir(join(tmpdir(), 'gawd-voice'), { recursive: true });
    const promptFile = join(tmpdir(), 'gawd-voice', `voice-${randomUUID()}.prompt`);
    await writeFile(promptFile, transcript, 'utf8');

    // Determine call arguments by mode.
    // Note: no model name literals here; everything flows from config.
    let bin;
    let args;
    const maxTokens = String(llmConfig.max_tokens ?? 512);

    if (llmConfig.mode === 'chain') {
        // Pass empty model arg --> the LLM caller binary uses the daemon's
        // primary chain (OpenClaw config). This is the default; same model
        // the Gawd uses elsewhere.
        bin = LLM_CALL_BIN;
        args = ['', promptFile, maxTokens];
    } else if (llmConfig.mode === 'tier') {
        // Tier-based dispatch via the dispatch.sh library. Tier name is
        // resolved at runtime; no model literal here.
        if (!llmConfig.tier) {
            throw new Error('llm.mode=tier but llm.tier missing in config');
        }
        // In-image: /usr/local/lib/gawd/runtime/lib/dispatch-cli.sh.
        // Resolved self-relative so it works on any machine (H-2 fix, phase4-20260609).
        bin = process.env.GAWD_DISPATCH_CLI_BIN
            || join(_GAWD_LIB, 'runtime', 'lib', 'dispatch-cli.sh');
        args = [llmConfig.tier, promptFile, maxTokens];
        // If the CLI wrapper does not exist (it is a small shell adapter
        // around the sourced dispatch.sh), fall back to direct llm-call.
        if (!existsSync(bin)) {
            bin = LLM_CALL_BIN;
            args = ['', promptFile, maxTokens];
        }
    } else if (llmConfig.mode === 'explicit') {
        if (!llmConfig.model_id) {
            throw new Error('llm.mode=explicit but llm.model_id missing in config');
        }
        bin = LLM_CALL_BIN;
        args = [llmConfig.model_id, promptFile, maxTokens];
        console.warn(`[voice-relay] DRIFT: explicit model pin in voice config: ${llmConfig.model_id}. Audit recommended.`);
    } else {
        throw new Error(`unknown llm.mode: ${llmConfig.mode}`);
    }

    // Spawn the caller. Capture stdout.
    return new Promise((resolve, reject) => {
        const proc = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
        let stdout = '';
        let stderr = '';
        proc.stdout.on('data', (d) => { stdout += d.toString('utf8'); });
        proc.stderr.on('data', (d) => { stderr += d.toString('utf8'); });
        proc.on('close', (code) => {
            // Best-effort cleanup of the prompt file. Ignore errors.
            (async () => { try { await import('node:fs/promises').then(m => m.unlink(promptFile)); } catch {} })();
            if (code === 0) resolve(stdout.trim());
            else reject(new Error(`llm-call exit ${code}: ${stderr.trim()}`));
        });
    });
}

// ---------------------------------------------------------------------------
// Graceful-failure helpers
// ---------------------------------------------------------------------------

function preflight(config) {
    // Returns { ok: true } or { ok: false, reason } and applies the
    // fail_graceful.on_missing_api_key policy.
    if (!config) return { ok: false, reason: 'no_config' };
    if (config.enabled === false) return { ok: false, reason: 'disabled' };

    const sttKeyEnv = config.stt?.api_key_env;
    const ttsKeyEnv = config.tts?.api_key_env;

    const sttProvider = config.stt?.provider;
    const ttsProvider = config.tts?.provider;
    // Local/mock providers do not need API keys.
    const sttNeedsKey = !['local-whisper', 'mock'].includes(sttProvider);
    const ttsNeedsKey = !['local-piper', 'mock'].includes(ttsProvider);

    const sttKeyOk = !sttNeedsKey || checkEnvKey(sttKeyEnv);
    const ttsKeyOk = !ttsNeedsKey || checkEnvKey(ttsKeyEnv);

    if (sttKeyOk && ttsKeyOk) return { ok: true };

    const missing = [];
    if (!sttKeyOk) missing.push(sttKeyEnv);
    if (!ttsKeyOk) missing.push(ttsKeyEnv);

    const policy = config.fail_graceful?.on_missing_api_key || 'disable_voice';
    if (policy === 'fail_daemon') {
        return { ok: false, reason: `fail_daemon: missing keys ${missing.join(', ')}`, fatal: true };
    }
    // disable_voice: graceful exit; per acceptance criterion 8, voice never blocks startup.
    return { ok: false, reason: `disable_voice: missing keys ${missing.join(', ')}` };
}

// ---------------------------------------------------------------------------
// WebSocket session handler
// ---------------------------------------------------------------------------

function attachSessionHandler(wss, providers, config) {
    const stt = providers.stt;
    const tts = providers.tts;
    const llmConfig = config.llm;
    const voiceId = config.voice_id;
    const ttsFormat = config.tts?.format || 'mp3';
    const maxSessionMs = (config.browser_relay?.max_session_seconds || 600) * 1000;

    wss.on('connection', (ws, req) => {
        const sessionId = randomUUID();
        const startedAt = Date.now();
        console.log(`[voice-relay] session ${sessionId} opened from ${req.socket.remoteAddress}`);

        const timer = setTimeout(() => {
            try {
                ws.send(JSON.stringify({ type: 'session_timeout', sessionId }));
            } catch {}
            ws.close(1000, 'session_timeout');
        }, maxSessionMs);

        let audioChunks = [];

        ws.on('message', async (data, isBinary) => {
            if (isBinary) {
                // Binary frame = audio chunk
                audioChunks.push(Buffer.from(data));
                return;
            }
            // Text frame = control message (e.g., utterance_end)
            let msg;
            try { msg = JSON.parse(data.toString('utf8')); }
            catch { ws.send(JSON.stringify({ type: 'error', error: 'invalid_json' })); return; }

            if (msg.type === 'utterance_end') {
                // Drain: STT -> LLM -> TTS -> back
                const audio = Buffer.concat(audioChunks);
                audioChunks = [];

                let transcript;
                try {
                    transcript = await stt.transcribe(audio, { language: config.stt?.language });
                } catch (err) {
                    return handleSttFailure(ws, config, err);
                }
                ws.send(JSON.stringify({ type: 'transcript', text: transcript }));

                let reply;
                try {
                    reply = await resolveLlm(llmConfig, transcript);
                } catch (err) {
                    ws.send(JSON.stringify({ type: 'error', stage: 'llm', error: String(err.message) }));
                    return;
                }
                ws.send(JSON.stringify({ type: 'reply_text', text: reply }));

                let audioReply;
                try {
                    audioReply = await tts.synthesize(reply, { voiceId, format: ttsFormat });
                } catch (err) {
                    return handleTtsFailure(ws, config, reply, err);
                }
                ws.send(audioReply, { binary: true });
                ws.send(JSON.stringify({ type: 'reply_end' }));
            }
        });

        ws.on('close', () => {
            clearTimeout(timer);
            console.log(`[voice-relay] session ${sessionId} closed (${Date.now() - startedAt}ms)`);
        });

        ws.on('error', (err) => {
            console.error(`[voice-relay] session ${sessionId} error:`, err.message);
        });
    });
}

function handleSttFailure(ws, config, err) {
    const policy = config.fail_graceful?.on_stt_failure || 'retry_once_then_text';
    console.error(`[voice-relay] STT failure (policy=${policy}):`, err.message);
    // For v1, all three policies degrade the same way at the WS layer: send
    // an error frame + a text apology. The Gawd's main runtime decides
    // whether to surface this to the Prophit; relay just emits.
    ws.send(JSON.stringify({
        type: 'error',
        stage: 'stt',
        error: String(err.message),
        degrade: 'text',
    }));
}

function handleTtsFailure(ws, config, replyText, err) {
    const policy = config.fail_graceful?.on_tts_failure || 'retry_once_then_text';
    console.error(`[voice-relay] TTS failure (policy=${policy}):`, err.message);
    // Per acceptance criterion 8: never silently drop the Gawd's response.
    ws.send(JSON.stringify({
        type: 'reply_text_only',
        text: replyText,
        error: String(err.message),
        degrade: 'text',
    }));
}

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

async function main() {
    const config = await loadConfig();
    const pf = preflight(config);
    if (!pf.ok) {
        console.log(`[voice-relay] not starting: ${pf.reason}`);
        process.exit(pf.fatal ? 1 : 0);
    }

    if (!config.browser_relay?.enabled) {
        console.log('[voice-relay] browser_relay.enabled=false — exiting cleanly (Telegram voice still works via separate handler).');
        process.exit(0);
    }

    let stt, tts;
    try {
        stt = loadSttProvider(config.stt);
        tts = loadTtsProvider(config.tts);
    } catch (err) {
        console.error(`[voice-relay] provider load failure: ${err.message}`);
        process.exit(1);
    }

    const port = config.browser_relay.port || 8080;
    const host = config.browser_relay.bind_address || '127.0.0.1';

    const httpServer = createServer((req, res) => {
        if (req.url === '/health') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: true, voice: 'enabled' }));
            return;
        }
        res.writeHead(404);
        res.end();
    });

    // BLOCKER 4: authenticate every upgrade — signed ticket + origin allowlist.
    const wss = new WebSocketServer({
        server: httpServer,
        path: '/voice',
        verifyClient: makeVerifyClient(config),
    });
    attachSessionHandler(wss, { stt, tts }, config);

    httpServer.listen(port, host, () => {
        console.log(`[voice-relay] listening on ws://${host}:${port}/voice (browser-mic relay)`);
        console.log(`[voice-relay] llm mode: ${config.llm.mode}; stt: ${config.stt.provider}; tts: ${config.tts.provider}`);
    });

    // Graceful shutdown.
    const shutdown = (sig) => {
        console.log(`[voice-relay] ${sig} received — shutting down.`);
        wss.close();
        httpServer.close(() => process.exit(0));
    };
    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
}

// Export internals for tests.
export {
    loadConfig,
    loadSttProvider,
    loadTtsProvider,
    resolveLlm,
    preflight,
    attachSessionHandler,
    verifyVoiceTicket,
    buildOriginAllowlist,
    originAllowed,
    extractTicket,
    makeVerifyClient,
};

// Run if invoked directly.
const isDirectRun = import.meta.url === `file://${process.argv[1]}`;
if (isDirectRun) {
    main().catch((err) => {
        console.error('[voice-relay] fatal:', err);
        process.exit(1);
    });
}
