#!/bin/bash
# Validate the LSCKPT4 drafter-fingerprint fix: sidecars written under one drafter
# must be ignored (not crash) under another; same-drafter round trips must still
# restore checkpoints; a forged fingerprint must hit the non-fatal fallback.
# Needs the GPU free (production stopped). Runs on port 40912, own slot dir.
set -u
BIN=$HOME/code/llama-launcher/builds/cuda/bin/llama-server
M=/usr/local/share/llama.cpp/models/Qwen3.8-27B-GSQ-RCO/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf
DRAFT=/usr/local/share/llama.cpp/models/Qwen3.8-27B-DFlash2/Qwen3.8-27B-DFlash2-Q8_0.gguf
TMPL=$HOME/code/llama-launcher/model-configs/qwen38-froggeric-fixed.jinja
T=/usr/local/share/llama.cpp/llama-slots-test/sidecar-drafter; rm -rf "$T"; mkdir -p "$T"
OUT=${OUT:-$HOME/code/llama-launcher/eval-harness-2026-08}; LOGDIR=${LOGDIR:-${TMPDIR:-/tmp}/sidecar-drafter-test}; mkdir -p "$LOGDIR"
HDR=$OUT/sidecar_hdr.py; PORT=40912; URL=http://127.0.0.1:$PORT
COMMON=(-m "$M" -ngl 999 -c 65536 -fa on --temp 0 --threads 16 --host 127.0.0.1 --port $PORT --api-key ollama-local --jinja --parallel 1 --kv-unified --cache-ram 0 -ctk q4_0 -ctv q4_0 --checkpoint-min-step 512 --ctx-checkpoints 16 --slot-save-max-checkpoints 16 --seed 1320 --slot-save-path "$T" -b 2048 -ub 512 --min-p 0 --chat-template-file "$TMPL" --reasoning-format deepseek --chat-template-kwargs '{"reasoning_effort":"low"}' --load-mode dio)
MTP=(--spec-type draft-mtp --spec-draft-n-max 3); DFL=(--spec-type draft-dflash -md "$DRAFT" --spec-draft-n-max 5)
PID=""; LOG=""
start() { LOG=$LOGDIR/sidecar-test-$1.log; "$BIN" "${COMMON[@]}" "${@:2}" > "$LOG" 2>&1 & PID=$!; for i in $(seq 1 60); do curl -s -m 2 $URL/health 2>/dev/null | grep -q ok && return 0; sleep 2; done; echo "server $1 failed to start"; tail -5 "$LOG"; exit 1; }
stop()  { kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1; }
alive() { kill -0 $PID 2>/dev/null && echo "alive" || echo "DEAD"; }
DOC=$(python3 -c "
import random; r=random.Random(11); w='ledger invoice vendor payment credit debit account balance transfer receipt audit quarter fiscal branch depot warehouse consignment freight tariff surcharge rebate'.split()
print(' '.join((r.choice(w) if r.random()<0.8 else str(r.randint(1,99999))) for _ in range(3600)))")
DOC2="${DOC:0:9000}EDITED-HERE-${DOC:9000}"   # divergence at ~40% of the prompt
ask() { # $1 doc, $2 tag -> prints n_prompt/n_cached/answer head
  local body; body=$(python3 -c "import json,sys; print(json.dumps({'model':'local','max_tokens':40,'messages':[{'role':'user','content':'Document:\n'+sys.argv[1]+'\n\nReply with the first two words of the document only.'}]}))" "$1")
  curl -s -m 600 http://127.0.0.1:40912/v1/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer ollama-local' -d "$body" | python3 -c "
import json,sys; d=json.load(sys.stdin); t=d.get('timings',{}); u=d.get('usage',{})
print('  [$2] prompt_n=%s cached=%s tg=%s answer=%r' % (t.get('prompt_n'), u.get('prompt_tokens_details',{}).get('cached_tokens', t.get('cache_n')), t.get('predicted_n'), (d['choices'][0]['message'].get('content') or '')[:40]))" 2>/dev/null || echo "  [$2] REQUEST FAILED (server $(alive))"
}
slot() { curl -s -m 600 "http://127.0.0.1:40912/slots/0?action=$1" -H 'Content-Type: application/json' -H 'Authorization: Bearer ollama-local' -d "{\"filename\":\"$2\"}" | cut -c1-160; echo; }
grepl() { grep -a -E "$1" "$LOG" | tail -${2:-1} | cut -c1-200; }

echo "=== 1. MTP: run, save, inspect header"; start mtp "${MTP[@]}"
ask "$DOC" mtp-first; slot save t-mtp.bin; grepl 'context checkpoint'; python3 $HDR show $T/t-mtp.bin.ckpt
echo "=== 1b. MTP same-drafter round trip: restore + divergent prompt (expect checkpoint restore, no crash)"
slot restore t-mtp.bin; grepl 'restored .* context checkpoint'; ask "$DOC2" mtp-diverge; echo "  server: $(alive)"; stop

echo "=== 2. DFLASH: restore MTP sidecar (expect fingerprint warning, sidecar ignored, no crash)"; start dfl "${DFL[@]}"
slot restore t-mtp.bin; grepl 'written by drafter|restored .* context checkpoint'; ask "$DOC2" dfl-after-mtp-restore; echo "  server: $(alive)"
echo "=== 3. DFLASH same-drafter round trip"; ask "$DOC" dfl-first; slot save t-dfl.bin; python3 $HDR show $T/t-dfl.bin.ckpt
slot restore t-dfl.bin; grepl 'restored .* context checkpoint'; ask "$DOC2" dfl-diverge; echo "  server: $(alive)"
echo "=== 4. DFLASH: forged fingerprint on the MTP sidecar (expect non-fatal 'restore failed ... re-processing', no crash)"
FP=$(python3 $HDR show $T/t-dfl.bin.ckpt | sed -n "s/.*fingerprint='\(.*\)' count.*/\1/p"); cp $T/t-mtp.bin $T/t-forged.bin; python3 $HDR patch $T/t-mtp.bin.ckpt $T/t-forged.bin.ckpt "$FP"
slot restore t-forged.bin; grepl 'restored .* context checkpoint'; ask "$DOC2" dfl-forged-diverge; grepl 'checkpoint restore failed|size mismatch' 3; echo "  server: $(alive)"
echo "=== 5. DFLASH: legacy LSCKPT3 sidecar (expect 'expected LSCKPT4, ignoring')"
cp /usr/local/share/llama.cpp/llama-slots/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp/c2669a4a8995-6b09e4aa8a61.bin $T/t-old.bin; cp /usr/local/share/llama.cpp/llama-slots/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp/c2669a4a8995-6b09e4aa8a61.bin.ckpt $T/t-old.bin.ckpt
slot restore t-old.bin; grepl 'expected LSCKPT4'; echo "  server: $(alive)"; stop
echo "=== DONE"
