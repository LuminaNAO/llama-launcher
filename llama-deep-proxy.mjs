#!/usr/bin/env node

// Transparent HTTP proxy that tee-s raw request/response bodies to a log file.
// Optionally manages llama-server slot save/restore for cross-restart and
// cross-session KV persistence (single-slot only — assumes parallel=1).
//
// Usage:
//   node llama-deep-proxy.mjs <listen-port> <backend-port> [log-file] [--slot-cache-dir <dir>] [--api-key <key>]
//
// Behavior:
//   - All traffic forwarded to backend; bodies tee'd to log-file.
//   - For POST /v1/messages, when --slot-cache-dir is set: hashes
//     sha256(system + first-user-msg)[0:16] = sessionId, calls
//     /slots/0?action=save then /slots/0?action=restore on the backend
//     when sessionId differs from the currently-loaded slot.
//   - Concurrent /v1/messages are serialized through a Promise mutex on the
//     slot-mgmt critical section. The actual request forwarding is not
//     serialized — backend handles that via its own slot scheduling.
//   - Backpressure honored on both directions (important for slow downstream
//     clients like SSH-tunneled openclaw).
//   - Client/upstream socket lifecycle handled defensively: aborts and
//     errors are caught, in-flight counter never leaks, EPIPE on a closed
//     client doesn't crash the proxy.

import { createServer, request as httpRequest } from "node:http";
import { createWriteStream, mkdirSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";

// Defensive: re-create slot cache dir if it was wiped at runtime.
// Required because llama-server's slot-save endpoint silently returns HTTP
// 200 even when the underlying file write fails (file-not-found from a
// missing parent dir → 200 + log line). Without this, a wipe of the slot
// dir while the server is running corrupts the next session indefinitely.
function ensureSlotCacheDir() {
  if (slotCacheDir && !existsSync(slotCacheDir)) {
    try { mkdirSync(slotCacheDir, { recursive: true }); } catch {}
  }
}

// ── Args ──────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const listenPort = parseInt(args[0], 10);
const backendPort = parseInt(args[1], 10);
const logFile = args[2] && !args[2].startsWith("--") ? args[2] : `${process.env.HOME}/llama-deep.log`;

let slotCacheDir = null;
let apiKey = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--slot-cache-dir") slotCacheDir = args[i + 1];
  if (args[i] === "--api-key") apiKey = args[i + 1];
}

if (!listenPort || !backendPort) {
  console.error("Usage: llama-deep-proxy.mjs <listen-port> <backend-port> [log-file] [--slot-cache-dir <dir>] [--api-key <key>]");
  process.exit(1);
}

if (slotCacheDir) {
  if (!existsSync(slotCacheDir)) mkdirSync(slotCacheDir, { recursive: true });
  if (!slotCacheDir.endsWith("/")) slotCacheDir += "/";
}

const log = createWriteStream(logFile, { flags: "a" });
const SEP = "\n========================================\n";

// ── Slot management state (parallel=1: single slot, but proxy serializes) ─
let currentSession = null;        // sha256[:16] of (system + first user msg), or null
let slotMutex = Promise.resolve(); // Promise chain — await prior op before starting next
let inFlightRequests = 0;          // for graceful shutdown drain

// Slot ops to BOTH the deep log (for grep/audit) AND console (so the
// launcher's stdout shows them even when --no-deep-log routes the deep log
// to /dev/null). Console output gets ANSI color so HDD hits stand out from
// the firehose of regular server logs; the deep log gets plain text.
const C_GREEN  = "\x1b[1;32m";  // bright green — restore HIT (HDD cache served)
const C_YELLOW = "\x1b[33m";    // yellow      — restore MISS (cold session, no file yet)
const C_CYAN   = "\x1b[36m";    // cyan        — save persisted
const C_RED    = "\x1b[31m";    // red         — errors / non-200 save
const C_DIM    = "\x1b[2m";     // dim         — boilerplate "save:" / "restore:" intent lines
const C_RESET  = "\x1b[0m";

function slotLog(line, color = null) {
  log.write(line);
  const colored = color ? `${color}${line.replace(/\n$/, "")}${C_RESET}\n` : line;
  process.stdout.write(colored.startsWith("\n") ? colored : "\n" + colored);
}

