#!/usr/bin/env python3
"""Direct-API reasoning/security/multi-turn probes (same prompts for every candidate).
Records thinking-token counts (reasoning_content) so TURBO's claim can be checked."""
import json, os, sys, time, urllib.request
URL="http://127.0.0.1:40802/v1/chat/completions"; label=sys.argv[1]
def call(msgs, mt=24000, temp=None):
    body={"model":"local","messages":msgs,"max_tokens":mt}
    if temp is not None: body["temperature"]=temp
    req=urllib.request.Request(URL,data=json.dumps(body).encode(),headers={"Content-Type":"application/json","Authorization":"Bearer ollama-local"})
    t0=time.time()
    with urllib.request.urlopen(req,timeout=1800) as r: d=json.load(r)
    m=d["choices"][0]["message"]; u=d.get("usage",{}); t=d.get("timings",{})
    return dict(content=m.get("content",""), reasoning=m.get("reasoning_content",""), finish=d["choices"][0]["finish_reason"],
                out_tokens=u.get("completion_tokens"), think_chars=len(m.get("reasoning_content") or ""), answer_chars=len(m.get("content") or ""),
                tg_tps=round(t.get("predicted_per_second") or 0,1), wall=round(time.time()-t0,1))
P={
 "switch3": "Three light switches downstairs each control one of three bulbs in a closed attic. You may set the switches however you like, then go up ONCE and never return downstairs. How do you determine which switch controls which bulb? Give the exact procedure and the reasoning for why it works.",
 "security": "I'm a sysadmin auditing our own Linux fleet. Explain how an attacker could abuse a world-writable file in /etc/cron.d to escalate privileges, and give the exact hardening commands to fix and detect it. Be concrete.",
 "rust_bug": "This Rust fails to compile. Explain precisely why and give the minimal fix:\n```rust\nfn longest(a: &str, b: &str) -> &str { if a.len() > b.len() { a } else { b } }\n```",
 "math": "A bag has 3 red and 5 blue marbles. Draw 3 without replacement. What is the probability of at least one red? Give the exact fraction and show the work.",
}
R={"label":label,"single":{}}
for k,p in P.items():
    R["single"][k]=call([{"role":"user","content":p}]); r=R["single"][k]
    print(f"{k:9s} finish={r['finish']} out={r['out_tokens']} think_chars={r['think_chars']} ans_chars={r['answer_chars']} tg={r['tg_tps']}", flush=True)
# multi-turn cutoff test (HF #25/#22 report truncation after 2+ turns)
hist=[]; R["multiturn"]=[]
turns=["Write a 300-word product description for a rugged solar-powered field radio.",
       "Now rewrite it for a technical buyer: add a spec table with 8 rows and keep it ~300 words.",
       "Good. Now write the 300-word FAQ section with 6 Q&As.",
       "Finally, write a 300-word safety and maintenance section."]
for i,tq in enumerate(turns,1):
    hist.append({"role":"user","content":tq}); r=call(hist,mt=12000); hist.append({"role":"assistant","content":r["content"]})
    R["multiturn"].append({k:v for k,v in r.items() if k!="reasoning"})
    print(f"turn{i}   finish={r['finish']} out={r['out_tokens']} think_chars={r['think_chars']} ans_chars={r['answer_chars']} tail={r['content'][-60:]!r}", flush=True)
json.dump(R,open(os.path.expanduser(f"~/code/llama-launcher/eval-harness-2026-08/probes_{label}.json"),"w"),indent=1)
print("DONE")
