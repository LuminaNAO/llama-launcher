#!/usr/bin/env node

// Transparent HTTP proxy that tee-s raw request/response bodies to a log file.
// Optionally manages llama-server slot save/restore for cross-restart and
// cross-session KV persistence (single-slot only — assumes parallel=1).
//
// Usage:
//   node llama-deep-proxy.mjs <listen-port> <backend-port> [log-file]
//      [--slot-cache-dir <dir>] [--api-key <key>]
//      [--min-free-gb N] [--max-total-slots-gb N]
//      [--server-parallel N]
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
//   - With --slot-cache-dir, /v1/messages are serialized end-to-end because
//     slot save/restore is single-slot and operates on llama-server slot 0.
//   - Backpressure honored on both directions (important for slow downstream
//     clients like SSH-tunneled openclaw).
//   - Client/upstream socket lifecycle handled defensively: aborts and
//     errors are caught, in-flight counter never leaks, EPIPE on a closed
//     client doesn't crash the proxy.

import { createServer, request as httpRequest } from "node:http";
import { createWriteStream, mkdirSync, existsSync, statSync, statfsSync, unlinkSync, readdirSync, readFileSync, writeFileSync, realpathSync } from "node:fs";
import { dirname, basename, join } from "node:path";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

// The file doubles as a module: utilities (tests, diagnostics) import the
// request-identity helpers below without starting the server. Everything
// configured by CLI flags lives in module state that main() fills in.

// ── Config (set by main() when run as a CLI) ──────────────────────────────
let backendPort = 0;
let slotCacheDir = null;
let apiKey = null;
let minFreeGB = 100;
let maxTotalSlotsGB = 200;
let log = null;        // deep log write stream
let llamaLog = null;   // optional mirror for slot/server lines
const SEP = "\n========================================\n";

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
  // Only hash-derived "<base12>-<branch12>" ids have a base. OpenClaw slot
  // ids are exact-only and deliberately fall out of same-base matching.
  if (typeof sessionId !== "string") return null;
  const m = /^([0-9a-f]{12})-[0-9a-f]{12}$/i.exec(sessionId);
  return m ? m[1] : null;
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

