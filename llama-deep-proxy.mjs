#!/usr/bin/env node

// Transparent HTTP proxy that tee-s raw request/response bodies to a log file.
// Optionally manages llama-server slot save/restore for cross-restart and
// cross-session KV persistence (single-slot only — assumes parallel=1).
//
// Usage:
//   node llama-deep-proxy.mjs <listen-port> <backend-port> [log-file]
//      [--slot-cache-dir <dir>] [--api-key <key>]
//      [--min-free-gb N] [--max-total-slots-gb N]
//      [--llama-log-file <path>] [--stdout-is-llama-log]
//
// Behavior:
//   - All traffic forwarded to backend; bodies tee'd to log-file.
//   - For POST /v1/messages, when --slot-cache-dir is set: hashes a stable
//     conversation anchor plus a full request hash, calls
//     /slots/0?action=save then /slots/0?action=restore on the backend
//     when sessionId differs from the currently-loaded slot.
//   - Before each slot save, prunes the slot cache to keep (a) free disk
//     space above --min-free-gb (default 100) and (b) total bytes across
//     all sibling model slot dirs below --max-total-slots-gb (default 200).
//     Oldest .bin (with its .bin.ckpt sidecar) is evicted first; the
//     session about to be saved is excluded from candidates.
//   - Concurrent /v1/messages are serialized through a Promise mutex on the
//     slot-mgmt critical section. The actual request forwarding is not
//     serialized — backend handles that via its own slot scheduling.
//   - Backpressure honored on both directions (important for slow downstream
//     clients like SSH-tunneled openclaw).
//   - Client/upstream socket lifecycle handled defensively: aborts and
//     errors are caught, in-flight counter never leaks, EPIPE on a closed
//     client doesn't crash the proxy.

import { createServer, request as httpRequest } from "node:http";
import { createWriteStream, mkdirSync, existsSync, statSync, statfsSync, unlinkSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, basename, join } from "node:path";
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
const logFile = args[2] && !args[2].startsWith("--") ? args[2] : "llama-deep.log";

let slotCacheDir = null;
let apiKey = null;
let minFreeGB = 100;
let maxTotalSlotsGB = 200;
let llamaLogFile = null;
let stdoutIsLlamaLog = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--slot-cache-dir") slotCacheDir = args[i + 1];
  if (args[i] === "--api-key") apiKey = args[i + 1];
  if (args[i] === "--min-free-gb") minFreeGB = Number(args[i + 1]);
  if (args[i] === "--max-total-slots-gb") maxTotalSlotsGB = Number(args[i + 1]);
  if (args[i] === "--llama-log-file") llamaLogFile = args[i + 1];
  if (args[i] === "--stdout-is-llama-log") stdoutIsLlamaLog = true;
}

if (!listenPort || !backendPort) {
  console.error("Usage: llama-deep-proxy.mjs <listen-port> <backend-port> [log-file] [--slot-cache-dir <dir>] [--api-key <key>] [--min-free-gb N] [--max-total-slots-gb N] [--llama-log-file <path>] [--stdout-is-llama-log]");
  process.exit(1);
}

if (slotCacheDir) {
  if (!existsSync(slotCacheDir)) mkdirSync(slotCacheDir, { recursive: true });
  if (!slotCacheDir.endsWith("/")) slotCacheDir += "/";
}

const log = createWriteStream(logFile, { flags: "a" });
const llamaLog = llamaLogFile && !stdoutIsLlamaLog
  ? createWriteStream(llamaLogFile, { flags: "a" })
  : null;
const SEP = "\n========================================\n";

