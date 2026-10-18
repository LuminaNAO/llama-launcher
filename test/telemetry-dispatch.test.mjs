// WATERFALL.md "Usage telemetry for tokentail" items 2-4 and 6: one record per
// client request at every dispatch exit, explicit outcomes, schema v2 fields,
// usage extraction, provider hygiene and fail-silence. Fake upstreams only.

import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import {
    fakeUpstream, proxyFor, post, postAndAbandon, recorder, until, sleep,
    jsonReply, sseReply, chunk, COMPLETION,
} from "./helpers.mjs";
import { setTelemetry, isInferenceRequest } from "../llama-waterfall.mjs";
import { request } from "node:http";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const OPENCLAW = {
    "x-request-id": "req-abc-1",
    "x-openclaw-agent-id": "main",
    "x-openclaw-session-key": "agent:main:signal:group:42",
    "x-openclaw-session-id": "sess-uuid-should-lose",
    "x-openclaw-instance": "gateway-a",
};

let events;
const open = [];
async function table(tiers, name) { const t = await proxyFor(tiers, name); open.push(t); return t; }
async function upstream(h) { const u = await fakeUpstream(h); open.push(u); return u; }

beforeEach(() => { events = recorder(); });
after(async () => { setTelemetry(null); await Promise.all(open.map((x) => x.close())); });

// ── Item 2: the five exits, exactly once, explicit outcome ────────────────
describe("one record per request at each dispatch exit", () => {
    test("normal finish → complete, one record with the full v2 field set", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up, label: "gpu-main" }]);
        const r = await post(t, { headers: OPENCLAW });
        assert.equal(r.status, 200);
        assert.deepEqual(JSON.parse(r.body), COMPLETION, "response forwarded unchanged");
        assert.ok(await until(() => events.length === 1));
        await sleep(50);
        assert.equal(events.length, 1);
        const e = events[0];
        assert.deepEqual(Object.keys(e).sort(), [
            "agentId", "durationMs", "endpoint", "instance", "model", "outcome", "port",
            "provider", "requestId", "sessionId", "status", "usage",
        ]);
        assert.equal(e.outcome, "complete");
        assert.equal(e.status, 200);
        assert.equal(e.endpoint, "agent");
        assert.equal(e.port, t.listenPort);
        assert.equal(e.provider, "gpu-main");
        assert.equal(e.model, "qwen3-test.gguf");
        assert.equal(typeof e.durationMs, "number");
        assert.ok(e.durationMs >= 0);
    });

    test("failure after the commit point → error, status of the committed response", async () => {
        const up = await upstream((req, res) => {
            res.writeHead(200, { "content-type": "text/event-stream" });
            res.write(`data: ${JSON.stringify(chunk("partial"))}\n\n`);
            setTimeout(() => res.socket.destroy(), 30);
        });
        const t = await table([{ up, label: "flaky" }]);
        await post(t).catch(() => {});  // client sees a truncated stream
        assert.ok(await until(() => events.length >= 1));
        await sleep(50);
        assert.equal(events.length, 1);
        assert.equal(events[0].outcome, "error");
        assert.equal(events[0].status, 200);
        assert.equal(events[0].provider, "flaky");
        assert.equal(events[0].usage, null);
    });

    test("client gone first, after commit (mid-stream) → aborted", async () => {
        const up = await upstream(async (req, res) => {
            res.writeHead(200, { "content-type": "text/event-stream" });
            res.write(`data: ${JSON.stringify(chunk("a"))}\n\n`);
            // keep generating long after the client left
            const iv = setInterval(() => { if (!res.destroyed) res.write(`data: ${JSON.stringify(chunk("b"))}\n\n`); }, 20);
            res.on("close", () => clearInterval(iv));
        });
        const t = await table([{ up }]);
        await postAndAbandon(t, { after: "byte" });
        assert.ok(await until(() => events.length >= 1));
        await sleep(80);
        assert.equal(events.length, 1);
        assert.equal(events[0].outcome, "aborted");
        assert.equal(events[0].provider, "tier-1");
    });

    test("client gone first, before commit (upstream still thinking) → aborted, no retry", async () => {
        const hangs = await upstream(() => {});  // never answers
        const spare = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up: hangs }, { up: spare }]);
        await postAndAbandon(t, { after: "time", ms: 100 });
        assert.ok(await until(() => events.length >= 1));
        await sleep(80);
        assert.equal(events.length, 1);
        assert.equal(events[0].outcome, "aborted");
        assert.equal(spare.hits, 0, "a client that left is not retried on the next tier");
    });

    test("all tiers failed → one 503 error record, not one per tier", async () => {
        const a = await upstream(jsonReply({ error: "loading" }, 503));
        const b = await upstream(jsonReply({ error: "bad gateway" }, 502));
        const t = await table([{ up: a, label: "one" }, { up: b, label: "two" }]);
        const r = await post(t, { headers: OPENCLAW });
        assert.equal(r.status, 503);
        assert.match(r.body, /all tiers failed/);
        assert.ok(await until(() => events.length >= 1));
        await sleep(50);
        assert.equal(events.length, 1);
        assert.equal(events[0].outcome, "error");
        assert.equal(events[0].status, 503);
        assert.equal(events[0].provider, null, "no tier served it");
        assert.equal(events[0].usage, null);
        assert.equal(events[0].requestId, "req-abc-1");
        assert.equal(events[0].agentId, "main");
    });

    test("no endpoint available → one 503 error record", async () => {
        const t = await table([], "subagent");
        const r = await post(t);
        assert.equal(r.status, 503);
        assert.match(r.body, /no endpoints available/);
        assert.ok(await until(() => events.length >= 1));
        await sleep(30);
        assert.equal(events.length, 1);
        assert.equal(events[0].outcome, "error");
        assert.equal(events[0].status, 503);
        assert.equal(events[0].endpoint, "subagent");
        assert.equal(events[0].port, t.listenPort);
        assert.equal(events[0].provider, null);
    });

    test("disabled-only table is the no-endpoint exit too", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        t.endpoints[0].enabled = false;
        const r = await post(t);
        assert.equal(r.status, 503);
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].outcome, "error");
        assert.equal(up.hits, 0);
    });
});