// Color a slot-action status line based on the parsed status code.
function colorForStatus(action, status) {
  if (action === "restore") {
    return status === 200 ? C_GREEN : C_YELLOW;   // HIT vs cold
  }
  if (action === "save") {
    return status === 200 ? C_CYAN : C_RED;
  }
  return null;
}

function parseSlotActionBody(r) {
  try {
    return JSON.parse(r.body);
  } catch {
    return {};
  }
}

function slotSaveSucceeded(r) {
  const body = parseSlotActionBody(r);
  const nSaved = Number(body.n_saved ?? 0);
  const nWritten = Number(body.n_written ?? 0);
  return {
    ok: r.status === 200 && nSaved > 0 && nWritten > 0,
    nSaved,
    nWritten,
  };
}

function slotRestoreSucceeded(r) {
  const body = parseSlotActionBody(r);
  const nRestored = Number(body.n_restored ?? 0);
  const nRead = Number(body.n_read ?? 0);
  return {
    ok: r.status === 200 && nRestored > 0 && nRead > 0,
    nRestored,
    nRead,
  };
}

// ── Slot cache helpers ────────────────────────────────────────────────────
function callSlotAction(action, filename, timeoutMs = 0) {
  return new Promise((resolve) => {
    const body = JSON.stringify({ filename });
    const path = `/slots/0?action=${action}`;
    const headers = {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
    };
    if (apiKey) headers["Authorization"] = `Bearer ${apiKey}`;
    const req = httpRequest({ hostname: "127.0.0.1", port: backendPort, path, method: "POST", headers }, (res) => {
      let respBody = "";
      res.on("data", (c) => respBody += c);
      res.on("end", () => resolve({ status: res.statusCode, body: respBody }));
    });
    req.on("error", (e) => resolve({ status: 0, body: e.message }));
    if (timeoutMs > 0) {
      req.setTimeout(timeoutMs, () => {
        req.destroy(new Error(`slot ${action} timed out after ${timeoutMs}ms`));
      });
    }
    req.write(body);
    req.end();
  });
}

function sessionIdFromBody(jsonStr) {
  try {
    const obj = JSON.parse(jsonStr);
    let key = "";
    if (obj.system) {
      key += typeof obj.system === "string" ? obj.system : JSON.stringify(obj.system);
    }
    if (Array.isArray(obj.messages) && obj.messages.length > 0) {
      const m0 = obj.messages[0];
      key += "\n" + (typeof m0.content === "string" ? m0.content : JSON.stringify(m0.content));
    }
    if (!key) return null;
    return createHash("sha256").update(key).digest("hex").slice(0, 16);
  } catch {
    return null;
  }
}

// Serialize slot save+restore through a Promise mutex. Concurrent callers
// queue and wait. Each acquires the lock, re-checks currentSession (a prior
// holder may have already loaded the session this caller wants), then runs
// save+restore as needed.
async function ensureSlotLoaded(newSessionId) {
  if (!slotCacheDir) return;
  const prev = slotMutex;
  let release;
  slotMutex = new Promise((r) => { release = r; });
  await prev;
  try {
    if (newSessionId === currentSession) return;
    if (currentSession) {
      ensureSlotCacheDir();
      slotLog(`\n--- SLOT save: ${currentSession}.bin\n`, C_DIM);
      const r = await callSlotAction("save", `${currentSession}.bin`);
      const save = slotSaveSucceeded(r);
      slotLog(
        `--- SLOT save status=${r.status} n_saved=${save.nSaved} n_written=${save.nWritten}\n`,
        save.ok ? C_CYAN : C_RED,
      );
    }
    slotLog(`\n--- SLOT restore: ${newSessionId}.bin\n`, C_DIM);
    const r = await callSlotAction("restore", `${newSessionId}.bin`);
    const restore = slotRestoreSucceeded(r);
    slotLog(
      `--- SLOT restore status=${r.status} n_restored=${restore.nRestored} n_read=${restore.nRead} ${r.body.slice(0, 200)}\n`,
      restore.ok ? C_GREEN : colorForStatus("restore", r.status),
    );
    // Restore returning 4xx/5xx (e.g., file not found) is normal for new sessions.
    currentSession = newSessionId;
  } finally {
    release();
  }
}

