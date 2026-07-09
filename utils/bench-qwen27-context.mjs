#!/usr/bin/env bun
const base = process.env.LLAMA_BASE ?? "http://127.0.0.1:40802";
const apiKey = process.env.LLAMA_API_KEY ?? "ollama-local";
const targets = (process.env.BENCH_TARGETS ?? "1024,4096,16384,32768,65536,100000")
  .split(",")
  .map((s) => Number(s.trim()))
  .filter((n) => Number.isFinite(n) && n > 0);
const nPredict = Number(process.env.BENCH_N_PREDICT ?? "16");

async function post(path, body) {
  const resp = await fetch(`${base}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(60 * 60 * 1000),
  });
  const text = await resp.text();
  if (!resp.ok) throw new Error(`${path} HTTP ${resp.status}: ${text}`);
  return text ? JSON.parse(text) : {};
}

async function main() {
  console.log(`base=${base} n_predict=${nPredict}`);
  console.log("target,prompt_n,prompt_s,prompt_tok_s,predicted_n,predicted_tok_s,total_s");

  for (const target of targets) {
    try {
      await post("/slots/0?action=erase", {});
    } catch (err) {
      if (!String(err).includes("not_supported")) throw err;
    }
    const prompt = " alpha".repeat(target);
    const started = performance.now();
    const body = await post("/completion", {
      prompt,
      n_predict: nPredict,
      temperature: 0,
      cache_prompt: false,
      timings_per_token: false,
    });
    const elapsedS = (performance.now() - started) / 1000;
    const t = body.timings ?? {};
    console.log([
      target,
      t.prompt_n ?? "",
      ((t.prompt_ms ?? 0) / 1000).toFixed(3),
      (t.prompt_per_second ?? 0).toFixed(2),
      t.predicted_n ?? "",
      (t.predicted_per_second ?? 0).toFixed(2),
      elapsedS.toFixed(3),
    ].join(","));
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
