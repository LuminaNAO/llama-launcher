#!/usr/bin/env node

import { createServer, request as httpRequest } from "node:http";
import { createServer as createNetServer } from "node:net";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import assert from "node:assert/strict";

const ROOT = mkdtempSync(join(tmpdir(), "llama-proxy-cow-"));
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

let loadedFilename = null;
let requestCount = 0;
const saves = [];
const restores = [];
const messages = [];
let proxy = null;
let stderr = "";
const startedAt = Date.now();

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

function postJson(port, path, body) {
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

async function waitForSettledSlots(expectedBins, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const files = readdirSync(SLOT_DIR);
    const bins = files.filter((f) => f.endsWith(".bin")).sort();
    const metas = files.filter((f) => f.endsWith(".meta.json")).sort();
    if (bins.length >= expectedBins && bins.length === metas.length) {
      return { bins, metas };
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const files = readdirSync(SLOT_DIR);
  return {
    bins: files.filter((f) => f.endsWith(".bin")).sort(),
    metas: files.filter((f) => f.endsWith(".meta.json")).sort(),
  };
}

function makePrompt(branch, tail) {
  const stable = "shared-prefix ".repeat(5000);
  const branchText = branch === "main"
    ? "original branch content"
    : branch === "fork-a"
      ? "fork A replaces an older tool result with compacted text"
      : "fork B appends different task context";
  return {
    system: "system prompt",
    messages: [
      { role: "user", content: "conversation anchor" },
      { role: "assistant", content: stable },
      { role: "user", content: branchText },
      { role: "user", content: tail },
    ],
  };
}

function makeLongPrefixPrompt(tail) {
  return {
    system: "system prompt",
    messages: [
      { role: "user", content: "conversation anchor" },
      { role: "assistant", content: "long shared prefix ".repeat(18000) },
      { role: "user", content: tail },
    ],
  };
}

const backend = createServer(async (req, res) => {
  if (req.method === "POST" && req.url.startsWith("/slots/0")) {
    const action = new URL(req.url, "http://127.0.0.1").searchParams.get("action");
    const body = JSON.parse(await readBody(req));
    if (action === "save") {
      requestCount++;
      writeFileSync(join(SLOT_DIR, body.filename), `slot:${body.filename}:source:${loadedFilename ?? "cold"}:n:${requestCount}`);
      writeFileSync(join(SLOT_DIR, `${body.filename}.ckpt`), `ckpt:${body.filename}`);
      saves.push({ filename: body.filename, loadedFrom: loadedFilename });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ n_saved: 100 + requestCount, n_written: 1000 + requestCount }));
      return;
    }
    if (action === "restore") {
      restores.push(body.filename);
      const path = join(SLOT_DIR, body.filename);
      try {
        readFileSync(path);
        loadedFilename = body.filename;
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ n_restored: 100, n_read: 1000 }));
      } catch {
        loadedFilename = null;
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "missing" }));
      }
      return;
    }
  }

  if (req.method === "POST" && req.url.startsWith("/v1/messages")) {
    const body = await readBody(req);
    messages.push({ loadedFilename, bytes: Buffer.byteLength(body) });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ content: [{ type: "text", text: `ok ${messages.length}` }] }));
    return;
  }

  res.writeHead(404);
  res.end("not found");
});

await new Promise((resolve) => backend.listen(BACKEND_PORT, "127.0.0.1", resolve));

try {
  proxy = await startProxy();

  const initial = Array.from({ length: 4 }, (_, i) =>
    postJson(PROXY_PORT, "/v1/messages", makePrompt("main", `append ${i}`)));
  await Promise.all(initial);
  await waitForSettledSlots(4);

  await stopProxy();
  loadedFilename = null;
  proxy = await startProxy();

  await Promise.all([
    postJson(PROXY_PORT, "/v1/messages", makePrompt("fork-a", "fork turn 1")),
    postJson(PROXY_PORT, "/v1/messages", makePrompt("fork-b", "fork turn 1")),
    postJson(PROXY_PORT, "/v1/messages", makePrompt("main", "append resume 1")),
  ]);

  await Promise.all([
    postJson(PROXY_PORT, "/v1/messages", makePrompt("fork-a", "fork turn 2")),
    postJson(PROXY_PORT, "/v1/messages", makePrompt("main", "append resume 2")),
  ]);

  await Promise.all([
    postJson(PROXY_PORT, "/v1/messages", makeLongPrefixPrompt("late divergence A")),
    postJson(PROXY_PORT, "/v1/messages", makeLongPrefixPrompt("late divergence B")),
  ]);

  const { bins, metas } = await waitForSettledSlots(1);
  assert.ok(bins.length >= 1, `expected at least one saved branch, got ${bins.length}: ${bins.join(",")}`);
  assert.ok(bins.length <= 2, `expected old same-base branches to be pruned, got ${bins.length}: ${bins.join(",")}`);
  assert.equal(bins.length, metas.length, "each .bin should have a .meta.json");

  const parsedMetas = metas.map((f) => JSON.parse(readFileSync(join(SLOT_DIR, f), "utf8")));
  assert.ok(restores.length > 0, "expected persisted parent/exact restores after proxy restart");
  assert.ok(parsedMetas.every((m) => m.completed === true && m.volatile === false), "saved branches should be completed/non-volatile");
  assert.ok(new Set(bins).size === bins.length, "slot filenames should be unique");

  const slotFiles = readdirSync(SLOT_DIR);
  const bytesByKind = { bin: 0, ckpt: 0, meta: 0, total: 0 };
  for (const f of slotFiles) {
    const size = readFileSync(join(SLOT_DIR, f)).byteLength;
    bytesByKind.total += size;
    if (f.endsWith(".bin")) bytesByKind.bin += size;
    else if (f.endsWith(".bin.ckpt")) bytesByKind.ckpt += size;
    else if (f.endsWith(".meta.json")) bytesByKind.meta += size;
  }

  console.log(JSON.stringify({
    ok: true,
    elapsedMs: Date.now() - startedAt,
    requests: messages.length,
    saves: saves.length,
    restores,
    bins: bins.length,
    metas: metas.length,
    bytesByKind,
    slotDir: SLOT_DIR,
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
