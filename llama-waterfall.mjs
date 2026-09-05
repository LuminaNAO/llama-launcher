#!/usr/bin/env node

// llama-waterfall — priority failover proxy for llama.cpp endpoints.
//
// Routes inference traffic across N independent named "portals", each a
// routing table with its own listen port and ordered endpoint list
// (fastest first). Two portals exist by default:
//
//   [agent]     :40800  — the main agent endpoint (freeclaw points here)
//   [subagent]  :40810  — the sub-agent endpoint
//
// and waterfall.conf sections define any further portals ([a-z0-9-]+ names,
// optional "port = N" line per section).
//
// If the preferred tier is down the request cascades to the next tier;
// when a faster tier recovers it is promoted back after a hysteresis
// period. Clients point at this proxy once, permanently.
//
// Architecture: see docs/WATERFALL.md. The layering invariant is that
// deep-proxy belongs to a node (manages that machine's KV slot cache) and
// waterfall routes BETWEEN nodes, staying stateless. Each tier endpoint is
// normally a node's deep-proxy on port 40801.
//
// Usage:
//   llama-waterfall.mjs                       — start server if needed, open TUI.
//       q closes the server too IF this invocation started it (else detaches);
//       Q always stops the server.
//   llama-waterfall.mjs serve [agent-port] [--subagent-port <n>]
//       [--portal <name:port> …] [--config <path>] [--socket <path>]
//       [--api-key <key>] [--poll-interval <sec>] [--promote-after <n>]
//       [--connect-timeout <ms>] [--stall-timeout <sec>] [--max-body-mb <n>]
//   llama-waterfall.mjs tui    [--socket <path>]   — attach-only dashboard
//   llama-waterfall.mjs stop   [--socket <path>]   — stop server + attached TUIs
//   llama-waterfall.mjs status [--json] [--socket <path>]
//   llama-waterfall.mjs portal list|add <name> [--port <n>]|rm <name>
//
// Persistence: waterfall.conf holds every portal ([name] sections with an
// optional "port = N" line; legacy headerless files read as [agent], and
// [agent]/[subagent] default to :40800/:40810 when port= is absent).
// Endpoint order, labels, disabled (!) and pinned (*) state are saved on
// `w`/`write` AND automatically when the server exits (stop command,
// signals, owned-TUI quit).
//
// Failure semantics:
//   - Request bodies are buffered so a failed attempt can be replayed
//     against the next tier.
//   - Connect-refused / connect-timeout / upstream 502/503 mark the tier
//     down and cascade. llama-server answers 503 while a model is loading,
//     so a loading node correctly waterfalls to the next tier.
//   - The COMMIT POINT is the first response body byte, not the headers:
//     streaming responses are committed when the first SSE chunk arrives,
//     so a tier dying during prefill/queueing fails over invisibly.
//     Non-streaming responses are buffered in full and replay on the next
//     tier if the upstream dies anywhere mid-body.
//   - A pre-commit stall timeout (--stall-timeout, default 600s, 0=off)
//     catches black-holed tiers (power loss, dropped WireGuard peer — no
//     TCP reset ever arrives): no response activity before the first body
//     byte for that long → tier marked down, request cascades. It disarms
//     at the first forwarded byte, so long generations are never cut.
//   - Once body bytes have reached the client, a dying upstream fails the
//     request (tier marked down); the client's retry lands on the next
//     tier. Mid-generation failover would duplicate already-streamed
//     tokens and is impossible by design.
//   - The connect timeout applies ONLY to TCP establishment — inference
//     may legitimately take minutes before response bytes.

import { createServer as createHttpServer, request as httpRequest } from "node:http";
import { createServer as createNetServer, connect as netConnect } from "node:net";
import { readFileSync, writeFileSync, existsSync, unlinkSync, mkdirSync, realpathSync, openSync } from "node:fs";
import { spawn } from "node:child_process";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

// ── Root dir (repo checkout vs packaged install) ──────────────────────────
const SCRIPT_PATH = realpathSync(fileURLToPath(import.meta.url));
const SCRIPT_DIR = dirname(SCRIPT_PATH);
const ROOT_DIR = /^\/usr(\/local)?\/(lib|bin|share)\//.test(SCRIPT_DIR + "/")
    ? (process.env.LLAMA_LAUNCHER_DIR ||
       join(process.env.XDG_DATA_HOME || join(homedir(), ".local", "share"), "llama-launcher"))
    : SCRIPT_DIR;

const DEFAULT_CONFIG = join(ROOT_DIR, "waterfall.conf");
const DEFAULT_SOCKET = join(ROOT_DIR, "waterfall.sock");
const SERVER_LOG = join(ROOT_DIR, "waterfall.log");
// Built-in default listen ports for the two canonical portals. Any other
// portal must get its port from a "port = N" conf line, --portal name:port,
// or portal add --port. (Env overrides exist so test suites can exercise
// the defaulting chain without touching the real ports.)
const DEFAULT_PORTS = {
    agent: Number(process.env.LLAMA_WATERFALL_AGENT_PORT) || 40800,
    subagent: Number(process.env.LLAMA_WATERFALL_SUBAGENT_PORT) || 40810,
};
const PORTAL_NAME_RE = /^[a-z0-9-]+$/;

// ── Config (filled by serve()) ────────────────────────────────────────────
const cfg = {
    configPath: DEFAULT_CONFIG,
    socketPath: DEFAULT_SOCKET,
    apiKey: "ollama-local",
    pollIntervalSec: 10,
    promoteAfter: 3,
    connectTimeoutMs: 2000,
    stallTimeoutMs: 600_000,   // pre-commit only; 0 disables
    maxBodyBytes: 64 * 1024 * 1024,
};

// ── Runtime state ─────────────────────────────────────────────────────────
// N named portals (routing tables), each with its own listener, endpoint
// list and pin. [agent]/[subagent] exist by default; waterfall.conf
// sections and `portal add` define the rest.
// portal = { name, listenPort, endpoints, pinned, activeKey, server }
// endpoints[i] = {
//   host, port, label,           // from waterfall.conf (label optional)
//   enabled,                     // x/X toggles; persisted as "!" prefix
//   state,                       // "unknown" | "healthy" | "down"
//   consecutiveHealthy,          // hysteresis counter for promote-back
//   latencyMs,                   // last /health round-trip
//   requests, failures, inflight,
//   lastError, lastErrorAt,
//   model, nCtx,                 // from /props (best effort)
//   sockets,                     // live upstream sockets (for hard disable)
// }
function newPortal(name, listenPort = null) {
    return { name, listenPort, endpoints: [], pinned: null, activeKey: null, server: null };
}
const portals = [
    newPortal("agent", DEFAULT_PORTS.agent),
    newPortal("subagent", DEFAULT_PORTS.subagent),
];
// serve-flag port overrides (positional agent-port, --subagent-port,
// --portal name:port). They force the portal to exist and beat conf port=
// lines on every (re)load for this process lifetime.
const cliPorts = new Map();
let serving = false;        // serve() is running — new portals get listeners
let dirty = false;          // runtime portals differ from waterfall.conf
const startedAt = Date.now();
const events = [];          // ring buffer of { ts, line }
const EVENTS_MAX = 200;
const subscribers = new Set();  // control-socket connections in subscribe mode

const SPEC_RE = /^(\[?[A-Za-z0-9_.:-]+\]?):(\d+)(?:\s+(.*))?$/;

function epKey(ep) { return `${ep.host}:${ep.port}`; }
function epName(t, ep, i) { return `${t.name} tier ${i + 1} (${ep.label || epKey(ep)})`; }

function newEndpoint(host, port, label = "") {
    return {
        host, port, label,
        enabled: true, state: "unknown", consecutiveHealthy: 0,
        latencyMs: null, requests: 0, failures: 0, inflight: 0,
        lastError: null, lastErrorAt: null, model: null, nCtx: null,
        sockets: new Set(),
    };
}

function parseSpec(spec) {
    const m = String(spec || "").trim().match(SPEC_RE);
    if (!m) throw new Error("expected host:port [label]");
    return newEndpoint(m[1].replace(/^\[|\]$/g, ""), Number(m[2]), (m[3] || "").trim());
}

function resolvePortal(name) {
    if (name === undefined || name === null || name === "") return portals[0];
    const t = portals.find(t => t.name === name || (name === "sub" && t.name === "subagent"));
    if (!t) throw new Error(`unknown portal: ${name} (have: ${portals.map(p => p.name).join(", ") || "none"})`);
    return t;
}

