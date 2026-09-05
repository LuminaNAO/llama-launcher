#!/usr/bin/env python3
"""Two interleaved OpenClaw-style sessions against the merged (shrunk) build.
Exercises: save-on-switch, restore, checkpoint sidecar round-trip, divergence
rollback, MTP, and media persistence through upstream's packed slot format."""
import base64, json, os, time, urllib.request

BASE = "http://127.0.0.1:40801/v1/messages"
LOG  = os.path.expanduser("~/code/llama-launcher/llama.log")

doc = open("longdoc_100k.txt").read()
# ~8k-token chunks of ledger text as conversation filler
CH = [doc[i:i+32000] for i in range(0, 320000, 32000)]
img_b64 = base64.b64encode(open("vistest.png","rb").read()).decode()

A = "aaaa1111bbbb-2222cccc3333"
B = "dddd4444eeee-5555ffff6666"

hist = {A: [], B: []}
logpos = [0]

def log_tail():
    import os
    sz = os.path.getsize(LOG)
    with open(LOG, 'rb') as f:
        f.seek(logpos[0])
        new = f.read(sz - logpos[0]).decode(errors='replace')
    logpos[0] = sz
    keep = []
    for l in new.splitlines():
        if any(k in l for k in ("HDD CACHE", "context checkpoint", "prompt eval time",
                                "draft acceptance", "erasing", "restored")):
            keep.append(l[-160:])
    return keep

def turn(sess, content, label, max_tokens=200):
    hist[sess].append({"role":"user","content":content})
    body = {"model":"local","max_tokens":max_tokens,"messages":hist[sess]}
    req = urllib.request.Request(BASE, data=json.dumps(body).encode(),
        headers={"Content-Type":"application/json","x-api-key":"ollama-local",
                 "anthropic-version":"2023-06-01","x-openclaw-session-id":sess})
    t0=time.time()
    with urllib.request.urlopen(req, timeout=900) as r: d=json.load(r)
    wall=time.time()-t0
    txt = "".join(b.get("text","") for b in (d.get("content") or []) if b.get("type")=="text")
    hist[sess].append({"role":"assistant","content":txt or "(tool)"})
    print(f"\n### {label} [{'A' if sess==A else 'B'}] wall={wall:5.1f}s in={d.get('usage',{}).get('input_tokens')} out={d.get('usage',{}).get('output_tokens')} | {txt[:80]!r}")
    for l in log_tail(): print("   |", l)
    return txt

import os
logpos[0] = os.path.getsize(LOG)

# Build session A past checkpoint-min-step, interleaved with B (each switch = save+restore)
turn(A, "Here is part 1 of a ledger document:\n" + CH[0] + "\nAcknowledge with the first vendor name you see.", "A1 build ctx")
turn(A, "Part 2:\n" + CH[1] + "\nAcknowledge with any code from this part.", "A2 build ctx")
turn(B, "You are session B. Here is a document part:\n" + CH[5] + "\nName one vendor mentioned.", "B1 build ctx (switch A->B: A must save)")
turn(A, "Part 3:\n" + CH[2] + "\nHow many parts have I sent so far? Answer with the number.", "A3 (switch B->A: A restore + continue)")
turn(B, "More text:\n" + CH[6] + "\nAcknowledge with one item type mentioned.", "B2 (switch: B restore)")
turn(A, [{"type":"image","source":{"type":"base64","media_type":"image/png","data":img_b64}},
         {"type":"text","text":"Also, what shapes are in this image? List the colors."}], "A4 image turn (media into KV)")
turn(B, "Final:\n" + CH[7] + "\nSession B: reply DONE-B.", "B3 (switch: A saves WITH media)")
turn(A, "What was the text written in the image I sent you earlier?", "A5 (A restore WITH media; memory of image)")

# Divergence test: edit A's SECOND user turn, forcing rollback into checkpoint range
hist[A][2]["content"] = "Part 2 (EDITED):\n" + CH[3] + "\nAcknowledge the edit."
hist[A] = hist[A][:3]  # truncate history after edited turn
turn(A, "", "A6 divergence (edited turn 2: expect checkpoint rollback, partial re-prefill)") if False else None
# re-send truncated+edited history as a fresh continuation
hist[A].append({"role":"assistant","content":"(pending)"}); hist[A].pop()
turn(A, "After that edited part, summarize the last vendor you saw in one line.", "A6 divergence")

print("\n=== gauntlet complete ===")
