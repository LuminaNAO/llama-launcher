#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { OPENCLAW_MARKERS } from "../llama-deep-proxy.mjs";

const DEFAULT_LOG = "llama-deep.log";

function usage() {
  console.log(`Usage:
  utils/diagnose-cache-divergence.mjs [log-file] [--session ID|--latest] [--last N]
  utils/diagnose-cache-divergence.mjs [log-file] --session ID --compare A:B

Examples:
  utils/diagnose-cache-divergence.mjs --session tui-...
  utils/diagnose-cache-divergence.mjs --latest --last 4
  utils/diagnose-cache-divergence.mjs llama-deep.log --session tui-... --last 4
  utils/diagnose-cache-divergence.mjs --session tui-... --compare 41:72
`);
}

function parseArgs(argv) {
  const args = {
    logFile: DEFAULT_LOG,
    session: null,
    latest: false,
    last: 2,
    compare: null,
  };

  const rest = [...argv];
  if (rest[0] && !rest[0].startsWith("-")) {
    args.logFile = rest.shift();
  }

  while (rest.length > 0) {
    const arg = rest.shift();
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--session") {
      args.session = rest.shift() ?? null;
      continue;
    }
    if (arg === "--latest") {
      args.latest = true;
      continue;
    }
    if (arg === "--last") {
      args.last = Number.parseInt(rest.shift() ?? "", 10);
      continue;
    }
    if (arg === "--compare") {
      args.compare = rest.shift() ?? null;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }

  if (!Number.isInteger(args.last) || args.last < 2) {
    throw new Error("--last must be an integer >= 2");
  }

  return args;
}

function sha12(text) {
  return createHash("sha256").update(text).digest("hex").slice(0, 12);
}

function readContentText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (!part || typeof part !== "object") return "";
        if (typeof part.text === "string") return part.text;
        if (typeof part.content === "string") return part.content;
        if (part.type === "tool_use") return JSON.stringify(part.input ?? {});
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  if (content == null) return "";
  return JSON.stringify(content);
}

function systemText(obj) {
  const sys = obj.system;
  if (typeof sys === "string") return sys;
  if (Array.isArray(sys)) {
    return sys
      .map((part) => part && typeof part === "object" && typeof part.text === "string" ? part.text : String(part ?? ""))
      .join("");
  }
  if (sys == null) return "";
  return JSON.stringify(sys);
}

function toolNames(obj) {
  return Array.isArray(obj.tools)
    ? obj.tools.map((tool) => tool?.name).filter((name) => typeof name === "string")
    : [];
}

function messageText(message) {
  if (!message || typeof message !== "object") return "";
  return readContentText(message.content);
}

function blockSummary(block) {
  if (!block || typeof block !== "object") return "unknown";
  const size = JSON.stringify(block).length;
  if (block.type === "tool_result") {
    return `tool_result:${block.tool_use_id ?? "unknown"}:${size}`;
  }
  if (block.type === "tool_use") {
    return `tool_use:${block.name ?? "unknown"}:${size}`;
  }
  if (block.type === "text") {
    return `text:${size}`;
  }
  return `${block.type ?? "unknown"}:${size}`;
}

function messageSize(message) {
  return JSON.stringify(message ?? null).length;
}

function messageBlocks(message) {
  return Array.isArray(message?.content) ? message.content.map(blockSummary) : [];
}

function firstDiffIndex(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a.charCodeAt(i) !== b.charCodeAt(i)) return i;
  }
  return a.length === b.length ? -1 : n;
}

function lineNumberAt(text, idx) {
  if (idx < 0) return -1;
  return text.slice(0, idx).split("\n").length;
}

function excerpt(text, idx, radius = 420) {
  if (idx < 0) return "(no difference)";
  const start = Math.max(0, idx - radius);
  const end = Math.min(text.length, idx + radius);
  return text.slice(start, end).replaceAll("\r", "\\r");
}