function logEvent(line) {
    const ts = Date.now();
    events.push({ ts, line });
    if (events.length > EVENTS_MAX) events.shift();
    const hh = new Date(ts).toTimeString().slice(0, 8);
    console.log(`[${hh}] ${line}`);
    broadcast();
}

// ── waterfall.conf ────────────────────────────────────────────────────────
// Sectioned: one [name] header per portal ([a-z0-9-]+), an optional
// "port = N" line, then one endpoint per line:
//   "host:port  # label"  — priority = line order
// prefixed with "!" if disabled, "*" if pinned. Lines before any section
// header belong to [agent] (legacy single-table files keep working), and
// [agent]/[subagent] default to :40800/:40810 when port= is absent.
function parseConfig(text) {
    const out = {};
    const sectionFor = (name) => (out[name] ??= { port: null, endpoints: [], pinned: null });
    let section = "agent";
    for (const raw of text.split("\n")) {
        let line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const sec = line.match(/^\[([a-z0-9-]+)\]$/i);
        if (sec) {
            section = sec[1].toLowerCase();
            sectionFor(section);
            continue;
        }
        if (line.match(/^\[/)) {
            console.error(`waterfall.conf: bad section header ${line} (names are [a-z0-9-]+) — its lines are ignored`);
            section = null;
            continue;
        }
        if (section === null) continue;
        const portLine = line.match(/^port\s*=\s*(\d+)$/i);
        if (portLine) {
            sectionFor(section).port = Number(portLine[1]);
            continue;
        }
        let disabled = false, pinnedFlag = false;
        while (line[0] === "!" || line[0] === "*") {
            if (line[0] === "!") disabled = true; else pinnedFlag = true;
            line = line.slice(1).trim();
        }
        const hashAt = line.indexOf("#");
        const spec = (hashAt === -1 ? line : line.slice(0, hashAt)).trim();
        const label = hashAt === -1 ? "" : line.slice(hashAt + 1).trim();
        let ep;
        try { ep = parseSpec(spec); } catch {
            console.error(`waterfall.conf: skipping unparseable line: ${raw}`);
            continue;
        }
        ep.label = label;
        ep.enabled = !disabled;
        const dst = sectionFor(section);
        if (pinnedFlag && dst.pinned === null) dst.pinned = dst.endpoints.length;
        dst.endpoints.push(ep);
    }
    return out;
}

// Apply a parsed config to the runtime portals: the conf defines the
// portal set (plus any portals forced by serve flags), and endpoints that
// persist keep their runtime stats/state (matched by host:port). Portals
// gained/lost or re-ported at runtime have their listeners started,
// closed, or re-bound in place.
function applyConfig(parsed) {
    const wanted = new Map(Object.entries(parsed));
    for (const name of cliPorts.keys()) {
        if (!wanted.has(name)) wanted.set(name, { port: null, endpoints: [], pinned: null });
    }
    // Drop portals the conf no longer defines (and no serve flag forces).
    for (const t of [...portals]) {
        if (wanted.has(t.name)) continue;
        if (t.server) { t.server.close(); t.server = null; logEvent(`portal [${t.name}] removed — listener on :${t.listenPort} closed`); }
        portals.splice(portals.indexOf(t), 1);
    }
    // (Re)build in conf order, keeping existing portal objects by name.
    const byName = new Map(portals.map(t => [t.name, t]));
    portals.length = 0;
    for (const [name, src] of wanted) {
        const t = byName.get(name) || newPortal(name);
        portals.push(t);
        const old = new Map(t.endpoints.map(ep => [epKey(ep), ep]));
        t.endpoints = src.endpoints.map(fresh => {
            const prev = old.get(epKey(fresh));
            if (!prev) return fresh;
            prev.label = fresh.label;
            prev.enabled = fresh.enabled;
            return prev;
        });
        t.pinned = src.pinned;
        // Port precedence: serve flag > conf port= > built-in default > keep.
        const port = cliPorts.get(name) ?? src.port ?? DEFAULT_PORTS[name] ?? t.listenPort;
        if (port === null) {
            console.error(`waterfall.conf: portal [${name}] has no port — add a "port = N" line (not listening)`);
        } else if (port !== t.listenPort || (serving && !t.server)) {
            if (t.server) { t.server.close(); t.server = null; }
            t.listenPort = port;
            if (serving) startProxy(t, false);
        }
    }
    dirty = false;
}

function loadConfig() {
    if (!existsSync(cfg.configPath)) return;
    applyConfig(parseConfig(readFileSync(cfg.configPath, "utf8")));
}

function writeConfig() {
    const lines = [
        "# waterfall.conf — llama-waterfall endpoint priority lists",
        "# One [name] section per portal ([a-z0-9-]+), a port = N line, then one",
        '# endpoint per line: host:port  # label — priority = line order, fastest',
        '# first. Prefix "!" = disabled, "*" = pinned.',
        "# Managed by the waterfall TUI (w key; also saved automatically on server",
        "# exit). Hand edits are fine — reload with r in the TUI or SIGHUP.",
    ];
    for (const t of portals) {
        lines.push("", `[${t.name}]`);
        if (t.listenPort !== null) lines.push(`port = ${t.listenPort}`);
        t.endpoints.forEach((ep, i) => {
            const flags = `${t.pinned === i ? "*" : ""}${ep.enabled ? "" : "!"}`;
            lines.push(`${flags}${epKey(ep)}${ep.label ? `  # ${ep.label}` : ""}`);
        });
    }
    lines.push("");
    writeFileSync(cfg.configPath, lines.join("\n"));
    dirty = false;
}

function reloadConfig() {
    if (existsSync(cfg.configPath)) applyConfig(parseConfig(readFileSync(cfg.configPath, "utf8")));
    for (const t of portals) {
        if (t.pinned !== null && t.pinned >= t.endpoints.length) t.pinned = null;
    }
    dirty = false;
}

// ── Tier selection ────────────────────────────────────────────────────────
// Pinned tier gets ALL traffic regardless of health (that is what pin
// means). Otherwise: enabled endpoints in priority order, known-down ones
// demoted to last-resort attempts rather than skipped entirely.
function candidateIndices(t) {
    if (t.pinned !== null && t.endpoints[t.pinned]?.enabled) return [t.pinned];
    const up = [], down = [];
    t.endpoints.forEach((ep, i) => {
        if (!ep.enabled) return;
        (ep.state === "down" ? down : up).push(i);
    });
    return [...up, ...down];
}

function currentActiveIndex(t) {
    const c = candidateIndices(t);
    return c.length ? c[0] : null;
}

function noteActiveChange(t, why) {
    const i = currentActiveIndex(t);
    const key = i === null ? null : epKey(t.endpoints[i]);
    if (key !== t.activeKey) {
        t.activeKey = key;
        if (i === null) logEvent(`[${t.name}] no active tier — all endpoints down or disabled (${why})`);
        else logEvent(`active → ${epName(t, t.endpoints[i], i)} (${why})`);
    } else {
        broadcast();
    }
}

function markDown(t, i, reason) {
    const ep = t.endpoints[i];
    ep.lastError = reason;
    ep.lastErrorAt = Date.now();
    ep.consecutiveHealthy = 0;
    if (ep.state !== "down") {
        ep.state = "down";
        logEvent(`${epName(t, ep, i)} DOWN (${reason})`);
        noteActiveChange(t, "failover");
    } else {
        broadcast();
    }
}

// ── Proxy dispatch ────────────────────────────────────────────────────────
function attemptUpstream(ep, clientReq, body) {
    return new Promise((resolve, reject) => {
        const headers = { ...clientReq.headers, host: epKey(ep) };
        delete headers["content-length"];
        if (body !== null) headers["content-length"] = String(body.length);

        const upReq = httpRequest({
            host: ep.host, port: ep.port,
            method: clientReq.method, path: clientReq.url, headers,
        });

        let settled = false;
        const settle = (fn, val) => { if (!settled) { settled = true; fn(val); } };

        // Connect timeout only — once the TCP connection is up, inference
        // may take arbitrarily long before response headers arrive.
        const connectTimer = setTimeout(() => {
            upReq.destroy(new Error("connect timeout"));
        }, cfg.connectTimeoutMs);
        upReq.on("socket", (sock) => {
            ep.sockets.add(sock);
            sock.on("close", () => ep.sockets.delete(sock));
            if (sock.connecting) sock.once("connect", () => clearTimeout(connectTimer));
            else clearTimeout(connectTimer);
        });

        // Pre-commit stall detector: a black-holed tier (power loss, dropped
        // WireGuard peer) never errors — the socket just goes silent. Idle
        // socket with no response activity for stallTimeoutMs → destroy and
        // cascade. dispatch() disarms this at the first forwarded body byte.
        if (cfg.stallTimeoutMs > 0) {
            upReq.setTimeout(cfg.stallTimeoutMs, () => upReq.destroy(new Error("stall timeout")));
        }

        upReq.on("response", (upRes) => {
            clearTimeout(connectTimer);
            settle(resolve, { upReq, upRes });
        });
        upReq.on("error", (err) => {
            clearTimeout(connectTimer);
            settle(reject, err);
        });

        if (body !== null) upReq.end(body);
        else upReq.end();
    });
}

async function dispatch(t, clientReq, clientRes, body) {
    const order = candidateIndices(t);
    if (!order.length) {
        clientRes.writeHead(503, { "content-type": "application/json" });
        clientRes.end(JSON.stringify({ error: { message: `waterfall[${t.name}]: no endpoints available` } }));
        return;
    }

    let lastErr = "unreachable";
    for (const i of order) {
        const ep = t.endpoints[i];
        if (clientRes.destroyed) return;
        ep.inflight++;
        broadcast();
        let up;
        try {
            up = await attemptUpstream(ep, clientReq, body);
        } catch (err) {
            ep.inflight--;
            ep.failures++;
            lastErr = err.code || err.message;
            markDown(t, i, lastErr);
            continue;
        }

        const { upReq, upRes } = up;
        // 502/503 before we have committed anything to the client means the
        // tier is not serving (llama-server says 503 while loading a model,
        // and a live deep-proxy fronting a dead server yields 502-ish
        // errors) — cascade. Anything else is forwarded verbatim.
        if (upRes.statusCode === 502 || upRes.statusCode === 503) {
            ep.inflight--;
            ep.failures++;
            lastErr = `HTTP ${upRes.statusCode}`;
            markDown(t, i, lastErr);
            upRes.resume();
            upReq.destroy();
            continue;
        }

        // Commit point: the FIRST BODY BYTE forwarded to the client — not
        // the headers. Until then this tier can still fail invisibly:
        // streaming responses commit on the first SSE chunk (so death
        // during prefill/queueing cascades), non-streaming responses are
        // buffered in full and replay if the upstream dies mid-body.
        const isStream = String(upRes.headers["content-type"] || "").includes("text/event-stream");
        const outcome = await new Promise((resolve) => {
            let committed = false;
            let done = false;
            const bufs = [];
            let bufBytes = 0;

            const commit = () => {
                if (committed) return;
                committed = true;
                upReq.setTimeout(0);  // disarm the stall detector
                clientRes.writeHead(upRes.statusCode, upRes.headers);
                for (const b of bufs) clientRes.write(b);
                bufs.length = 0;
            };
            const finish = (ok, why) => {
                if (done) return;
                done = true;
                ep.inflight--;
                if (ok) ep.requests++;
                else {
                    ep.failures++;
                    if (why) markDown(t, i, why);
                }
                broadcast();
                resolve({ done: true });
            };
            const retry = (why) => {
                if (done) return;
                done = true;
                ep.inflight--;
                ep.failures++;
                markDown(t, i, why);
                upReq.destroy();
                resolve({ retry: why });
            };

            upRes.on("data", (chunk) => {
                if (committed) {
                    if (!clientRes.write(chunk)) { upRes.pause(); clientRes.once("drain", () => upRes.resume()); }
                    return;
                }
                if (isStream) {
                    commit();
                    clientRes.write(chunk);
                    return;
                }
                bufs.push(chunk);
                bufBytes += chunk.length;
                // Too big to hold for replay — give up failover, start forwarding.
                if (bufBytes > cfg.maxBodyBytes) commit();
            });
            upRes.on("end", () => {
                commit();
                clientRes.end();
                finish(true);
            });
            upRes.on("error", (err) => {
                const why = err.code || err.message;
                if (!committed) retry(`pre-commit: ${why}`);
                else { finish(false, `mid-stream: ${why}`); clientRes.destroy(); }
            });
            // Premature upstream close doesn't always surface as "error" —
            // without this the client would hang on a half-finished
            // response forever.
            upRes.on("close", () => {
                if (upRes.complete) return;
                if (!committed) retry("pre-commit: connection closed");
                else { finish(false, "mid-stream: connection closed"); clientRes.destroy(); }
            });
            clientReq.on("close", () => {
                // Client went away — not the tier's fault; no point retrying.
                if (!upRes.complete && !done) { upReq.destroy(); finish(true); }
            });
        });
        if (outcome.retry) { lastErr = outcome.retry; continue; }
        return;
    }

    if (!clientRes.headersSent && !clientRes.destroyed) {
        clientRes.writeHead(503, { "content-type": "application/json" });
        clientRes.end(JSON.stringify({ error: { message: `waterfall[${t.name}]: all tiers failed (last: ${lastErr})` } }));
    }
}

// fatal: a failed bind at serve() startup kills the process (the ports are
// the whole point); portals added/re-ported at runtime just log the error
// so a busy port cannot take down the running portals.
function startProxy(t, fatal = true) {
    const server = createHttpServer((req, res) => {
        const chunks = [];
        let size = 0;
        let overflow = false;
        req.on("data", (c) => {
            size += c.length;
            if (size > cfg.maxBodyBytes) {
                overflow = true;
                req.destroy();
                if (!res.headersSent) {
                    res.writeHead(413, { "content-type": "application/json" });
                    res.end(JSON.stringify({ error: { message: "waterfall: request body too large to buffer for failover" } }));
                }
                return;
            }
            chunks.push(c);
        });
        req.on("end", () => {
            if (overflow) return;
            const body = chunks.length ? Buffer.concat(chunks) : null;
            dispatch(t, req, res, body).catch((err) => {
                console.error(`dispatch error: ${err.stack || err}`);
                if (!res.headersSent && !res.destroyed) {
                    res.writeHead(500, { "content-type": "application/json" });
                    res.end(JSON.stringify({ error: { message: `waterfall: ${err.message}` } }));
                }
            });
        });
        req.on("error", () => {});
    });
    server.keepAliveTimeout = 75_000;
    server.on("error", (err) => {
        if (fatal) {
            console.error(`waterfall: cannot listen on :${t.listenPort} for [${t.name}] — ${err.code || err.message}`);
            process.exit(1);
        }
        t.server = null;
        logEvent(`[${t.name}] cannot listen on :${t.listenPort} — ${err.code || err.message}`);
    });
    server.listen(t.listenPort, () => {
        logEvent(`[${t.name}] listening on :${t.listenPort} — ${t.endpoints.length} endpoint(s)`);
    });
    t.server = server;
    return server;
}

// ── Health polling ────────────────────────────────────────────────────────
function probe(ep, path, { method = "GET", body = null, timeoutMs = 6000 } = {}) {
    return new Promise((resolve, reject) => {
        const started = Date.now();
        const req = httpRequest({
            host: ep.host, port: ep.port, method, path,
            headers: {
                authorization: `Bearer ${cfg.apiKey}`,
                ...(body ? { "content-type": "application/json", "content-length": String(Buffer.byteLength(body)) } : {}),
            },
        }, (res) => {
            const chunks = [];
            res.on("data", (c) => chunks.push(c));
            res.on("end", () => resolve({
                status: res.statusCode,
                ms: Date.now() - started,
                body: Buffer.concat(chunks).toString("utf8"),
            }));
            res.on("error", reject);
        });
        req.setTimeout(timeoutMs, () => req.destroy(new Error("probe timeout")));
        req.on("error", reject);
        if (body) req.end(body);
        else req.end();
    });
}

async function fetchProps(ep) {
    try {
        const r = await probe(ep, "/props");
        if (r.status !== 200) return;
        const props = JSON.parse(r.body);
        if (props.model_path) ep.model = basename(String(props.model_path));
        const nCtx = props.default_generation_settings?.n_ctx ?? props.n_ctx;
        if (nCtx) ep.nCtx = Number(nCtx);
    } catch { /* best effort */ }
}

let pollTimer = null;
async function pollOnce() {
    await Promise.all(portals.flatMap(t => t.endpoints.map(async (ep) => {
        const i = t.endpoints.indexOf(ep);
        if (i === -1) return;  // removed mid-poll
        try {
            const r = await probe(ep, "/health");
            if (r.status !== 200) throw new Error(`HTTP ${r.status}`);
            ep.latencyMs = r.ms;
            ep.consecutiveHealthy++;
            if (ep.state === "unknown") {
                ep.state = "healthy";
                fetchProps(ep);
                logEvent(`${epName(t, ep, i)} healthy (${r.ms}ms)`);
                noteActiveChange(t, "startup");
            } else if (ep.state === "down") {
                if (ep.consecutiveHealthy >= cfg.promoteAfter) {
                    ep.state = "healthy";
                    fetchProps(ep);
                    logEvent(`${epName(t, ep, i)} healthy ×${cfg.promoteAfter} → promoted`);
                    noteActiveChange(t, "recovery");
                } else {
                    broadcast();
                }
            }
        } catch (err) {
            ep.latencyMs = null;
            const reason = err.code || err.message;
            if (ep.state !== "down") markDown(t, i, reason);
            else { ep.lastError = reason; ep.lastErrorAt = Date.now(); ep.consecutiveHealthy = 0; }
        }
    })));
    broadcast();
}

function startPoller() {
    pollOnce();
    pollTimer = setInterval(pollOnce, cfg.pollIntervalSec * 1000);
}

// ── Control socket (unix, JSON-lines) ─────────────────────────────────────
function statusSnapshot() {
    const ps = portals.map(t => ({
        name: t.name,
        listenPort: t.listenPort,
        pinned: t.pinned,
        active: currentActiveIndex(t),
        endpoints: t.endpoints.map(ep => ({
            host: ep.host, port: ep.port, label: ep.label,
            enabled: ep.enabled, state: ep.state,
            latencyMs: ep.latencyMs, requests: ep.requests, failures: ep.failures,
            inflight: ep.inflight, consecutiveHealthy: ep.consecutiveHealthy,
            lastError: ep.lastError, lastErrorAt: ep.lastErrorAt,
            model: ep.model, nCtx: ep.nCtx,
        })),
    }));
    return {
        configPath: cfg.configPath,
        uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
        dirty,
        pid: process.pid,
        pollIntervalSec: cfg.pollIntervalSec,
        promoteAfter: cfg.promoteAfter,
        portals: ps,
        tables: ps,   // deprecated alias — pre-portal consumers read .tables
        events: events.slice(-100),
    };
}

let broadcastPending = false;
function broadcast() {
    // Coalesce bursts of state changes into one push per tick.
    if (broadcastPending || subscribers.size === 0) { broadcastPending = subscribers.size > 0; return; }
    broadcastPending = true;
    setImmediate(() => {
        broadcastPending = false;
        const msg = JSON.stringify({ event: "state", data: statusSnapshot() }) + "\n";
        for (const conn of subscribers) {
            try { conn.write(msg); } catch { subscribers.delete(conn); }
        }
    });
}

function validIndex(t, i) {
    return Number.isInteger(i) && i >= 0 && i < t.endpoints.length;
}

function shutdownServer(why) {
    if (dirty) {
        try { writeConfig(); console.log(`saved ${cfg.configPath} on exit`); }
        catch (err) { console.error(`failed to save config on exit: ${err.message}`); }
    }
    console.log(`waterfall shutting down (${why})`);
    const msg = JSON.stringify({ event: "shutdown" }) + "\n";
    for (const conn of subscribers) { try { conn.write(msg); } catch { } }
    clearInterval(pollTimer);
    try { unlinkSync(cfg.socketPath); } catch { }
    // Give the shutdown event / command reply a tick to flush.
    setTimeout(() => process.exit(0), 100);
}

async function handleCommand(msg, conn) {
    const { cmd } = msg;
    switch (cmd) {
        case "status":
            return statusSnapshot();
        case "subscribe":
            subscribers.add(conn);
            conn.on("close", () => subscribers.delete(conn));
            return statusSnapshot();
        case "shutdown":
            shutdownServer("stop requested");
            return statusSnapshot();
        case "pin": {
            const t = resolvePortal(msg.portal ?? msg.table);
            if (msg.index === null) { t.pinned = null; dirty = true; logEvent(`[${t.name}] pin cleared`); }
            else if (validIndex(t, msg.index)) { t.pinned = msg.index; dirty = true; logEvent(`pinned to ${epName(t, t.endpoints[t.pinned], t.pinned)}`); }
            else throw new Error("bad index");
            noteActiveChange(t, "pin");
            return statusSnapshot();
        }
        case "setEnabled": {
            const t = resolvePortal(msg.portal ?? msg.table);
            if (!validIndex(t, msg.index)) throw new Error("bad index");
            const ep = t.endpoints[msg.index];
            ep.enabled = Boolean(msg.enabled);
            dirty = true;
            if (!ep.enabled && msg.hard) {
                for (const s of ep.sockets) s.destroy(new Error("hard disable"));
                logEvent(`${epName(t, ep, msg.index)} hard-disabled (${ep.sockets.size} socket(s) cut)`);
            } else {
                logEvent(`${epName(t, ep, msg.index)} ${ep.enabled ? "enabled" : `disabled${ep.inflight ? " (draining)" : ""}`}`);
            }
            if (t.pinned === msg.index && !ep.enabled) t.pinned = null;
            noteActiveChange(t, ep.enabled ? "enable" : "disable");
            return statusSnapshot();
        }
        case "add": {
            const t = resolvePortal(msg.portal ?? msg.table);
            const ep = parseSpec(msg.spec);
            const at = validIndex(t, msg.index) ? msg.index : t.endpoints.length;
            t.endpoints.splice(at, 0, ep);
            if (t.pinned !== null && t.pinned >= at) t.pinned++;
            dirty = true;
            logEvent(`added ${epName(t, ep, at)}`);
            noteActiveChange(t, "add");
            return statusSnapshot();
        }
        case "remove": {
            const t = resolvePortal(msg.portal ?? msg.table);
            if (!validIndex(t, msg.index)) throw new Error("bad index");
            const [ep] = t.endpoints.splice(msg.index, 1);
            if (t.pinned === msg.index) t.pinned = null;
            else if (t.pinned !== null && t.pinned > msg.index) t.pinned--;
            dirty = true;
            logEvent(`[${t.name}] removed ${ep.label || epKey(ep)}`);
            noteActiveChange(t, "remove");
            return statusSnapshot();
        }
        case "move": {
            const t = resolvePortal(msg.portal ?? msg.table);
            const { index, to } = msg;
            if (!validIndex(t, index) || !validIndex(t, to)) throw new Error("bad index");
            const [ep] = t.endpoints.splice(index, 1);
            t.endpoints.splice(to, 0, ep);
            if (t.pinned === index) t.pinned = to;
            else if (t.pinned !== null) {
                if (index < t.pinned && to >= t.pinned) t.pinned--;
                else if (index > t.pinned && to <= t.pinned) t.pinned++;
            }
            dirty = true;
            logEvent(`[${t.name}] moved ${ep.label || epKey(ep)} to rank ${to + 1}`);
            noteActiveChange(t, "move");
            return statusSnapshot();
        }
        case "edit": {
            const t = resolvePortal(msg.portal ?? msg.table);
            if (!validIndex(t, msg.index)) throw new Error("bad index");
            const old = t.endpoints[msg.index];
            const ep = parseSpec(msg.spec);
            ep.enabled = old.enabled;
            t.endpoints[msg.index] = ep;
            dirty = true;
            logEvent(`[${t.name}] edited rank ${msg.index + 1} → ${epKey(ep)}${ep.label ? ` (${ep.label})` : ""}`);
            noteActiveChange(t, "edit");
            return statusSnapshot();
        }
        case "write":
            writeConfig();
            logEvent(`wrote ${portals.map(t => `${t.endpoints.length} [${t.name}]`).join(" + ")} endpoint(s) to ${cfg.configPath}`);
            broadcast();
            return statusSnapshot();
        case "reload":
            reloadConfig();
            logEvent(`reloaded ${cfg.configPath} (${portals.map(t => `${t.endpoints.length} [${t.name}]`).join(", ")})`);
            for (const t of portals) noteActiveChange(t, "reload");
            return statusSnapshot();
        case "portalAdd": {
            const name = String(msg.name || "").trim();
            if (!PORTAL_NAME_RE.test(name)) throw new Error(`bad portal name: ${name || "(empty)"} (names are [a-z0-9-]+)`);
            if (portals.some(p => p.name === name)) throw new Error(`portal ${name} already exists`);
            const port = msg.port ?? cliPorts.get(name) ?? DEFAULT_PORTS[name];
            if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`portal ${name} needs --port <n> (no default port for that name)`);
            const t = newPortal(name, port);
            portals.push(t);
            if (serving) startProxy(t, false);
            dirty = true;
            logEvent(`portal [${name}] added on :${port}`);
            broadcast();
            return statusSnapshot();
        }
        case "portalRemove": {
            if (!msg.name) throw new Error("portal rm needs a name");
            const t = resolvePortal(msg.name);
            if (portals.length === 1) throw new Error("cannot remove the last portal");
            if (t.server) { t.server.close(); t.server = null; }
            for (const ep of t.endpoints) for (const s of ep.sockets) s.destroy(new Error("portal removed"));
            portals.splice(portals.indexOf(t), 1);
            dirty = true;
            logEvent(`portal [${t.name}] removed — listener on :${t.listenPort} closed`);
            broadcast();
            return statusSnapshot();
        }
        case "test": {
            const t = resolvePortal(msg.portal ?? msg.table);
            if (!validIndex(t, msg.index)) throw new Error("bad index");
            const ep = t.endpoints[msg.index];
            const name = epName(t, ep, msg.index);
            const result = { health: null, completion: null };
            try {
                const h = await probe(ep, "/health");
                result.health = { status: h.status, ms: h.ms };
            } catch (err) {
                result.health = { error: err.code || err.message };
            }
            if (result.health.status === 200) {
                await fetchProps(ep);
                try {
                    const body = JSON.stringify({
                        model: ep.model || "default",
                        messages: [{ role: "user", content: "hi" }],
                        max_tokens: 1, stream: false,
                    });
                    const c = await probe(ep, "/v1/chat/completions", { method: "POST", body, timeoutMs: 120_000 });
                    result.completion = { status: c.status, ms: c.ms };
                } catch (err) {
                    result.completion = { error: err.code || err.message };
                }
            }
            const hTxt = result.health.error ? `health FAIL (${result.health.error})` : `health ${result.health.status} ${result.health.ms}ms`;
            const cTxt = !result.completion ? "completion skipped"
                : result.completion.error ? `completion FAIL (${result.completion.error})`
                : `1-token completion ${result.completion.status} ${result.completion.ms}ms`;
            logEvent(`test ${name}: ${hTxt}, ${cTxt}${ep.model ? ` [${ep.model}]` : ""}`);
            return { ...result, model: ep.model, nCtx: ep.nCtx };
        }
        default:
            throw new Error(`unknown command: ${cmd}`);
    }
}

function startControlSocket() {
    if (existsSync(cfg.socketPath)) {
        // Refuse to clobber a live instance; clean up a stale socket.
        const alive = new Promise((resolve) => {
            const c = netConnect(cfg.socketPath);
            c.on("connect", () => { c.destroy(); resolve(true); });
            c.on("error", () => resolve(false));
        });
        return alive.then((isAlive) => {
            if (isAlive) {
                console.error(`another waterfall is already running on ${cfg.socketPath}`);
                process.exit(1);
            }
            unlinkSync(cfg.socketPath);
            return startControlSocket();
        });
    }
    const server = createNetServer((conn) => {
        let buf = "";
        conn.on("data", async (chunk) => {
            buf += chunk.toString("utf8");
            let nl;
            while ((nl = buf.indexOf("\n")) !== -1) {
                const line = buf.slice(0, nl).trim();
                buf = buf.slice(nl + 1);
                if (!line) continue;
                let msg;
                try { msg = JSON.parse(line); } catch { continue; }
                try {
                    const data = await handleCommand(msg, conn);
                    conn.write(JSON.stringify({ id: msg.id, ok: true, data }) + "\n");
                } catch (err) {
                    conn.write(JSON.stringify({ id: msg.id, ok: false, error: err.message }) + "\n");
                }
            }
        });
        conn.on("error", () => {});
    });
    server.listen(cfg.socketPath);
    return Promise.resolve(server);
}

// ── serve ─────────────────────────────────────────────────────────────────
function applyServeArgs(args) {
    // Port overrides: the legacy positional agent-port and --subagent-port,
    // plus the general --portal name:port (repeatable). Each forces the
    // portal to exist and beats conf port= lines (see cliPorts).
    if (args._[0] !== undefined) cliPorts.set("agent", Number(args._[0]));
    if (args["subagent-port"] !== undefined) cliPorts.set("subagent", Number(args["subagent-port"]));
    for (const spec of [].concat(args.portal ?? [])) {
        const m = String(spec).match(/^([a-z0-9-]+):(\d+)$/);
        if (!m) { console.error(`bad --portal: ${spec} (expected name:port, name = [a-z0-9-]+)`); process.exit(1); }
        cliPorts.set(m[1], Number(m[2]));
    }
    for (const [name, port] of cliPorts) {
        const t = portals.find(p => p.name === name) ?? portals[portals.push(newPortal(name)) - 1];
        t.listenPort = port;
    }
    if (args.config) cfg.configPath = args.config;
    if (args.socket) cfg.socketPath = args.socket;
    if (args["api-key"]) cfg.apiKey = args["api-key"];
    if (args["poll-interval"]) cfg.pollIntervalSec = Number(args["poll-interval"]);
    if (args["promote-after"]) cfg.promoteAfter = Number(args["promote-after"]);
    if (args["connect-timeout"]) cfg.connectTimeoutMs = Number(args["connect-timeout"]);
    if (args["stall-timeout"] !== undefined) cfg.stallTimeoutMs = Number(args["stall-timeout"]) * 1000;
    if (args["max-body-mb"]) cfg.maxBodyBytes = Number(args["max-body-mb"]) * 1024 * 1024;
}

async function serve(args) {
    applyServeArgs(args);

    mkdirSync(dirname(cfg.configPath), { recursive: true });
    loadConfig();
    for (const t of portals) {
        if (!t.endpoints.length) {
            console.error(`no [${t.name}] endpoints in ${cfg.configPath} — add lines like "127.0.0.1:40801  # local" (or use the TUI once running)`);
        }
    }

    await startControlSocket();
    for (const t of portals) {
        if (t.listenPort === null) { console.error(`portal [${t.name}] has no port — not listening`); continue; }
        startProxy(t);
    }
    serving = true;
    startPoller();

    process.on("SIGINT", () => shutdownServer("SIGINT"));
    process.on("SIGTERM", () => shutdownServer("SIGTERM"));
    process.on("SIGHUP", () => {
        reloadConfig();
        logEvent(`SIGHUP: reloaded ${cfg.configPath} (${portals.map(t => `${t.endpoints.length} [${t.name}]`).join(", ")})`);
        for (const t of portals) noteActiveChange(t, "reload");
    });
}

// ── Control-socket client (tui / status / stop) ───────────────────────────
function connectControl(socketPath) {
    return new Promise((resolve, reject) => {
        const conn = netConnect(socketPath);
        let buf = "";
        let nextId = 1;
        const waiters = new Map();
        const pushHandlers = new Set();
        conn.on("connect", () => resolve({
            conn,
            onPush(fn) { pushHandlers.add(fn); },
            send(cmd, extra = {}) {
                return new Promise((res, rej) => {
                    const id = nextId++;
                    waiters.set(id, { res, rej });
                    conn.write(JSON.stringify({ id, cmd, ...extra }) + "\n");
                });
            },
        }));
        conn.on("data", (chunk) => {
            buf += chunk.toString("utf8");
            let nl;
            while ((nl = buf.indexOf("\n")) !== -1) {
                const line = buf.slice(0, nl);
                buf = buf.slice(nl + 1);
                if (!line.trim()) continue;
                let msg;
                try { msg = JSON.parse(line); } catch { continue; }
                if (msg.event) { for (const fn of pushHandlers) fn(msg); }
                else if (waiters.has(msg.id)) {
                    const w = waiters.get(msg.id);
                    waiters.delete(msg.id);
                    msg.ok ? w.res(msg.data) : w.rej(new Error(msg.error));
                }
            }
        });
        conn.on("error", reject);
    });
}

function socketAlive(socketPath) {
    return new Promise((resolve) => {
        if (!existsSync(socketPath)) return resolve(false);
        const c = netConnect(socketPath);
        c.on("connect", () => { c.destroy(); resolve(true); });
        c.on("error", () => resolve(false));
    });
}

async function waitUntil(fn, timeoutMs = 8000, everyMs = 100) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (await fn()) return true;
        await new Promise(r => setTimeout(r, everyMs));
    }
    return false;
}

