#!/usr/bin/env node

// llama-waterfall — priority failover proxy for llama.cpp endpoints.
//
// Routes inference traffic to an ordered list of endpoints (fastest first).
// If the preferred tier is down the request cascades to the next tier;
// when a faster tier recovers it is promoted back after a hysteresis
// period. Clients (freeclaw) point at this proxy once, permanently.
//
// Architecture: see docs/WATERFALL.md. The layering invariant is that
// deep-proxy belongs to a node (manages that machine's KV slot cache) and
// waterfall routes BETWEEN nodes, staying stateless. Each tier endpoint is
// normally a node's deep-proxy on port 40801.
//
// Usage:
//   llama-waterfall.mjs serve <listen-port> [--config <path>] [--socket <path>]
//       [--api-key <key>] [--poll-interval <sec>] [--promote-after <n>]
//       [--connect-timeout <ms>] [--max-body-mb <n>]
//   llama-waterfall.mjs tui    [--socket <path>]
//   llama-waterfall.mjs status [--json] [--socket <path>]
//
// Failure semantics:
//   - Request bodies are buffered so a failed attempt can be replayed
//     against the next tier.
//   - Connect-refused / connect-timeout / upstream 502/503 (before any
//     response bytes reach the client) mark the tier down and cascade.
//     llama-server answers 503 while a model is loading, so a loading
//     node correctly waterfalls to the next tier.
//   - Once response headers are forwarded, a dying upstream fails the
//     request (tier marked down); the client's retry lands on the next
//     tier. Mid-stream failover is impossible by design.
//   - The connect timeout applies ONLY to TCP establishment — inference
//     may legitimately take minutes before response headers.

