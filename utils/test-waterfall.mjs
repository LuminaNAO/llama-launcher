#!/usr/bin/env node

// End-to-end tests for llama-waterfall.mjs.
//
// Spins up mock llama-server backends (with /health, /props,
// /v1/chat/completions incl. SSE), launches a real `waterfall serve`
// child process against them, and exercises: the default agent+subagent
// portals (dual listeners), legacy headerless conf compat, priority
// routing, failover on connect-refused / 503 / pre-commit death
// (pre-first-SSE-chunk, mid-JSON-body, stall timeout), promote-back
// hysteresis, mid-stream death, per-portal pin / disable / add / move,
// sectioned conf persistence with !/* flags, the CLI control surface
// (--portal plus the deprecated --table alias), and save-on-stop.
// Phase 2 covers N named portals: 3-portal conf parse/save round-trip,
// port= defaulting, --portal serve overrides, portal add/rm/list, live
// re-bind on conf port changes, and a PTY smoke test of the N-pane TUI.
//
// Run: node utils/test-waterfall.mjs

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { connect as netConnect } from "node:net";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const WATERFALL = join(dirname(dirname(fileURLToPath(import.meta.url))), "llama-waterfall.mjs");
const WF_AGENT = 41890;
const WF_SUB = 41889;
const TIER = [41891, 41892, 41893];

