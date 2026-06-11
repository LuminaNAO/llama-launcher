#!/usr/bin/env node

// Exercises the OpenClaw slot routing and no-HDD policy state machine of
// llama-deep-proxy.mjs against a mock backend:
//   - header-identified sessions get exact-only, sanitized slot files
//   - subagent traffic bypasses the cache; the prior clean session is
//     persisted first (fail closed)
//   - internal runtime events run read-only on the live slot (no redundant
//     multi-GB restore) and never clobber persisted state or metadata
//   - tainted KV is refused by every save gate and recovered via the
//     server-side prompt cache on the next persistent turn
//
// Identity helpers are imported from the proxy itself (single source of
// truth); the proxy process is spawned like production.

import { createServer, request as httpRequest } from "node:http";
import { createServer as createNetServer } from "node:net";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import assert from "node:assert/strict";
import {
  safeSlotIdFromOpenClawSessionId,
  cacheInfoFromBody,
  OPENCLAW_MARKERS,
} from "../llama-deep-proxy.mjs";

const ROOT = mkdtempSync(join(tmpdir(), "llama-proxy-openclaw-"));
const SLOT_DIR = join(ROOT, "slots");
const LOG_FILE = join(ROOT, "deep.log");

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createNetServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

const BACKEND_PORT = await freePort();
const PROXY_PORT = await freePort();

// Chronological record of everything the backend sees, for ordering asserts.
const actions = [];
let saveCounter = 0;
let proxy = null;
let stderr = "";

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

function postJson(port, path, body, headers = {}) {
  const payload = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = httpRequest({
      hostname: "127.0.0.1",
      port,
      path,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(payload),
        ...headers,
      },
    }, (res) => {
      let text = "";
      res.on("data", (c) => text += c);
      res.on("end", () => resolve({ status: res.statusCode, body: text }));
    });
    req.on("error", reject);
    req.end(payload);
  });
}

function waitForProxyReady(proc) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("proxy did not start")), 5000);
    proc.stdout.on("data", (chunk) => {
      if (chunk.toString().includes("llama-deep-proxy:")) {
        clearTimeout(timeout);
        resolve();
      }
    });
    proc.once("exit", (code) => reject(new Error(`proxy exited early: ${code}`)));
  });
}

async function startProxy() {
  const proc = spawn(process.execPath, [
    "llama-deep-proxy.mjs",
    String(PROXY_PORT),
    String(BACKEND_PORT),
    LOG_FILE,
    "--slot-cache-dir",
    SLOT_DIR,
    "--min-free-gb",
    "0",
    "--max-total-slots-gb",
    "999999",
  ], {
    cwd: new URL("..", import.meta.url).pathname,
    stdio: ["ignore", "pipe", "pipe"],
  });
  proc.stderr.on("data", (c) => { stderr += c; });
  await waitForProxyReady(proc);
  return proc;
}

async function stopProxy() {
  if (!proxy) return;
  const proc = proxy;
  proxy = null;
  proc.kill("SIGTERM");
  await new Promise((resolve) => proc.once("exit", resolve));
}

const backend = createServer(async (req, res) => {
  if (req.method === "POST" && req.url.startsWith("/slots/0")) {
    const action = new URL(req.url, "http://127.0.0.1").searchParams.get("action");
    const body = JSON.parse(await readBody(req));
    if (action === "save") {
      saveCounter++;
      writeFileSync(join(SLOT_DIR, body.filename), `slot:${body.filename}:n:${saveCounter}`);
      writeFileSync(join(SLOT_DIR, `${body.filename}.ckpt`), `ckpt:${body.filename}`);
      actions.push({ t: "save", f: body.filename });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ n_saved: 100 + saveCounter, n_written: 1000 + saveCounter }));
      return;
    }
    if (action === "restore") {
      actions.push({ t: "restore", f: body.filename });
      try {
        readFileSync(join(SLOT_DIR, body.filename));
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ n_restored: 100, n_read: 1000 }));
      } catch {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "missing" }));
      }
      return;
    }
  }

  if (req.method === "POST" && req.url.startsWith("/v1/messages")) {
    const body = await readBody(req);
    actions.push({ t: "message", bytes: Buffer.byteLength(body) });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ content: [{ type: "text", text: `ok ${actions.length}` }] }));
    return;
  }

  res.writeHead(404);
  res.end("not found");
});

await new Promise((resolve) => backend.listen(BACKEND_PORT, "127.0.0.1", resolve));

const MAIN_SESSION = "signal:group:abc+def=";
const MAIN_SLOT = safeSlotIdFromOpenClawSessionId(MAIN_SESSION);
const SUB_SESSION = "agent:sub:runner-01";
const SUB_SLOT = safeSlotIdFromOpenClawSessionId(SUB_SESSION);
const TUI_SESSION = "tui-0a1b2c3d";
const WEBGUI_SESSION = "webgui/chat#42 user@host";
const WEBGUI_SLOT = safeSlotIdFromOpenClawSessionId(WEBGUI_SESSION);

