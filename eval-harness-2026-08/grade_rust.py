#!/usr/bin/env python3
"""Grade rust results: extract last ```rust block, append hidden tests, rustc, run."""
import json, re, subprocess, sys, os, tempfile

Q = {q["id"]: q for q in json.load(open("rust_questions.json"))}
FORBID = {"R4": ["chunks_mut", "chunks_exact_mut", "split_at_mut", "as_chunks", "array_chunks"]}

def grade(qid, content):
    q = Q[qid]
    blocks = re.findall(r"```(?:rust)?\s*\n(.*?)```", content, re.DOTALL)
    if not blocks:
        return False, "no code block"
    code = blocks[-1]
    if "fn main" in code:
        code = re.sub(r"(?s)fn\s+main\s*\(\s*\)\s*(?:->\s*[^{]+)?\{.*", "", code)
    for bad in FORBID.get(qid, []):
        if re.search(rf"\.{bad}\s*\(", code):
            return False, f"forbidden helper {bad}"
    src = code + "\n" + q["tests"] + "\n"
    with tempfile.TemporaryDirectory() as td:
        fp = os.path.join(td, "t.rs")
        open(fp, "w").write(src)
        c = subprocess.run(["rustc", "--edition", "2021", "-O", fp, "-o", os.path.join(td, "t")],
                           capture_output=True, text=True, timeout=120)
        if c.returncode != 0:
            errs = [l for l in c.stderr.splitlines() if "error" in l][:2]
            return False, "compile: " + " | ".join(errs)[:120]
        try:
            r = subprocess.run([os.path.join(td, "t")], capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return False, "runtime: timeout/deadlock"
        if r.returncode != 0:
            tail = (r.stderr.strip().splitlines() or ["crash"])[-1]
            return False, "test: " + tail[:110]
        return "OK" in r.stdout, "ok" if "OK" in r.stdout else "no OK marker"

def main():
    for path in sys.argv[1:]:
        R = json.load(open(path))
        print(f"\n=== {path} ===")
        npass = 0
        for r in R:
            if r["id"] not in Q: continue
            ok, detail = grade(r["id"], r.get("content") or "")
            if r.get("error"): ok, detail = False, "ERR " + str(r["error"])[:60]
            npass += bool(ok)
            print(f"  {r['id']} {'PASS' if ok else 'fail'}  wall={r.get('wall',0):.0f}s  {detail[:100]}")
        print(f"  == RUST {npass}/{len([r for r in R if r['id'] in Q])}")

main()
