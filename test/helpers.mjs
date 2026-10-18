// Shared fixtures for the waterfall telemetry tests: fake llama-server
// upstreams on loopback ephemeral ports, a recording emitter, and a proxy
// table wired to them. No network beyond 127.0.0.1, no fixed ports.

import { createServer, request } from "node:http";
import {
    createProxyServer, newEndpoint, setTelemetry, cfg,
} from "../llama-waterfall.mjs";

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Waterfall logs tier state changes to stdout; keep test output readable.
console.log = () => {};

cfg.connectTimeoutMs = 500;
cfg.stallTimeoutMs = 0;

const listen = (server) => new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));

/**
 * Fake upstream. `handler(req, res, body)` decides the response; it can be
 * swapped later through the returned object.
 */
export async function fakeUpstream(handler) {
    const up = { handler, hits: 0, server: null, port: 0, sockets: new Set() };
    up.server = createServer((req, res) => {
        const chunks = [];
        req.on("data", (c) => chunks.push(c));
        req.on("end", () => { up.hits++; up.handler(req, res, Buffer.concat(chunks)); });
    });
    up.server.on("connection", (s) => { up.sockets.add(s); s.on("close", () => up.sockets.delete(s)); });
    up.port = await listen(up.server);
    up.close = () => new Promise((r) => { for (const s of up.sockets) s.destroy(); up.server.close(() => r()); });
    return up;
}

// ── Canned llama.cpp responses ────────────────────────────────────────────
export function jsonReply(obj, status = 200) {
    return (req, res) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify(obj));
    };
}

export const COMPLETION = {
    id: "chatcmpl-1", object: "chat.completion", model: "qwen3-test.gguf",
    choices: [{ index: 0, message: { role: "assistant", content: "hello" }, finish_reason: "stop" }],
    usage: { prompt_tokens: 120, completion_tokens: 7, total_tokens: 127 },
};

export function sseReply(events, { delayMs = 0 } = {}) {
    return async (req, res) => {
        res.writeHead(200, { "content-type": "text/event-stream" });
        for (const e of events) {
            res.write(typeof e === "string" ? e : `data: ${JSON.stringify(e)}\n\n`);
            if (delayMs) await sleep(delayMs);
        }
        res.end();
    };
}

export const chunk = (content, extra = {}) => ({
    id: "chatcmpl-s", object: "chat.completion.chunk", model: "qwen3-test.gguf",
    choices: [{ index: 0, delta: { content }, finish_reason: null }], ...extra,
});

// ── Recording emitter ─────────────────────────────────────────────────────
export function recorder() {
    const events = [];
    const emitter = { record: (e) => { events.push(structuredClone(e)); } };
    setTelemetry(emitter);
    return events;
}

/**
 * A routing table over the given upstreams, served by the real waterfall
 * request handler. tiers: [{ up, label?, host? }]
 */
export async function proxyFor(tiers, name = "agent") {
    const t = {
        name, listenPort: 0, pinned: null, activeKey: null, server: null,
        endpoints: tiers.map(({ up, port, label = "", host = "127.0.0.1" }) =>
            newEndpoint(host, port ?? up.port, label)),
    };
    const server = createProxyServer(t);
    t.listenPort = await listen(server);
    t.close = () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => r()); });
    return t;
}

/** POST to the proxy; resolves { status, headers, body }. */
export function post(t, { path = "/v1/chat/completions", headers = {}, body = { model: "x", messages: [] } } = {}) {
    return new Promise((resolve, reject) => {
        const data = Buffer.from(JSON.stringify(body));
        const req = request({
            host: "127.0.0.1", port: t.listenPort, method: "POST", path,
            headers: { "content-type": "application/json", "content-length": data.length, connection: "close", ...headers },
        }, (res) => {
            const chunks = [];
            res.on("data", (c) => chunks.push(c));
            res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
            res.on("error", reject);
        });
        req.on("error", reject);
        req.end(data);
    });
}

/**
 * POST and walk away: after the first response byte (`after: "byte"`) or
 * after `ms` without any response (`after: "time"`).
 */
export function postAndAbandon(t, { after = "byte", ms = 150, headers = {} } = {}) {
    return new Promise((resolve) => {
        const data = Buffer.from(JSON.stringify({ model: "x", messages: [] }));
        const req = request({
            host: "127.0.0.1", port: t.listenPort, method: "POST", path: "/v1/chat/completions",
            headers: { "content-type": "application/json", "content-length": data.length, connection: "close", ...headers },
        }, (res) => {
            res.once("data", () => { if (after === "byte") { req.destroy(); resolve(); } });
            res.on("error", () => {});
        });
        req.on("error", () => {});
        req.end(data);
        if (after === "time") setTimeout(() => { req.destroy(); resolve(); }, ms);
    });
}

/** Wait until `fn()` is truthy (records are written after the response). */
export async function until(fn, timeoutMs = 3000) {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
        if (fn()) return true;
        await sleep(10);
    }
    return Boolean(fn());
}