// ── CLI control subcommands (the same surface the TUI drives) ─────────────
// Ranks on the CLI are 1-based, matching the TUI display. Per-tier commands
// target the first portal ([agent]) by default; pass --portal <name> for
// any other. (--table is kept as a deprecated alias.)
function printStatus(s) {
    console.log(`waterfall  uptime ${fmtUptime(s.uptimeSec)}${s.dirty ? "  [+unsaved]" : ""}  conf ${s.configPath}`);
    for (const t of s.portals ?? s.tables) {
        console.log(`[${t.name}] :${t.listenPort}${t.pinned !== null ? `  PINNED→${t.pinned + 1}` : ""}`);
        t.endpoints.forEach((ep, i) => {
            const flags = [
                i === t.active ? "ACTIVE" : "",
                !ep.enabled ? (ep.inflight ? "draining" : "disabled") : "",
            ].filter(Boolean).join(",");
            console.log(`  ${i + 1}. ${ep.host}:${ep.port}${ep.label ? ` (${ep.label})` : ""} — ${ep.state}${ep.latencyMs != null ? ` ${ep.latencyMs}ms` : ""}  req=${ep.requests} fail=${ep.failures}${flags ? `  [${flags}]` : ""}${ep.lastError ? `  last-err: ${ep.lastError}` : ""}`);
        });
        if (!t.endpoints.length) console.log("  (no endpoints)");
    }
}

