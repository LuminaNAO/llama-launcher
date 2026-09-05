#!/usr/bin/env python3
"""GSQ-RCO tune sweep: drafter depth, p-split, n-gram stacking, q8_0 KV, -ub 1024.
Each variant = temp tune -> relaunch (--no-hdd-cache) -> probes on :40802 -> JSON."""
import json, os, re, subprocess, time, random, urllib.request, glob
REPO=os.path.expanduser("~/code/llama-launcher"); LOG=f"{REPO}/llama.log"; TUNES=f"{REPO}/model-configs"
BASE=f"{TUNES}/Qwen3.8-27B-GSQ-RCO.32gb-cuda-5090-gsq3s-262k-v1.yaml"
MODEL="/usr/local/share/llama.cpp/models/Qwen3.8-27B-GSQ-RCO/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf"
OUT=f"{REPO}/eval-harness-2026-08/sweep_gsq3s.json"
def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)
def health():
    try: return "ok" in subprocess.run(["curl","-s","-m","3","http://127.0.0.1:40802/health"],capture_output=True,text=True,timeout=10).stdout
    except Exception: return False
def write_tune(name, nmax=3, extra="", spec="draft-mtp", kv="q4_0", ub=512):
    s=open(BASE).read()
    s=s.replace('name: "32gb-cuda-5090-gsq3s-262k-v1"', f'name: "sweep-{name}"')
    s=s.replace("--spec-type draft-mtp --spec-draft-n-max 3", f"--spec-type {spec} --spec-draft-n-max {nmax}{(' '+extra) if extra else ''}")
    s=s.replace('CACHE_TYPE_K: "q4_0"', f'CACHE_TYPE_K: "{kv}"').replace('CACHE_TYPE_V: "q4_0"', f'CACHE_TYPE_V: "{kv}"')
    s=s.replace("-ub 512", f"-ub {ub}")
    p=f"{TUNES}/Qwen3.8-27B-GSQ-RCO.sweep-{name}.yaml"; open(p,"w").write(s); return p
def launch(name):
    subprocess.run([f"{REPO}/llama-server-launcher.sh","stop"],capture_output=True,timeout=120,cwd=REPO); time.sleep(3)
    subprocess.Popen(["bash",f"{REPO}/llama-server-launcher.sh","--build","cuda","--model",MODEL,"--tune",f"sweep-{name}",
                      "--log","--proxy","--no-hdd-cache","--vision","1"],
                     stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,cwd=REPO,start_new_session=True)
    t0=time.time()
    while time.time()-t0<300:
        if health(): time.sleep(2); return True
        time.sleep(3)
    return False
def call(msgs, mt, effort=None):
    pos=os.path.getsize(LOG)
    body={"model":"local","messages":msgs,"max_tokens":mt,"cache_prompt":False}
    if effort: body["chat_template_kwargs"]={"reasoning_effort":effort}
    req=urllib.request.Request("http://127.0.0.1:40802/v1/chat/completions",data=json.dumps(body).encode(),headers={"Content-Type":"application/json","Authorization":"Bearer ollama-local"})
    try:
        with urllib.request.urlopen(req,timeout=900) as r: d=json.load(r)
    except Exception as e: return {"error":str(e)[:120]}
    t=d.get("timings",{}); new=open(LOG,'rb').read()[pos:].decode(errors="replace")
    m=re.findall(r"draft acceptance = (0\.\d+) \(\s*(\d+) accepted /\s*(\d+) generated\), mean len =\s*([\d.]+)",new); a=m[-1] if m else None
    return dict(tg=round(t.get("predicted_per_second") or 0,1), pp=round(t.get("prompt_per_second") or 0), n=t.get("predicted_n"),
                acc=float(a[0]) if a else None, mlen=float(a[3]) if a else None)