describe("never at a pre-commit tier retry", () => {
    test("HTTP 503 on tier 1 cascades; only the serving tier 2 is recorded", async () => {
        const loading = await upstream(jsonReply({ error: "loading model" }, 503));
        const ok = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up: loading, label: "fast" }, { up: ok, label: "slow" }]);
        const r = await post(t);
        assert.equal(r.status, 200);
        assert.ok(await until(() => events.length >= 1));
        await sleep(50);
        assert.equal(loading.hits, 1, "tier 1 was tried");
        assert.equal(events.length, 1);
        assert.equal(events[0].provider, "slow");
        assert.equal(events[0].outcome, "complete");
    });

    test("connect refused on tier 1 cascades without a record", async () => {
        const ok = await upstream(jsonReply(COMPLETION));
        const dead = await fakeUpstream(jsonReply({}));
        const deadPort = dead.port;
        await dead.close();
        const t = await table([{ port: deadPort }, { up: ok }]);
        const r = await post(t);
        assert.equal(r.status, 200);
        assert.ok(await until(() => events.length >= 1));
        await sleep(50);
        assert.equal(events.length, 1);
        assert.equal(events[0].provider, "tier-2");
    });

    test("tier dying mid-body before commit (non-streaming) cascades without a record", async () => {
        const dies = await upstream((req, res) => {
            res.writeHead(200, { "content-type": "application/json", "content-length": "500" });
            res.write('{"id":"x","choi');
            setTimeout(() => res.socket.destroy(), 20);
        });
        const ok = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up: dies }, { up: ok }]);
        const r = await post(t);
        assert.equal(r.status, 200);
        assert.deepEqual(JSON.parse(r.body), COMPLETION);
        assert.ok(await until(() => events.length >= 1));
        await sleep(50);
        assert.equal(events.length, 1);
        assert.equal(events[0].provider, "tier-2");
        assert.equal(events[0].outcome, "complete");
        assert.deepEqual(events[0].usage, { input: 120, output: 7, cacheRead: 0, cacheWrite: 0 });
    });

    test("tier dying before the first SSE chunk cascades without a record", async () => {
        const dies = await upstream((req, res) => {
            res.writeHead(200, { "content-type": "text/event-stream" });
            res.flushHeaders();
            setTimeout(() => res.socket.destroy(), 20);
        });
        const ok = await upstream(sseReply([chunk("hi"), "data: [DONE]\n\n"]));
        const t = await table([{ up: dies }, { up: ok }]);
        const r = await post(t);
        assert.equal(r.status, 200);
        assert.ok(await until(() => events.length >= 1));
        await sleep(50);
        assert.equal(events.length, 1);
        assert.equal(events[0].provider, "tier-2");
    });

    test("each of several sequential requests is recorded once", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        for (let k = 0; k < 5; k++) await post(t, { headers: { "x-request-id": `r${k}` } });
        assert.ok(await until(() => events.length === 5));
        await sleep(50);
        assert.deepEqual(events.map((e) => e.requestId), ["r0", "r1", "r2", "r3", "r4"]);
    });
});