function rankToIndex(v) {
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1) { console.error(`bad rank: ${v} (ranks are 1-based)`); process.exit(1); }
    return n - 1;
}

function portalArg(args) {
    let v = args.portal !== undefined ? args.portal : args.table;   // --table = deprecated alias
    if (Array.isArray(v)) v = v[v.length - 1];
    if (v === undefined) return undefined;   // server default: first portal
    if (v === "sub") return "subagent";
    if (!PORTAL_NAME_RE.test(v)) { console.error(`bad --portal: ${v} (names are [a-z0-9-]+)`); process.exit(1); }
    return v;
}

async function ctlCmd(sub, args) {
    const socketPath = args.socket || DEFAULT_SOCKET;
    let ctl;
    try { ctl = await connectControl(socketPath); }
    catch { console.error(`waterfall not running (no socket at ${socketPath})`); process.exit(1); }

    const p = args._;
    const portal = portalArg(args);
    let cmd, extra = {};
    switch (sub) {
        case "status": cmd = "status"; break;
        case "pin":
            cmd = "pin";
            extra = { portal, index: (p[0] === "off" || p[0] === "none" || p[0] === undefined) ? null : rankToIndex(p[0]) };
            break;
        case "disable": cmd = "setEnabled"; extra = { portal, index: rankToIndex(p[0]), enabled: false, hard: Boolean(args.hard) }; break;
        case "enable": cmd = "setEnabled"; extra = { portal, index: rankToIndex(p[0]), enabled: true }; break;
        case "add":
            cmd = "add";
            extra = { portal, spec: p.join(" "), index: args.rank !== undefined ? rankToIndex(args.rank) : undefined };
            break;
        case "remove": cmd = "remove"; extra = { portal, index: rankToIndex(p[0]) }; break;
        case "move": cmd = "move"; extra = { portal, index: rankToIndex(p[0]), to: rankToIndex(p[1]) }; break;
        case "edit": cmd = "edit"; extra = { portal, index: rankToIndex(p[0]), spec: p.slice(1).join(" ") }; break;
        case "write": cmd = "write"; break;
        case "reload": cmd = "reload"; break;
        case "test": cmd = "test"; extra = { portal, index: rankToIndex(p[0]) }; break;
    }

    let result;
    try { result = await ctl.send(cmd, extra); }
    catch (err) { console.error(`error: ${err.message}`); ctl.conn.destroy(); process.exit(1); }

    if (cmd === "test") {
        console.log(JSON.stringify(result, null, args.json ? 2 : 0));
    } else if (args.json) {
        console.log(JSON.stringify(result, null, 2));
    } else {
        printStatus(result);
    }
    ctl.conn.destroy();
}

