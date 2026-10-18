// Vendored verbatim from tokentail lib/emit.mjs at commit d797a67a0727fe6e82c9c3840e08d7f8ea21f1b7
// (WATERFALL.md "Usage telemetry for tokentail" item 1). Do not edit below this
// header: re-copy the upstream file and update the commit instead.

// tokentail producer SDK — the tiny surface producers (cloudburst, waterfall)
// import to emit usage events. Design contract (ARCH.md "Zero disruption"):
// fire-and-forget, non-blocking, fail-silent. Telemetry loss is always
// preferable to adding latency or failure to a serving path, so nothing here
// ever throws to the caller or performs blocking I/O while the producer is
// serving: record() only buffers, and the flush path is fully async behind a
// serialized queue. The one synchronous write is the best-effort process-exit
// hook, where the event loop is already gone.
//
// Storage: append-only JSONL spool at
//   $XDG_DATA_HOME/tokentail/spool/<source>.jsonl   (default ~/.local/share)
// rotated by size to <source>.jsonl.1 (single generation — old .1 is
// replaced). The spool reader (lib/ingest/spool.mjs) reads both.
import { appendFileSync } from "node:fs";
import { appendFile, mkdir, rename, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_MAX_BYTES = 32 * 1024 * 1024; // 32 MiB per spool generation

/** Resolve the spool directory (no I/O). */
export function spoolDir() {
  const base = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  return join(base, "tokentail", "spool");
}

/** Resolve the spool file path for a source (no I/O). */
export function spoolPath(source) {
  return join(spoolDir(), `${sanitizeSource(source)}.jsonl`);
}

function sanitizeSource(source) {
  return String(source).replace(/[^a-zA-Z0-9._-]/g, "_") || "unknown";
}

/**
 * Create an emitter for one producer.
 *
 * @param {object} opts
 * @param {string} opts.source        Producer name, e.g. "cloudburst", "waterfall".
 * @param {string} [opts.dir]         Override spool directory (tests).
 * @param {number} [opts.maxBytes]    Rotate the spool when it exceeds this size.
 * @param {number} [opts.flushMs]     Buffer window before writing (default 250ms).
 * @returns {{record(event: object): void, flush(): Promise<void>, close(): Promise<void>}}
 *   record() is synchronous, never throws, never touches disk; it buffers the
 *   line and arms an unref'd timer. flush() forces buffered lines to disk
 *   (async, never rejects). close() flushes and stops accepting events.
 */
export function createEmitter({ source, dir = spoolDir(), maxBytes = DEFAULT_MAX_BYTES, flushMs = 250 } = {}) {
  const name = sanitizeSource(source);
  const file = join(dir, `${name}.jsonl`);
  let buf = [];
  let timer = null;
  let dirOk = false;
  let closed = false;
  let chain = Promise.resolve(); // serializes all disk work; nothing overlaps

  const doFlush = async () => {
    if (!buf.length) return;
    const lines = buf.join("");
    buf = [];
    if (!dirOk) {
      try { await mkdir(dir, { recursive: true }); dirOk = true; }
      catch { return; } // drop silently — never disturb the producer
    }
    try {
      const st = await stat(file).catch(() => null);
      if (st && st.size > maxBytes) await rename(file, `${file}.1`);
      await appendFile(file, lines);
    } catch { /* fail-silent: drop this batch */ }
  };

  const flush = () => {
    if (timer) { clearTimeout(timer); timer = null; }
    chain = chain.then(doFlush, () => {});
    return chain;
  };

  const record = (event) => {
    if (closed) return;
    try {
      const line = JSON.stringify({ ts: new Date().toISOString(), ...event, source: name });
      buf.push(line + "\n");
      if (!timer) {
        timer = setTimeout(flush, flushMs);
        timer.unref?.(); // never keep the producer process alive
      }
    } catch { /* unserializable event — drop */ }
  };

  // Best-effort salvage of a still-buffered tail if the producer exits
  // without close(). The event loop is gone here, so sync is the only
  // option left and cannot add serving latency. close() removes the
  // listener so long-lived processes can churn emitters without leaking.
  const onExit = () => {
    if (!buf.length || !dirOk) return;
    try { appendFileSync(file, buf.join("")); } catch { /* fail-silent */ }
  };
  process.once("exit", onExit);

  const close = () => {
    closed = true;
    process.removeListener("exit", onExit);
    return flush();
  };

  return { record, flush, close };
}
