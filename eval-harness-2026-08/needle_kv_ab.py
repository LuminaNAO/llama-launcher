#!/usr/bin/env python3
"""Needle retrieval at deep context against the running server (:40802).
Builds a ~200k-token haystack from wikitext with 6 planted facts at increasing
depth, asks each back, scores exact recall. Usage: needle_kv_ab.py <label>"""
import json, os, re, sys, time, urllib.request
label=sys.argv[1]
text=open(os.path.expanduser("~/.cache/llama-eval/wiki.test.raw")).read()
# measured 2026-09-05: this text tokenises at ~2.1 chars/token; 430k chars ~ 205k tokens
# (660k chars was ~310k tokens and forced a context shift at n_ctx 262144)
hay=text[:430000]
facts=[("The access code for the Dunsborough depot is 7Q4-KESTREL-19.", "7Q4-KESTREL-19"),
       ("Marguerite Okonkwo's favourite lighthouse is at Cape Naturaliste.", "Cape Naturaliste"),
       ("The Yallingup ledger lists exactly 4,312 crates of tin.", "4,312"),
       ("Project SANDPIPER was cancelled on 17 March 2021.", "17 March 2021"),
       ("The vault password hint is the word PERIWINKLE.", "PERIWINKLE"),
       ("Engineer Tobias Vrettakos measured the shaft at 611 metres.", "611")]
depths=[0.05,0.20,0.40,0.60,0.80,0.95]
qs=["What is the access code for the Dunsborough depot?","Which lighthouse is Marguerite Okonkwo's favourite?",
    "How many crates of tin does the Yallingup ledger list?","On what date was Project SANDPIPER cancelled?",
    "What is the vault password hint?","How many metres did Tobias Vrettakos measure the shaft at?"]
parts=[]; last=0
for (f,_),d in zip(facts,depths):
    cut=int(len(hay)*d); parts.append(hay[last:cut]); parts.append("\n\n"+f+"\n\n"); last=cut
parts.append(hay[last:]); doc="".join(parts)
def ask(q):
    body={"model":"local","max_tokens":200,"chat_template_kwargs":{"reasoning_effort":"low"},"cache_prompt":True,
          "messages":[{"role":"user","content":"Here is a long document. Answer the question at the end using only the document.\n\n"+doc+"\n\nQuestion: "+q+"\nAnswer with just the value."}]}
    req=urllib.request.Request("http://127.0.0.1:40802/v1/chat/completions",data=json.dumps(body).encode(),headers={"Content-Type":"application/json","Authorization":"Bearer ollama-local"})
    t0=time.time()
    with urllib.request.urlopen(req,timeout=1800) as r: d=json.load(r)
    return d["choices"][0]["message"]["content"], d.get("timings",{}).get("prompt_n"), round(time.time()-t0,1)
R={"label":label,"items":[]}; hits=0
for (f,ans),d,q in zip(facts,depths,qs):
    out,ntok,wall=ask(q); ok=ans.lower().replace(",","") in out.lower().replace(",",""); hits+=ok
    R["items"].append(dict(depth=d,expect=ans,got=out.strip()[:80],ok=ok,prompt_tokens=ntok,wall=wall))
    print(f"  depth {d:.2f}  {'OK  ' if ok else 'MISS'}  expect={ans!r:20s} got={out.strip()[:60]!r}  (prompt {ntok} tok, {wall}s)",flush=True)
R["score"]=f"{hits}/{len(facts)}"; print(f"  == NEEDLE {label}: {hits}/{len(facts)}")
json.dump(R,open(f"needle_{label}.json","w"),indent=1)