// Portal CRUD: `portal list [--json]`, `portal add <name> [--port <n>]`,
// `portal rm <name>`. Like every other control command it drives the
// running server over the control socket; persist with `write` (or w).
async function portalCmd(args) {
    const [action, name] = args._;
    const socketPath = args.socket || DEFAULT_SOCKET;
    let ctl;
    try { ctl = await connectControl(socketPath); }
    catch { console.error(`waterfall not running (no socket at ${socketPath})`); process.exit(1); }

    let result;
    try {
        if (action === "list" || action === undefined) {
            const s = await ctl.send("status");
            const list = s.portals.map(t => ({
                name: t.name, listenPort: t.listenPort, endpoints: t.endpoints.length,
                pinned: t.pinned, active: t.active,
            }));
            if (args.json) console.log(JSON.stringify(list, null, 2));
            else for (const t of list) console.log(`${t.name}  :${t.listenPort}  ${t.endpoints} endpoint(s)${t.pinned !== null ? `  PINNED→${t.pinned + 1}` : ""}`);
            ctl.conn.destroy();
            return;
        }
        if (action === "add") result = await ctl.send("portalAdd", { name, port: args.port !== undefined ? Number(args.port) : undefined });
        else if (action === "rm" || action === "remove") result = await ctl.send("portalRemove", { name });
        else { console.error("usage: llama-waterfall portal list [--json] | add <name> [--port <n>] | rm <name>"); process.exit(1); }
    } catch (err) { console.error(`error: ${err.message}`); ctl.conn.destroy(); process.exit(1); }

    if (args.json) console.log(JSON.stringify(result, null, 2));
    else printStatus(result);
    ctl.conn.destroy();
}