SNIP="""pub struct Foo { items: Vec<u32>, cap: usize }
impl Foo {
    pub fn new(cap: usize) -> Self { Foo { items: Vec::with_capacity(cap), cap } }
    pub fn push(&mut self, v: u32) -> Result<(), u32> { if self.items.len() >= self.cap { return Err(v); } self.items.push(v); Ok(()) }
    pub fn pop(&mut self) -> Option<u32> { if self.items.is_empty() { None } else { Some(self.items.remove(0)) } }
    pub fn len(&self) -> usize { self.items.len() }
    pub fn is_empty(&self) -> bool { self.items.is_empty() }
    pub fn capacity(&self) -> usize { self.cap }
    pub fn clear(&mut self) { self.items.clear() }
    pub fn peek(&self) -> Option<&u32> { self.items.first() }
    pub fn contains(&self, v: u32) -> bool { self.items.contains(&v) }
    pub fn drain_all(&mut self) -> Vec<u32> { std::mem::take(&mut self.items) }
}
#[cfg(test)] mod tests { use super::*;
    #[test] fn push_pop() { let mut f = Foo::new(2); assert!(f.push(1).is_ok()); assert!(f.push(2).is_ok()); assert_eq!(f.push(3), Err(3)); assert_eq!(f.pop(), Some(1)); assert_eq!(f.len(), 1); }
    #[test] fn peek_contains() { let mut f = Foo::new(4); f.push(7).unwrap(); assert_eq!(f.peek(), Some(&7)); assert!(f.contains(7)); assert!(!f.contains(8)); }
}"""
PROBES=[("code","Write a complete Rust module implementing a generic bounded MPMC queue over std primitives, with tests.",1200,None),
        ("reason","A 5x5 grid has lamps all off; pressing toggles a lamp and orthogonal neighbours. Explain, step by step, how to reason about solving all-on, then give the minimal press count.",1200,None),
        ("edit","Here is a Rust file:\n```rust\n"+SNIP+"\n```\nRename `Foo` to `RingBuf` everywhere, add a `///` doc comment to every pub fn, change nothing else, and return the complete updated file in one code block.",1500,"low")]
random.seed(7); W="ledger invoice vendor payment credit debit account balance transfer receipt audit quarter fiscal branch depot warehouse consignment freight tariff surcharge rebate".split()
def doc(n):
    o=[]
    for i in range(n):
        if i%12==0: o.append(f"\n{random.randint(2019,2026)}-{random.randint(1,12):02d}-{random.randint(1,28):02d} #{random.randint(10000,99999)}")
        o.append(random.choice(W) if random.random()<0.8 else str(random.randint(1,99999)))
    return " ".join(o)
D62=doc(9000); D201=doc(29000)
def measure(deep=False):
    r={}
    for name,p,mt,eff in PROBES: r[name]=call([{"role":"user","content":p}],mt,eff); log(f"   {name}: {r[name]}")
    vals=[r[k]["tg"] for k in ("code","reason","edit") if "tg" in r[k]]; r["tg_mean"]=round(sum(vals)/len(vals),1) if vals else None
    if deep:
        r["pp62k"]=call([{"role":"user","content":"Document:\n"+D62+"\n\nReply with only the first date."}],32,"low"); log(f"   pp62k: {r['pp62k']}")
        r["deep201k"]=call([{"role":"user","content":"Document:\n"+D201+"\n\nWrite a 250-word summary of what kind of document this is."}],400,"low"); log(f"   deep201k: {r['deep201k']}")
    r["vram_mib"]=int(subprocess.run(["nvidia-smi","--query-gpu=memory.used","--format=csv,noheader,nounits"],capture_output=True,text=True).stdout.strip() or 0)
    spec=subprocess.run(["bash","-c",f"tail -c 400000 {LOG} | grep -a -iE 'speculative_init|spec.*type|ngram' | tail -3"],capture_output=True,text=True).stdout.strip()
    r["spec_log"]=spec[-300:]
    return r
R={}
def run(name, deep=False, **kw):
    write_tune(name, **kw); log(f"== {name} {kw}")
    if not launch(name): R[name]={"error":"launch failed"}; log("   LAUNCH FAILED"); 
    else: R[name]=dict(kw, **measure(deep))
    R[name]["vram_mib"]=R[name].get("vram_mib"); json.dump(R,open(OUT,"w"),indent=1)
for n in (3,2,4,5): run(f"d{n}", nmax=n)
best=max((n for n in (3,2,4,5) if R[f"d{n}"].get("tg_mean")), key=lambda n:R[f"d{n}"]["tg_mean"]); log(f"** best depth = {best}")
run("psplit05", nmax=best, extra="--spec-draft-p-split 0.05")
run("psplit20", nmax=best, extra="--spec-draft-p-split 0.20")
run("mtp+ngramk4v", nmax=best, spec="draft-mtp,ngram-map-k4v")
run("mtp+ngrammod", nmax=best, spec="draft-mtp,ngram-mod")
run("kvq8", deep=True, nmax=best, kv="q8_0")
run("kvq8-ub1024", deep=True, nmax=best, kv="q8_0", ub=1024)
run("base-deep", deep=True, nmax=best)   # q4_0 KV reference at the same depth for the deep probes
for f in glob.glob(f"{TUNES}/Qwen3.8-27B-GSQ-RCO.sweep-*.yaml"): os.remove(f)
log("SWEEP COMPLETE"); print(json.dumps({k:{kk:vv for kk,vv in v.items() if kk in ('nmax','extra','spec','kv','ub','tg_mean','vram_mib')} for k,v in R.items()},indent=1))
