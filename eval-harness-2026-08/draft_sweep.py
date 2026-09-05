#!/usr/bin/env python3
"""Proper MTP draft-depth sweep for HIGHEST: 3 depths x 3 content types,
capturing decode speed AND acceptance per probe from llama.log."""
import json, os, re, subprocess, time, urllib.request

EVAL = os.path.expanduser("~/code/llama-launcher/eval-harness-2026-08")
LOG=os.path.expanduser("~/code/llama-launcher/llama.log")
LAUNCHER=os.path.expanduser("~/.local/bin/llama-launcher")
MODEL="/usr/local/share/llama.cpp/models/Qwen3.8-27B-NVFP4-MTP-HIGHEST/Qwen3.8-27B-NVFP4-MTP-HIGHEST.gguf"
TUNEDIR=os.path.expanduser("~/code/llama-launcher/model-configs")
BASE="Qwen3.8-27B-NVFP4-MTP-HIGHEST.32gb-cuda-5090-nvfp4hi-262k-v1.yaml"

PROBES=[
 ("prose","Write a 700-word essay about the history of Western Australian gold mining.",1200),
 ("code","Write a complete Rust module implementing a generic bounded MPMC queue over std primitives, with tests.",1800),
 ("reason","A 5x5 grid has lamps all off; pressing toggles a lamp and orthogonal neighbours. Explain, step by step, how to reason about solving all-on, then give the minimal press count.",1800),
]

def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)
def health():
    try:
        r=subprocess.run(["curl","-s","-m","3","http://127.0.0.1:40802/health"],capture_output=True,text=True,timeout=10)
        return "ok" in r.stdout
    except Exception: return False

def launch(tune):
    subprocess.run([LAUNCHER,"stop"],capture_output=True,timeout=120); time.sleep(4)
    subprocess.Popen([LAUNCHER,"--build","cuda","--model",MODEL,"--tune",tune,
                      "--port","40801","--internal-port","40802","--log","--proxy","--no-hdd-cache"],
                     stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                     cwd=os.path.expanduser("~/code/llama-launcher"),start_new_session=True)
    t0=time.time()
    while time.time()-t0<420:
        if health(): return True
        time.sleep(5)
    return False

def probe(name,prompt,mt):
    pos=os.path.getsize(LOG)
    body={"model":"local","messages":[{"role":"user","content":prompt}],"max_tokens":mt}
    req=urllib.request.Request("http://127.0.0.1:40802/v1/chat/completions",data=json.dumps(body).encode(),
        headers={"Content-Type":"application/json","Authorization":"Bearer ollama-local"})
    with urllib.request.urlopen(req,timeout=900) as r: d=json.load(r)
    t=d.get("timings",{})
    new=open(LOG,'rb').read()[pos:].decode(errors="replace")
    m=re.findall(r"draft acceptance = (0\.\d+) \(\s*(\d+) accepted /\s*(\d+) generated\), mean len =\s*([\d.]+)",new)
    acc=m[-1] if m else None
    return dict(tg=round(t.get("predicted_per_second") or 0,1),
                n=(d.get("usage") or {}).get("completion_tokens"),
                accept=float(acc[0]) if acc else None,
                mean_len=float(acc[3]) if acc else None)

R={}
for depth in (2,3,4):
    if depth==3: tune=BASE.split(".")[1]
    else:
        src=open(f"{TUNEDIR}/{BASE}").read().replace("--spec-draft-n-max 3",f"--spec-draft-n-max {depth}")
        name=f"sweep-draft{depth}"
        src=src.replace(BASE.split(".")[1],name)
        open(f"{TUNEDIR}/Qwen3.8-27B-NVFP4-MTP-HIGHEST.{name}.yaml","w").write(src)
        tune=name
    log(f"draft-{depth}: launching")
    if not launch(tune):
        R[f"d{depth}"]={"error":"launch failed"}; continue
    R[f"d{depth}"]={}
    for pname,prompt,mt in PROBES:
        try:
            R[f"d{depth}"][pname]=probe(pname,prompt,mt)
            log(f"draft-{depth}/{pname}: {R[f'd{depth}'][pname]}")
        except Exception as e:
            R[f"d{depth}"][pname]={"error":str(e)[:120]}
    json.dump(R,open(f"{EVAL}/draft_sweep_results.json","w"),indent=1)
log("draft sweep complete")