async function stopCmd(args) {
    const socketPath = args.socket || DEFAULT_SOCKET;
    let ctl;
    try { ctl = await connectControl(socketPath); }
    catch { console.log(`waterfall not running (no socket at ${socketPath})`); process.exit(0); }
    try { await ctl.send("shutdown"); }
    catch (err) { console.error(`error: ${err.message}`); process.exit(1); }
    ctl.conn.destroy();
    console.log("waterfall stopped");
}

function fmtUptime(sec) {
    const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
    return h ? `${h}h${String(m).padStart(2, "0")}m` : `${m}m${String(sec % 60).padStart(2, "0")}s`;
}

// ── TUI ───────────────────────────────────────────────────────────────────
const A = {
    reset: "\x1b[0m", bold: "\x1b[1m", dim: "\x1b[2m", inv: "\x1b[7m",
    red: "\x1b[31m", green: "\x1b[32m", yellow: "\x1b[33m", cyan: "\x1b[36m", magenta: "\x1b[35m",
    altOn: "\x1b[?1049h", altOff: "\x1b[?1049l", hide: "\x1b[?25l", show: "\x1b[?25h",
    clear: "\x1b[2J\x1b[H",
};

// opts.owns: this invocation spawned the server — q shuts it down on exit.
// Otherwise q just detaches. Q always stops the server (and every TUI).
async function tui(args, opts = { owns: false }) {
    if (!process.stdin.isTTY || !process.stdout.isTTY) {
        console.error("the TUI needs a terminal — for scripting use: status/pin/add/… [--json], serve, stop");
        process.exit(1);
    }
    const socketPath = args.socket || DEFAULT_SOCKET;
    let ctl;
    try { ctl = await connectControl(socketPath); }
    catch {
        console.error(`waterfall not running (no socket at ${socketPath})`);
        console.error(`start it with: llama-waterfall   (or: llama-waterfall serve, or llama-launcher --waterfall)`);
        process.exit(1);
    }

    let state = null;
    let focus = 0;              // index into state.portals (one pane each)
    const cursors = new Map();  // portal name → selected endpoint row
    let mode = "normal";        // "normal" | "input"
    let inputPrompt = "", inputBuf = "", inputSubmit = null;
    let pendingD = false;
    let logScroll = 0;          // 0 = follow tail
    let helpVisible = false;
    let flash = "";             // one-line transient message
    let stopping = false;       // we initiated a server shutdown

    const out = process.stdout;
    const exitTui = (msg, code = 0) => {
        out.write(A.show + A.altOff);
        try { process.stdin.setRawMode(false); } catch { }
        if (msg) console.log(msg);
        process.exit(code);
    };
    async function quit(forceStop) {
        if (opts.owns || forceStop) {
            stopping = true;
            try { await ctl.send("shutdown"); } catch { }
            exitTui("waterfall stopped");
        } else {
            const ports = state ? state.portals.map(t => `:${t.listenPort}`).join(" ") : "";
            exitTui(`detached — waterfall still running${ports ? ` on ${ports}` : ""} (llama-waterfall stop to kill it)`);
        }
    }
    process.on("SIGINT", () => quit(false));
    process.on("SIGTERM", () => quit(false));
    ctl.conn.on("close", () => {
        if (stopping) exitTui("waterfall stopped");
        out.write(A.show + A.altOff);
        console.error("waterfall proxy went away — exiting");
        process.exit(1);
    });

    ctl.onPush((msg) => {
        if (msg.event === "state") { state = msg.data; clampCursors(); render(); }
        else if (msg.event === "shutdown" && !stopping) exitTui("waterfall stopped (by another client)");
    });
    state = await ctl.send("subscribe");

    const T = () => state.portals[focus];
    const cur = () => cursors.get(T()?.name) ?? 0;
    const setCur = (v) => cursors.set(T().name, Math.max(0, Math.min(v, T().endpoints.length - 1)));

    function clampCursors() {
        if (!state) return;
        if (focus >= state.portals.length) focus = Math.max(0, state.portals.length - 1);
        for (const t of state.portals) {
            const c = cursors.get(t.name) ?? 0;
            if (c >= t.endpoints.length) cursors.set(t.name, Math.max(0, t.endpoints.length - 1));
        }
    }

    function stateCell(ep, t) {
        if (!ep.enabled) return ep.inflight ? `${A.yellow}draining…${A.reset}` : `${A.dim}disabled${A.reset}`;
        if (ep.state === "healthy") return `${A.green}healthy${A.reset}`;
        if (ep.state === "down") return `${A.red}DOWN${A.reset}${ep.consecutiveHealthy ? ` ${A.dim}(${ep.consecutiveHealthy}/${state.promoteAfter}↑)${A.reset}` : ""}`;
        return `${A.dim}unknown${A.reset}`;
    }

    function paneLines(t, ti, cols) {
        const L = [];
        const focused = ti === focus;
        const pinTxt = t.pinned !== null ? `  ${A.magenta}${A.bold}PIN→${t.pinned + 1}${A.reset}` : "";
        const title = ` ${t.name.toUpperCase()} :${t.listenPort}`;
        L.push(focused
            ? `${A.cyan}${A.bold}${A.inv}${title} ${A.reset}${pinTxt}`
            : `${A.dim}${A.bold}${title}${A.reset}${pinTxt}`);
        L.push(`${A.dim}   #  endpoint                     state        latency   req   fail  model${A.reset}`);
        const models = new Set(t.endpoints.filter(e => e.model).map(e => e.model));
        t.endpoints.forEach((ep, i) => {
            const sel = focused && i === (cursors.get(t.name) ?? 0);
            const active = i === t.active;
            const addr = `${ep.host}:${ep.port}${ep.label ? ` ${A.dim}(${ep.label})${A.reset}` : ""}`;
            const mism = ep.model && models.size > 1;
            const model = ep.model
                ? `${mism ? A.red : A.dim}${ep.model.length > 34 ? ep.model.slice(0, 31) + "…" : ep.model}${ep.nCtx ? ` ctx=${ep.nCtx}` : ""}${A.reset}`
                : "";
            const lat = ep.latencyMs != null ? `${ep.latencyMs}ms` : "—";
            const mark = active ? `${A.cyan}◀ ACTIVE${A.reset}` : "";
            L.push(`${sel ? A.cyan + A.bold + ">" : " "}${A.reset}${String(i + 1).padStart(3)}  ` +
                pad(addr, 29) + pad(stateCell(ep, t), 13) + pad(lat, 10) +
                pad(String(ep.requests), 6) + pad(String(ep.failures), 7) + model + "  " + mark +
                (ep.lastError && ep.state === "down" ? `  ${A.red}${A.dim}${ep.lastError}${A.reset}` : ""));
        });
        if (!t.endpoints.length) L.push(`${A.dim}   (no endpoints — ${focused ? "press a to add one" : "Tab here, then a"})${A.reset}`);
        return L;
    }

    // One-line pane summary — used for unfocused panes when the terminal is
    // too short to show every portal expanded.
    function paneSummary(t) {
        const healthy = t.endpoints.filter(e => e.state === "healthy").length;
        const act = t.active !== null ? t.endpoints[t.active] : null;
        const pinTxt = t.pinned !== null ? `  ${A.magenta}PIN→${t.pinned + 1}${A.reset}` : "";
        return `${A.dim}${A.bold} ${t.name.toUpperCase()} :${t.listenPort}${A.reset}${pinTxt}  ${A.dim}${t.endpoints.length} tier(s), ${healthy} healthy${act ? ` — active ${act.host}:${act.port}` : ""}${A.reset}`;
    }

    function render() {
        if (!state) return;
        const rows = out.rows || 40, cols = out.columns || 100;
        const L = [];
        const owner = opts.owns
            ? `${A.magenta}owned — q stops server${A.reset}`
            : `${A.dim}attached — q detaches${A.reset}`;
        L.push(`${A.bold} llama-waterfall${A.reset}${state.dirty ? ` ${A.yellow}[+]${A.reset}` : ""}   ${owner}   ${A.dim}uptime ${fmtUptime(state.uptimeSec)}   conf ${state.configPath}${A.reset}`);
        // N stacked panes; when they cannot all fit expanded, unfocused
        // panes collapse to a one-line summary so the focused one stays whole.
        const expanded = state.portals.map((t, ti) => paneLines(t, ti, cols));
        const fullHeight = 1 + expanded.reduce((a, l) => a + l.length + 1, 0) + 3 + 4;  // header + panes(+sep) + footer + min log
        const collapse = fullHeight > rows;
        state.portals.forEach((t, ti) => {
            L.push(A.dim + "─".repeat(Math.min(cols, 110)) + A.reset);
            if (collapse && ti !== focus) L.push(paneSummary(t));
            else L.push(...expanded[ti]);
        });

        L.push(A.dim + "─".repeat(Math.min(cols, 110)) + A.reset);
        const footerLines = 3;
        const logSpace = Math.max(3, rows - L.length - footerLines);
        const evs = state.events || [];
        const end = Math.max(0, evs.length - logScroll);
        const view = evs.slice(Math.max(0, end - logSpace), end);
        for (const e of view) {
            const hh = new Date(e.ts).toTimeString().slice(0, 8);
            L.push(` ${A.dim}${hh}${A.reset}  ${e.line}`);
        }
        while (L.length < rows - footerLines) L.push("");

        L.push(A.dim + "─".repeat(Math.min(cols, 110)) + A.reset);
        if (mode === "input") {
            L.push(` ${A.bold}${inputPrompt}${A.reset}${inputBuf}${A.inv} ${A.reset}`);
        } else if (helpVisible) {
            L.push(` ${A.dim}h/l/Tab pane  j/k move  C-d/C-u jump  g/G top/bot  J/K rank  a add  dd remove  e edit  x drain  X hard-off  p pin  t test  A add-portal  D rm-portal  w write  u undo  r reload  C-e/C-y log  q quit  Q stop-all${A.reset}`);
        } else {
            L.push(` ${flash ? A.yellow + flash + A.reset : A.dim + "[?] help   h/l Tab j/k J/K g/G a dd e x p t A D w u r q Q" + A.reset}`);
        }
        out.write(A.clear + L.slice(0, rows).map(l => truncVis(l, cols - 1)).join("\n"));
    }

    function pad(s, n) {
        const vis = s.replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, "");
        return s + " ".repeat(Math.max(1, n - vis.length));
    }

    // Truncate to `max` VISIBLE chars, preserving ANSI codes. Without this,
    // long rows (model names, error strings) wrap onto extra physical lines
    // and scroll the header off the top of the screen.
    function truncVis(s, max) {
        let vis = 0, out = "";
        for (let i = 0; i < s.length;) {
            const m = /^\x1b\[[0-9;?]*[a-zA-Z]/.exec(s.slice(i));
            if (m) { out += m[0]; i += m[0].length; continue; }
            if (vis >= max) break;
            out += s[i]; vis++; i++;
        }
        return out + A.reset;
    }

    function say(msg) { flash = msg; render(); setTimeout(() => { if (flash === msg) { flash = ""; render(); } }, 3000); }

    async function cmd(c, extra) {
        try { state = await ctl.send(c, { portal: T()?.name, ...extra }); clampCursors(); render(); }
        catch (err) { say(`error: ${err.message}`); }
    }

    function openInput(prompt, initial, submit) {
        mode = "input"; inputPrompt = prompt; inputBuf = initial; inputSubmit = submit; render();
    }

    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.on("data", (buf) => {
        const key = buf.toString("utf8");
        if (mode === "input") {
            if (key === "\x1b") { mode = "normal"; render(); return; }
            if (key === "\r" || key === "\n") {
                mode = "normal";
                const v = inputBuf.trim();
                if (v) inputSubmit(v);
                else render();
                return;
            }
            if (key === "\x7f" || key === "\b") { inputBuf = inputBuf.slice(0, -1); render(); return; }
            if (key === "\x03") quit(false);
            if (key >= " " && key.length === 1) { inputBuf += key; render(); }
            return;
        }

        const n = T()?.endpoints.length ?? 0;
        const nPanes = state.portals.length;
        const wasD = pendingD; pendingD = false;
        switch (key) {
            case "q": case "\x03": quit(false); break;
            case "Q": quit(true); break;
            case "\t": case "l": focus = (focus + 1) % nPanes; render(); break;                        // next pane
            case "\x1b[Z": case "h": focus = (focus - 1 + nPanes) % nPanes; render(); break;           // prev pane (Shift-Tab)
            case "j": case "\x1b[B": setCur(cur() + 1); render(); break;
            case "k": case "\x1b[A": setCur(cur() - 1); render(); break;
            case "\x04": setCur(cur() + 5); render(); break;   // C-d half-jump
            case "\x15": setCur(cur() - 5); render(); break;   // C-u half-jump
            case "g": setCur(0); render(); break;              // g (and thus gg) = top
            case "G": setCur(n - 1); render(); break;
            case "J": if (cur() < n - 1) { cmd("move", { index: cur(), to: cur() + 1 }); setCur(cur() + 1); } break;
            case "K": if (cur() > 0) { cmd("move", { index: cur(), to: cur() - 1 }); setCur(cur() - 1); } break;
            case "d": pendingD = !wasD; if (wasD && n) cmd("remove", { index: cur() }); break;
            case "a": openInput(`add to [${T().name}] (host:port [label]): `, "", (v) => cmd("add", { spec: v, index: n ? cur() + 1 : 0 })); break;
            case "A": openInput("new portal (name:port): ", "", (v) => {
                const m = v.match(/^([a-z0-9-]+)(?::(\d+))?$/);
                if (!m) { say("bad portal spec (name[:port], name = [a-z0-9-]+)"); return; }
                cmd("portalAdd", { name: m[1], port: m[2] ? Number(m[2]) : undefined });
            }); break;
            case "D": if (nPanes > 1) openInput(`remove portal [${T().name}]? (y/N): `, "", (v) => {
                if (v === "y" || v === "Y") cmd("portalRemove", { name: T().name });
                else render();
            }); else say("cannot remove the last portal"); break;
            case "e": if (n) {
                const ep = T().endpoints[cur()];
                openInput(`edit [${T().name}] (host:port [label]): `, `${ep.host}:${ep.port}${ep.label ? " " + ep.label : ""}`, (v) => cmd("edit", { index: cur(), spec: v }));
            } break;
            case "x": if (n) cmd("setEnabled", { index: cur(), enabled: !T().endpoints[cur()].enabled }); break;
            case "X": if (n) cmd("setEnabled", { index: cur(), enabled: false, hard: true }); break;
            case "p": if (n) cmd("pin", { index: T().pinned === cur() ? null : cur() }); break;
            case "t": if (n) { say(`testing ${T().name} tier ${cur() + 1}…`); cmd("test", { index: cur() }); } break;
            case "w": cmd("write"); break;
            case "u": case "r": cmd("reload"); break;
            case "\x05": logScroll += 3; render(); break;                 // C-e
            case "\x19": logScroll = Math.max(0, logScroll - 3); render(); break;  // C-y
            case "?": helpVisible = !helpVisible; render(); break;
        }
    });
    out.on("resize", render);

    out.write(A.altOn + A.hide);
    render();
}

