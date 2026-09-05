#!/bin/bash
set -uo pipefail
cd ~/code/llama-launcher
L=./llama-server-launcher.sh; MODEL=/usr/local/share/llama.cpp/models/Qwen3.8-27B-GSQ-RCO/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf
BIN=builds/cuda/bin/llama-perplexity; CORPUS=~/.cache/llama-eval/wiki.test.raw
$L stop >/dev/null 2>&1; sleep 3
# PPL at >=128k is NOT run here: llama-perplexity keeps an n_ctx x n_vocab float
# logits buffer on the host (~80 GB at 128k, ~160 GB at 256k on this vocab) and
# gets OOM-killed on a 62 GB host (2026-09-05, took btop with it). Use
# ppl_kv_ab.sh for 32k/64k; use the needle test below for deeper context.
launch() { $L stop >/dev/null 2>&1; sleep 3; setsid nohup bash $L --build cuda --model $MODEL --tune "$1" --log --proxy --no-hdd-cache --no-vision </dev/null >/dev/null 2>&1 & disown
  for i in $(seq 1 240); do curl -sf -m 2 http://127.0.0.1:40802/health 2>/dev/null | grep -q ok && { sleep 2; return 0; }; sleep 1; done; return 1; }
echo; echo "=== NEEDLE @~200k: q4_0 (v3) ==="; launch gsq3s-262k-v1 && (cd eval-harness-2026-08 && python3 needle_kv_ab.py q4_0)
echo; echo "=== NEEDLE @~200k: q8_0 (needs a q8_0 variant tune; v2 was folded into v1 2026-09-05) ==="; launch gsq3s-262k-v2 2>/dev/null && (cd eval-harness-2026-08 && python3 needle_kv_ab.py q8_0)
echo; echo "=== restore v3 ==="; $L stop >/dev/null 2>&1; sleep 3; setsid nohup bash $L --build cuda --model $MODEL --tune gsq3s-262k-v1 --log --proxy --hdd-cache --vision 1 </dev/null >/dev/null 2>&1 & disown
for i in $(seq 1 180); do curl -sf -m 2 -H 'Authorization: Bearer ollama-local' http://127.0.0.1:40801/props >/dev/null 2>&1 && { echo "v3 back after ${i}s"; break; }; sleep 1; done
echo DONE
