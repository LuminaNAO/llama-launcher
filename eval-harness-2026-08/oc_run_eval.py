#!/usr/bin/env python3
"""Drive the eval suite through the OpenClaw harness (gateway agent turns).
Each question runs in its own fresh session with --thinking xhigh."""
import json, subprocess, sys, time, argparse

ap = argparse.ArgumentParser()
ap.add_argument("--label", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--thinking", default="xhigh")
ap.add_argument("--only", default=None)
ap.add_argument("--timeout", type=int, default=1800)
ap.add_argument("--questions", default="questions.json")
args = ap.parse_args()

Q = json.load(open(args.questions))
if args.only:
    ids = set(args.only.split(","))
    Q = [q for q in Q if q["id"] in ids]

results = []
try:
    results = json.load(open(args.out))
    done = {r["id"] for r in results}
    Q = [q for q in Q if q["id"] not in done]
    print(f"resuming: {len(done)} done, {len(Q)} to go")
except FileNotFoundError:
    pass

for i, q in enumerate(Q):
    sid = f"eval-{args.label}-{q['id']}"
    t0 = time.time()
    try:
        p = subprocess.run(["openclaw","--profile","eval","agent","--local",
                            "--session-id",sid,
                            "--message",q["prompt"],
                            "--thinking",args.thinking,"--json"],
                           capture_output=True, text=True, timeout=args.timeout+60)
        wall = time.time() - t0
        raw = p.stdout.strip()
        content, err = "", None
        try:
            d = json.loads(raw[raw.index("{"):]) if "{" in raw else {}
            # tolerate several shapes: {reply|text|message|payloads:[{text}]}
            content = "\n".join((x.get("text") or "") for x in (d.get("payloads") or []) if isinstance(x, dict))
        except Exception as e:
            err = f"parse: {e}; raw head: {raw[:200]}"
        if not content and not err:
            err = f"empty content; rc={p.returncode}; stderr: {p.stderr[:200]}; raw: {raw[:200]}"
        served = ""
        try:
            served = (d.get("meta") or {}).get("agentMeta", {}).get("model", "")
        except Exception:
            pass
        rec = dict(id=q["id"], cat=q["cat"], label=args.label, content=content,
                   error=err, wall=wall, rc=p.returncode, requested_model=served)
    except subprocess.TimeoutExpired:
        rec = dict(id=q["id"], cat=q["cat"], label=args.label, content="",
                   error="hard timeout", wall=time.time()-t0)
    results.append(rec)
    json.dump(results, open(args.out,"w"), indent=1)
    print(f"[{i+1}/{len(Q)}] {q['id']} wall={rec['wall']:.0f}s err={str(rec.get('error'))[:80]}", flush=True)
print("DONE")