function deleteSlotFiles(slotId) {
  const bin = slotPath(`${slotId}.bin`);
  const ckpt = `${bin}.ckpt`;
  const meta = metaPathForSlotId(slotId);
  try { unlinkSync(bin); } catch {}
  try { unlinkSync(ckpt); } catch {}
  try { unlinkSync(meta); } catch {}
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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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

async function callSlotSaveWithRetry(filename, reason, timeoutMs = 0) {
  const delays = reason === "shutdown" ? [0] : [0, 250, 1000, 2500];
  let last = null;
  for (let i = 0; i < delays.length; i++) {
    if (delays[i] > 0) await sleep(delays[i]);
    const r = await callSlotAction("save", filename, timeoutMs);
    const save = slotSaveSucceeded(r);
    last = { r, save };
    if (save.ok || i === delays.length - 1) return last;
    slotLog(
      `HDD CACHE save retry pending (${reason}) ${filename}: status=${r.status} n_saved=${save.nSaved} n_written=${save.nWritten}\n`,
      C_YELLOW,
    );
  }
  return last;
}

export function commonPrefixBytes(a, b) {
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
    identitySource: info.identitySource,
    identityLabel: info.identityLabel,
    agentKind: info.agentKind,
    openClaw: info.openClaw,
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

// ── Request identity ──────────────────────────────────────────────────────
// Slot routing prefers explicit client identity over prompt-content hashing.
// OpenClaw labels every backend request with x-openclaw-* headers; the
// session id maps 1:1 to a slot file regardless of how the prompt mutates
// (compaction, tool churn, system prompt updates). Body identity keys and
// the system+first-message anchor hash remain as fallbacks for clients that
// don't send headers.
export const OPENCLAW_HEADERS = {
  sessionId: "x-openclaw-session-id",
  agentKind: "x-openclaw-agent-kind",
  cachePolicy: "x-openclaw-cache-policy",
  sessionKey: "x-openclaw-session-key",
  agentId: "x-openclaw-agent-id",
  runId: "x-openclaw-run-id",
  trigger: "x-openclaw-trigger",
};

export function stableHashId(prefix, value, bytes = 12) {
  return createHash("sha256").update(`${prefix}:${value}`).digest("hex").slice(0, bytes);
}

// Map an OpenClaw session id (e.g. "signal:group:b64+chars=",
// "tui-<uuid>", "agent:main:foo") onto a filesystem-safe slot id that stays
// human-readable. All segments are kept — leaf-only naming collides across
// channels. Falls back to a hashed name when sanitizing eats everything,
// and caps length with a hash suffix so distinct long ids stay distinct.
export function safeSlotIdFromOpenClawSessionId(value) {
  if (typeof value !== "string") return null;
  const raw = value.trim();
  if (!raw) return null;
  const hash = createHash("sha256").update(raw).digest("hex").slice(0, 12);
  const safe = raw
    .split(":")
    .filter(Boolean)
    .map((segment) => segment
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=/g, "")
      .replace(/[^A-Za-z0-9._-]+/g, "-")
      .replace(/-+/g, "-")
      .replace(/^[.-]+/, "")
      .replace(/[.-]+$/, ""))
    .filter(Boolean)
    .join("-")
    .replace(/^\.+/, "")
    .replace(/\.+$/, "")
    .replace(/-+/g, "-");
  if (!safe || safe === "." || safe === "..") return `openclaw-${hash}`;
  if (safe.length <= 180) return safe;
  return `${safe.slice(0, 167).replace(/[.-]+$/, "")}-${hash}`;
}

function scalarIdentityValue(value) {
  if (typeof value === "string") {
    const v = value.trim();
    if (v.length >= 6 && v.length <= 256) return v;
  }
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

export function headerValue(headers, key) {
  const value = headers?.[key.toLowerCase()];
  const raw = Array.isArray(value) ? value[0] : value;
  if (typeof raw !== "string") return null;
  const v = raw.trim();
  if (v.length >= 1 && v.length <= 512) return v;
  return null;
}

export function findOpenClawHeaderIdentity(headers) {
  const sessionId = headerValue(headers, OPENCLAW_HEADERS.sessionId);
  // Metadata headers can be short ("main"), but a session id under 4 chars
  // is more plausibly a stray value than a real conversation id — don't let
  // it become a slot filename.
  if (!sessionId || sessionId.length < 4) return null;
  const agentKind = (headerValue(headers, OPENCLAW_HEADERS.agentKind) ?? "").toLowerCase();
  return {
    source: "openclaw-session-id",
    value: sessionId,
    agentKind: agentKind === "subagent" ? "subagent" : agentKind === "main" ? "main" : null,
    sessionKey: headerValue(headers, OPENCLAW_HEADERS.sessionKey),
    agentId: headerValue(headers, OPENCLAW_HEADERS.agentId),
    runId: headerValue(headers, OPENCLAW_HEADERS.runId),
    trigger: headerValue(headers, OPENCLAW_HEADERS.trigger),
  };
}

export function findStableIdentity(obj, headers = {}) {
  const openClawHeaderIdentity = findOpenClawHeaderIdentity(headers);
  if (openClawHeaderIdentity) return openClawHeaderIdentity;

  const preferred = [
    "session_id", "sessionId",
    "conversation_id", "conversationId",
    "thread_id", "threadId",
    "chat_id", "chatId",
    "transcript_id", "transcriptId",
  ];
  const containers = [
    obj?.metadata,
    obj?.meta,
    obj?.extra,
    obj?.session,
    obj?.conversation,
    obj,
  ].filter((v) => v && typeof v === "object" && !Array.isArray(v));

  for (const container of containers) {
    for (const key of preferred) {
      const value = scalarIdentityValue(container[key]);
      if (value) return { source: key, value };
    }
  }
  return null;
}

// Build the prefix used for copy-on-write parent comparison from the parts
// of the prompt that actually reach the KV cache (system, tools, messages),
// serialized in a fixed order. Comparing raw request JSON instead lets
// field ordering or unrelated sampling params fake an early divergence.
export function cacheComparisonPrefix(obj, fallbackJsonStr) {
  const parts = [];
  if (obj?.system) {
    parts.push(typeof obj.system === "string" ? obj.system : JSON.stringify(obj.system));
  }
  if (obj?.tools) {
    parts.push(JSON.stringify(obj.tools));
  }
  if (Array.isArray(obj?.messages)) {
    parts.push(JSON.stringify(obj.messages));
  }
  const canonical = parts.join("\n");
  return canonical ? canonical.slice(0, BRANCH_PREFIX_BYTES) : fallbackJsonStr.slice(0, BRANCH_PREFIX_BYTES);
}

export function cacheInfoFromBody(jsonStr, headers = {}) {
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

    const branchPrefix = cacheComparisonPrefix(obj, jsonStr);
    const promptHash = createHash("sha256").update(jsonStr).digest("hex");
    const stableIdentity = findStableIdentity(obj, headers);
    // Header-identified OpenClaw sessions get one slot file named after the
    // session id, restored by exact match only: the id is already unique per
    // conversation, so prefix-similarity parent matching can only misroute.
    const openClawSlotId = stableIdentity?.source === "openclaw-session-id"
      ? safeSlotIdFromOpenClawSessionId(stableIdentity.value)
      : null;
    const baseId = openClawSlotId ?? (stableIdentity
      ? stableHashId(stableIdentity.source, stableIdentity.value)
      : stableHashId("anchor", anchor));
    const branchId = openClawSlotId ? "openclaw" : promptHash.slice(0, 12);
    const sessionId = openClawSlotId ?? `${baseId}-${branchId}`;
    return {
      sessionId,
      baseId,
      branchId,
      exactOnly: Boolean(openClawSlotId),
      identitySource: stableIdentity ? stableIdentity.source : "anchor",
      identityLabel: stableIdentity ? stableIdentity.source : "system+first-message",
      agentKind: stableIdentity?.agentKind ?? null,
      openClaw: stableIdentity?.source === "openclaw-session-id"
        ? {
            sessionId: stableIdentity.value ?? null,
            slotId: openClawSlotId,
            sessionKey: stableIdentity.sessionKey ?? null,
            agentId: stableIdentity.agentId ?? null,
            runId: stableIdentity.runId ?? null,
            trigger: stableIdentity.trigger ?? null,
          }
        : null,
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
    }
  }
  return best;
}

function selectRestoreTarget(info) {
  const exact = `${info.sessionId}.bin`;
  if (existsSync(slotPath(exact))) {
    return { filename: exact, slotId: info.sessionId, kind: "exact" };
  }
  if (info?.exactOnly) {
    return null;
  }
  const parent = findBestSameBaseParent(info);
  if (parent) return { ...parent, kind: parent.legacy ? "legacy-parent" : "parent" };
  return null;
}

function scoreLiveParent(info) {
  if (info?.exactOnly) return null;
  if (!currentSession || !slotHasContent || !sameSessionBase(currentSession, info?.sessionId)) return null;
  const parentInfo = currentRequestInfo;
  if (!parentInfo || typeof parentInfo.branchPrefix !== "string" || typeof info?.branchPrefix !== "string") {
    return { slotId: currentSession, lcp: 0, similarity: 0, missingMeta: true };
  }
  const lcp = commonPrefixBytes(parentInfo.branchPrefix, info.branchPrefix);
  const denom = Math.max(1, Math.min(parentInfo.branchPrefix.length, info.branchPrefix.length));
  return {
    slotId: currentSession,
    lcp,
    similarity: lcp / denom,
    missingMeta: false,
  };
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
        const { r, save } = await callSlotSaveWithRetry(`${currentSession}.bin`, "switch");
        slotLog(
          `HDD CACHE save status=${r.status} n_saved=${save.nSaved} n_written=${save.nWritten} checkpoint_sidecar=${currentSession}.bin.ckpt\n`,
          save.ok ? C_CYAN : C_RED,
        );
        if (!save.ok) {
          if (currentRequestInfo) {
            writeSlotMeta(currentRequestInfo, {
              completed: false,
              volatile: true,
              createdFrom: currentLoadedFrom,
              saveReason: "switch",
              nSaved: save.nSaved,
              nWritten: save.nWritten,
              failureReason: "switch-save-failed",
            });
          }
          throw new Error(`refusing slot switch after failed save of ${currentSession}.bin`);
        }
        if (currentRequestInfo) {
          writeSlotMeta(currentRequestInfo, {
            completed: true,
            volatile: false,
            createdFrom: currentLoadedFrom,
            saveReason: "switch",
            nSaved: save.nSaved,
            nWritten: save.nWritten,
          });
        }
        slotDirtySinceSave = false;
      }
    }

    // If the incoming request is a new branch of the same base conversation,
    // the live slot is often the cheapest parent. It is not always the best
    // parent: OpenClaw can emit a later same-base request whose prompt diverges
    // before the current live checkpoints. Compare the live prefix against
    // persisted same-base parents and restore a better disk parent when one
    // exists.
    const liveParent = scoreLiveParent(info);
    if (!existsSync(slotPath(exactRestoreFilename)) && liveParent) {
      const diskParent = selectRestoreTarget(info);
      const diskIsBetter =
        diskParent &&
        diskParent.kind === "parent" &&
        diskParent.slotId !== liveParent.slotId &&
        diskParent.lcp > liveParent.lcp;

      if (!diskIsBetter) {
        const detail = liveParent.missingMeta
          ? "live parent metadata unavailable"
          : `lcp=${liveParent.lcp} similarity=${liveParent.similarity.toFixed(3)}`;
        slotLog(
          `\n=== HDD CACHE restore SKIPPED: ${newSessionId}.bin (copy-on-write from live same-base slot ${currentSession}.bin; ${detail})\n`,
          liveParent.similarity >= 0.5 ? C_CYAN : C_YELLOW,
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
          restoreLcp: liveParent.lcp,
          restoreSimilarity: liveParent.similarity,
        });
        return;
      }

      slotLog(
        `\n=== HDD CACHE live parent bypassed: ${newSessionId}.bin live ${liveParent.slotId}.bin lcp=${liveParent.lcp} similarity=${liveParent.similarity.toFixed(3)}; disk ${diskParent.filename} lcp=${diskParent.lcp} similarity=${diskParent.similarity.toFixed(3)}\n`,
        C_YELLOW,
      );
    }

    const restoreTarget = selectRestoreTarget(info);
    if (!restoreTarget) {
      const missReason = info.exactOnly
        ? "no exact OpenClaw session cache"
        : "no exact or similar same-base parent";
      slotLog(`\n=== HDD CACHE restore MISS: ${newSessionId}.bin (${missReason})\n`, C_YELLOW);
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
    const { r, save } = await callSlotSaveWithRetry(`${currentSession}.bin`, reason, timeoutMs);
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
    if (save.ok) {
      slotDirtySinceSave = false;
    }
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
    slotLog(`\n!!! HDD CACHE request blocked: ${e.message}\n`, C_RED);
    if (sessionId && slotCacheDir) {
      if (currentRequestInfo) {
        writeSlotMeta(currentRequestInfo, {
          completed: false,
          volatile: true,
          failureReason: "slot-management-error",
        });
      }
    }
    if (!clientRes.headersSent) {
      try { clientRes.writeHead(503, { "Content-Type": "text/plain" }); } catch {}
    }
    try { clientRes.end(`HDD cache slot management failed: ${e.message}\n`); } catch {}
    finalize();
    return;
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
async function handleRequest(clientReq, clientRes) {
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

      const sessionInfo = cacheInfoFromBody(bodyBuf.toString("utf8"), clientReq.headers);
      const sessionId = sessionInfo?.sessionId ?? null;
      requestLog(
        `REQUEST ${tag} body_bytes=${bodyBuf.length} (${formatBytes(bodyBuf.length)}) content_length=${clientReq.headers["content-length"] ?? "chunked"} session=${sessionId ?? "none"} identity=${sessionInfo?.identitySource ?? "none"} agent=${sessionInfo?.agentKind ?? "unknown"}\n`,
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
}

// ── CLI entrypoint ────────────────────────────────────────────────────────
// Importers (tests, diagnostics) get the exported helpers only; the server
// starts solely when the file itself is executed.
function runsAsMain() {
  if (!process.argv[1]) return false;
  try {
    return import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href;
  } catch {
    return false;
  }
}

function main() {
  const args = process.argv.slice(2);
  const listenPort = parseInt(args[0], 10);
  backendPort = parseInt(args[1], 10);
  const logFile = args[2] && !args[2].startsWith("--") ? args[2] : "llama-deep.log";

  let serverParallel = 1;
  let llamaLogFile = null;
  let stdoutIsLlamaLog = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--slot-cache-dir") slotCacheDir = args[i + 1];
    if (args[i] === "--api-key") apiKey = args[i + 1];
    if (args[i] === "--min-free-gb") minFreeGB = Number(args[i + 1]);
    if (args[i] === "--max-total-slots-gb") maxTotalSlotsGB = Number(args[i + 1]);
    if (args[i] === "--server-parallel") serverParallel = Number(args[i + 1]);
    if (args[i] === "--llama-log-file") llamaLogFile = args[i + 1];
    if (args[i] === "--stdout-is-llama-log") stdoutIsLlamaLog = true;
  }

  if (!listenPort || !backendPort) {
    console.error("Usage: llama-deep-proxy.mjs <listen-port> <backend-port> [log-file] [--slot-cache-dir <dir>] [--api-key <key>] [--min-free-gb N] [--max-total-slots-gb N] [--llama-log-file <path>] [--stdout-is-llama-log]");
    process.exit(1);
  }

  if (slotCacheDir) {
    if (serverParallel !== 1) {
      console.error(`ERROR: --slot-cache-dir is single-slot only, but server parallel=${serverParallel}.`);
      console.error("Disable HDD cache or launch with --parallel 1 to avoid wiping checkpoints on slot 0.");
      process.exit(1);
    }
    if (!existsSync(slotCacheDir)) mkdirSync(slotCacheDir, { recursive: true });
    if (!slotCacheDir.endsWith("/")) slotCacheDir += "/";
  }

  log = createWriteStream(logFile, { flags: "a" });
  llamaLog = llamaLogFile && !stdoutIsLlamaLog
    ? createWriteStream(llamaLogFile, { flags: "a" })
    : null;

  const server = createServer(handleRequest);
  server.listen(listenPort, "0.0.0.0", () => {
    console.log(`llama-deep-proxy: 0.0.0.0:${listenPort} -> 127.0.0.1:${backendPort}`);
    console.log(`llama-deep-proxy: logging to ${logFile}`);
    if (slotCacheDir) console.log(`llama-deep-proxy: slot cache dir = ${slotCacheDir}`);
    if (apiKey) console.log(`llama-deep-proxy: api-key set (used for slot management calls)`);
  });

  // ── Graceful shutdown: save current slot before exiting ─────────────────
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
}

if (runsAsMain()) main();
