#!/usr/bin/env python3
"""Tuning sweeps for the top-3: for each (model, variant) launch and measure
prefill (32k tokens) + decode (1.5k gen) + MTP acceptance. Records JSON."""
import json, os, subprocess, time, urllib.request

EVAL = os.path.expanduser("~/code/llama-launcher/eval-harness-2026-08")
M = "/usr/local/share/llama.cpp/models"
LAUNCHER = os.path.expanduser("~/.local/bin/llama-launcher")
FIXED_TMPL = f"{M}/Qwen3.8-27B-UD-Q6_K_XL/chat_template_fixed.jinja"
os.chdir(EVAL)

def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

def health():
    try:
        r = subprocess.run(["curl","-s","-m","3","http://127.0.0.1:40802/health"],capture_output=True,text=True,timeout=10)
        return "ok" in r.stdout
    except Exception: return False

def launch(model, ctx, kv, extra):
    subprocess.run([LAUNCHER,"stop"],capture_output=True,timeout=120); time.sleep(4)
    args=[LAUNCHER,"--build","cuda","--model",model,"--context",str(ctx),
          "--port","40801","--internal-port","40802","--log","--proxy","--no-hdd-cache"]
    env=os.environ.copy()
    # bypass tunes: pass everything explicit via a synthetic tune-less launch
    subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     cwd=os.path.expanduser("~/code/llama-launcher"), start_new_session=True, env=env)
    t0=time.time()
    while time.time()-t0 < 420:
        if health(): return True
        time.sleep(5)
    return False

def measure():
    doc = open("longdoc_100k.txt").read()[:128000]  # ~32k tokens
    out = {}
    # prefill probe
    body={"model":"local","messages":[{"role":"user","content":doc+"\nSay OK."}],"max_tokens":8,"cache_prompt":False}
    req=urllib.request.Request("http://127.0.0.1:40802/v1/chat/completions",data=json.dumps(body).encode(),
        headers={"Content-Type":"application/json","Authorization":"Bearer ollama-local"})
    with urllib.request.urlopen(req,timeout=900) as r: d=json.load(r)
    t=d.get("timings",{})
    out["pp32k"]=round(t.get("prompt_per_second") or 0)
    # decode probe
    body={"model":"local","messages":[{"role":"user","content":"Write a 900-word essay on tidal energy."}],"max_tokens":1500}
    req=urllib.request.Request("http://127.0.0.1:40802/v1/chat/completions",data=json.dumps(body).encode(),
        headers={"Content-Type":"application/json","Authorization":"Bearer ollama-local"})
    with urllib.request.urlopen(req,timeout=900) as r: d=json.load(r)
    t=d.get("timings",{})
    out["tg"]=round(t.get("predicted_per_second") or 0,1)
    # acceptance from log
    r=subprocess.run(["bash","-c","grep -a 'draft acceptance' ~/code/llama-launcher/llama.log | tail -1"],capture_output=True,text=True)
    out["accept"]=r.stdout.strip()[-60:]
    r=subprocess.run(["nvidia-smi","--query-gpu=memory.used","--format=csv,noheader"],capture_output=True,text=True)
    out["vram"]=r.stdout.strip()
    return out

# variants are expressed as tune files created on the fly
def write_tune(base_tune, name, subs):
    src=os.path.expanduser(f"~/code/llama-launcher/model-configs/{base_tune}")
    dst=src.replace(base_tune.split(".")[1], name)
    s=open(src).read()
    for a,b in subs: s=s.replace(a,b)
    s=s.replace(base_tune.split(".")[1], name)
    open(dst,"w").write(s)
    return name

def launch_tune(model, tune):
    subprocess.run([LAUNCHER,"stop"],capture_output=True,timeout=120); time.sleep(4)
    subprocess.Popen([LAUNCHER,"--build","cuda","--model",model,"--tune",tune,
                      "--port","40801","--internal-port","40802","--log","--proxy","--no-hdd-cache"],
                     stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                     cwd=os.path.expanduser("~/code/llama-launcher"),start_new_session=True)
    t0=time.time()
    while time.time()-t0<420:
        if health(): return True
        time.sleep(5)
    return False

RESULTS={}
PLANS=[
 ("HIGHEST", f"{M}/Qwen3.8-27B-NVFP4-MTP-HIGHEST/Qwen3.8-27B-NVFP4-MTP-HIGHEST.gguf",
  "Qwen3.8-27B-NVFP4-MTP-HIGHEST.32gb-cuda-5090-nvfp4hi-262k-v1.yaml",
  [("base", []),
   ("ub512", [("-ub 256","-ub 512")]),
   ("draft2", [("--spec-draft-n-max 3","--spec-draft-n-max 2")]),
   ("draft4", [("--spec-draft-n-max 3","--spec-draft-n-max 4")]),
   ("gpuproj", [("--no-mmproj-offload","")]),
  ]),
 ("STOCKQ6", f"{M}/Qwen3.8-27B-UD-Q6_K_XL/Qwen3.8-27B-UD-Q6_K_XL.gguf",
  "Qwen3.8-27B-UD-Q6_K_XL.32gb-cuda-5090-q6xl-262k-v1.yaml",
  [("base", []),
   ("draft2", [("--spec-draft-n-max 3","--spec-draft-n-max 2")]),
   ("draft4", [("--spec-draft-n-max 3","--spec-draft-n-max 4")]),
   ("kv8-131k", [("CONTEXT: \"262144\"","CONTEXT: \"131072\""),("q4_0","q8_0"),("CHECKPOINT_MIN_STEP: \"16384\"","CHECKPOINT_MIN_STEP: \"8192\"")]),
  ]),
 ("FABLED", f"{M}/Qwen3.8-27B-Fable-Distill/Qwen3.8-27B-Fable-Distill-Q6_K.gguf",
  "Qwen3.8-27B-Fable-Distill.32gb-cuda-5090-fdq6-262k-v1.yaml",
  [("base", []),
   ("ub512", [("-ub 256","-ub 512")]),
   ("draft4", [("--spec-draft-n-max 3","--spec-draft-n-max 4")]),
  ]),
]
for mlabel, model, base_tune, variants in PLANS:
    for vname, subs in variants:
        tname = base_tune.split(".")[1] if vname=="base" else write_tune(base_tune, f"sweep-{vname}", subs)
        log(f"{mlabel}/{vname}: launching tune {tname}")
        if not launch_tune(model, tname):
            RESULTS[f"{mlabel}/{vname}"]={"error":"launch failed"}; log(f"{mlabel}/{vname}: LAUNCH FAILED"); continue
        try:
            RESULTS[f"{mlabel}/{vname}"]=measure()
            log(f"{mlabel}/{vname}: {RESULTS[f'{mlabel}/{vname}']}")
        except Exception as e:
            RESULTS[f"{mlabel}/{vname}"]={"error":str(e)[:200]}; log(f"{mlabel}/{vname}: MEASURE FAIL {e}")
        json.dump(RESULTS, open("tune_sweep_results.json","w"), indent=1)
log("sweep complete")