import { createServer as createHttpServer, request as httpRequest } from "node:http";
import { createServer as createNetServer, connect as netConnect } from "node:net";
import { readFileSync, writeFileSync, existsSync, unlinkSync, mkdirSync, realpathSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

// ── Root dir (repo checkout vs packaged install) ──────────────────────────
const SCRIPT_DIR = dirname(realpathSync(fileURLToPath(import.meta.url)));
const ROOT_DIR = /^\/usr(\/local)?\/(lib|bin|share)\//.test(SCRIPT_DIR + "/")
    ? (process.env.LLAMA_LAUNCHER_DIR ||
       join(process.env.XDG_DATA_HOME || join(homedir(), ".local", "share"), "llama-launcher"))
    : SCRIPT_DIR;

const DEFAULT_CONFIG = join(ROOT_DIR, "waterfall.conf");
const DEFAULT_SOCKET = join(ROOT_DIR, "waterfall.sock");

// ── Config (filled by serve()) ────────────────────────────────────────────
const cfg = {
    listenPort: 0,
    configPath: DEFAULT_CONFIG,
    socketPath: DEFAULT_SOCKET,
    apiKey: "ollama-local",
    pollIntervalSec: 10,
    promoteAfter: 3,
    connectTimeoutMs: 2000,
    maxBodyBytes: 64 * 1024 * 1024,
};

// ── Runtime state ─────────────────────────────────────────────────────────
// endpoints[i] = {
//   host, port, label,           // from waterfall.conf (label optional)
//   enabled,                     // x/X toggles; runtime-only, not persisted
//   state,                       // "unknown" | "healthy" | "down"
//   consecutiveHealthy,          // hysteresis counter for promote-back
//   latencyMs,                   // last /health round-trip
//   requests, failures, inflight,
//   lastError, lastErrorAt,
//   model, nCtx,                 // from /props (best effort)
//   sockets,                     // live upstream sockets (for hard disable)
// }
let endpoints = [];
let pinned = null;          // index into endpoints, or null
let dirty = false;          // runtime list differs from waterfall.conf
let activeKey = null;       // "host:port" of last-computed active tier
const startedAt = Date.now();
const events = [];          // ring buffer of { ts, line }
const EVENTS_MAX = 200;
const subscribers = new Set();  // control-socket connections in subscribe mode

function epKey(ep) { return `${ep.host}:${ep.port}`; }
function epName(ep, i) { return `tier ${i + 1} (${ep.label || epKey(ep)})`; }

function newEndpoint(host, port, label = "") {
    return {
        host, port, label,
        enabled: true, state: "unknown", consecutiveHealthy: 0,
        latencyMs: null, requests: 0, failures: 0, inflight: 0,
        lastError: null, lastErrorAt: null, model: null, nCtx: null,
        sockets: new Set(),
    };
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
// One endpoint per line: "host:port  # label". Priority = line order.
function parseConfig(text) {
    const out = [];
    for (const raw of text.split("\n")) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const hashAt = line.indexOf("#");
        const spec = (hashAt === -1 ? line : line.slice(0, hashAt)).trim();
        const label = hashAt === -1 ? "" : line.slice(hashAt + 1).trim();
        const m = spec.match(/^(\[?[A-Za-z0-9_.:-]+\]?):(\d+)$/);
        if (!m) {
            console.error(`waterfall.conf: skipping unparseable line: ${raw}`);
            continue;
        }
        out.push(newEndpoint(m[1].replace(/^\[|\]$/g, ""), Number(m[2]), label));
    }
    return out;
}

function loadConfig() {
    if (!existsSync(cfg.configPath)) return [];
    return parseConfig(readFileSync(cfg.configPath, "utf8"));
}

function writeConfig() {
    const lines = [
        "# waterfall.conf — llama-waterfall endpoint priority list",
        "# One endpoint per line: host:port  # label",
        "# Priority = line order, fastest first. Managed by the waterfall TUI (w key);",
        "# hand edits are fine — reload with r in the TUI or SIGHUP to the proxy.",
        "",
        ...endpoints.map(ep => ep.label ? `${epKey(ep)}  # ${ep.label}` : epKey(ep)),
        "",
    ];
    writeFileSync(cfg.configPath, lines.join("\n"));
    dirty = false;
}

// Re-read conf, preserving runtime stats/state for endpoints that persist.
function reloadConfig() {
    const old = new Map(endpoints.map(ep => [epKey(ep), ep]));
    endpoints = loadConfig().map(fresh => {
        const prev = old.get(epKey(fresh));
        if (!prev) return fresh;
        prev.label = fresh.label;
        return prev;
    });
    if (pinned !== null && pinned >= endpoints.length) pinned = null;
    dirty = false;
}

// ── Tier selection ────────────────────────────────────────────────────────
// Pinned tier gets ALL traffic regardless of health (that is what pin
// means). Otherwise: enabled endpoints in priority order, known-down ones
// demoted to last-resort attempts rather than skipped entirely.
function candidateIndices() {
    if (pinned !== null && endpoints[pinned]?.enabled) return [pinned];
    const up = [], down = [];
    endpoints.forEach((ep, i) => {
        if (!ep.enabled) return;
        (ep.state === "down" ? down : up).push(i);
    });
    return [...up, ...down];
}

function currentActiveIndex() {
    const c = candidateIndices();
    return c.length ? c[0] : null;
}

function noteActiveChange(why) {
    const i = currentActiveIndex();
    const key = i === null ? null : epKey(endpoints[i]);
    if (key !== activeKey) {
        activeKey = key;
        if (i === null) logEvent(`no active tier — all endpoints down or disabled (${why})`);
        else logEvent(`active → ${epName(endpoints[i], i)} (${why})`);
    } else {
        broadcast();
    }
}

function markDown(i, reason) {
    const ep = endpoints[i];
    ep.lastError = reason;
    ep.lastErrorAt = Date.now();
    ep.consecutiveHealthy = 0;
    if (ep.state !== "down") {
        ep.state = "down";
        logEvent(`${epName(ep, i)} DOWN (${reason})`);
        noteActiveChange("failover");
    } else {
        broadcast();
    }
}

// ── Proxy dispatch ────────────────────────────────────────────────────────
function attemptUpstream(i, clientReq, body) {
    const ep = endpoints[i];
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

async function dispatch(clientReq, clientRes, body) {
    const order = candidateIndices();
    if (!order.length) {
        clientRes.writeHead(503, { "content-type": "application/json" });
        clientRes.end(JSON.stringify({ error: { message: "waterfall: no endpoints available" } }));
        return;
    }

    let lastErr = "unreachable";
    for (const i of order) {
        const ep = endpoints[i];
        if (clientRes.destroyed) return;
        ep.inflight++;
        broadcast();
        let up;
        try {
            up = await attemptUpstream(i, clientReq, body);
        } catch (err) {
            ep.inflight--;
            ep.failures++;
            lastErr = err.code || err.message;
            markDown(i, lastErr);
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
            markDown(i, lastErr);
            upRes.resume();
            upReq.destroy();
            continue;
        }

        // Commit point: headers go to the client; no more failover.
        clientRes.writeHead(upRes.statusCode, upRes.headers);
        upRes.pipe(clientRes);

        return new Promise((resolve) => {
            let done = false;
            const finish = (ok, why) => {
                if (done) return;
                done = true;
                ep.inflight--;
                if (ok) ep.requests++;
                else {
                    ep.failures++;
                    if (why) markDown(i, why);
                }
                broadcast();
                resolve();
            };
            upRes.on("end", () => finish(true));
            upRes.on("error", (err) => {
                finish(false, `mid-stream: ${err.code || err.message}`);
                clientRes.destroy();
            });
            // Premature upstream close doesn't always surface as "error",
            // and pipe() won't destroy the destination — without this the
            // client would hang on a half-finished response forever.
            upRes.on("close", () => {
                if (!upRes.complete) {
                    finish(false, "mid-stream: connection closed");
                    clientRes.destroy();
                }
            });
            clientReq.on("close", () => {
                // Client went away — not the tier's fault.
                if (!upRes.complete) { upReq.destroy(); finish(true); }
            });
        });
    }

    if (!clientRes.headersSent && !clientRes.destroyed) {
        clientRes.writeHead(503, { "content-type": "application/json" });
        clientRes.end(JSON.stringify({ error: { message: `waterfall: all tiers failed (last: ${lastErr})` } }));
    }
}

function startProxy() {
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
            dispatch(req, res, body).catch((err) => {
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
    server.listen(cfg.listenPort, () => {
        logEvent(`waterfall listening on :${cfg.listenPort} — ${endpoints.length} endpoint(s), config ${cfg.configPath}`);
    });
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
    await Promise.all(endpoints.map(async (ep) => {
        const i = endpoints.indexOf(ep);
        if (i === -1) return;  // removed mid-poll
        try {
            const r = await probe(ep, "/health");
            if (r.status !== 200) throw new Error(`HTTP ${r.status}`);
            ep.latencyMs = r.ms;
            ep.consecutiveHealthy++;
            if (ep.state === "unknown") {
                ep.state = "healthy";
                fetchProps(ep);
                logEvent(`${epName(ep, i)} healthy (${r.ms}ms)`);
                noteActiveChange("startup");
            } else if (ep.state === "down") {
                if (ep.consecutiveHealthy >= cfg.promoteAfter) {
                    ep.state = "healthy";
                    fetchProps(ep);
                    logEvent(`${epName(ep, i)} healthy ×${cfg.promoteAfter} → promoted`);
                    noteActiveChange("recovery");
                } else {
                    broadcast();
                }
            }
        } catch (err) {
            ep.latencyMs = null;
            const reason = err.code || err.message;
            if (ep.state !== "down") markDown(i, reason);
            else { ep.lastError = reason; ep.lastErrorAt = Date.now(); ep.consecutiveHealthy = 0; }
        }
    }));
    broadcast();
}

function startPoller() {
    pollOnce();
    pollTimer = setInterval(pollOnce, cfg.pollIntervalSec * 1000);
}

// ── Control socket (unix, JSON-lines) ─────────────────────────────────────
function statusSnapshot() {
    return {
        listenPort: cfg.listenPort,
        configPath: cfg.configPath,
        uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
        pinned, dirty,
        active: currentActiveIndex(),
        pollIntervalSec: cfg.pollIntervalSec,
        promoteAfter: cfg.promoteAfter,
        endpoints: endpoints.map(ep => ({
            host: ep.host, port: ep.port, label: ep.label,
            enabled: ep.enabled, state: ep.state,
            latencyMs: ep.latencyMs, requests: ep.requests, failures: ep.failures,
            inflight: ep.inflight, consecutiveHealthy: ep.consecutiveHealthy,
            lastError: ep.lastError, lastErrorAt: ep.lastErrorAt,
            model: ep.model, nCtx: ep.nCtx,
        })),
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

function validIndex(i) {
    return Number.isInteger(i) && i >= 0 && i < endpoints.length;
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
        case "pin": {
            if (msg.index === null) { pinned = null; logEvent("pin cleared"); }
            else if (validIndex(msg.index)) { pinned = msg.index; logEvent(`pinned to ${epName(endpoints[pinned], pinned)}`); }
            else throw new Error("bad index");
            noteActiveChange("pin");
            return statusSnapshot();
        }
        case "setEnabled": {
            if (!validIndex(msg.index)) throw new Error("bad index");
            const ep = endpoints[msg.index];
            ep.enabled = Boolean(msg.enabled);
            if (!ep.enabled && msg.hard) {
                for (const s of ep.sockets) s.destroy(new Error("hard disable"));
                logEvent(`${epName(ep, msg.index)} hard-disabled (${ep.sockets.size} socket(s) cut)`);
            } else {
                logEvent(`${epName(ep, msg.index)} ${ep.enabled ? "enabled" : `disabled${ep.inflight ? " (draining)" : ""}`}`);
            }
            if (pinned === msg.index && !ep.enabled) pinned = null;
            noteActiveChange(ep.enabled ? "enable" : "disable");
            return statusSnapshot();
        }
        case "add": {
            const m = String(msg.spec || "").trim().match(/^(\[?[A-Za-z0-9_.:-]+\]?):(\d+)(?:\s+(.*))?$/);
            if (!m) throw new Error("expected host:port [label]");
            const ep = newEndpoint(m[1].replace(/^\[|\]$/g, ""), Number(m[2]), (m[3] || "").trim());
            const at = validIndex(msg.index) ? msg.index : endpoints.length;
            endpoints.splice(at, 0, ep);
            if (pinned !== null && pinned >= at) pinned++;
            dirty = true;
            logEvent(`added ${epName(ep, at)}`);
            noteActiveChange("add");
            return statusSnapshot();
        }
        case "remove": {
            if (!validIndex(msg.index)) throw new Error("bad index");
            const [ep] = endpoints.splice(msg.index, 1);
            if (pinned === msg.index) pinned = null;
            else if (pinned !== null && pinned > msg.index) pinned--;
            dirty = true;
            logEvent(`removed ${ep.label || epKey(ep)}`);
            noteActiveChange("remove");
            return statusSnapshot();
        }
        case "move": {
            const { index, to } = msg;
            if (!validIndex(index) || !validIndex(to)) throw new Error("bad index");
            const [ep] = endpoints.splice(index, 1);
            endpoints.splice(to, 0, ep);
            if (pinned === index) pinned = to;
            else if (pinned !== null) {
                if (index < pinned && to >= pinned) pinned--;
                else if (index > pinned && to <= pinned) pinned++;
            }
            dirty = true;
            logEvent(`moved ${ep.label || epKey(ep)} to rank ${to + 1}`);
            noteActiveChange("move");
            return statusSnapshot();
        }
        case "edit": {
            if (!validIndex(msg.index)) throw new Error("bad index");
            const m = String(msg.spec || "").trim().match(/^(\[?[A-Za-z0-9_.:-]+\]?):(\d+)(?:\s+(.*))?$/);
            if (!m) throw new Error("expected host:port [label]");
            const old = endpoints[msg.index];
            const ep = newEndpoint(m[1].replace(/^\[|\]$/g, ""), Number(m[2]), (m[3] || "").trim());
            ep.enabled = old.enabled;
            endpoints[msg.index] = ep;
            dirty = true;
            logEvent(`edited rank ${msg.index + 1} → ${epKey(ep)}${ep.label ? ` (${ep.label})` : ""}`);
            noteActiveChange("edit");
            return statusSnapshot();
        }
        case "write":
            writeConfig();
            logEvent(`wrote ${endpoints.length} endpoint(s) to ${cfg.configPath}`);
            broadcast();
            return statusSnapshot();
        case "reload":
            reloadConfig();
            logEvent(`reloaded ${cfg.configPath} (${endpoints.length} endpoint(s))`);
            noteActiveChange("reload");
            return statusSnapshot();
        case "test": {
            if (!validIndex(msg.index)) throw new Error("bad index");
            const ep = endpoints[msg.index];
            const name = epName(ep, msg.index);
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
async function serve(args) {
    cfg.listenPort = Number(args._[0] || 40800);
    if (args.config) cfg.configPath = args.config;
    if (args.socket) cfg.socketPath = args.socket;
    if (args["api-key"]) cfg.apiKey = args["api-key"];
    if (args["poll-interval"]) cfg.pollIntervalSec = Number(args["poll-interval"]);
    if (args["promote-after"]) cfg.promoteAfter = Number(args["promote-after"]);
    if (args["connect-timeout"]) cfg.connectTimeoutMs = Number(args["connect-timeout"]);
    if (args["max-body-mb"]) cfg.maxBodyBytes = Number(args["max-body-mb"]) * 1024 * 1024;

    mkdirSync(dirname(cfg.configPath), { recursive: true });
    endpoints = loadConfig();
    if (!endpoints.length) {
        console.error(`no endpoints in ${cfg.configPath} — add lines like "127.0.0.1:40801  # local" (or use the TUI once running)`);
    }

    await startControlSocket();
    startProxy();
    startPoller();

    const shutdown = () => {
        clearInterval(pollTimer);
        try { unlinkSync(cfg.socketPath); } catch { }
        process.exit(0);
    };
    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
    process.on("SIGHUP", () => {
        reloadConfig();
        logEvent(`SIGHUP: reloaded ${cfg.configPath} (${endpoints.length} endpoint(s))`);
        noteActiveChange("reload");
    });
}

// ── Control-socket client (tui / status) ──────────────────────────────────
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

// ── CLI control subcommands (the same surface the TUI drives) ─────────────
// Ranks on the CLI are 1-based, matching the TUI display.
function printStatus(s) {
    console.log(`waterfall :${s.listenPort}  uptime ${fmtUptime(s.uptimeSec)}${s.dirty ? "  [+unsaved]" : ""}${s.pinned !== null ? `  PINNED→${s.pinned + 1}` : ""}`);
    s.endpoints.forEach((ep, i) => {
        const flags = [
            i === s.active ? "ACTIVE" : "",
            !ep.enabled ? (ep.inflight ? "draining" : "disabled") : "",
        ].filter(Boolean).join(",");
        console.log(`  ${i + 1}. ${ep.host}:${ep.port}${ep.label ? ` (${ep.label})` : ""} — ${ep.state}${ep.latencyMs != null ? ` ${ep.latencyMs}ms` : ""}  req=${ep.requests} fail=${ep.failures}${flags ? `  [${flags}]` : ""}${ep.lastError ? `  last-err: ${ep.lastError}` : ""}`);
    });
}

function rankToIndex(v) {
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1) { console.error(`bad rank: ${v} (ranks are 1-based)`); process.exit(1); }
    return n - 1;
}

async function ctlCmd(sub, args) {
    const socketPath = args.socket || DEFAULT_SOCKET;
    let ctl;
    try { ctl = await connectControl(socketPath); }
    catch { console.error(`waterfall not running (no socket at ${socketPath})`); process.exit(1); }

    const p = args._;
    let cmd, extra = {};
    switch (sub) {
        case "status": cmd = "status"; break;
        case "pin":
            cmd = "pin";
            extra.index = (p[0] === "off" || p[0] === "none" || p[0] === undefined) ? null : rankToIndex(p[0]);
            break;
        case "disable": cmd = "setEnabled"; extra = { index: rankToIndex(p[0]), enabled: false, hard: Boolean(args.hard) }; break;
        case "enable": cmd = "setEnabled"; extra = { index: rankToIndex(p[0]), enabled: true }; break;
        case "add":
            cmd = "add";
            extra = { spec: p.join(" "), index: args.rank !== undefined ? rankToIndex(args.rank) : undefined };
            break;
        case "remove": cmd = "remove"; extra = { index: rankToIndex(p[0]) }; break;
        case "move": cmd = "move"; extra = { index: rankToIndex(p[0]), to: rankToIndex(p[1]) }; break;
        case "edit": cmd = "edit"; extra = { index: rankToIndex(p[0]), spec: p.slice(1).join(" ") }; break;
        case "write": cmd = "write"; break;
        case "reload": cmd = "reload"; break;
        case "test": cmd = "test"; extra = { index: rankToIndex(p[0]) }; break;
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

async function tui(args) {
    const socketPath = args.socket || DEFAULT_SOCKET;
    let ctl;
    try { ctl = await connectControl(socketPath); }
    catch {
        console.error(`waterfall not running (no socket at ${socketPath})`);
        console.error(`start it with: llama-waterfall serve 40800   (or llama-launcher --waterfall)`);
        process.exit(1);
    }

    let state = null;
    let cursor = 0;
    let mode = "normal";        // "normal" | "input"
    let inputPrompt = "", inputBuf = "", inputSubmit = null;
    let pendingD = false;
    let logScroll = 0;          // 0 = follow tail
    let helpVisible = false;
    let flash = "";             // one-line transient message

    const out = process.stdout;
    const cleanup = () => {
        out.write(A.show + A.altOff);
        try { process.stdin.setRawMode(false); } catch { }
        process.exit(0);
    };
    process.on("SIGINT", cleanup);
    process.on("SIGTERM", cleanup);
    ctl.conn.on("close", () => {
        out.write(A.show + A.altOff);
        console.error("waterfall proxy went away — exiting");
        process.exit(1);
    });

    ctl.onPush((msg) => {
        if (msg.event === "state") { state = msg.data; clampCursor(); render(); }
    });
    state = await ctl.send("subscribe");

    function clampCursor() {
        const n = state?.endpoints.length ?? 0;
        if (cursor >= n) cursor = Math.max(0, n - 1);
    }

    function stateCell(ep, isActive) {
        if (!ep.enabled) return ep.inflight ? `${A.yellow}draining…${A.reset}` : `${A.dim}disabled${A.reset}`;
        if (ep.state === "healthy") return `${A.green}healthy${A.reset}`;
        if (ep.state === "down") return `${A.red}DOWN${A.reset}${ep.consecutiveHealthy ? ` ${A.dim}(${ep.consecutiveHealthy}/${state.promoteAfter}↑)${A.reset}` : ""}`;
        return `${A.dim}unknown${A.reset}`;
    }

    function render() {
        if (!state) return;
        const rows = out.rows || 40, cols = out.columns || 100;
        const L = [];
        const pinTxt = state.pinned !== null ? `  ${A.magenta}${A.bold}PIN→${state.pinned + 1}${A.reset}` : "";
        L.push(`${A.bold} llama-waterfall :${state.listenPort}${A.reset}${state.dirty ? ` ${A.yellow}[+]${A.reset}` : ""}${pinTxt}   ${A.dim}uptime ${fmtUptime(state.uptimeSec)}   conf ${state.configPath}${A.reset}`);
        L.push(A.dim + "─".repeat(Math.min(cols, 110)) + A.reset);
        L.push(`${A.dim}   #  endpoint                     state        latency   req   fail  model${A.reset}`);

        const models = new Set(state.endpoints.filter(e => e.model).map(e => e.model));
        state.endpoints.forEach((ep, i) => {
            const sel = i === cursor;
            const active = i === state.active;
            const addr = `${ep.host}:${ep.port}${ep.label ? ` ${A.dim}(${ep.label})${A.reset}` : ""}`;
            const mism = ep.model && models.size > 1;
            const model = ep.model
                ? `${mism ? A.red : A.dim}${ep.model.length > 34 ? ep.model.slice(0, 31) + "…" : ep.model}${ep.nCtx ? ` ctx=${ep.nCtx}` : ""}${A.reset}`
                : "";
            const lat = ep.latencyMs != null ? `${ep.latencyMs}ms` : "—";
            const mark = active ? `${A.cyan}◀ ACTIVE${A.reset}` : "";
            const line = `${sel ? A.cyan + A.bold + ">" : " "}${A.reset}${String(i + 1).padStart(3)}  ` +
                pad(addr, 29) + pad(stateCell(ep, active), 13) + pad(lat, 10) +
                pad(String(ep.requests), 6) + pad(String(ep.failures), 7) + model + "  " + mark +
                (ep.lastError && ep.state === "down" ? `  ${A.red}${A.dim}${ep.lastError}${A.reset}` : "");
            L.push(line);
        });
        if (!state.endpoints.length) L.push(`${A.dim}   (no endpoints — press a to add one)${A.reset}`);

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
            L.push(` ${A.dim}j/k move  g/G top/bot  J/K rank  a add  dd remove  e edit  x drain  X hard-off  p pin  t test  w write  u undo  r reload  C-e/C-y log  q quit${A.reset}`);
        } else {
            L.push(` ${flash ? A.yellow + flash + A.reset : A.dim + "[?] help   j/k J/K a dd e x p t w u r q" + A.reset}`);
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
        try { state = await ctl.send(c, extra); clampCursor(); render(); }
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
            if (key === "\x03") cleanup();
            if (key >= " " && key.length === 1) { inputBuf += key; render(); }
            return;
        }

        const n = state?.endpoints.length ?? 0;
        const wasD = pendingD; pendingD = false;
        switch (key) {
            case "q": case "\x03": cleanup(); break;
            case "j": case "\x1b[B": if (cursor < n - 1) cursor++; render(); break;
            case "k": case "\x1b[A": if (cursor > 0) cursor--; render(); break;
            case "g": cursor = 0; render(); break;
            case "G": cursor = Math.max(0, n - 1); render(); break;
            case "J": if (cursor < n - 1) { cmd("move", { index: cursor, to: cursor + 1 }); cursor++; } break;
            case "K": if (cursor > 0) { cmd("move", { index: cursor, to: cursor - 1 }); cursor--; } break;
            case "d": pendingD = !wasD; if (wasD && n) cmd("remove", { index: cursor }); break;
            case "a": openInput("add (host:port [label]): ", "", (v) => cmd("add", { spec: v, index: n ? cursor + 1 : 0 })); break;
            case "e": if (n) {
                const ep = state.endpoints[cursor];
                openInput("edit (host:port [label]): ", `${ep.host}:${ep.port}${ep.label ? " " + ep.label : ""}`, (v) => cmd("edit", { index: cursor, spec: v }));
            } break;
            case "x": if (n) cmd("setEnabled", { index: cursor, enabled: !state.endpoints[cursor].enabled }); break;
            case "X": if (n) cmd("setEnabled", { index: cursor, enabled: false, hard: true }); break;
            case "p": if (n) cmd("pin", { index: state.pinned === cursor ? null : cursor }); break;
            case "t": if (n) { say(`testing tier ${cursor + 1}…`); cmd("test", { index: cursor }); } break;
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

// ── CLI entry ─────────────────────────────────────────────────────────────
const BOOL_FLAGS = new Set(["json", "hard"]);
function parseArgs(argv) {
    const args = { _: [] };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith("--")) {
            const name = a.slice(2);
            if (BOOL_FLAGS.has(name)) args[name] = true;
            else args[name] = argv[++i];
        }
        else args._.push(a);
    }
    return args;
}

const CTL_SUBS = new Set(["status", "pin", "disable", "enable", "add", "remove", "move", "edit", "write", "reload", "test"]);
const [sub, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);
if (sub === "serve") serve(args);
else if (sub === "tui") tui(args);
else if (CTL_SUBS.has(sub)) ctlCmd(sub, args);
else {
    console.error("usage: llama-waterfall.mjs serve <listen-port> [--config <path>] [--socket <path>] [--api-key <key>]");
    console.error("                            [--poll-interval <sec>] [--promote-after <n>] [--connect-timeout <ms>] [--max-body-mb <n>]");
    console.error("       llama-waterfall.mjs tui [--socket <path>]");
    console.error("");
    console.error("  control (ranks are 1-based, as shown in the TUI; all accept --json and --socket <path>):");
    console.error("       llama-waterfall.mjs status");
    console.error("       llama-waterfall.mjs pin <rank>|off        force all traffic to one tier / clear pin");
    console.error("       llama-waterfall.mjs disable <rank> [--hard]   drain (or cut) a tier; enable <rank> restores");
    console.error("       llama-waterfall.mjs add <host:port> [label…] [--rank <n>]");
    console.error("       llama-waterfall.mjs remove <rank>");
    console.error("       llama-waterfall.mjs move <rank> <new-rank>");
    console.error("       llama-waterfall.mjs edit <rank> <host:port> [label…]");
    console.error("       llama-waterfall.mjs write | reload        persist runtime list / re-read waterfall.conf");
    console.error("       llama-waterfall.mjs test <rank>           health + 1-token completion probe");
    process.exit(sub ? 1 : 0);
}