const mainHeaders = {
  "x-openclaw-session-id": MAIN_SESSION,
  "x-openclaw-agent-kind": "main",
};

function turn(tail, extraMessages = []) {
  return {
    system: "shared system prompt",
    messages: [
      { role: "user", content: "conversation start" },
      { role: "assistant", content: "stable history ".repeat(2000) },
      ...extraMessages,
      { role: "user", content: tail },
    ],
  };
}

function internalEventTurn() {
  return turn(
    `${OPENCLAW_MARKERS.internalRuntime} queue drained\n${OPENCLAW_MARKERS.internalCompletion} task 7 done`,
  );
}

function subagentSniffTurn() {
  return {
    system: "subagent system prompt",
    messages: [
      { role: "user", content: `${OPENCLAW_MARKERS.subagentContext} repo xyz\n${OPENCLAW_MARKERS.subagentTask} run the linter` },
    ],
  };
}

function sliceFrom(mark) {
  return actions.slice(mark);
}

function countBy(list, t, f = null) {
  return list.filter((a) => a.t === t && (f === null || a.f === f)).length;
}

try {
  // ── Unit: sanitizer + classification (imported from the proxy) ──────────
  assert.equal(MAIN_SLOT, "signal-group-abc-def");
  assert.equal(SUB_SLOT, "agent-sub-runner-01");
  assert.equal(WEBGUI_SLOT, "webgui_chat-42-user-host");
  assert.ok(safeSlotIdFromOpenClawSessionId("x".repeat(400)).length <= 180, "long ids must be capped");
  assert.ok(safeSlotIdFromOpenClawSessionId(":.:.:").startsWith("openclaw-"), "unsanitizable ids fall back to hash");

  const roInfo = cacheInfoFromBody(JSON.stringify(internalEventTurn()), mainHeaders);
  assert.equal(roInfo.slotAccess, "read-only", "internal runtime event on main should be read-only");
  assert.equal(roInfo.cachePolicy, "no-hdd");
  const bypassInfo = cacheInfoFromBody(JSON.stringify(subagentSniffTurn()), {});
  assert.equal(bypassInfo.slotAccess, "bypass", "body-sniffed subagent should bypass");
  assert.equal(bypassInfo.agentKind, "subagent");
  const persistentInfo = cacheInfoFromBody(JSON.stringify(turn("hello")), mainHeaders);
  assert.equal(persistentInfo.slotAccess, "persistent");
  assert.equal(persistentInfo.sessionId, MAIN_SLOT);

  proxy = await startProxy();

  // ── A: persistent main session, two turns, no slot files yet ────────────
  await postJson(PROXY_PORT, "/v1/messages", turn("turn 1"), mainHeaders);
  await postJson(PROXY_PORT, "/v1/messages", turn("turn 2"), mainHeaders);
  assert.equal(countBy(actions, "save"), 0, "no saves while a single session stays live");
  assert.equal(countBy(actions, "restore"), 0, "cold exact-only session must not trigger restores");

  // ── B: subagent bypass; clean main state persisted first ────────────────
  let mark = actions.length;
  await postJson(PROXY_PORT, "/v1/messages", turn("sub work 1"), {
    "x-openclaw-session-id": SUB_SESSION,
    "x-openclaw-agent-kind": "subagent",
  });
  let recent = sliceFrom(mark);
  assert.deepEqual(
    recent.map((a) => a.t),
    ["save", "message"],
    "bypass must persist the dirty main slot before the subagent runs",
  );
  assert.equal(recent[0].f, `${MAIN_SLOT}.bin`);

  mark = actions.length;
  await postJson(PROXY_PORT, "/v1/messages", turn("sub work 2"), {
    "x-openclaw-session-id": SUB_SESSION,
    "x-openclaw-agent-kind": "subagent",
  });
  recent = sliceFrom(mark);
  assert.deepEqual(recent.map((a) => a.t), ["message"], "consecutive subagent turns need no slot IO");

  // ── C: main returns; tainted slot skipped, exact restore from disk ──────
  mark = actions.length;
  await postJson(PROXY_PORT, "/v1/messages", turn("turn 3"), mainHeaders);
  recent = sliceFrom(mark);
  assert.deepEqual(
    recent.map((a) => a.t),
    ["restore", "message"],
    "switch off a tainted slot must skip the save and restore main from disk",
  );
  assert.equal(recent[0].f, `${MAIN_SLOT}.bin`);

  // ── D: internal event on the live main session — checkpoint, no restore ─
  mark = actions.length;
  await postJson(PROXY_PORT, "/v1/messages", internalEventTurn(), mainHeaders);
  recent = sliceFrom(mark);
  assert.deepEqual(
    recent.map((a) => a.t),
    ["save", "message"],
    "same-session internal event checkpoints dirty state and reuses the live KV",
  );
  assert.equal(recent[0].f, `${MAIN_SLOT}.bin`);
  const binAfterCheckpoint = readFileSync(join(SLOT_DIR, `${MAIN_SLOT}.bin`), "utf8");
  const metaAfterCheckpoint = JSON.parse(readFileSync(join(SLOT_DIR, `${MAIN_SLOT}.meta.json`), "utf8"));
  assert.equal(metaAfterCheckpoint.completed, true, "checkpoint save must mark the slot completed");

  // ── E: persistent turn on the tainted live slot — zero slot IO ──────────
  mark = actions.length;
  await postJson(PROXY_PORT, "/v1/messages", turn("turn 4"), mainHeaders);
  recent = sliceFrom(mark);
  assert.deepEqual(
    recent.map((a) => a.t),
    ["message"],
    "persistent turn after an internal event must reuse the live slot without IO",
  );

  // ── F: explicit no-hdd on an unknown main session — read-only miss ──────
  mark = actions.length;
  await postJson(PROXY_PORT, "/v1/messages", turn("ephemeral probe"), {
    "x-openclaw-session-id": TUI_SESSION,
    "x-openclaw-agent-kind": "main",
    "x-openclaw-cache-policy": "no-hdd",
  });
  recent = sliceFrom(mark);
  assert.deepEqual(
    recent.map((a) => a.t),
    ["save", "message"],
    "read-only switch saves the dirty main slot, then misses without restore",
  );
  assert.equal(recent[0].f, `${MAIN_SLOT}.bin`);
  const binAfterSwitch = readFileSync(join(SLOT_DIR, `${MAIN_SLOT}.bin`), "utf8");
  assert.notEqual(binAfterSwitch, binAfterCheckpoint, "turn 4 must have been persisted on switch");
  assert.ok(!readdirSync(SLOT_DIR).some((f) => f.startsWith(TUI_SESSION)),
    "read-only miss must not create slot files or metadata");

  // ── G: internal event for main while another session is live ────────────
  mark = actions.length;
  await postJson(PROXY_PORT, "/v1/messages", internalEventTurn(), mainHeaders);
  recent = sliceFrom(mark);
  assert.deepEqual(
    recent.map((a) => a.t),
    ["restore", "message"],
    "read-only switch from a tainted slot skips the save and restores main",
  );
  assert.equal(recent[0].f, `${MAIN_SLOT}.bin`);
  assert.equal(readFileSync(join(SLOT_DIR, `${MAIN_SLOT}.bin`), "utf8"), binAfterSwitch,
    "read-only traffic must not rewrite the persisted slot");
  const metaAfterReadOnly = JSON.parse(readFileSync(join(SLOT_DIR, `${MAIN_SLOT}.meta.json`), "utf8"));
  assert.equal(metaAfterReadOnly.completed, true, "read-only traffic must not clobber slot metadata");

  // ── H: body-sniffed subagent without headers — bypass, no slot files ────
  mark = actions.length;
  await postJson(PROXY_PORT, "/v1/messages", subagentSniffTurn());
  recent = sliceFrom(mark);
  assert.deepEqual(recent.map((a) => a.t), ["message"],
    "tainted slot + sniffed subagent: no saves, no restores");
  assert.ok(!readdirSync(SLOT_DIR).some((f) => f.startsWith(SUB_SLOT)),
    "subagent sessions must never get slot files");

  // ── I: odd web-GUI session id — sanitized slot, persisted on shutdown ───
  await postJson(PROXY_PORT, "/v1/messages", turn("webgui turn"), {
    "x-openclaw-session-id": WEBGUI_SESSION,
    "x-openclaw-agent-kind": "main",
  });
  await stopProxy();
  const files = readdirSync(SLOT_DIR);
  assert.ok(files.includes(`${WEBGUI_SLOT}.bin`), `expected sanitized webgui slot, got ${files.join(",")}`);
  const webguiMeta = JSON.parse(readFileSync(join(SLOT_DIR, `${WEBGUI_SLOT}.meta.json`), "utf8"));
  assert.equal(webguiMeta.openClaw.sessionId, WEBGUI_SESSION);
  assert.equal(webguiMeta.completed, true, "shutdown must persist the live clean session");

  console.log(JSON.stringify({
    ok: true,
    actions: actions.length,
    saves: countBy(actions, "save"),
    restores: countBy(actions, "restore"),
    slotFiles: files.filter((f) => f.endsWith(".bin")).sort(),
  }, null, 2));
} finally {
  await stopProxy();
  await new Promise((resolve) => backend.close(resolve));
  if (stderr.trim()) console.error(stderr);
  if (process.env.KEEP_TEST_DIR === "1") {
    console.error(`kept test dir: ${ROOT}`);
  } else {
    rmSync(ROOT, { recursive: true, force: true });
  }
}