// ── Item 4: usage ─────────────────────────────────────────────────────────
describe("usage", () => {
    test("non-streaming body: prompt/completion tokens", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        await post(t);
        assert.ok(await until(() => events.length === 1));
        assert.deepEqual(events[0].usage, { input: 120, output: 7, cacheRead: 0, cacheWrite: 0 });
    });

    test("non-streaming body: timings.cache_n → cacheRead, input excludes it", async () => {
        const up = await upstream(jsonReply({ ...COMPLETION, timings: { cache_n: 100, prompt_n: 20, predicted_n: 7 } }));
        const t = await table([{ up }]);
        await post(t);
        assert.ok(await until(() => events.length === 1));
        assert.deepEqual(events[0].usage, { input: 20, output: 7, cacheRead: 100, cacheWrite: 0 });
    });

    test("non-streaming body without usage → null (request still counts)", async () => {
        const { usage, ...noUsage } = COMPLETION;
        const up = await upstream(jsonReply(noUsage));
        const t = await table([{ up }]);
        await post(t);
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].usage, null);
        assert.equal(events[0].model, "qwen3-test.gguf");
        assert.equal(events[0].outcome, "complete");
    });

    test("unparseable body → usage null, body forwarded verbatim", async () => {
        const up = await upstream((req, res) => { res.writeHead(200, { "content-type": "application/json" }); res.end("{not json"); });
        const t = await table([{ up }]);
        const r = await post(t);
        assert.equal(r.body, "{not json");
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].usage, null);
        assert.equal(events[0].model, null);
    });

    test("upstream 4xx is forwarded and recorded with its status", async () => {
        const up = await upstream(jsonReply({ error: { message: "context too long" } }, 400));
        const t = await table([{ up }]);
        const r = await post(t);
        assert.equal(r.status, 400);
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].status, 400);
        assert.equal(events[0].outcome, "complete");
        assert.equal(events[0].usage, null);
    });

    test("streaming: final usage chunk before [DONE], with timings", async () => {
        const up = await upstream(sseReply([
            chunk("Hel"), chunk("lo"),
            { ...chunk(""), choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
            { id: "chatcmpl-s", object: "chat.completion.chunk", model: "qwen3-test.gguf", choices: [],
              usage: { prompt_tokens: 900, completion_tokens: 2, total_tokens: 902 },
              timings: { cache_n: 850, prompt_n: 50, predicted_n: 2 } },
            "data: [DONE]\n\n",
        ], { delayMs: 5 }));
        const t = await table([{ up }]);
        const r = await post(t, { body: { stream: true, stream_options: { include_usage: true } } });
        assert.match(r.body, /\[DONE\]/);
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].outcome, "complete");
        assert.equal(events[0].model, "qwen3-test.gguf");
        assert.deepEqual(events[0].usage, { input: 50, output: 2, cacheRead: 850, cacheWrite: 0 });
    });

    test("streaming: usage chunk split across TCP writes is still found", async () => {
        const final = `data: ${JSON.stringify({ choices: [], model: "m", usage: { prompt_tokens: 10, completion_tokens: 3 } })}\n\n`;
        const cut = Math.floor(final.length / 2);
        const up = await upstream(sseReply([chunk("x"), final.slice(0, cut), final.slice(cut), "data: [DONE]\n\n"], { delayMs: 10 }));
        const t = await table([{ up }]);
        await post(t);
        assert.ok(await until(() => events.length === 1));
        assert.deepEqual(events[0].usage, { input: 10, output: 3, cacheRead: 0, cacheWrite: 0 });
    });

    test("streaming: long stream beyond the tail window keeps only what it needs", async () => {
        const big = Array.from({ length: 600 }, (_, k) => chunk("x".repeat(200) + k));  // ~200 KiB
        const up = await upstream(sseReply([
            ...big,
            { choices: [], model: "qwen3-test.gguf", usage: { prompt_tokens: 5000, completion_tokens: 600 } },
            "data: [DONE]\n\n",
        ]));
        const t = await table([{ up }]);
        const r = await post(t);
        assert.ok(r.body.length > 100_000, "whole stream forwarded");
        assert.ok(await until(() => events.length === 1));
        assert.deepEqual(events[0].usage, { input: 5000, output: 600, cacheRead: 0, cacheWrite: 0 });
    });

    test("streaming without usage (client did not ask) → null, request still counts", async () => {
        const up = await upstream(sseReply([chunk("a"), chunk("b"), "data: [DONE]\n\n"]));
        const t = await table([{ up }]);
        await post(t);
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].usage, null);
        assert.equal(events[0].outcome, "complete");
        assert.equal(events[0].model, "qwen3-test.gguf");
    });
});