// ── Slot management state (parallel=1: single slot, but proxy serializes) ─
let currentSession = null;        // prompt branch cache id, or null
let currentRequestInfo = null;     // cache identity/provenance for currentSession
let currentLoadedFrom = null;      // source slot id used to bootstrap currentSession, if any
let slotMutex = Promise.resolve(); // Promise chain — await prior op before starting next
let messageQueue = Promise.resolve(); // End-to-end /v1/messages queue when HDD cache is active
let inFlightRequests = 0;          // for graceful shutdown drain
const BRANCH_PREFIX_BYTES = 256 * 1024;
// Tracks whether the slot is believed to hold real KV content. Set true after
// a successful restore (n_restored > 0) or a 200 response from /v1/messages
// (PP filled the slot). Set false after a failed restore — llama-server's
// SLOT_RESTORE clears slot->prompt.tokens on nread==0/4xx (see
// server-context.cpp ~L2181), so saving in that state writes a zero-token
// file that overwrites a previously-good cache. The save gate below uses
// this to refuse such self-destructive saves.
let slotHasContent = false;
let slotDirtySinceSave = false;    // true after a request may have mutated KV

function sessionBase(sessionId) {
  const dash = typeof sessionId === "string" ? sessionId.indexOf("-") : -1;
  return dash > 0 ? sessionId.slice(0, dash) : null;
}

function sameSessionBase(a, b) {
  const baseA = sessionBase(a);
  return !!baseA && baseA === sessionBase(b);
}

function slotPath(filename) {
  return join(slotCacheDir, filename);
}

function slotIdFromFilename(filename) {
  return filename.endsWith(".bin") ? filename.slice(0, -4) : filename;
}

function metaFilenameForSlotId(slotId) {
  return `${slotId}.meta.json`;
}

function metaPathForSlotId(slotId) {
  return slotPath(metaFilenameForSlotId(slotId));
}

function enqueueMessage(fn) {
  const prev = messageQueue.catch(() => {});
  const run = prev.then(fn);
  messageQueue = run.catch(() => {});
  return run;
}

// Slot ops to BOTH the deep log (for grep/audit) AND console (so the
// launcher's stdout shows them even when --no-deep-log routes the deep log
// to /dev/null). Console output gets ANSI color so HDD hits stand out from
// the firehose of regular server logs; the deep log gets plain text.
const C_GREEN   = "\x1b[1;32m";  // bright green — restore HIT (served from HDD)
const C_YELLOW  = "\x1b[33m";    // yellow      — checkpoint/miss/prune warnings
const C_CYAN    = "\x1b[36m";    // cyan        — save persisted
const C_BCYAN   = "\x1b[1;36m";  // bright cyan — incoming request summary
const C_MAGENTA = "\x1b[1;35m";  // bright purple — HDD cache operation banners
const C_RED     = "\x1b[31m";    // red         — errors / non-200 save
const C_DIM     = "\x1b[2m";     // dim         — low-priority detail
const C_RESET  = "\x1b[0m";

function colorLine(line, color = null) {
  return color ? `${color}${line.replace(/\n$/, "")}${C_RESET}\n` : line;
}

function slotLog(line, color = null) {
  log.write(line);
  const colored = colorLine(line, color);
  process.stdout.write(colored.startsWith("\n") ? colored : "\n" + colored);
  if (llamaLog) {
    llamaLog.write(colored.startsWith("\n") ? colored : "\n" + colored);
  }
}

function requestLog(line) {
  log.write(line);
  const colored = colorLine(line, C_BCYAN);
  process.stdout.write(colored.startsWith("\n") ? colored : "\n" + colored);
  if (llamaLog) {
    llamaLog.write(colored.startsWith("\n") ? colored : "\n" + colored);
  }
}

// ── Slot cache disk-quota enforcement ──────────────────────────────────────
// Called immediately before every slot save. Scope is "one dir up" from the
// model-specific slotCacheDir, so sibling model dirs share the budget.
// Enforces two limits — evicts oldest .bin (with its .ckpt sidecar) one at a
// time until BOTH pass:
//   1. free disk space on the slot filesystem >= minFreeGB
//   2. total bytes across all sibling slot dirs <= maxTotalSlotsGB
// The session about to be saved is excluded from eviction candidates so the
// proxy can't kill its own destination right before writing.
function diskFreeGB(p) {
  try {
    const s = statfsSync(p);
    return Number(s.bavail) * Number(s.bsize) / (1024 ** 3);
  } catch {
    return Infinity;  // can't measure → conservatively skip the free-disk gate
  }
}

