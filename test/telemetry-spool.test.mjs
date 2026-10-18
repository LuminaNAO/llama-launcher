// WATERFALL.md "Usage telemetry for tokentail" items 1, 5 and 6 end to end:
// the vendored emitter writes the tokentail JSONL spool, a read-only spool
// never affects serving, and --no-telemetry / WATERFALL_TELEMETRY=0 write
// nothing. Real `serve` children on ephemeral loopback ports, temp
// XDG_DATA_HOME, fake upstreams only.

import { test, describe, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, chmodSync, rmSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { createEmitter, spoolPath } from "../utils/tokentail-emit.mjs";
import { fakeUpstream, proxyFor, post, until, sleep, jsonReply, COMPLETION } from "./helpers.mjs";
import { setTelemetry, telemetryEnabled, parseArgs } from "../llama-waterfall.mjs";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const WATERFALL = join(ROOT, "llama-waterfall.mjs");
const RESERVED = new Set([40800, 40801, 40810, 40811]);

const temps = [];
const tmp = () => { const d = mkdtempSync(join(tmpdir(), "wf-tel-")); temps.push(d); return d; };
const cleanup = [];
after(async () => {
    setTelemetry(null);
    for (const fn of cleanup.reverse()) await fn();
    for (const d of temps) { try { chmodSync(join(d, "tokentail"), 0o755); } catch { } rmSync(d, { recursive: true, force: true }); }
});

function freePort() {
    return new Promise((resolve) => {
        const s = createServer();
        s.listen(0, "127.0.0.1", () => {
            const { port } = s.address();
            s.close(() => (RESERVED.has(port) ? freePort().then(resolve) : resolve(port)));
        });
    });
}

const readSpool = (file) => (existsSync(file)
    ? readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l))
    : []);

function run(args, env) {
    return new Promise((resolve) => {
        const p = spawn(process.execPath, [WATERFALL, ...args], { env, stdio: ["ignore", "pipe", "pipe"] });
        let out = "";
        p.stdout.on("data", (c) => (out += c));
        p.stderr.on("data", (c) => (out += c));
        p.on("exit", (code) => resolve({ code, out }));
    });
}

/** Start `waterfall serve` against one upstream; returns { port, stop, log }. */
async function serve(upPort, { flags = [], env = {}, extraConf = "", waitFor = [], poll = 60 } = {}) {
    const dir = tmp();
    const conf = join(dir, "waterfall.conf");
    const sock = join(dir, "waterfall.sock");
    writeFileSync(conf, `[agent]\n127.0.0.1:${upPort}  # gpu-main\n[subagent]\n127.0.0.1:${upPort}\n${extraConf}`);
    const agentPort = await freePort();
    const subPort = await freePort();
    const fullEnv = { ...process.env, XDG_DATA_HOME: dir, ...env };
    const child = spawn(process.execPath, [
        WATERFALL, "serve", String(agentPort), "--subagent-port", String(subPort),
        "--config", conf, "--socket", sock, "--poll-interval", String(poll), ...flags,
    ], { env: fullEnv, stdio: ["ignore", "pipe", "pipe"] });
    let log = "";
    child.stdout.on("data", (c) => (log += c));
    child.stderr.on("data", (c) => (log += c));
    const exited = new Promise((r) => child.on("exit", r));
    const ready = ["agent", "subagent", ...waitFor].map((n) => new RegExp(`\\[${n}\\] listening`));
    assert.ok(await until(() => ready.every((re) => re.test(log)), 5000), `serve did not start:\n${log}`);
    let stopped = false;
    const stop = async () => {
        if (stopped) return;
        stopped = true;
        await run(["stop", "--socket", sock], fullEnv);
        await Promise.race([exited, sleep(4000)]);
        child.kill("SIGKILL");
    };
    cleanup.push(stop);
    return {
        dir, conf, sock, env: fullEnv, agentPort, subPort, stop, log: () => log,
        ctl: (...a) => run([...a, "--socket", sock], fullEnv),
        spool: join(dir, "tokentail", "spool", "waterfall.jsonl"),
        t: (port) => ({ listenPort: port }),
    };
}

