#!/usr/bin/env python3
"""Reproduce the published 450 t/s condition (archive recall, greedy, thinking off, 256 tok)
on the served Huihui artifact, then vary one knob at a time toward real work."""
import json, random, time, urllib.request
URL="http://127.0.0.1:8000/v1/chat/completions"; MODEL="qwen3.8-27b-huihui-abliterated-cinference"
def call(msgs, mt, **extra):
    body={"model":MODEL,"messages":msgs,"max_tokens":mt}; body.update(extra)
    req=urllib.request.Request(URL,data=json.dumps(body).encode(),headers={"Content-Type":"application/json"})
    t0=time.time()
    with urllib.request.urlopen(req,timeout=1800) as r: d=json.load(r)
    t=d.get("timings",{}); m=d["choices"][0]["message"]
    dn=t.get("draft_n") or 0; da=t.get("draft_n_accepted") or 0
    return dict(pp_tps=round(t.get("prompt_per_second") or 0), pp_n=t.get("prompt_n"), tg_tps=round(t.get("predicted_per_second") or 0,1),
                tg_n=t.get("predicted_n"), accept=round(da/dn,3) if dn else None, think_chars=len(m.get("reasoning_content") or ""),
                answer=(m.get("content") or "")[:160].replace("\n"," "), wall=round(time.time()-t0,1))
def archive(seed, nwords):
    rnd=random.Random(seed); words="ledger invoice vendor payment credit debit account balance transfer receipt audit quarter fiscal branch depot warehouse consignment freight tariff surcharge rebate".split()
    body=[rnd.choice(words) if rnd.random()<0.8 else str(rnd.randint(1,99999)) for _ in range(nwords)]
    markers={}
    for i,frac in enumerate([0.01,0.10,0.25,0.50,0.75,0.95]):
        val=f"{rnd.randint(100000,999999)}"; markers[f"MARKER-{i+1}"]=val
        body.insert(int(len(body)*frac), f"\n[MARKER-{i+1} = {val}]\n")
    return " ".join(body), markers
def recall_msgs(seed, nwords):
    doc,mk=archive(seed,nwords)
    return [{"role":"user","content":"Archive:\n"+doc+"\n\nList the value of MARKER-1 through MARKER-6, one per line, exactly as written."}], mk
R={}
def run(name, msgs, mt, **kw):
    R[name]=call(msgs,mt,**kw); print(f"{name:34s} pp={R[name]['pp_tps']} tg={R[name]['tg_tps']} n={R[name]['tg_n']} acc={R[name]['accept']} think={R[name]['think_chars']} wall={R[name]['wall']}  {R[name]['answer'][:70]}", flush=True)
m8,_=recall_msgs(1, 2400)     # ~8k tokens
run("recall8k_greedy_nothink",  m8, 256, temperature=0, enable_thinking=False)
m8b,_=recall_msgs(2, 2400)
run("recall8k_default_nothink", m8b, 256, enable_thinking=False)
m8c,_=recall_msgs(3, 2400)
run("recall8k_default_think",   m8c, 2048)
m32,_=recall_msgs(4, 9600)    # ~32k tokens
run("recall32k_greedy_nothink", m32, 256, temperature=0, enable_thinking=False)
essay=[{"role":"user","content":"Write a 700-word essay about the history of Western Australian gold mining."}]
run("prose_greedy_nothink",  essay, 900, temperature=0, enable_thinking=False)
run("prose_default_nothink", essay, 900, enable_thinking=False)
code=[{"role":"user","content":"Write a complete Rust module implementing a generic bounded MPMC queue over std primitives, with tests."}]
run("code_greedy_nothink",   code, 1200, temperature=0, enable_thinking=False)
json.dump(R,open("claim_check_ninfer_huihui_20260923.json","w"),indent=1); print("DONE")