function totalSlotsBytes(rootDir) {
  let total = 0;
  let entries;
  try { entries = readdirSync(rootDir, { withFileTypes: true }); } catch { return 0; }
  for (const sub of entries) {
    if (!sub.isDirectory()) continue;
    const subPath = join(rootDir, sub.name);
    let files;
    try { files = readdirSync(subPath); } catch { continue; }
    for (const f of files) {
      try { total += statSync(join(subPath, f)).size; } catch {}
    }
  }
  return total;
}

function findOldestBin(rootDir, excludeBasenames) {
  // excludeBasenames is a Set of file basenames that must NOT be evicted —
  // typically the slot we're saving now AND the slot we're about to load next.
  let oldest = null;
  let entries;
  try { entries = readdirSync(rootDir, { withFileTypes: true }); } catch { return null; }
  for (const sub of entries) {
    if (!sub.isDirectory()) continue;
    const subPath = join(rootDir, sub.name);
    let files;
    try { files = readdirSync(subPath); } catch { continue; }
    for (const f of files) {
      if (!f.endsWith(".bin")) continue;
      if (excludeBasenames.has(f)) continue;
      const full = join(subPath, f);
      let m;
      try { m = statSync(full).mtimeMs; } catch { continue; }
      if (!oldest || m < oldest.mtime) oldest = { path: full, mtime: m };
    }
  }
  return oldest;
}

function pruneSlotCacheIfNeeded(currentSlotFilename, incomingSlotFilename = null) {
  // Protect BOTH the slot we're about to save (current) and the slot we're
  // about to load next (incoming). Without the second exclusion, an LRU
  // candidate that happens to be the incoming session can get evicted right
  // before the proxy tries to restore it, causing the restore to fail with
  // "failed to open". incomingSlotFilename may be null (e.g., on plain
  // saveCurrentSlot without a follow-up restore).
  if (!slotCacheDir) return;
  const slotRoot = dirname(slotCacheDir.replace(/\/$/, ""));
  const excludeBasenames = new Set();
  if (currentSlotFilename) excludeBasenames.add(basename(currentSlotFilename));
  if (incomingSlotFilename) excludeBasenames.add(basename(incomingSlotFilename));
  let evicted = 0;
  const maxIters = 1000;  // safety: never loop forever
  for (let iter = 0; iter < maxIters; iter++) {
    const free = diskFreeGB(slotRoot);
    const totalGB = totalSlotsBytes(slotRoot) / (1024 ** 3);
    const lowFree = free < minFreeGB;
    const highTotal = totalGB > maxTotalSlotsGB;
    if (!lowFree && !highTotal) break;
    const victim = findOldestBin(slotRoot, excludeBasenames);
    if (!victim) {
      slotLog(`pruneSlotCache: out of candidates (free=${free.toFixed(1)} GB, total=${totalGB.toFixed(1)} GB; want free>=${minFreeGB}, total<=${maxTotalSlotsGB})\n`, C_YELLOW);
      break;
    }
    const ckpt = victim.path + ".ckpt";
    const meta = victim.path.replace(/\.bin$/, ".meta.json");
    let bytesFreed = 0;
    try { bytesFreed += statSync(victim.path).size; } catch {}
    try { bytesFreed += statSync(ckpt).size; } catch {}
    try { bytesFreed += statSync(meta).size; } catch {}
    try { unlinkSync(victim.path); } catch {}
    try { unlinkSync(ckpt); } catch {}
    try { unlinkSync(meta); } catch {}
    evicted++;
    const reason = lowFree ? `free<${minFreeGB} GB` : `total>${maxTotalSlotsGB} GB`;
    slotLog(`pruneSlotCache: evicted ${victim.path} (+ .ckpt) — ${(bytesFreed / (1024 ** 3)).toFixed(2)} GB freed (reason: ${reason})\n`, C_YELLOW);
  }
  if (evicted > 0) {
    const free = diskFreeGB(slotRoot);
    const totalGB = totalSlotsBytes(slotRoot) / (1024 ** 3);
    slotLog(`pruneSlotCache: ${evicted} file(s) evicted, free=${free.toFixed(1)} GB total=${totalGB.toFixed(1)} GB\n`, C_DIM);
  }
}

