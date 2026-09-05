#!/bin/bash
# ppl_kv_ab.sh — KV-cache quant A/B on one GGUF: perplexity (wikitext-2 test) for
# each KV type at each context size. Usage: ppl_kv_ab.sh <model.gguf> [label]
# Needs the GPU to itself (stop the server first). Results -> eval-harness-2026-08/ppl_<label>.json
set -uo pipefail
MODEL=$1; LABEL=${2:-$(basename "$MODEL" .gguf)}
BIN=~/code/llama-launcher/builds/cuda/bin/llama-perplexity
CORPUS=~/.cache/llama-eval/wiki.test.raw
OUT=~/code/llama-launcher/eval-harness-2026-08/ppl_${LABEL}.json
echo "{" > "$OUT"; first=1
for kv in q4_0 q8_0 f16; do
  for c in 32768 65536; do
    chunks=$(( c == 32768 ? 8 : 4 ))
    t0=$SECONDS
    line=$("$BIN" -m "$MODEL" -f "$CORPUS" -c "$c" -b 2048 -ub 512 -ngl 999 -fa on -ctk "$kv" -ctv "$kv" --chunks "$chunks" 2>&1 | grep -E 'Final estimate' | tail -1)
    ppl=$(sed -nE 's/.*PPL = ([0-9.]+) \+\/- ([0-9.]+).*/\1/p' <<<"$line"); err=$(sed -nE 's/.*PPL = ([0-9.]+) \+\/- ([0-9.]+).*/\2/p' <<<"$line")
    printf '[%s] kv=%-5s c=%-6s chunks=%d  PPL=%s +/- %s  (%ds)\n' "$(date +%H:%M:%S)" "$kv" "$c" "$chunks" "${ppl:-FAIL}" "${err:-?}" $((SECONDS-t0))
    [[ $first -eq 0 ]] && echo "," >> "$OUT"; first=0
    printf '  "%s_c%s": {"ppl": %s, "err": %s, "chunks": %d}' "$kv" "$c" "${ppl:-null}" "${err:-null}" "$chunks" >> "$OUT"
  done
done
echo; echo "}" >> "$OUT"; echo "wrote $OUT"