// ── Item 3: headers and provider ──────────────────────────────────────────
describe("fields from headers", () => {
    test("agentId / sessionId (session-key preferred) / instance / requestId", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        await post(t, { headers: OPENCLAW });
        assert.ok(await until(() => events.length === 1));
        const e = events[0];
        assert.equal(e.requestId, "req-abc-1");
        assert.equal(e.agentId, "main");
        assert.equal(e.sessionId, "agent:main:signal:group:42");
        assert.equal(e.instance, "gateway-a");
    });

    test("sessionId falls back to x-openclaw-session-id", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        await post(t, { headers: { "x-openclaw-session-id": "tui-1234" } });
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].sessionId, "tui-1234");
    });

    test("no headers → fresh UUID requestId and null identity fields", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        await post(t);
        await post(t);
        assert.ok(await until(() => events.length === 2));
        assert.match(events[0].requestId, UUID_RE);
        assert.notEqual(events[0].requestId, events[1].requestId);
        assert.equal(events[0].agentId, null);
        assert.equal(events[0].sessionId, null);
        assert.equal(events[0].instance, null);
    });

    test("an oversized x-request-id is replaced, never truncated into a collision", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        await post(t, { headers: { "x-request-id": "r".repeat(300) } });
        assert.ok(await until(() => events.length === 1));
        assert.match(events[0].requestId, UUID_RE);
    });

    test("subagent table reports its own endpoint name and port", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }], "subagent");
        await post(t);
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].endpoint, "subagent");
        assert.equal(events[0].port, t.listenPort);
    });
});

describe("provider hygiene", () => {
    test("provider is the label, else tier-<n>, and never host or port", async () => {
        const a = await upstream(jsonReply({ error: "x" }, 503));
        const b = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up: a, label: "fast" }, { up: b }]);
        await post(t);
        assert.ok(await until(() => events.length === 1));
        assert.equal(events[0].provider, "tier-2");

        const lines = [];
        const t2 = await table([{ up: b, label: `127.0.0.1:${b.port}` }]);
        await post(t2);
        const t3 = await table([{ up: b, label: `box on ${b.port}` }]);
        await post(t3);
        assert.ok(await until(() => events.length === 3));
        assert.equal(events[1].provider, "tier-1");
        assert.equal(events[2].provider, "tier-1");
        for (const e of events) {
            lines.push(JSON.stringify(e));
            assert.doesNotMatch(e.provider, /127\.0\.0\.1|localhost/);
            assert.ok(!e.provider.includes(String(a.port)) && !e.provider.includes(String(b.port)));
        }
        // and nowhere else in the record either
        for (const l of lines) assert.doesNotMatch(l, /127\.0\.0\.1/);
    });
});

// ── Fail-silence ──────────────────────────────────────────────────────────
describe("telemetry never affects the response", () => {
    test("an emitter whose record() throws", async () => {
        let calls = 0;
        setTelemetry({ record: () => { calls++; throw new Error("boom"); } });
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        const r = await post(t);
        assert.equal(r.status, 200);
        assert.deepEqual(JSON.parse(r.body), COMPLETION);
        const s = await upstream(sseReply([chunk("a"), "data: [DONE]\n\n"]));
        const ts = await table([{ up: s }]);
        const rs = await post(ts);
        assert.match(rs.body, /\[DONE\]/);
        const r503 = await post(await table([]));
        assert.equal(r503.status, 503);
        assert.equal(calls, 3);
    });

    test("an emitter whose record() hangs on a getter or returns garbage", async () => {
        setTelemetry({ get record() { throw new Error("no record for you"); } });
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        const r = await post(t);
        assert.equal(r.status, 200);
    });

    test("telemetry off: dispatch behaves exactly as before", async () => {
        setTelemetry(null);
        const up = await upstream(sseReply([chunk("a"), "data: [DONE]\n\n"]));
        const t = await table([{ up }]);
        const r = await post(t);
        assert.match(r.body, /\[DONE\]/);
        assert.equal(events.length, 0);
    });
});