let passed = 0, failed = 0;
function ok(cond, name) {
    if (cond) { passed++; console.log(`  ✅ ${name}`); }
    else { failed++; console.log(`  ❌ ${name}`); }
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// ── Mock backend ──────────────────────────────────────────────────────────
// modes: ok | http503 | midstream-die | die-pre-chunk | die-mid-json | hang
function mockBackend(port, name, opts = {}) {
    const state = { mode: "ok", server: null, port, name };
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
        if (state.mode === "hang") {
            res.writeHead(200, { "content-type": "application/json" });
            return; // headers only, then silence — stall-timeout territory
        }
        if (state.mode === "die-mid-json") {
            res.writeHead(200, { "content-type": "application/json" });
            res.write('{"served_by":"');
            setTimeout(() => res.destroy(), 30);
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
                if (state.mode === "die-pre-chunk") {
                    setTimeout(() => res.destroy(), 50);  // headers sent, no body byte
                    return;
                }
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
function req(port, path, { method = "GET", body = null, timeoutMs = 10_000 } = {}) {
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
            r.setTimeout(timeoutMs, () => r.destroy(new Error("timeout")));
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
// Agent lines are deliberately headerless — legacy single-table conf compat.
writeFileSync(confPath, [
    `127.0.0.1:${TIER[0]}  # tier1`,
    `127.0.0.1:${TIER[1]}  # tier2`,
    `127.0.0.1:${TIER[2]}  # tier3`,
    "",
    "[subagent]",
    `127.0.0.1:${TIER[1]}  # sub1`,
    `127.0.0.1:${TIER[2]}  # sub2`,
    "",
].join("\n"));

const backends = [
    await mockBackend(TIER[0], "t1"),
    await mockBackend(TIER[1], "t2"),
    await mockBackend(TIER[2], "t3"),
];

const child = spawn(process.execPath, [
    WATERFALL, "serve", String(WF_AGENT), "--subagent-port", String(WF_SUB),
    "--config", confPath, "--socket", sockPath,
    "--poll-interval", "0.3", "--promote-after", "2", "--connect-timeout", "800",
    "--stall-timeout", "2",
], { stdio: ["ignore", "pipe", "pipe"] });
let childOut = "";
let childExit = null;
child.stdout.on("data", c => childOut += c);
child.stderr.on("data", c => childOut += c);
child.on("exit", (code) => {
    childExit = code;
    if (!shuttingDown) { console.error(`waterfall died early (code ${code}):\n${childOut}`); process.exit(1); }
});
let shuttingDown = false;

const agentEp = (s, i) => s.tables[0].endpoints[i];
const subEp = (s, i) => s.tables[1].endpoints[i];

try {
    ok(await waitFor(async () => {
        try { return (await req(WF_AGENT, "/health")).status === 200; } catch { return false; }
    }), "agent listener up, /health passes through to tier 1");

    const c = await ctl(sockPath);

    // 1. Dual tables loaded, legacy headerless lines land in [agent]
    let s = await c.send("status");
    ok(s.tables.length === 2 && s.tables[0].name === "agent" && s.tables[1].name === "subagent",
        "status exposes both routing tables");
    ok(s.tables[0].endpoints.length === 3 && agentEp(s, 0).port === TIER[0],
        "legacy headerless conf lines load into [agent]");
    ok(s.tables[1].endpoints.length === 2 && subEp(s, 0).port === TIER[1],
        "[subagent] section loads into subagent table");

    // 2. Independent priority routing per listener
    let r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t1", "agent port routes to its tier 1");
    r = await req(WF_SUB, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "subagent port routes to ITS tier 1 (different endpoint)");

    // 3. Failover on connect-refused, subagent unaffected
    backends[0].server.close();
    await sleep(100);
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "agent cascades to tier 2 on connect-refused");
    s = await c.send("status");
    ok(agentEp(s, 0).state === "down", "agent tier 1 marked down after connect failure");
    r = await req(WF_SUB, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "subagent table unaffected by agent-tier failure");

    // 4. Failover on HTTP 503 (model loading) — hits both tables
    backends[1].mode = "http503";
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t3", "agent cascades past a 503 (loading) tier to tier 3");
    r = await req(WF_SUB, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t3", "subagent cascades past the same 503 tier independently");
    backends[1].mode = "ok";

    // 5. Promote-back hysteresis
    backends[0] = await mockBackend(TIER[0], "t1");
    ok(await waitFor(async () => (await c.send("status")).tables.every(t => t.endpoints.every(e => e.state === "healthy"))),
        "all tiers promoted back to healthy after consecutive polls");
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t1", "agent traffic returns to tier 1 after promotion");

    // 6. SSE streaming passthrough
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"stream":true,"messages":[]}' });
    ok(r.body.includes('"chunk":1') && r.body.includes('"chunk":2') && r.body.includes("[DONE]"),
        "SSE stream passes through intact");

    const healAll = async () => {
        backends[0].mode = "ok";
        await waitFor(async () => (await c.send("status")).tables.every(t => t.endpoints.every(e => e.state === "healthy")));
    };

    // 7. Pre-commit failover: death AFTER headers but BEFORE first SSE chunk
    backends[0].mode = "die-pre-chunk";
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"stream":true,"messages":[]}' });
    ok(r.body.includes('"served_by":"t2"') && r.body.includes("[DONE]"),
        "tier dying before first SSE chunk fails over invisibly (prefill death)");
    s = await c.send("status");
    ok(agentEp(s, 0).state === "down", "pre-chunk death marks the tier down");
    await healAll();

    // 8. Pre-commit failover: non-streaming response dies mid-body → replay
    backends[0].mode = "die-mid-json";
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    let parsed = null;
    try { parsed = JSON.parse(r.body); } catch { }
    ok(parsed?.served_by === "t2", "non-stream response dying mid-body replays on next tier (client sees clean JSON)");
    await healAll();

    // 9. Stall timeout: black-holed tier (headers then silence) cascades
    backends[0].mode = "hang";
    const t0 = Date.now();
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "stalled (black-holed) tier cascades to next tier");
    ok(Date.now() - t0 >= 1800 && Date.now() - t0 < 8000, "stall failover fires at ~stall-timeout");
    await healAll();

    // 10. Mid-stream death POST-commit: request fails (no impossible failover)
    backends[0].mode = "midstream-die";
    let truncated = false;
    try {
        r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"stream":true,"messages":[]}' });
        truncated = !r.body.includes("[DONE]");
    } catch { truncated = true; }
    ok(truncated, "mid-generation backend death truncates the request (tokens already streamed)");
    ok(await waitFor(async () => (await c.send("status")).tables[0].endpoints[0].state === "down"),
        "tier marked down after mid-stream death");
    await healAll();

    // 11. Per-table pin
    await c.send("pin", { table: "subagent", index: 1 });
    r = await req(WF_SUB, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t3", "pin on subagent table forces its traffic to rank 2");
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t1", "agent table unaffected by subagent pin");
    await c.send("pin", { table: "subagent", index: null });

    // 12. Disable / enable
    await c.send("setEnabled", { table: "agent", index: 0, enabled: false });
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "disabled tier receives no traffic");
    await c.send("setEnabled", { table: "agent", index: 0, enabled: true });

    // 13. Reorder + write persists sectioned conf
    await c.send("move", { table: "agent", index: 2, to: 0 });
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t3", "rank change takes effect immediately");
    s = await c.send("status");
    ok(s.dirty === true, "unsaved rank change sets dirty flag");
    await c.send("write");
    let conf = readFileSync(confPath, "utf8");
    const agentSec = conf.slice(conf.indexOf("\n[agent]"), conf.indexOf("\n[subagent]"));
    ok(agentSec.indexOf(String(TIER[2])) !== -1 && agentSec.indexOf(String(TIER[2])) < agentSec.indexOf(String(TIER[0])),
        "write persists new order under [agent]");
    ok(conf.includes("\n[subagent]") && conf.indexOf("\n[agent]") < conf.indexOf("\n[subagent]"),
        "write emits sectioned conf for both tables");
    ok((await c.send("status")).dirty === false, "write clears dirty flag");
    await c.send("move", { table: "agent", index: 0, to: 2 });
    await c.send("write");  // restore original order

    // 14. Disabled/pinned state persists via !/* flags and survives reload
    await c.send("pin", { table: "agent", index: 0 });
    await c.send("setEnabled", { table: "subagent", index: 0, enabled: false });
    await c.send("write");
    conf = readFileSync(confPath, "utf8");
    ok(conf.includes(`*127.0.0.1:${TIER[0]}`), "pinned tier saved with * prefix");
    ok(conf.includes(`!127.0.0.1:${TIER[1]}`), "disabled tier saved with ! prefix");
    await c.send("pin", { table: "agent", index: null });
    await c.send("setEnabled", { table: "subagent", index: 0, enabled: true });
    await c.send("reload");
    s = await c.send("status");
    ok(s.tables[0].pinned === 0 && subEp(s, 0).enabled === false,
        "reload restores pinned/disabled state from conf flags");
    await c.send("pin", { table: "agent", index: null });
    await c.send("setEnabled", { table: "subagent", index: 0, enabled: true });
    await c.send("write");

    // 15. Add / remove / reload on the subagent table
    await c.send("add", { table: "subagent", spec: "127.0.0.1:49999 ghost" });
    s = await c.send("status");
    ok(s.tables[1].endpoints.length === 3 && subEp(s, 2).label === "ghost", "add appends to subagent table");
    ok(s.tables[0].endpoints.length === 3, "add to subagent does not touch agent table");
    await c.send("remove", { table: "subagent", index: 2 });
    await c.send("reload");
    s = await c.send("status");
    ok(s.tables[1].endpoints.length === 2, "reload restores subagent table from disk");

    // 16. /props model info surfaced
    ok(await waitFor(async () => (await c.send("status")).tables.every(t => t.endpoints.every(e => e.model === "qwen3.6-test.gguf"))),
        "model name from /props surfaced for every tier in both tables");

    // 17. test command
    const t = await c.send("test", { table: "agent", index: 0 });
    ok(t.health?.status === 200 && t.completion?.status === 200, "test command runs health + completion probe");

    // 18. CLI control surface (agent-friendly scripting)
    const cli = (...a) => new Promise((resolve) => {
        const p = spawn(process.execPath, [WATERFALL, ...a, "--socket", sockPath]);
        let o = "", e = "";
        p.stdout.on("data", c => o += c);
        p.stderr.on("data", c => e += c);
        p.on("exit", (code) => resolve({ code, out: o, err: e }));
    });
    let cr = await cli("status", "--json");
    ok(cr.code === 0 && JSON.parse(cr.out).tables.length === 2, "CLI: status --json exposes both tables");
    cr = await cli("pin", "2", "--json");
    ok(JSON.parse(cr.out).tables[0].pinned === 1, "CLI: pin 2 defaults to the agent table (1-based ranks)");
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(JSON.parse(r.body).served_by === "t2", "CLI pin affects live routing");
    cr = await cli("pin", "off", "--json");
    ok(JSON.parse(cr.out).tables[0].pinned === null, "CLI: pin off clears the pin");
    cr = await cli("pin", "2", "--table", "subagent", "--json");
    ok(JSON.parse(cr.out).tables[1].pinned === 1 && JSON.parse(cr.out).tables[0].pinned === null,
        "CLI: --table subagent targets the subagent table");
    await cli("pin", "off", "--table", "subagent");
    cr = await cli("add", "127.0.0.1:49998", "cli-ghost", "--rank", "1", "--table", "subagent", "--json");
    let cs = JSON.parse(cr.out);
    ok(cs.tables[1].endpoints[0].port === 49998 && cs.tables[1].endpoints[0].label === "cli-ghost",
        "CLI: add --rank 1 --table subagent inserts at top of subagent");
    cr = await cli("remove", "1", "--table", "subagent", "--json");
    ok(JSON.parse(cr.out).tables[1].endpoints.length === 2, "CLI: remove --table subagent deletes");
    cr = await cli("disable", "1", "--json");
    ok(JSON.parse(cr.out).tables[0].endpoints[0].enabled === false, "CLI: disable 1 drains agent tier 1");
    cr = await cli("enable", "1", "--json");
    ok(JSON.parse(cr.out).tables[0].endpoints[0].enabled === true, "CLI: enable 1 restores it");
    cr = await cli("test", "1");
    ok(cr.code === 0 && JSON.parse(cr.out).health?.status === 200, "CLI: test 1 probes health+completion");
    cr = await cli("remove", "99");
    ok(cr.code === 1, "CLI: bad rank exits non-zero");
    cr = await cli("reload", "--json");
    ok(JSON.parse(cr.out).dirty === false, "CLI: reload clears dirty state");

    // 19. All tiers down → clean 503 on both listeners
    backends.forEach(b => { try { b.server.close(); } catch { } });
    await sleep(1000);
    r = await req(WF_AGENT, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(r.status === 503 && r.body.includes("all tiers failed"), "agent: all tiers down yields clean 503");
    r = await req(WF_SUB, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
    ok(r.status === 503 && r.body.includes("all tiers failed"), "subagent: all tiers down yields clean 503");

    // 20. stop: shuts the server down AND saves unsaved changes
    await c.send("move", { table: "agent", index: 0, to: 1 });   // dirty: t2 now rank 1
    ok((await c.send("status")).dirty === true, "pre-stop: runtime change is unsaved");
    shuttingDown = true;
    cr = await cli("stop");
    ok(cr.code === 0 && cr.out.includes("stopped"), "CLI: stop reports success");
    ok(await waitFor(() => childExit !== null, 5000), "stop terminates the serve process");
    conf = readFileSync(confPath, "utf8");
    const agentSec2 = conf.slice(conf.indexOf("\n[agent]"), conf.indexOf("\n[subagent]"));
    ok(agentSec2.indexOf(String(TIER[1])) !== -1 && agentSec2.indexOf(String(TIER[1])) < agentSec2.indexOf(String(TIER[0])),
        "stop saves the unsaved routing change to waterfall.conf");
    ok(!existsSync(sockPath), "stop removes the control socket");
    cr = await cli("stop");
    ok(cr.code === 0 && cr.out.includes("not running"), "CLI: stop is a no-op exit-0 when not running");

    c.close();
} finally {
    shuttingDown = true;
    if (childExit === null) child.kill("SIGTERM");
    backends.forEach(b => { try { b.server.close(); } catch { } });
    await sleep(200);
    rmSync(dir, { recursive: true, force: true });
}

// ── Phase 2: N named portals ──────────────────────────────────────────────
// A 3-portal conf ([agent] without port=, [subagent]/[cloud] with port=),
// served with NO port flags, so the resolution chain is exercised:
// default > conf port= > flag override. The built-in :40800/:40810 defaults
// are redirected to high ports via the env overrides — a production
// waterfall may own the real ports on this machine.
const P2 = { agent: 41880, sub: 41881, cloud: 41882, extra: 41883, cloud2: 41884, auto: [41885, 41886] };
const TIER2 = [41894, 41895, 41896];
await (async function phase2() {
    const dir2 = mkdtempSync(join(tmpdir(), "wf-test2-"));
    const conf2 = join(dir2, "waterfall.conf");
    const sock2 = join(dir2, "waterfall.sock");
    writeFileSync(conf2, [
        "[agent]",
        `127.0.0.1:${TIER2[0]}  # a1`,
        "",
        "[subagent]",
        `port = ${P2.sub}`,
        `127.0.0.1:${TIER2[1]}  # s1`,
        "",
        "[cloud]",
        `port = ${P2.cloud}`,
        `*127.0.0.1:${TIER2[2]}  # c1`,
        `!127.0.0.1:${TIER2[1]}  # c2`,
        "",
    ].join("\n"));

    const backends2 = [
        await mockBackend(TIER2[0], "p2-t1"),
        await mockBackend(TIER2[1], "p2-t2"),
        await mockBackend(TIER2[2], "p2-t3"),
    ];
    const env2 = {
        ...process.env,
        LLAMA_WATERFALL_AGENT_PORT: String(P2.agent),      // stand-in for :40800
        LLAMA_WATERFALL_SUBAGENT_PORT: String(41878),      // must LOSE to [subagent] port=
    };
    const child2 = spawn(process.execPath, [
        WATERFALL, "serve", "--config", conf2, "--socket", sock2,
        "--poll-interval", "0.3", "--promote-after", "2", "--connect-timeout", "800",
    ], { stdio: ["ignore", "pipe", "pipe"], env: env2 });
    let child2Out = "";
    let child2Exit = null;
    child2.stdout.on("data", c => child2Out += c);
    child2.stderr.on("data", c => child2Out += c);
    child2.on("exit", (code) => {
        child2Exit = code;
        if (!shutting2) { console.error(`phase-2 waterfall died early (code ${code}):\n${child2Out}`); process.exit(1); }
    });
    let shutting2 = false;

    const cli = (...a) => new Promise((resolve) => {
        const p = spawn(process.execPath, [WATERFALL, ...a, "--socket", sock2], { env: env2 });
        let o = "", e = "";
        p.stdout.on("data", c => o += c);
        p.stderr.on("data", c => e += c);
        p.on("exit", (code) => resolve({ code, out: o, err: e }));
    });

    try {
        ok(await waitFor(async () => {
            try { return (await req(P2.cloud, "/health")).status === 200; } catch { return false; }
        }), "phase2: third portal [cloud] listener up on its port= port");

        const c = await ctl(sock2);

        // 21. 3-portal conf parse + port resolution chain
        let s = await c.send("status");
        ok(s.portals.length === 3 && s.portals.map(t => t.name).join(",") === "agent,subagent,cloud",
            "3-portal conf loads all portals in conf order");
        ok(s.portals[0].listenPort === P2.agent, "[agent] without port= falls back to its default port");
        ok(s.portals[1].listenPort === P2.sub, "[subagent] port= line beats the default port");
        ok(s.portals[2].listenPort === P2.cloud, "arbitrary portal gets its port from port=");
        ok(JSON.stringify(s.tables) === JSON.stringify(s.portals), "status keeps .tables as an alias of .portals");
        ok(s.portals[2].pinned === 0 && s.portals[2].endpoints[1].enabled === false,
            "*/! markers parse inside a named portal section");

        // 22. Routing through a named portal (pinned to c1)
        let r = await req(P2.cloud, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
        ok(JSON.parse(r.body).served_by === "p2-t3", "[cloud] portal routes to its own pinned tier");
        r = await req(P2.agent, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
        ok(JSON.parse(r.body).served_by === "p2-t1", "[agent] portal routes independently");

        // 23. --portal CLI routing (and the sub alias)
        let cr = await cli("pin", "off", "--portal", "cloud", "--json");
        ok(JSON.parse(cr.out).portals[2].pinned === null, "CLI: pin off --portal cloud targets the named portal");
        cr = await cli("disable", "1", "--portal", "sub", "--json");
        ok(JSON.parse(cr.out).portals[1].endpoints[0].enabled === false, "CLI: --portal sub still aliases subagent");
        await cli("enable", "1", "--portal", "subagent");
        cr = await cli("pin", "1", "--portal", "nosuch", "--json");
        ok(cr.code === 1 && cr.err.includes("unknown portal"), "CLI: unknown --portal errors out");

        // 24. portal list / add / rm
        cr = await cli("portal", "list", "--json");
        let list = JSON.parse(cr.out);
        ok(list.length === 3 && list[2].name === "cloud" && list[2].listenPort === P2.cloud,
            "CLI: portal list --json reports every portal");
        cr = await cli("portal", "add", "extra", "--port", String(P2.extra), "--json");
        ok(JSON.parse(cr.out).portals.length === 4, "CLI: portal add creates a fourth portal");
        await cli("add", `127.0.0.1:${TIER2[2]}`, "x1", "--portal", "extra");
        r = await req(P2.extra, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
        ok(JSON.parse(r.body).served_by === "p2-t3", "added portal listens and routes immediately");
        cr = await cli("portal", "add", "extra", "--port", "41999");
        ok(cr.code === 1 && cr.err.includes("already exists"), "CLI: duplicate portal add errors");
        cr = await cli("portal", "add", "Bad_Name", "--port", "41999");
        ok(cr.code === 1 && cr.err.includes("bad portal name"), "CLI: portal names outside [a-z0-9-]+ are rejected");
        cr = await cli("portal", "add", "noport");
        ok(cr.code === 1 && cr.err.includes("--port"), "CLI: portal add without --port errors for non-default names");

        // 25. Save round-trip: 4 portals with explicit port= lines and markers
        await c.send("pin", { portal: "cloud", index: 0 });
        await c.send("write");
        let conf = readFileSync(conf2, "utf8");
        ok(conf.includes(`[agent]\nport = ${P2.agent}`), "write emits an explicit port= for the defaulted portal");
        ok(conf.includes(`[extra]\nport = ${P2.extra}`), "write persists the runtime-added portal with its port");
        ok(conf.includes(`*127.0.0.1:${TIER2[2]}`) && conf.includes(`!127.0.0.1:${TIER2[1]}`),
            "write keeps */! markers inside named portal sections");
        await c.send("reload");
        s = await c.send("status");
        ok(s.portals.length === 4 && s.portals[2].pinned === 0 && s.portals[2].endpoints[1].enabled === false,
            "reload round-trips the 4-portal conf (ports, pin, disabled)");

        // 26. portal rm: listener closes, conf loses the section on write
        cr = await cli("portal", "rm", "extra", "--json");
        ok(JSON.parse(cr.out).portals.length === 3, "CLI: portal rm removes the portal");
        let refused = false;
        try { await req(P2.extra, "/health", { timeoutMs: 1500 }); } catch { refused = true; }
        ok(refused, "removed portal's listener is closed");
        await c.send("write");
        ok(!readFileSync(conf2, "utf8").includes("[extra]"), "write drops the removed portal from the conf");

        // 27. Hand-edited port= change + reload re-binds the listener live
        writeFileSync(conf2, readFileSync(conf2, "utf8").replace(`port = ${P2.cloud}`, `port = ${P2.cloud2}`));
        await c.send("reload");
        r = await req(P2.cloud2, "/v1/chat/completions", { method: "POST", body: '{"messages":[]}' });
        ok(JSON.parse(r.body).served_by === "p2-t3", "reload re-binds a portal whose conf port changed");
        refused = false;
        try { await req(P2.cloud, "/health", { timeoutMs: 1500 }); } catch { refused = true; }
        ok(refused, "old port is released after the re-bind");

        c.close();

        // 28. PTY smoke: attach-only TUI renders one pane per portal
        // (keys go one per write with a gap — the TUI reads a chunk per key)
        const pty = (cmdline, keys, delayMs) => new Promise((resolve) => {
            const feed = keys.split("").map(k => `printf '${k}'; sleep 0.3;`).join(" ");
            const p = spawn("bash", ["-c",
                `(sleep ${delayMs / 1000}; ${feed} sleep 0.5) | script -qec "${cmdline}" /dev/null`,
            ], { env: env2 });
            let o = "";
            p.stdout.on("data", c => o += c);
            p.stderr.on("data", c => o += c);
            const t = setTimeout(() => p.kill("SIGKILL"), 15000);
            p.on("exit", (code) => { clearTimeout(t); resolve({ code, out: o }); });
        });
        let tr = await pty(`${process.execPath} ${WATERFALL} tui --socket ${sock2}`, "lj?q", 1500);
        ok(tr.out.includes(`AGENT :${P2.agent}`) && tr.out.includes(`SUBAGENT :${P2.sub}`) && tr.out.includes(`CLOUD :${P2.cloud2}`),
            "TUI renders one pane per portal (3 panes)");
        ok(tr.out.includes("attached — q detaches") && tr.out.includes("detached"),
            "attach-only TUI detaches on q, leaving the server up");
        ok(await socketUp(sock2), "server survives an attached TUI quitting");

        shutting2 = true;
        await cli("stop");
        ok(await waitFor(() => child2Exit !== null, 5000), "phase2: stop terminates the serve process");

        // 29. No-arg lifecycle: autostart serve + owned TUI, q stops it all
        tr = await pty(`${process.execPath} ${WATERFALL} --portal agent:${P2.auto[0]} --portal subagent:${P2.auto[1]} --config ${conf2}.auto --socket ${sock2}`, "q", 2500);
        ok(tr.out.includes("owned — q stops server") && tr.out.includes(`AGENT :${P2.auto[0]}`),
            "no-arg mode autostarts the server (--portal overrides forwarded) and owns it");
        ok(tr.out.includes("waterfall stopped") && !(await socketUp(sock2)),
            "owned TUI q stops the autostarted server");
    } finally {
        shutting2 = true;
        if (child2Exit === null) child2.kill("SIGTERM");
        backends2.forEach(b => { try { b.server.close(); } catch { } });
        await sleep(200);
        rmSync(dir2, { recursive: true, force: true });
    }
})();

function socketUp(path) {
    return new Promise((resolve) => {
        if (!existsSync(path)) return resolve(false);
        const c = netConnect(path);
        c.on("connect", () => { c.destroy(); resolve(true); });
        c.on("error", () => resolve(false));
    });
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
