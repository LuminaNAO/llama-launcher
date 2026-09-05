#!/usr/bin/env python3
"""Overnight rotation: for each candidate — launch, pin, wipe, run 26-suite + 5 rust
through the FreeClaw harness. Skips a model on launch failure and continues."""
import json, os, subprocess, sys, time

EVAL = os.path.expanduser("~/code/llama-launcher/eval-harness-2026-08")
M = "/usr/local/share/llama.cpp/models"
LAUNCHER = os.path.expanduser("~/.local/bin/llama-launcher")
os.chdir(EVAL)

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def sh(cmd, timeout=None, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)

def health_ok():
    try:
        r = sh(["curl", "-s", "-m", "3", "http://127.0.0.1:40802/health"], timeout=10)
        return "ok" in r.stdout
    except Exception:
        return False

def wait_health(secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        if health_ok(): return True
        time.sleep(5)
    return False

def wait_file_entries(path, n, secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        try:
            if len(json.load(open(path))) >= n: return True
        except Exception:
            pass
        time.sleep(30)
    return False

def launch(model_path, tune):
    sh([LAUNCHER, "stop"], timeout=120)
    time.sleep(4)
    subprocess.Popen([LAUNCHER, "--build", "cuda", "--model", model_path, "--tune", tune,
                      "--port", "40801", "--internal-port", "40802",
                      "--log", "--proxy", "--hdd-cache", "--vision"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     cwd=os.path.expanduser("~/code/llama-launcher"), start_new_session=True)
    return wait_health(420)

def set_pin(model_path):
    r = sh(["python3", f"{EVAL}/set_eval_pin.py", model_path], timeout=30)
    log(r.stdout.strip() or r.stderr.strip())

def wipe_eval():
    sh(["rm", "-rf",
        os.path.expanduser("~/.openclaw-eval/agents/main/sessions"),
        os.path.expanduser("~/.openclaw-eval/memory"),
        os.path.expanduser("~/.openclaw/workspace-eval")], timeout=30)

def run_suite(label, qfile, out):
    log(f"suite {qfile} -> {out}")
    r = subprocess.run(["python3", f"{EVAL}/oc_run_eval.py", "--label", label, "--out", out,
                        "--thinking", "high", "--questions", qfile],
                       capture_output=True, text=True, timeout=3*3600)
    log(f"suite done rc={r.returncode} tail={r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ''}")

CANDIDATES = [
 # (label, model_path, tune, run_main_suite)
 ("oc-nvfp4hi38",
  f"{M}/Qwen3.8-27B-NVFP4-MTP-HIGHEST/Qwen3.8-27B-NVFP4-MTP-HIGHEST.gguf",
  "32gb-cuda-5090-nvfp4hi-262k-v1", False),          # 26-suite already running; rust only after it finishes
 ("oc-coldfusion38",
  f"{M}/Qwen3.8-27B-Cold-Fusion-GAIN-V1.1-NM-DAU-NEO-MAX-MTP/Qwen3.8-27B-Cold-Fusion-GAIN-V1.1-NM-DAU-NEO-MAX-NEO-MTP-Q6_K.gguf",
  "32gb-cuda-5090-cfq6-262k-v1", True),
 ("oc-fabledistill38",
  f"{M}/Qwen3.8-27B-Fable-Distill/Qwen3.8-27B-Fable-Distill-Q6_K.gguf",
  "32gb-cuda-5090-fdq6-262k-v1", True),
 ("oc-hereticara38",
  f"{M}/Qwen3.8-27B-heretic-ara/Qwen3.8-27B-heretic-ara.i1-Q6_K.gguf",
  "32gb-cuda-5090-haq6-262k-v1", True),
 # rust backfill for already-scored models
 ("oc-stock38",
  f"{M}/Qwen3.8-27B-UD-Q6_K_XL/Qwen3.8-27B-UD-Q6_K_XL.gguf",
  "32gb-cuda-5090-q6xl-262k-v1", False),
 ("oc-heretic36",
  f"{M}/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP/Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-Q6_K.gguf",
  "32gb-cuda-5090-q6-262k-v2", False),
]

# step 0: let the in-flight HIGHEST 26-suite finish, then rust it on the live server
log("waiting for in-flight HIGHEST 26-suite")
wait_file_entries(f"{EVAL}/results_oc_nvfp4hi38.json", 26, 2*3600)
first = CANDIDATES[0]
if health_ok():
    wipe_eval()
    set_pin(first[1])
    run_suite(first[0], "rust_questions.json", f"results_{first[0].replace('-','_')}_rust.json")
else:
    log("HIGHEST server not healthy, skipping its rust pass")

for label, model, tune, main_suite in CANDIDATES[1:]:
    if not os.path.exists(model):
        log(f"SKIP {label}: model file missing"); continue
    log(f"=== {label}: launching {os.path.basename(model)}")
    if not launch(model, tune):
        log(f"SKIP {label}: launch failed/health timeout"); continue
    set_pin(model)
    wipe_eval()
    if main_suite:
        run_suite(label, "questions.json", f"results_{label.replace('-','_')}.json")
    run_suite(label, "rust_questions.json", f"results_{label.replace('-','_')}_rust.json")

log("rotation complete")