// ── Item 8: inference only ────────────────────────────────────────────────
function send(t, method, path, body = null) {
    return new Promise((resolve, reject) => {
        const data = body === null ? null : Buffer.from(JSON.stringify(body));
        const req = request({
            host: "127.0.0.1", port: t.listenPort, method, path,
            headers: { connection: "close", ...(data ? { "content-type": "application/json", "content-length": data.length } : {}) },
        }, (res) => { res.resume(); res.on("end", () => resolve(res.statusCode)); res.on("error", reject); });
        req.on("error", reject);
        req.end(data ?? undefined);
    });
}

describe("inference only (item 8)", () => {
    test("model calls are recorded, on every inference path", async () => {
        const up = await upstream(jsonReply(COMPLETION));
        const t = await table([{ up }]);
        const paths = [
            "/v1/chat/completions", "/v1/completions", "/completion", "/v1/embeddings",
            "/embedding", "/v1/rerank", "/infill", "/v1/messages", "/v1/chat/completions?stream=false",
            "/v1/chat/completions/",
        ];
        for (const path of paths) assert.equal(await send(t, "POST", path, { model: "x" }), 200, path);
        assert.ok(await until(() => events.length === paths.length));
        await sleep(50);
        assert.equal(events.length, paths.length);
        assert.ok(events.every((e) => e.outcome === "complete"));
    });

    test("health probes, GET /v1/models and other non-model calls are never recorded", async () => {
        const up = await upstream(jsonReply({ status: "ok", data: [] }));
        const t = await table([{ up }]);
        const calls = [
            ["GET", "/health"], ["GET", "/v1/health"], ["GET", "/v1/models"], ["GET", "/models"],
            ["GET", "/props"], ["GET", "/slots"], ["GET", "/metrics"], ["HEAD", "/health"],
            ["GET", "/v1/chat/completions"], ["OPTIONS", "/v1/chat/completions"],
            ["POST", "/tokenize"], ["POST", "/detokenize"], ["POST", "/apply-template"],
            ["POST", "/slots/0?action=save"], ["POST", "/v1/chat/completions-not"],
        ];
        for (const [m, path] of calls) {
            assert.equal(await send(t, m, path, m === "POST" ? { content: "x" } : null), 200, `${m} ${path}`);
        }
        assert.equal(up.hits, calls.length, "all forwarded");
        await sleep(100);
        assert.deepEqual(events, []);
    });

    test("non-model calls stay unrecorded on the 503 exits too", async () => {
        const t = await table([{ up: null, port: 1 }]);
        assert.equal(await send(t, "GET", "/health"), 503);
        assert.equal(await send(t, "GET", "/v1/models"), 503);
        t.endpoints[0].enabled = false;
        assert.equal(await send(t, "GET", "/health"), 503);
        assert.equal(await send(t, "POST", "/v1/chat/completions", { model: "x" }), 503);
        assert.ok(await until(() => events.length === 1));
        await sleep(50);
        assert.equal(events.length, 1, "only the model call");
        assert.equal(events[0].status, 503);
    });

    test("isInferenceRequest: method and path", () => {
        const r = (method, url) => isInferenceRequest({ method, url });
        assert.equal(r("POST", "/v1/chat/completions"), true);
        assert.equal(r("post", "/V1/Chat/Completions"), true);
        assert.equal(r("POST", "http://upstream/v1/completions"), true);
        assert.equal(r("POST", "/v1/embeddings#x"), true);
        assert.equal(r("GET", "/v1/chat/completions"), false);
        assert.equal(r("POST", "/health"), false);
        assert.equal(r("POST", "/v1/models"), false);
        assert.equal(r("POST", "/"), false);
        assert.equal(r(undefined, undefined), false);
    });
});
