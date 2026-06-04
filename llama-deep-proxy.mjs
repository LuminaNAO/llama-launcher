#!/usr/bin/env node

// Transparent HTTP proxy that tee-s raw request/response bodies to a log file.
// Zero external dependencies — uses only Node.js built-in http module.
//
// Usage: node llama-deep-proxy.mjs <listen-port> <backend-port> [log-file]
//
// All traffic is forwarded unchanged. Both directions (request body = input,
// response body = output) are appended to the log file as-is, with minimal
// delimiters so you can tell requests apart.

import { createServer, request as httpRequest } from "node:http";
import { createWriteStream } from "node:fs";

const listenPort = parseInt(process.argv[2], 10);
const backendPort = parseInt(process.argv[3], 10);
const logFile = process.argv[4] || `${process.env.HOME}/llama-deep.log`;

if (!listenPort || !backendPort) {
  console.error("Usage: llama-deep-proxy.mjs <listen-port> <backend-port> [log-file]");
  process.exit(1);
}

const log = createWriteStream(logFile, { flags: "a" });

const SEP = "\n========================================\n";

const server = createServer((clientReq, clientRes) => {
  const tag = `${clientReq.method} ${clientReq.url}`;

  // Log request header
  log.write(`${SEP}>>> ${tag}\n`);

  const proxyOpts = {
    hostname: "127.0.0.1",
    port: backendPort,
    path: clientReq.url,
    method: clientReq.method,
    headers: clientReq.headers,
  };

  const proxyReq = httpRequest(proxyOpts, (proxyRes) => {
    // Log response status
    log.write(`\n<<< ${proxyRes.statusCode} ${tag}\n`);

    clientRes.writeHead(proxyRes.statusCode, proxyRes.headers);

    proxyRes.on("data", (chunk) => {
      log.write(chunk);
      clientRes.write(chunk);
    });

    proxyRes.on("end", () => {
      log.write("\n");
      clientRes.end();
    });
  });

  proxyReq.on("error", (err) => {
    log.write(`\n!!! ERROR ${tag}: ${err.message}\n`);
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { "Content-Type": "text/plain" });
    }
    clientRes.end(`Proxy error: ${err.message}`);
  });

  // Pipe request body to backend and log it
  clientReq.on("data", (chunk) => {
    log.write(chunk);
    proxyReq.write(chunk);
  });

  clientReq.on("end", () => {
    proxyReq.end();
  });
});

server.listen(listenPort, "0.0.0.0", () => {
  console.log(`llama-deep-proxy: 0.0.0.0:${listenPort} -> 127.0.0.1:${backendPort}`);
  console.log(`llama-deep-proxy: logging to ${logFile}`);
});

// Clean shutdown
process.on("SIGTERM", () => {
  server.close();
  log.end();
});
process.on("SIGINT", () => {
  server.close();
  log.end();
});