async function saveCurrentSlot(reason, timeoutMs = 0) {
  if (!slotCacheDir || !currentSession) return;
  // Acquire mutex so we don't race with an in-flight switch
  const prev = slotMutex;
  let release;
  slotMutex = new Promise((r) => { release = r; });
  await prev;
  try {
    ensureSlotCacheDir();
    slotLog(`\n--- SLOT save (${reason}): ${currentSession}.bin\n`, C_DIM);
    const r = await callSlotAction("save", `${currentSession}.bin`, timeoutMs);
    const save = slotSaveSucceeded(r);
    slotLog(
      `--- SLOT save status=${r.status} n_saved=${save.nSaved} n_written=${save.nWritten}\n`,
      save.ok ? C_CYAN : C_RED,
    );
  } finally {
    release();
  }
}

// ── Forwarding helpers ────────────────────────────────────────────────────
// Pipe proxyRes → clientRes with backpressure + EPIPE-safe writes.
// Logs response chunks to the deep log. Calls onDone() exactly once when the
// stream finishes (success or aborted).
function pipeResponse(tag, proxyRes, clientRes, onDone) {
  let done = false;
  const finalize = () => { if (!done) { done = true; onDone(); } };

  const teardown = () => {
    try { proxyRes.destroy(); } catch {}
    try { clientRes.end(); } catch {}
    finalize();
  };

  clientRes.writeHead(proxyRes.statusCode, proxyRes.headers);
  log.write(`\n<<< ${proxyRes.statusCode} ${tag}\n`);

  proxyRes.on("data", (chunk) => {
    log.write(chunk);
    let ok;
    try { ok = clientRes.write(chunk); }
    catch (e) {
      log.write(`\n!!! clientRes write error ${tag}: ${e.message}\n`);
      return teardown();
    }
    if (!ok) proxyRes.pause();
  });
  clientRes.on("drain", () => { try { proxyRes.resume(); } catch {} });
  clientRes.on("close", () => {
    // Client gave up — stop pulling from backend
    if (!done) {
      log.write(`\n--- client closed early ${tag}\n`);
      try { proxyRes.destroy(); } catch {}
      finalize();
    }
  });
  clientRes.on("error", (e) => {
    log.write(`\n!!! clientRes error ${tag}: ${e.message}\n`);
    teardown();
  });

  proxyRes.on("end", () => {
    log.write("\n");
    try { clientRes.end(); } catch {}
    finalize();
  });
  proxyRes.on("error", (e) => {
    log.write(`\n!!! proxyRes error ${tag}: ${e.message}\n`);
    try { clientRes.end(); } catch {}
    finalize();
  });
}

// Pipe clientReq → proxyReq with backpressure (used by the streaming
// pass-through path; the buffered /v1/messages path doesn't need this).
function pipeRequestStreaming(tag, clientReq, proxyReq) {
  clientReq.on("data", (chunk) => {
    log.write(chunk);
    if (!proxyReq.write(chunk)) clientReq.pause();
  });
  proxyReq.on("drain", () => { try { clientReq.resume(); } catch {} });
  clientReq.on("end", () => { try { proxyReq.end(); } catch {} });
  clientReq.on("aborted", () => {
    log.write(`\n!!! clientReq aborted ${tag}\n`);
    try { proxyReq.destroy(); } catch {}
  });
  clientReq.on("error", (e) => {
    log.write(`\n!!! clientReq error ${tag}: ${e.message}\n`);
    try { proxyReq.destroy(); } catch {}
  });
}