// ── Item 5: opt-out switch ────────────────────────────────────────────────
describe("opt-out", () => {
    test("default on; --no-telemetry and WATERFALL_TELEMETRY=0 turn it off", () => {
        assert.equal(telemetryEnabled({}, {}), true);
        assert.equal(telemetryEnabled({}, { WATERFALL_TELEMETRY: "1" }), true);
        assert.equal(telemetryEnabled({}, { WATERFALL_TELEMETRY: "" }), true);
        assert.equal(telemetryEnabled({}, { WATERFALL_TELEMETRY: "0" }), false);
        assert.equal(telemetryEnabled({}, { WATERFALL_TELEMETRY: "off" }), false);
        assert.equal(telemetryEnabled(parseArgs(["--no-telemetry"]), {}), false);
        assert.equal(parseArgs(["--no-telemetry", "--config", "c"]).config, "c", "flag takes no value");
    });
});

// ── Item 1 + 3: the real emitter writes a tokentail-shaped spool ──────────
describe("spool (vendored emitter)", () => {
    test("vendored SDK is the upstream file plus a commit header", () => {
        const src = readFileSync(join(ROOT, "utils", "tokentail-emit.mjs"), "utf8");
        assert.match(src.split("\n")[0], /^\/\/ Vendored verbatim from tokentail lib\/emit\.mjs at commit [0-9a-f]{40}$/);
        assert.match(src, /export function createEmitter/);
    });

    test("in-process: dispatch → emitter → JSONL line with source and ts", async () => {
        const dir = tmp();
        const em = createEmitter({ source: "waterfall", dir, flushMs: 5 });
        setTelemetry(em);
        const up = await fakeUpstream(jsonReply(COMPLETION));
        const t = await proxyFor([{ up, label: "gpu-main" }]);
        cleanup.push(() => up.close(), () => t.close());
        await post(t, { headers: { "x-request-id": "spool-1", "x-openclaw-agent-id": "main" } });
        await sleep(30);
        await em.close();
        const rows = readSpool(join(dir, "waterfall.jsonl"));
        assert.equal(rows.length, 1);
        const r = rows[0];
        assert.equal(r.source, "waterfall");
        assert.ok(!Number.isNaN(Date.parse(r.ts)));
        assert.equal(r.requestId, "spool-1");
        assert.equal(r.endpoint, "agent");
        assert.equal(r.provider, "gpu-main");
        assert.equal(r.agentId, "main");
        assert.deepEqual(r.usage, { input: 120, output: 7, cacheRead: 0, cacheWrite: 0 });
        setTelemetry(null);
    });

    // root ignores directory permissions, so the read-only case cannot be staged
    const asRoot = { skip: process.getuid?.() === 0 && "running as root" };

    test("in-process: read-only spool directory never affects the response", asRoot, async () => {
        const base = tmp();
        const ro = join(base, "tokentail");
        mkdirSync(ro);
        chmodSync(ro, 0o500);
        const em = createEmitter({ source: "waterfall", dir: join(ro, "spool"), flushMs: 1 });
        setTelemetry(em);
        const up = await fakeUpstream(jsonReply(COMPLETION));
        const t = await proxyFor([{ up }]);
        cleanup.push(() => up.close(), () => t.close());
        for (let k = 0; k < 3; k++) {
            const r = await post(t);
            assert.equal(r.status, 200);
            assert.deepEqual(JSON.parse(r.body), COMPLETION);
        }
        await em.close();
        assert.deepEqual(readdirSync(ro), [], "nothing written");
        setTelemetry(null);
    });

    test("serve: records land in $XDG_DATA_HOME/tokentail/spool/waterfall.jsonl", async () => {
        const up = await fakeUpstream(jsonReply(COMPLETION));
        cleanup.push(() => up.close());
        const s = await serve(up.port);
        assert.match(s.log(), /telemetry on/);
        const a = await post(s.t(s.agentPort), { headers: { "x-request-id": "e2e-a", "x-openclaw-session-key": "k1" } });
        const b = await post(s.t(s.subPort), { headers: { "x-request-id": "e2e-b" } });
        assert.equal(a.status, 200);
        assert.equal(b.status, 200);
        await s.stop();  // shutdown flushes the buffered tail
        const rows = readSpool(s.spool);
        assert.equal(rows.length, 2);
        const byId = Object.fromEntries(rows.map((r) => [r.requestId, r]));
        assert.equal(byId["e2e-a"].endpoint, "agent");
        assert.equal(byId["e2e-a"].port, s.agentPort);
        assert.equal(byId["e2e-a"].provider, "gpu-main");
        assert.equal(byId["e2e-a"].sessionId, "k1");
        assert.equal(byId["e2e-b"].endpoint, "subagent");
        assert.equal(byId["e2e-b"].port, s.subPort);
        assert.equal(byId["e2e-b"].provider, "tier-1");
        const raw = readFileSync(s.spool, "utf8");
        assert.doesNotMatch(raw, /127\.0\.0\.1/, "no host in the spool");
        assert.ok(!raw.includes(`:${up.port}`) && !raw.includes(`"${up.port}"`), "no upstream port in the spool");
    });

    test("serve: read-only spool dir — requests still served", asRoot, async () => {
        const up = await fakeUpstream(jsonReply(COMPLETION));
        cleanup.push(() => up.close());
        const s = await serve(up.port);
        const tt = join(s.dir, "tokentail");
        mkdirSync(tt);
        chmodSync(tt, 0o500);
        for (let k = 0; k < 3; k++) {
            const r = await post(s.t(s.agentPort));
            assert.equal(r.status, 200);
        }
        await sleep(400);  // past the emitter's flush window
        assert.equal((await post(s.t(s.agentPort))).status, 200);
        await s.stop();
        assert.deepEqual(readdirSync(tt), []);
    });

    test("serve --no-telemetry writes nothing", async () => {
        const up = await fakeUpstream(jsonReply(COMPLETION));
        cleanup.push(() => up.close());
        const s = await serve(up.port, { flags: ["--no-telemetry"] });
        assert.match(s.log(), /telemetry off/);
        assert.equal((await post(s.t(s.agentPort))).status, 200);
        await s.stop();
        assert.equal(existsSync(join(s.dir, "tokentail")), false);
    });

    test("serve with WATERFALL_TELEMETRY=0 writes nothing", async () => {
        const up = await fakeUpstream(jsonReply(COMPLETION));
        cleanup.push(() => up.close());
        const s = await serve(up.port, { env: { WATERFALL_TELEMETRY: "0" } });
        assert.equal((await post(s.t(s.agentPort))).status, 200);
        await s.stop();
        assert.equal(existsSync(join(s.dir, "tokentail")), false);
    });
});