function compact(text, max = 260) {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length <= max ? oneLine : `${oneLine.slice(0, max)}...`;
}

function flagsForRequest(obj) {
  const last = messageText(obj.messages?.[obj.messages.length - 1]);
  const allText = [
    systemText(obj),
    ...(Array.isArray(obj.messages) ? obj.messages.map(messageText) : []),
  ].join("\n");
  return {
    heartbeat: /heartbeat/i.test(last) &&
      !/HEARTBEAT\.md|Keep this file empty/i.test(last),
    internalRuntime: last.includes(OPENCLAW_MARKERS.internalRuntime),
    internalCompletion: last.includes(OPENCLAW_MARKERS.internalCompletion),
    subagentContext: allText.includes(OPENCLAW_MARKERS.subagentContext) ||
      allText.includes(OPENCLAW_MARKERS.subagentTask),
  };
}

function parseDeepLog(logText) {
  const marker = "\n========================================\n>>> POST /v1/messages\n";
  const chunks = logText.split(marker).slice(1);
  const requests = [];

  for (let chunkIdx = 0; chunkIdx < chunks.length; chunkIdx++) {
    const chunk = chunks[chunkIdx];
    const summary = chunk.match(/\nREQUEST POST \/v1\/messages body_bytes=(\d+).*?session=([^ \n]+)(?: identity=([^ \n]+))?(?: agent=([^ \n]+))?(?: cache=([^ \n]+))?(?: access=([^ \n]+))?/);
    if (!summary) continue;

    const body = chunk.slice(0, summary.index);
    let obj;
    try {
      obj = JSON.parse(body);
    } catch (err) {
      requests.push({
        idx: chunkIdx,
        parseError: err.message,
        session: summary[2],
        bodyBytes: Number(summary[1]),
      });
      continue;
    }

    requests.push({
      idx: chunkIdx,
      body,
      obj,
      bodyBytes: Number(summary[1]),
      session: summary[2],
      identity: summary[3] ?? "unknown",
      agent: summary[4] ?? "unknown",
      cache: summary[5] ?? "unknown",
      access: summary[6] ?? "unknown",
      hash: sha12(body),
    });
  }

  return requests;
}

function summarizeRequest(req) {
  const obj = req.obj;
  const sys = systemText(obj);
  const tools = toolNames(obj);
  const messages = Array.isArray(obj.messages) ? obj.messages : [];
  const flags = flagsForRequest(obj);
  const latest = messages.length > 0 ? messageText(messages[messages.length - 1]) : "";

  return {
    idx: req.idx,
    session: req.session,
    agent: req.agent,
    cache: req.cache,
    bodyBytes: req.bodyBytes,
    hash: req.hash,
    systemChars: sys.length,
    tools,
    messageCount: messages.length,
    latestRole: messages[messages.length - 1]?.role ?? "(none)",
    latestPreview: compact(latest),
    flags,
  };
}

function compareNameList(label, a, b) {
  const aa = new Set(a);
  const bb = new Set(b);
  const removed = [...aa].filter((x) => !bb.has(x)).sort();
  const added = [...bb].filter((x) => !aa.has(x)).sort();
  if (removed.length === 0 && added.length === 0) return;
  console.log(`${label}:`);
  if (removed.length) console.log(`  removed: ${removed.join(", ")}`);
  if (added.length) console.log(`  added:   ${added.join(", ")}`);
}

