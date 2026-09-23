#!/usr/bin/env python3
"""Fill empty `content` in a harness results file from the agent's session transcripts.
Usage: recover_from_sessions.py <results.json> <sessions_dir> <label>
Takes the last assistant text block of session eval-<label>-<id>.jsonl."""
import json, os, sys
res_path, sdir, label = sys.argv[1:4]
R = json.load(open(res_path))
for r in R:
    if r.get("content"): continue
    f = os.path.join(sdir, f"eval-{label}-{r['id']}.jsonl")
    if not os.path.exists(f): continue
    last = ""
    for line in open(f):
        try: d = json.loads(line)
        except Exception: continue
        m = d.get("message") or {}
        if m.get("role") != "assistant": continue
        for b in m.get("content") or []:
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text"): last = b["text"]
    if last:
        r["content"] = last; r["error"] = None; r["recovered_from"] = "session"
json.dump(R, open(res_path, "w"), indent=1)
print("recovered:", [r["id"] for r in R if r.get("recovered_from")])