// ── No-arg mode: the TUI is the app ───────────────────────────────────────
// Start the server (detached, logging to waterfall.log) if it is not
// already running, then attach the TUI. Quitting shuts the server down
// only if this invocation started it.
async function autoTui(args) {
    if (!process.stdin.isTTY || !process.stdout.isTTY) {
        console.error("the TUI needs a terminal — for scripting use: serve, stop, or status/pin/add/… [--json]");
        process.exit(1);
    }
    const socketPath = args.socket || DEFAULT_SOCKET;
    let owns = false;
    if (!(await socketAlive(socketPath))) {
        const logFd = openSync(SERVER_LOG, "a");
        const serveArgs = [SCRIPT_PATH, "serve"];
        if (args._[0]) serveArgs.push(String(args._[0]));
        for (const f of ["subagent-port", "portal", "config", "socket", "api-key", "poll-interval", "promote-after", "connect-timeout", "stall-timeout", "max-body-mb"]) {
            if (args[f] === undefined) continue;
            for (const v of [].concat(args[f])) serveArgs.push(`--${f}`, String(v));  // --portal repeats
        }
        const child = spawn(process.execPath, serveArgs, { detached: true, stdio: ["ignore", logFd, logFd] });
        child.unref();
        owns = true;
        if (!(await waitUntil(() => socketAlive(socketPath)))) {
            console.error(`failed to start waterfall server — see ${SERVER_LOG}`);
            process.exit(1);
        }
    }
    await tui(args, { owns });
}