// ── Every portal, endpoint = portal name (items 2-3 on the portal code) ──
describe("portals", () => {
    test("conf-defined, --portal and runtime-added portals each record their own name and port", async () => {
        const up = await fakeUpstream(jsonReply(COMPLETION));
        cleanup.push(() => up.close());
        const [coderPort, extraPort, addedPort] = [await freePort(), await freePort(), await freePort()];
        const s = await serve(up.port, {
            extraConf: `[coder]\nport = ${coderPort}\n127.0.0.1:${up.port}  # coder-box\n[extra]\n127.0.0.1:${up.port}\n`,
            flags: ["--portal", `extra:${extraPort}`],
            waitFor: ["coder", "extra"],
        });
        const add = await s.ctl("portal", "add", "late", "--port", String(addedPort));
        assert.equal(add.code, 0, add.out);
        assert.equal((await s.ctl("add", `127.0.0.1:${up.port}`, "late-box", "--portal", "late")).code, 0);
        assert.ok(await until(() => /\[late\] listening/.test(s.log())), s.log());
        for (const [id, port] of [["c", coderPort], ["x", extraPort], ["l", addedPort]]) {
            const r = await post(s.t(port), { headers: { "x-request-id": `portal-${id}` } });
            assert.equal(r.status, 200);
        }
        await s.stop();
        const byId = Object.fromEntries(readSpool(s.spool).map((r) => [r.requestId, r]));
        assert.deepEqual(Object.keys(byId).sort(), ["portal-c", "portal-l", "portal-x"]);
        assert.equal(byId["portal-c"].endpoint, "coder");
        assert.equal(byId["portal-c"].port, coderPort);
        assert.equal(byId["portal-c"].provider, "coder-box");
        assert.equal(byId["portal-x"].endpoint, "extra");
        assert.equal(byId["portal-x"].port, extraPort);
        assert.equal(byId["portal-x"].provider, "tier-1");
        assert.equal(byId["portal-l"].endpoint, "late");
        assert.equal(byId["portal-l"].port, addedPort);
        assert.equal(byId["portal-l"].provider, "late-box");
    });

    test("a portal re-ported at runtime records its new port", async () => {
        const up = await fakeUpstream(jsonReply(COMPLETION));
        cleanup.push(() => up.close());
        const [p1, p2] = [await freePort(), await freePort()];
        const extra = (port) => `[coder]\nport = ${port}\n127.0.0.1:${up.port}\n`;
        const s = await serve(up.port, { extraConf: extra(p1), waitFor: ["coder"] });
        assert.equal((await post(s.t(p1), { headers: { "x-request-id": "before" } })).status, 200);
        writeFileSync(s.conf, `[agent]\n127.0.0.1:${up.port}  # gpu-main\n[subagent]\n127.0.0.1:${up.port}\n${extra(p2)}`);
        assert.equal((await s.ctl("reload")).code, 0);
        assert.ok(await until(() => new RegExp(`\\[coder\\] listening on :${p2}`).test(s.log())), s.log());
        assert.equal((await post(s.t(p2), { headers: { "x-request-id": "after" } })).status, 200);
        await s.stop();
        const byId = Object.fromEntries(readSpool(s.spool).map((r) => [r.requestId, r]));
        assert.equal(byId.before.endpoint, "coder");
        assert.equal(byId.before.port, p1);
        assert.equal(byId.after.endpoint, "coder");
        assert.equal(byId.after.port, p2);
    });

    test("health probes and the control-socket test never reach the spool (item 8)", async () => {
        const up = await fakeUpstream((req, res) => {
            if (req.url === "/health") return jsonReply({ status: "ok" })(req, res);
            if (req.url === "/props") return jsonReply({ model_path: "/m/qwen3-test.gguf" })(req, res);
            return jsonReply(COMPLETION)(req, res);
        });
        cleanup.push(() => up.close());
        const s = await serve(up.port, { poll: 1 });
        await sleep(1300);  // startup poll + at least one interval
        const tst = await s.ctl("test", "1");
        assert.equal(tst.code, 0, tst.out);
        assert.ok(up.hits >= 4, `upstream saw the probes (${up.hits})`);
        await s.stop();
        assert.deepEqual(readSpool(s.spool), [], "probes recorded");
    });
});

test("spoolPath matches what serve writes", () => {
    const prev = process.env.XDG_DATA_HOME;
    process.env.XDG_DATA_HOME = "/x";
    try { assert.equal(spoolPath("waterfall"), "/x/tokentail/spool/waterfall.jsonl"); }
    finally { if (prev === undefined) delete process.env.XDG_DATA_HOME; else process.env.XDG_DATA_HOME = prev; }
});