// ── Server ────────────────────────────────────────────────────────────────
const server = createServer(async (clientReq, clientRes) => {
  const tag = `${clientReq.method} ${clientReq.url}`;
  log.write(`${SEP}>>> ${tag}\n`);

  const isMessages = clientReq.method === "POST" && clientReq.url.startsWith("/v1/messages");

  // ── Buffered path: /v1/messages with slot mgmt ──────────────────────────
  if (isMessages && slotCacheDir) {
    inFlightRequests++;
    let counted = true;
    const finalize = () => { if (counted) { counted = false; inFlightRequests--; } };

    const chunks = [];
    let aborted = false;
    clientReq.on("data", (c) => chunks.push(c));
    clientReq.on("aborted", () => {
      aborted = true;
      log.write(`\n!!! clientReq aborted (upload) ${tag}\n`);
      finalize();
    });
    clientReq.on("error", (e) => {
      aborted = true;
      log.write(`\n!!! clientReq error ${tag}: ${e.message}\n`);
      finalize();
    });
    clientReq.on("end", async () => {
      if (aborted) return;
      const bodyBuf = Buffer.concat(chunks);
      log.write(bodyBuf);

      const sessionId = sessionIdFromBody(bodyBuf.toString("utf8"));
      try {
        if (sessionId) await ensureSlotLoaded(sessionId);
      } catch (e) {
        log.write(`\n!!! SLOT mgmt error ${tag}: ${e.message}\n`);
      }

      // Re-send the buffered request. Strip hop-by-hop and length-related
      // headers from the inbound request — we control the body length now,
      // and forwarding stale Transfer-Encoding/Connection/Host can corrupt
      // the request on the backend (chunked + content-length conflict per
      // RFC 7230 → silent body parsing failures, e.g., tool-call grammar
      // not engaging on the response side).
      const fwdHeaders = { ...clientReq.headers };
      delete fwdHeaders["transfer-encoding"];
      delete fwdHeaders["content-length"];
      delete fwdHeaders["connection"];
      delete fwdHeaders["host"];
      fwdHeaders["content-length"] = Buffer.byteLength(bodyBuf);

      const proxyReq = httpRequest({
        hostname: "127.0.0.1",
        port: backendPort,
        path: clientReq.url,
        method: clientReq.method,
        headers: fwdHeaders,
      }, (proxyRes) => {
        pipeResponse(tag, proxyRes, clientRes, finalize);
      });

      proxyReq.on("error", (e) => {
        log.write(`\n!!! proxyReq error ${tag}: ${e.message}\n`);
        if (!clientRes.headersSent) {
          try { clientRes.writeHead(502, { "Content-Type": "text/plain" }); } catch {}
        }
        try { clientRes.end(`Proxy error: ${e.message}`); } catch {}
        finalize();
      });

      proxyReq.end(bodyBuf);
    });
    return;
  }

  // ── Pass-through path: everything else (health, slots/*, models, etc.) ──
  inFlightRequests++;
  let counted = true;
  const finalize = () => { if (counted) { counted = false; inFlightRequests--; } };

  const fwdHeaders = { ...clientReq.headers };
  // Strip same headers in pass-through too — caller may have weird framing.
  delete fwdHeaders["connection"];
  delete fwdHeaders["host"];

  const proxyReq = httpRequest({
    hostname: "127.0.0.1",
    port: backendPort,
    path: clientReq.url,
    method: clientReq.method,
    headers: fwdHeaders,
  }, (proxyRes) => {
    pipeResponse(tag, proxyRes, clientRes, finalize);
  });

  proxyReq.on("error", (e) => {
    log.write(`\n!!! proxyReq error ${tag}: ${e.message}\n`);
    if (!clientRes.headersSent) {
      try { clientRes.writeHead(502, { "Content-Type": "text/plain" }); } catch {}
    }
    try { clientRes.end(`Proxy error: ${e.message}`); } catch {}
    finalize();
  });

  pipeRequestStreaming(tag, clientReq, proxyReq);
});

server.listen(listenPort, "0.0.0.0", () => {
  console.log(`llama-deep-proxy: 0.0.0.0:${listenPort} -> 127.0.0.1:${backendPort}`);
  console.log(`llama-deep-proxy: logging to ${logFile}`);
  if (slotCacheDir) console.log(`llama-deep-proxy: slot cache dir = ${slotCacheDir}`);
  if (apiKey) console.log(`llama-deep-proxy: api-key set (used for slot management calls)`);
});

// ── Graceful shutdown: save current slot before exiting ───────────────────
let shuttingDown = false;
async function gracefulShutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`\nllama-deep-proxy: received ${sig}, shutting down`);
  setTimeout(() => {
    console.error("llama-deep-proxy: shutdown deadline exceeded, force-exiting");
    process.exit(1);
  }, 15000).unref();
  server.close();
  const drainDeadline = Date.now() + 5000;
  while (inFlightRequests > 0 && Date.now() < drainDeadline) {
    await new Promise((r) => setTimeout(r, 100));
  }
  try {
    await saveCurrentSlot("shutdown", 8000);
  } catch (e) {
    console.error(`shutdown save error: ${e.message}`);
  }
  log.end();
  process.exit(0);
}
process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT", () => gracefulShutdown("SIGINT"));
