#!/usr/bin/env node

// End-to-end tests for llama-waterfall.mjs.
//
// Spins up mock llama-server backends (with /health, /props,
// /v1/chat/completions incl. SSE), launches a real `waterfall serve`
// child process against them, and exercises: priority routing, failover
// on connect-refused and on 503, promote-back hysteresis, mid-stream
// death, pin / disable / add / move / write via the control socket, and
// large streaming passthrough.
//
// Run: node utils/test-waterfall.mjs

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { connect as netConnect } from "node:net";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const WATERFALL = join(dirname(dirname(fileURLToPath(import.meta.url))), "llama-waterfall.mjs");
const WF_PORT = 41890;
const TIER = [41891, 41892, 41893];

let passed = 0, failed = 0;
function ok(cond, name) {
    if (cond) { passed++; console.log(`  ✅ ${name}`); }
    else { failed++; console.log(`  ❌ ${name}`); }
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// ── Mock backend ──────────────────────────────────────────────────────────
function mockBackend(port, name, opts = {}) {
    const state = { mode: "ok", server: null, port, name };  // ok | http503 | midstream-die
    state.server = createServer((req, res) => {
        if (req.url === "/health") {
            res.writeHead(state.mode === "http503" ? 503 : 200, { "content-type": "application/json" });
            res.end(JSON.stringify({ status: "ok" }));
            return;
        }
        if (req.url === "/props") {
            res.writeHead(200, { "content-type": "application/json" });
            res.end(JSON.stringify({
                model_path: `/models/${opts.model || "qwen3.6-test"}.gguf`,
                default_generation_settings: { n_ctx: 8192 },
            }));
            return;
        }
        if (state.mode === "http503") {
            res.writeHead(503, { "content-type": "application/json" });
            res.end(JSON.stringify({ error: { message: "Loading model" } }));
            return;
        }
        const chunks = [];
        req.on("data", c => chunks.push(c));
        req.on("end", () => {
            const body = Buffer.concat(chunks).toString("utf8");
            let stream = false;
            try { stream = JSON.parse(body).stream === true; } catch { }
            if (stream) {
                res.writeHead(200, { "content-type": "text/event-stream" });
                res.write(`data: ${JSON.stringify({ served_by: name, chunk: 1 })}\n\n`);
                if (state.mode === "midstream-die") {
                    setTimeout(() => res.destroy(), 50);
                    return;
                }
                setTimeout(() => {
                    res.write(`data: ${JSON.stringify({ served_by: name, chunk: 2 })}\n\n`);
                    res.end("data: [DONE]\n\n");
                }, 50);
            } else {
                res.writeHead(200, { "content-type": "application/json" });
                res.end(JSON.stringify({ served_by: name, echo_bytes: body.length }));
            }
        });
    });
    return new Promise((resolve) => state.server.listen(port, () => resolve(state)));
}

// ── HTTP + control-socket helpers ─────────────────────────────────────────
function req(port, path, { method = "GET", body = null } = {}) {
    return new Promise((resolve, reject) => {
        import("node:http").then(({ request }) => {
            let settled = false;
            const settle = (v) => { if (!settled) { settled = true; resolve(v); } };
            const r = request({ host: "127.0.0.1", port, path, method, headers: body ? { "content-type": "application/json" } : {} }, (res) => {
                const chunks = [];
                res.on("data", c => chunks.push(c));
                res.on("end", () => settle({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
                res.on("error", () => settle({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8"), truncated: true }));
                res.on("close", () => settle({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8"), truncated: !res.complete }));
            });
            r.on("error", reject);
            r.setTimeout(10_000, () => r.destroy(new Error("timeout")));
            if (body) r.end(body); else r.end();
        });
    });
}

function ctl(socketPath) {
    return new Promise((resolve, reject) => {
        const conn = netConnect(socketPath);
        let buf = "", nextId = 1;
        const waiters = new Map();
        conn.on("connect", () => resolve({
            close: () => conn.destroy(),
            send: (cmd, extra = {}) => new Promise((res, rej) => {
                const id = nextId++;
                waiters.set(id, { res, rej });
                conn.write(JSON.stringify({ id, cmd, ...extra }) + "\n");
            }),
        }));
        conn.on("data", (chunk) => {
            buf += chunk.toString("utf8");
            let nl;
            while ((nl = buf.indexOf("\n")) !== -1) {
                const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
                if (!line.trim()) continue;
                let msg; try { msg = JSON.parse(line); } catch { continue; }
                if (msg.event) continue;
                const w = waiters.get(msg.id);
                if (w) { waiters.delete(msg.id); msg.ok ? w.res(msg.data) : w.rej(new Error(msg.error)); }
            }
        });
        conn.on("error", reject);
    });
}

async function waitFor(fn, timeoutMs = 8000, everyMs = 100) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (await fn()) return true;
        await sleep(everyMs);
    }
    return false;
}

// ── Main ──────────────────────────────────────────────────────────────────
const dir = mkdtempSync(join(tmpdir(), "wf-test-"));
const confPath = join(dir, "waterfall.conf");
const sockPath = join(dir, "waterfall.sock");
writeFileSync(confPath, TIER.map((p, i) => `127.0.0.1:${p}  # tier${i + 1}`).join("\n") + "\n");

const backends = [
    await mockBackend(TIER[0], "t1"),
    await mockBackend(TIER[1], "t2"),
    await mockBackend(TIER[2], "t3"),
];

const child = spawn(process.execPath, [
    WATERFALL, "serve", String(WF_PORT),
    "--config", confPath, "--socket", sockPath,
    "--poll-interval", "0.3", "--promote-after", "2", "--connect-timeout", "800",
], { stdio: ["ignore", "pipe", "pipe"] });
let childOut = "";
child.stdout.on("data", c => childOut += c);
child.stderr.on("data", c => childOut += c);
child.on("exit", (code) => { if (!shuttingDown) { console.error(`waterfall died early (code ${code}):\n${childOut}`); process.exit(1); } });
let shuttingDown = false;

try {
    ok(await waitFor(async () => {
        try { return (await req(WF_PORT, "/health")).status === 200; } catch { return false; }
    }), "waterfall up, /health passes through to tier 1");

    const c = await ctl(sockPath);

    // 1. Priority routing
    let r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t1", "routes to tier 1 (fastest) when all healthy");

    // 2. Failover on connect-refused
    backends[0].server.close();
    await sleep(100);
    r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "cascades to tier 2 on connect-refused");
    let s = await c.send("status");
    ok(s.endpoints[0].state === "down", "tier 1 marked down after connect failure");

    // 3. Failover on HTTP 503 (model loading)
    backends[1].mode = "http503";
    r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t3", "cascades past a 503 (loading) tier to tier 3");
    backends[1].mode = "ok";

    // 4. Promote-back hysteresis
    backends[0] = await mockBackend(TIER[0], "t1");
    ok(await waitFor(async () => (await c.send("status")).endpoints[0].state === "healthy"),
        "tier 1 promoted back after consecutive healthy polls");
    r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t1", "traffic returns to tier 1 after promotion");

    // 5. SSE streaming passthrough
    r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"stream":true,"messages":[]}' });
    ok(r.body.includes('"chunk":1') && r.body.includes('"chunk":2') && r.body.includes("[DONE]"),
        "SSE stream passes through intact");

    // 6. Mid-stream death: request fails (no silent switch), tier marked down
    backends[0].mode = "midstream-die";
    let truncated = false;
    try {
        r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"stream":true,"messages":[]}' });
        truncated = !r.body.includes("[DONE]");
    } catch { truncated = true; }
    ok(truncated, "mid-stream backend death truncates the request (no impossible failover)");
    ok(await waitFor(async () => (await c.send("status")).endpoints[0].state === "down"),
        "tier marked down after mid-stream death");
    backends[0].mode = "ok";
    await waitFor(async () => (await c.send("status")).endpoints[0].state === "healthy");

    // 7. Pin
    await c.send("pin", { index: 1 });
    r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "pin forces traffic to tier 2 while tier 1 healthy");
    await c.send("pin", { index: null });

    // 8. Disable / enable
    await c.send("setEnabled", { index: 0, enabled: false });
    r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "disabled tier receives no traffic");
    await c.send("setEnabled", { index: 0, enabled: true });

    // 9. Reorder + write persists to conf
    await c.send("move", { index: 2, to: 0 });
    r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t3", "rank change takes effect immediately");
    s = await c.send("status");
    ok(s.dirty === true, "unsaved rank change sets dirty flag");
    await c.send("write");
    const conf = readFileSync(confPath, "utf8");
    ok(conf.indexOf(String(TIER[2])) < conf.indexOf(String(TIER[0])), "write persists new order to waterfall.conf");
    ok((await c.send("status")).dirty === false, "write clears dirty flag");

    // 10. Add / remove / reload
    await c.send("add", { spec: "127.0.0.1:49999 ghost" });
    s = await c.send("status");
    ok(s.endpoints.length === 4 && s.endpoints[3].label === "ghost", "add appends endpoint with label");
    await c.send("remove", { index: 3 });
    await c.send("reload");
    s = await c.send("status");
    ok(s.endpoints.length === 3 && s.endpoints[0].port === TIER[2], "reload restores runtime list from disk");
    await c.send("move", { index: 0, to: 2 });
    await c.send("write");  // restore original order for cleanliness

    // 11. /props model info surfaced
    ok(await waitFor(async () => (await c.send("status")).endpoints.every(e => e.model === "qwen3.6-test.gguf")),
        "model name from /props surfaced for every tier");

    // 12. test command (health + 1-token completion)
    const t = await c.send("test", { index: 0 });
    ok(t.health?.status === 200 && t.completion?.status === 200, "test command runs health + completion probe");

    // 13. status subcommand (scripting surface)
    const statusOut = await new Promise((resolve) => {
        const p = spawn(process.execPath, [WATERFALL, "status", "--json", "--socket", sockPath]);
        let o = ""; p.stdout.on("data", c => o += c);
        p.on("exit", () => resolve(o));
    });
    ok(JSON.parse(statusOut).endpoints.length === 3, "status --json is valid and complete");

    // 14. All tiers down → clean 503
    backends.forEach(b => b.server.close());
    await sleep(1000);
    r = await req(WF_PORT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(r.status === 503 && r.body.includes("all tiers failed"), "all tiers down yields clean 503");

    c.close();
} finally {
    shuttingDown = true;
    child.kill("SIGTERM");
    backends.forEach(b => { try { b.server.close(); } catch { } });
    await sleep(200);
    rmSync(dir, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