// ── CLI entry ─────────────────────────────────────────────────────────────
const BOOL_FLAGS = new Set(["json", "hard"]);
function parseArgs(argv) {
    const args = { _: [] };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith("--")) {
            const name = a.slice(2);
            if (BOOL_FLAGS.has(name)) args[name] = true;
            else {
                const v = argv[++i];
                args[name] = name in args ? [].concat(args[name], v) : v;  // repeated flag → array (--portal)
            }
        }
        else args._.push(a);
    }
    return args;
}

function usage(code) {
    console.error("usage: llama-waterfall                        start server if needed + open TUI (q closes what it opened; Q stops all)");
    console.error("       llama-waterfall serve [agent-port] [--subagent-port <n>] [--portal <name:port> …]");
    console.error("                             [--config <path>] [--socket <path>] [--api-key <key>]");
    console.error("                             [--poll-interval <sec>] [--promote-after <n>]");
    console.error("                             [--connect-timeout <ms>] [--stall-timeout <sec>] [--max-body-mb <n>]");
    console.error(`                             (defaults: [agent] :${DEFAULT_PORTS.agent}, [subagent] :${DEFAULT_PORTS.subagent}; conf sections define further portals)`);
    console.error("       llama-waterfall tui  [--socket <path>]  attach-only dashboard (q detaches)");
    console.error("       llama-waterfall stop [--socket <path>]  stop the server and any attached TUIs (saves config)");
    console.error("");
    console.error("  portals (named routing tables, one listener each; defined in waterfall.conf or at runtime):");
    console.error("       llama-waterfall portal list [--json]");
    console.error("       llama-waterfall portal add <name> [--port <n>]     name = [a-z0-9-]+ (persist with write / w)");
    console.error("       llama-waterfall portal rm <name>");
    console.error("");
    console.error("  control (ranks are 1-based, as shown in the TUI; all accept --json and --socket <path>;");
    console.error("  per-tier commands act on the first portal ([agent]) unless --portal <name> is given):");
    console.error("       llama-waterfall status");
    console.error("       llama-waterfall pin <rank>|off [--portal <name>]     force all traffic to one tier / clear pin");
    console.error("       llama-waterfall disable <rank> [--hard] [--portal …]  drain (or cut) a tier; enable <rank> restores");
    console.error("       llama-waterfall add <host:port> [label…] [--rank <n>] [--portal …]");
    console.error("       llama-waterfall remove <rank> [--portal …]");
    console.error("       llama-waterfall move <rank> <new-rank> [--portal …]");
    console.error("       llama-waterfall edit <rank> <host:port> [label…] [--portal …]");
    console.error("       llama-waterfall write | reload            persist runtime portals / re-read waterfall.conf");
    console.error("       llama-waterfall test <rank> [--portal …]  health + 1-token completion probe");
    process.exit(code);
}

const CTL_SUBS = new Set(["status", "pin", "disable", "enable", "add", "remove", "move", "edit", "write", "reload", "test"]);
const argv = process.argv.slice(2);
if (argv[0] === "--help" || argv[0] === "-h" || argv[0] === "help") usage(0);
else if (argv[0] === undefined || argv[0].startsWith("--")) autoTui(parseArgs(argv));
else {
    const [sub, ...rest] = argv;
    const args = parseArgs(rest);
    if (sub === "serve") serve(args);
    else if (sub === "tui") tui(args, { owns: false });
    else if (sub === "stop") stopCmd(args);
    else if (sub === "portal") portalCmd(args);
    else if (CTL_SUBS.has(sub)) ctlCmd(sub, args);
    else usage(1);
}