// Color a slot-action status line based on the parsed status code.
function colorForStatus(action, status) {
  if (action === "restore") {
    return status === 200 ? C_GREEN : C_YELLOW;   // HDD hit vs cold/miss
  }
  if (action === "save") {
    return status === 200 ? C_CYAN : C_RED;
  }
  return null;
}

function hddBanner(action, filename, detail = "") {
  const suffix = detail ? ` ${detail}` : "";
  slotLog(`\n=== HDD CACHE ${action}: ${filename}${suffix}\n`, C_MAGENTA);
}

function formatBytes(n) {
  if (!Number.isFinite(n)) return "unknown";
  if (n >= 1024 ** 2) return `${(n / (1024 ** 2)).toFixed(2)} MiB`;
  if (n >= 1024) return `${(n / 1024).toFixed(1)} KiB`;
  return `${n} B`;
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

function commonPrefixBytes(a, b) {
  const len = Math.min(a.length, b.length);
  let i = 0;
  while (i < len && a.charCodeAt(i) === b.charCodeAt(i)) i++;
  return i;
}

function readSlotMeta(slotId) {
  try {
    return JSON.parse(readFileSync(metaPathForSlotId(slotId), "utf8"));
  } catch {
    return null;
  }
}

function writeSlotMeta(info, extra = {}) {
  if (!slotCacheDir || !info?.sessionId) return;
  const now = Date.now();
  const previous = readSlotMeta(info.sessionId) ?? {};
  const meta = {
    ...previous,
    version: 1,
    slotId: info.sessionId,
    baseId: info.baseId,
    branchId: info.branchId,
    promptHash: info.promptHash,
    promptPrefixHash: info.promptPrefixHash,
    promptPrefixBytes: Buffer.byteLength(info.branchPrefix, "utf8"),
    bodyBytes: info.bodyBytes,
    updatedAt: now,
    ...extra,
  };
  if (extra.storePromptPrefix !== false) {
    // This is sensitive, but the slot cache already contains model state
    // derived from the same prompt. Keeping the prefix lets the proxy choose
    // the closest copy-on-write parent instead of "latest same-base".
    meta.promptPrefix = info.branchPrefix;
  }
  try {
    writeFileSync(metaPathForSlotId(info.sessionId), `${JSON.stringify(meta, null, 2)}\n`);
  } catch (e) {
    slotLog(`slot meta write failed: ${metaFilenameForSlotId(info.sessionId)} ${e.message}\n`, C_YELLOW);
  }
}

function cacheInfoFromBody(jsonStr) {
  try {
    const obj = JSON.parse(jsonStr);
    let anchor = "";
    if (obj.system) {
      anchor += typeof obj.system === "string" ? obj.system : JSON.stringify(obj.system);
    }
    if (Array.isArray(obj.messages) && obj.messages.length > 0) {
      const m0 = obj.messages[0];
      anchor += "\n" + (typeof m0.content === "string" ? m0.content : JSON.stringify(m0.content));
    }
    if (!anchor) return null;

    const branchPrefix = jsonStr.slice(0, BRANCH_PREFIX_BYTES);
    const promptHash = createHash("sha256").update(jsonStr).digest("hex");
    const baseId = createHash("sha256").update(anchor).digest("hex").slice(0, 12);
    const branchId = promptHash.slice(0, 12);
    return {
      sessionId: `${baseId}-${branchId}`,
      baseId,
      branchId,
      promptHash,
      promptPrefixHash: createHash("sha256").update(branchPrefix).digest("hex"),
      branchPrefix,
      bodyBytes: Buffer.byteLength(jsonStr, "utf8"),
    };
  } catch {
    return null;
  }
}

function findBestSameBaseParent(info) {
  if (!slotCacheDir) return null;
  const base = info?.baseId ?? sessionBase(info?.sessionId);
  if (!base) return null;
  const prefix = `${base}-`;
  const exact = `${info.sessionId}.bin`;
  let best = null;
  let latestLegacy = null;
  let files;
  try { files = readdirSync(slotCacheDir); } catch { return null; }
  for (const f of files) {
    if (!f.endsWith(".bin")) continue;
    if (!f.startsWith(prefix)) continue;
    if (f === exact) continue;
    const full = join(slotCacheDir, f);
    let mtime;
    let size;
    try {
      const st = statSync(full);
      mtime = st.mtimeMs;
      size = st.size;
    } catch { continue; }
    if (size <= 0) continue;
    const slotId = slotIdFromFilename(f);
    const meta = readSlotMeta(slotId);
    if (meta?.completed && !meta.volatile && typeof meta.promptPrefix === "string") {
      const lcp = commonPrefixBytes(meta.promptPrefix, info.branchPrefix);
      const denom = Math.max(1, Math.min(meta.promptPrefix.length, info.branchPrefix.length));
      const similarity = lcp / denom;
      const candidate = {
        filename: f,
        slotId,
        mtime,
        lcp,
        similarity,
        createdFrom: meta.createdFrom ?? null,
      };
      if (
        lcp >= 4096 &&
        (!best ||
          candidate.lcp > best.lcp ||
          (candidate.lcp === best.lcp && candidate.mtime > best.mtime))
      ) {
        best = candidate;
      }
    } else if (!latestLegacy || mtime > latestLegacy.mtime) {
      latestLegacy = { filename: f, slotId, mtime, lcp: 0, similarity: 0, legacy: true };
    }
  }
  return best ?? latestLegacy;
}

function selectRestoreTarget(info) {
  const exact = `${info.sessionId}.bin`;
  if (existsSync(slotPath(exact))) {
    return { filename: exact, slotId: info.sessionId, kind: "exact" };
  }
  const parent = findBestSameBaseParent(info);
  return parent ? { ...parent, kind: parent.legacy ? "legacy-parent" : "parent" } : null;
}

// Serialize slot save+restore through a Promise mutex. Concurrent callers
// queue and wait. Each acquires the lock, re-checks currentSession (a prior
// holder may have already loaded the session this caller wants), then runs
// save+restore as needed.
async function ensureSlotLoaded(info) {
  if (!slotCacheDir) return;
  const newSessionId = info.sessionId;
  const prev = slotMutex;
  let release;
  slotMutex = new Promise((r) => { release = r; });
  await prev;
  try {
    if (newSessionId === currentSession && slotHasContent) {
      currentRequestInfo = info;
      return;
    }
    ensureSlotCacheDir();
    const exactRestoreFilename = `${newSessionId}.bin`;
    const preSaveRestore = selectRestoreTarget(info);
    const protectIncomingFilename = preSaveRestore?.filename ?? exactRestoreFilename;
    if (currentSession) {
      if (!slotHasContent) {
        // Skip: slot is known-empty (previous restore failed, no /v1/messages
        // has populated it since). Saving here would overwrite the on-disk
        // file with a zero-token payload, locking in the corruption.
        slotLog(`\n=== HDD CACHE save SKIPPED: ${currentSession}.bin (slot empty; not overwriting cache)\n`, C_YELLOW);
      } else if (!slotDirtySinceSave) {
        slotLog(`\n=== HDD CACHE save SKIPPED: ${currentSession}.bin (already persisted)\n`, C_DIM);
      } else {
        ensureSlotCacheDir();
        // Pass both: don't evict the slot we're saving (currentSession) OR
        // the one we're about to restore next. Otherwise the
        // LRU prune can wipe our restore target before we read it.
        pruneSlotCacheIfNeeded(`${currentSession}.bin`, protectIncomingFilename);
        hddBanner("save", `${currentSession}.bin`, "(writes .bin + .bin.ckpt)");
        const r = await callSlotAction("save", `${currentSession}.bin`);
        const save = slotSaveSucceeded(r);
        slotLog(
          `HDD CACHE save status=${r.status} n_saved=${save.nSaved} n_written=${save.nWritten} checkpoint_sidecar=${currentSession}.bin.ckpt\n`,
          save.ok ? C_CYAN : C_RED,
        );
        if (save.ok) slotDirtySinceSave = false;
      }
    }

    // If the incoming request is a new branch of the same base conversation,
    // the live slot is already the best prefix. Saving above persisted the
    // old branch; restoring an older disk fallback here would throw away the
    // freshest in-RAM checkpoints and cause avoidable replay.
    if (!existsSync(slotPath(exactRestoreFilename)) && sameSessionBase(currentSession, newSessionId) && slotHasContent) {
      slotLog(
        `\n=== HDD CACHE restore SKIPPED: ${newSessionId}.bin (copy-on-write from live same-base slot ${currentSession}.bin)\n`,
        C_CYAN,
      );
      currentLoadedFrom = currentSession;
      currentSession = newSessionId;
      currentRequestInfo = info;
      slotDirtySinceSave = false;
      writeSlotMeta(info, {
        completed: false,
        volatile: true,
        createdFrom: currentLoadedFrom,
        restoreKind: "live-parent",
      });
      return;
    }

    const restoreTarget = selectRestoreTarget(info);
    if (!restoreTarget) {
      slotLog(`\n=== HDD CACHE restore MISS: ${newSessionId}.bin (no exact or similar same-base parent)\n`, C_YELLOW);
      slotHasContent = false;
      slotDirtySinceSave = false;
      currentSession = newSessionId;
      currentRequestInfo = info;
      currentLoadedFrom = null;
      writeSlotMeta(info, {
        completed: false,
        volatile: true,
        createdFrom: null,
        restoreKind: "miss",
      });
      return;
    }
    if (restoreTarget.kind !== "exact") {
      const detail = restoreTarget.kind === "parent"
        ? `lcp=${restoreTarget.lcp} similarity=${restoreTarget.similarity.toFixed(3)}`
        : "legacy metadata missing";
      slotLog(
        `\n=== HDD CACHE restore PARENT: ${newSessionId}.bin <- ${restoreTarget.filename} (${detail}; copy-on-write target remains ${newSessionId}.bin)\n`,
        C_YELLOW,
      );
    }
    hddBanner(restoreTarget.kind === "exact" ? "restore" : "restore parent", restoreTarget.filename, "(reads .bin + .bin.ckpt)");
    const r = await callSlotAction("restore", restoreTarget.filename);
    const restore = slotRestoreSucceeded(r);
    slotLog(
      `HDD CACHE restore status=${r.status} n_restored=${restore.nRestored} n_read=${restore.nRead} checkpoint_sidecar=${restoreTarget.filename}.ckpt ${r.body.slice(0, 200)}\n`,
      restore.ok ? C_GREEN : colorForStatus("restore", r.status),
    );
    // Restore returning 4xx/5xx (e.g., file not found) is normal for new sessions.
    // A 200 with n_restored=0 means the file exists but has 0 stored tokens
    // (previously corrupted) — server-side this clears slot->prompt.tokens.
    // Either way, the slot is now empty; gate future saves until a request
    // refills it.
    slotHasContent = restore.ok;
    slotDirtySinceSave = false;
    currentSession = newSessionId;
    currentRequestInfo = info;
    const existingMeta = restoreTarget.kind === "exact" ? readSlotMeta(info.sessionId) : null;
    currentLoadedFrom = restoreTarget.kind === "exact" ? (existingMeta?.createdFrom ?? null) : restoreTarget.slotId;
    writeSlotMeta(info, {
      completed: false,
      volatile: true,
      createdFrom: currentLoadedFrom,
      restoreKind: restoreTarget.kind,
      restoreOk: restore.ok,
      restoredFrom: restoreTarget.slotId,
      restoredFilename: restoreTarget.filename,
      restoreLcp: restoreTarget.lcp ?? null,
      restoreSimilarity: restoreTarget.similarity ?? null,
    });
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
    if (!slotHasContent) {
      slotLog(`\n=== HDD CACHE save (${reason}) SKIPPED: ${currentSession}.bin (slot empty; not overwriting cache)\n`, C_YELLOW);
      return;
    }
    if (!slotDirtySinceSave) {
      slotLog(`\n=== HDD CACHE save (${reason}) SKIPPED: ${currentSession}.bin (already persisted)\n`, C_DIM);
      return;
    }
    ensureSlotCacheDir();
    pruneSlotCacheIfNeeded(`${currentSession}.bin`);
    hddBanner(`save (${reason})`, `${currentSession}.bin`, "(writes .bin + .bin.ckpt)");
    const r = await callSlotAction("save", `${currentSession}.bin`, timeoutMs);
    const save = slotSaveSucceeded(r);
    slotLog(
      `HDD CACHE save status=${r.status} n_saved=${save.nSaved} n_written=${save.nWritten} checkpoint_sidecar=${currentSession}.bin.ckpt\n`,
      save.ok ? C_CYAN : C_RED,
    );
    if (currentRequestInfo) {
      writeSlotMeta(currentRequestInfo, {
        completed: save.ok,
        volatile: !save.ok,
        createdFrom: currentLoadedFrom,
        saveReason: reason,
        nSaved: save.nSaved,
        nWritten: save.nWritten,
      });
    }
    if (save.ok) slotDirtySinceSave = false;
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
  let backpressureTimer = null;
  const clearBackpressureTimer = () => {
    if (backpressureTimer) {
      clearTimeout(backpressureTimer);
      backpressureTimer = null;
    }
  };
  const finalize = (result = {}) => {
    if (!done) {
      done = true;
      clearBackpressureTimer();
      onDone(result);
    }
  };

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
    if (!ok) {
      proxyRes.pause();
      clearBackpressureTimer();
      backpressureTimer = setTimeout(() => {
        if (done) return;
        log.write(`\n!!! downstream backpressure timeout ${tag}: client did not drain; closing stalled stream\n`);
        try { proxyRes.destroy(); } catch {}
        try { clientRes.destroy(); } catch {}
        finalize({ ended: false, reason: "downstream-backpressure-timeout", statusCode: proxyRes.statusCode });
      }, 30000);
    }
  });
  clientRes.on("drain", () => {
    clearBackpressureTimer();
    try { proxyRes.resume(); } catch {}
  });
  clientRes.on("close", () => {
    // Client gave up — stop pulling from backend
    if (!done) {
      log.write(`\n--- client closed early ${tag}\n`);
      try { proxyRes.destroy(); } catch {}
      finalize({ ended: false, reason: "client-close", statusCode: proxyRes.statusCode });
    }
  });
  clientRes.on("error", (e) => {
    log.write(`\n!!! clientRes error ${tag}: ${e.message}\n`);
    teardown();
  });

  proxyRes.on("end", () => {
    log.write("\n");
    try { clientRes.end(); } catch {}
    finalize({ ended: true, reason: "backend-end", statusCode: proxyRes.statusCode });
  });
  proxyRes.on("close", () => {
    if (!done) {
      log.write(`\n--- backend response closed ${tag}\n`);
      try { clientRes.end(); } catch {}
      finalize({ ended: false, reason: "backend-close", statusCode: proxyRes.statusCode });
    }
  });
  proxyRes.on("error", (e) => {
    log.write(`\n!!! proxyRes error ${tag}: ${e.message}\n`);
    try { clientRes.end(); } catch {}
    finalize({ ended: false, reason: "backend-error", statusCode: proxyRes.statusCode });
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

async function processBufferedMessage(tag, clientReq, clientRes, bodyBuf, sessionInfo, finalize) {
  const sessionId = sessionInfo?.sessionId ?? null;
  try {
    if (sessionInfo && slotCacheDir) await ensureSlotLoaded(sessionInfo);
  } catch (e) {
    log.write(`\n!!! SLOT mgmt error ${tag}: ${e.message}\n`);
    if (sessionId && slotCacheDir) {
      currentSession = sessionId;
      slotHasContent = false;
    }
  }

  // From this point until a complete 200 response, the slot is volatile:
  // prompt processing or generation may mutate KV/checkpoints, and aborts can
  // leave a partial state. Fail closed so the next switch does not persist an
  // uncertain slot under a branch id.
  if (sessionId && slotCacheDir) {
    currentSession = sessionId;
    slotHasContent = false;
    slotDirtySinceSave = true;
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

  await new Promise((resolve) => {
    const proxyReq = httpRequest({
      hostname: "127.0.0.1",
      port: backendPort,
      path: clientReq.url,
      method: clientReq.method,
      headers: fwdHeaders,
    }, (proxyRes) => {
      pipeResponse(tag, proxyRes, clientRes, async (result) => {
        // Only a complete 200 response means the loaded slot now contains
        // a successful session state that is safe to save on the next switch.
        // Setting this at response headers is too early: another session can
        // arrive while prompt processing/generation is still mutating the slot.
        if (result.ended && result.statusCode === 200) {
          slotHasContent = true;
          slotDirtySinceSave = true;
          if (sessionId && slotCacheDir) {
            try {
              await saveCurrentSlot("response-complete");
            } catch (e) {
              slotLog(`\n!!! HDD CACHE save response-complete error: ${e.message}\n`, C_RED);
            }
          }
        } else if (sessionId && slotCacheDir) {
          slotHasContent = false;
          slotDirtySinceSave = false;
          if (currentRequestInfo) {
            writeSlotMeta(currentRequestInfo, {
              completed: false,
              volatile: true,
              createdFrom: currentLoadedFrom,
              failureReason: result.reason ?? "incomplete-response",
              responseStatus: result.statusCode ?? null,
            });
          }
        }
        finalize();
        resolve();
      });
    });

    proxyReq.on("error", (e) => {
      log.write(`\n!!! proxyReq error ${tag}: ${e.message}\n`);
      if (!clientRes.headersSent) {
        try { clientRes.writeHead(502, { "Content-Type": "text/plain" }); } catch {}
      }
      try { clientRes.end(`Proxy error: ${e.message}`); } catch {}
      finalize();
      resolve();
    });

    proxyReq.end(bodyBuf);
  });
}

// ── Server ────────────────────────────────────────────────────────────────
const server = createServer(async (clientReq, clientRes) => {
  const tag = `${clientReq.method} ${clientReq.url}`;
  log.write(`${SEP}>>> ${tag}\n`);

  const isMessages = clientReq.method === "POST" && clientReq.url.startsWith("/v1/messages");

  // ── Buffered path: /v1/messages ─────────────────────────────────────────
  // Always buffer messages so request size/session summaries are visible.
  // Slot save/restore still only runs when --slot-cache-dir is enabled.
  if (isMessages) {
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
      log.write("\n");

      const sessionInfo = cacheInfoFromBody(bodyBuf.toString("utf8"));
      const sessionId = sessionInfo?.sessionId ?? null;
      requestLog(
        `REQUEST ${tag} body_bytes=${bodyBuf.length} (${formatBytes(bodyBuf.length)}) content_length=${clientReq.headers["content-length"] ?? "chunked"} session=${sessionId ?? "none"}\n`,
      );
      const run = () => processBufferedMessage(tag, clientReq, clientRes, bodyBuf, sessionInfo, finalize);
      if (slotCacheDir) {
        await enqueueMessage(run);
      } else {
        await run();
      }
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
  if (llamaLog) llamaLog.end();
  process.exit(0);
}
process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT", () => gracefulShutdown("SIGINT"));
