#!/usr/bin/env python3
"""Speed probes against llama-server directly (:40802, bypasses proxy/hdd-cache).
Shallow decode x3 content types, prefill @32k, decode @~100k ctx; MTP acceptance from llama.log."""
import json, os, re, sys, time, random, urllib.request
LOG=os.path.expanduser("~/code/llama-launcher/llama.log")
URL="http://127.0.0.1:40802/v1/chat/completions"
label=sys.argv[1]
def call(msgs, mt, effort=None):
    pos=os.path.getsize(LOG)
    body={"model":"local","messages":msgs,"max_tokens":mt}
    if effort: body["chat_template_kwargs"]={"reasoning_effort":effort}
    req=urllib.request.Request(URL,data=json.dumps(body).encode(),headers={"Content-Type":"application/json","Authorization":"Bearer ollama-local"})
    t0=time.time()
    try:
        with urllib.request.urlopen(req,timeout=1800) as r: d=json.load(r)
    except urllib.error.HTTPError as e:
        return dict(error=f"HTTP {e.code}: {e.read().decode(errors='replace')[:200]}")
    wall=time.time()-t0
    t=d.get("timings",{})
    new=open(LOG,'rb').read()[pos:].decode(errors="replace")
    m=re.findall(r"draft acceptance = (0\.\d+) \(\s*(\d+) accepted /\s*(\d+) generated\), mean len =\s*([\d.]+)",new)
    acc=m[-1] if m else None
    return dict(pp_tps=round(t.get("prompt_per_second") or 0,1), pp_n=t.get("prompt_n"),
                tg_tps=round(t.get("predicted_per_second") or 0,1), tg_n=t.get("predicted_n"),
                accept=float(acc[0]) if acc else None, mean_len=float(acc[3]) if acc else None,
                finish=d["choices"][0]["finish_reason"], wall=round(wall,1))
random.seed(7)
words="ledger invoice vendor payment credit debit account balance transfer receipt audit quarter fiscal branch depot warehouse consignment freight tariff surcharge rebate".split()
def doc(nwords):
    out=[]
    for i in range(nwords):
        if i%12==0: out.append(f"\n{random.randint(2019,2026)}-{random.randint(1,12):02d}-{random.randint(1,28):02d} #{random.randint(10000,99999)}")
        out.append(random.choice(words) if random.random()<0.8 else str(random.randint(1,99999)))
    return " ".join(out)
R={"label":label}
PROBES=[("prose","Write a 700-word essay about the history of Western Australian gold mining.",900),
        ("code","Write a complete Rust module implementing a generic bounded MPMC queue over std primitives, with tests.",1200),
        ("reason","A 5x5 grid has lamps all off; pressing toggles a lamp and orthogonal neighbours. Explain, step by step, how to reason about solving all-on, then give the minimal press count.",1200)]
for name,p,mt in PROBES:
    R["shallow_"+name]=call([{"role":"user","content":p}],mt); print(name,R["shallow_"+name],flush=True)
# prefill @ ~32k tokens (ledger text ~ 1 token per word-ish)
d32=doc(9000)   # ~3.4 tok/word -> ~32k tokens
R["prefill_32k"]=call([{"role":"user","content":"Document:\n"+d32+"\n\nReply with only the first date in the document."}],32,"low"); print("prefill_32k",R["prefill_32k"],flush=True)
# decode @ ~100k ctx: big doc then a 300-token generation
d100=doc(29000)  # ~100k tokens
R["deep_100k"]=call([{"role":"user","content":"Document:\n"+d100+"\n\nWrite a 250-word summary of what kind of document this is and what patterns you notice."}],400,"low"); print("deep_100k",R["deep_100k"],flush=True)
json.dump(R,open(os.path.expanduser(f"~/code/llama-launcher/eval-harness-2026-08/speed_{label}.json"),"w"),indent=1)
print("DONE")