function compareRequests(a, b) {
  const as = summarizeRequest(a);
  const bs = summarizeRequest(b);
  const byteDelta = bs.bodyBytes - as.bodyBytes;
  console.log(`\n=== Compare request ${a.idx} -> ${b.idx} (${a.session}) ===`);
  console.log(`old: bytes=${as.bodyBytes} cache=${as.cache} agent=${as.agent} hash=${as.hash} system=${as.systemChars} tools=${as.tools.length} messages=${as.messageCount}`);
  console.log(`new: bytes=${bs.bodyBytes} cache=${bs.cache} agent=${bs.agent} hash=${bs.hash} system=${bs.systemChars} tools=${bs.tools.length} messages=${bs.messageCount}`);
  console.log(`delta: bytes=${byteDelta >= 0 ? "+" : ""}${byteDelta} messages=${bs.messageCount - as.messageCount >= 0 ? "+" : ""}${bs.messageCount - as.messageCount}`);

  const aSys = systemText(a.obj);
  const bSys = systemText(b.obj);
  const sysDiff = firstDiffIndex(aSys, bSys);
  if (sysDiff >= 0) {
    console.log(`\nSystem first difference: char ${sysDiff}, line ${lineNumberAt(aSys, sysDiff)} -> ${lineNumberAt(bSys, sysDiff)}`);
    console.log("--- old system excerpt ---");
    console.log(excerpt(aSys, sysDiff));
    console.log("--- new system excerpt ---");
    console.log(excerpt(bSys, sysDiff));
  } else {
    console.log("\nSystem text: identical");
  }

  compareNameList("\nTools changed", as.tools, bs.tools);

  const aMessages = Array.isArray(a.obj.messages) ? a.obj.messages : [];
  const bMessages = Array.isArray(b.obj.messages) ? b.obj.messages : [];
  const minMsgs = Math.min(aMessages.length, bMessages.length);
  let msgDiff = -1;
  for (let i = 0; i < minMsgs; i++) {
    const left = JSON.stringify(aMessages[i]);
    const right = JSON.stringify(bMessages[i]);
    if (left !== right) {
      msgDiff = i;
      break;
    }
  }
  if (msgDiff < 0 && aMessages.length !== bMessages.length) {
    msgDiff = minMsgs;
  }

  if (msgDiff >= 0) {
    console.log(`\nMessages first difference: index ${msgDiff}`);
    const oldMsg = aMessages[msgDiff];
    const newMsg = bMessages[msgDiff];
    console.log(`old role=${oldMsg?.role ?? "(missing)"} size=${messageSize(oldMsg)} blocks=${messageBlocks(oldMsg).join(", ") || "(none)"} text=${JSON.stringify(compact(messageText(oldMsg), 420))}`);
    console.log(`new role=${newMsg?.role ?? "(missing)"} size=${messageSize(newMsg)} blocks=${messageBlocks(newMsg).join(", ") || "(none)"} text=${JSON.stringify(compact(messageText(newMsg), 420))}`);
  } else {
    console.log("\nMessages: identical");
  }

  const rows = [];
  const maxMsgs = Math.max(aMessages.length, bMessages.length);
  for (let i = 0; i < maxMsgs; i++) {
    const oldMsg = aMessages[i];
    const newMsg = bMessages[i];
    const oldSize = oldMsg ? messageSize(oldMsg) : 0;
    const newSize = newMsg ? messageSize(newMsg) : 0;
    const delta = newSize - oldSize;
    if (Math.abs(delta) >= 1024 || !oldMsg || !newMsg) {
      rows.push({ i, oldMsg, newMsg, oldSize, newSize, delta });
    }
  }
  if (rows.length > 0) {
    console.log("\nLarge message changes:");
    for (const row of rows.sort((x, y) => Math.abs(y.delta) - Math.abs(x.delta)).slice(0, 8)) {
      const msg = row.newMsg ?? row.oldMsg;
      const preview = compact(messageText(msg), 360);
      const deltaText = row.delta >= 0 ? `+${row.delta}` : String(row.delta);
      console.log(`  [${row.i}] ${row.oldMsg?.role ?? "(missing)"} -> ${row.newMsg?.role ?? "(missing)"} size ${row.oldSize} -> ${row.newSize} (${deltaText}) blocks=${messageBlocks(msg).join(", ") || "(none)"}`);
      if (preview) console.log(`      ${JSON.stringify(preview)}`);
    }
  }

  console.log("\nLatest message:");
  console.log(`old role=${as.latestRole} ${JSON.stringify(as.latestPreview)}`);
  console.log(`new role=${bs.latestRole} ${JSON.stringify(bs.latestPreview)}`);

  console.log("\nMarkers:");
  for (const [name, value] of Object.entries(bs.flags)) {
    if (value) console.log(`  new request has ${name}`);
  }
  if (!Object.values(bs.flags).some(Boolean)) console.log("  none detected in new request");

  const likely = [];
  if (sysDiff >= 0) likely.push("system/tool block changed near prompt start");
  if (as.tools.length !== bs.tools.length) likely.push("available tools changed");
  if (bs.flags.internalRuntime) likely.push("latest message is OpenClaw internal runtime context");
  if (bs.flags.internalCompletion) likely.push("latest message is an internal task completion event");
  if (bs.flags.heartbeat) likely.push("heartbeat text detected");
  if (bs.flags.subagentContext) likely.push("subagent context text detected");
  if (byteDelta > 32768) likely.push(`request body grew by ${(byteDelta / 1024).toFixed(1)} KiB`);
  const largestGrowth = rows.reduce((best, row) => row.delta > best.delta ? row : best, { delta: 0 });
  if (largestGrowth.delta > 32768) {
    const msg = largestGrowth.newMsg;
    const blocks = messageBlocks(msg).join(", ") || "unknown block";
    likely.push(`large appended/expanded message at index ${largestGrowth.i} (${blocks})`);
  }

  console.log("\nLikely cause:");
  console.log(likely.length ? `  ${likely.join("; ")}` : "  no obvious structural cause found");
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const requests = parseDeepLog(readFileSync(args.logFile, "utf8"));
  const parsed = requests.filter((req) => req.obj);
  if (parsed.length === 0) {
    throw new Error(`no parsed /v1/messages requests found in ${args.logFile}`);
  }

  if (args.latest) {
    args.session = parsed[parsed.length - 1].session;
    console.log(`Using latest session from log tail: ${args.session}`);
  }

  if (!args.session) {
    const counts = new Map();
    for (const req of parsed) counts.set(req.session, (counts.get(req.session) ?? 0) + 1);
    console.log("Sessions found:");
    for (const [session, count] of [...counts.entries()].sort((a, b) => b[1] - a[1])) {
      console.log(`  ${session} (${count})`);
    }
    console.log("\nPass --session ID to compare requests.");
    return;
  }

  const sessionReqs = parsed.filter((req) => req.session === args.session);
  if (sessionReqs.length === 0) {
    throw new Error(`session not found: ${args.session}`);
  }

  console.log(`Found ${sessionReqs.length} request(s) for session ${args.session}`);
  for (const req of sessionReqs.slice(-args.last)) {
    const s = summarizeRequest(req);
    console.log(`  idx=${s.idx} bytes=${s.bodyBytes} cache=${s.cache} agent=${s.agent} system=${s.systemChars} tools=${s.tools.length} messages=${s.messageCount} hash=${s.hash}`);
  }

  let pairs = [];
  if (args.compare) {
    const [aIdxRaw, bIdxRaw] = args.compare.split(":");
    const aIdx = Number.parseInt(aIdxRaw, 10);
    const bIdx = Number.parseInt(bIdxRaw, 10);
    const a = parsed.find((req) => req.idx === aIdx);
    const b = parsed.find((req) => req.idx === bIdx);
    if (!a || !b) throw new Error(`--compare indices not found: ${args.compare}`);
    pairs = [[a, b]];
  } else {
    const tail = sessionReqs.slice(-args.last);
    for (let i = 1; i < tail.length; i++) {
      pairs.push([tail[i - 1], tail[i]]);
    }
  }

  for (const [a, b] of pairs) {
    compareRequests(a, b);
  }
}

try {
  main();
} catch (err) {
  console.error(`diagnose-cache-divergence: ${err.message}`);
  process.exit(1);
}
