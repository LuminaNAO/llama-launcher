#!/bin/bash
# parse-llama-log.sh — extract per-request performance stats from a llama.log
# slice. Emits CSV + prints a summary.
#
# Usage: ./parse-llama-log.sh <llama_log_path> [start_line] [end_line] [label]
#        (start/end_line optional — default = full file)

set -uo pipefail

LOG="${1:?Usage: $0 <llama.log> [start_line] [end_line] [label]}"
START="${2:-1}"
END="${3:-$(wc -l < "$LOG")}"
LABEL="${4:-run}"

OUT_DIR="${HOME}/llama-crash-watch"
mkdir -p "$OUT_DIR"
OUT_CSV="$OUT_DIR/llamalog-${LABEL}-$(date +%Y%m%d-%H%M%S).csv"

echo "task_id,prompt_tokens,pp_tok_s,pp_ms,gen_tokens,tg_tok_s,gen_ms,total_tokens,total_ms" >"$OUT_CSV"

# Extract print_timing blocks. Each block spans ~4 lines after "print_timing" marker.
awk -v start="$START" -v end="$END" 'NR >= start && NR <= end {
    if (/print_timing: id +0 \| task ([0-9]+)/) {
        match($0, /task ([0-9]+)/, m); task = m[1]
        pp_ms=0; pp_tok=0; pp_rate=0; tg_ms=0; tg_tok=0; tg_rate=0; tot_ms=0; tot_tok=0
        in_block=1; next
    }
    if (in_block) {
        if (/prompt eval time = +([0-9.]+) ms \/ +([0-9]+) tokens.*([0-9.]+) tokens per second/) {
            match($0, /([0-9.]+) ms \/ +([0-9]+) tokens.* ([0-9.]+) tokens per second/, m)
            pp_ms = m[1]+0; pp_tok = m[2]+0; pp_rate = m[3]+0
        } else if (/eval time = +([0-9.]+) ms \/ +([0-9]+) tokens.*([0-9.]+) tokens per second/ && !/prompt/) {
            match($0, /([0-9.]+) ms \/ +([0-9]+) tokens.* ([0-9.]+) tokens per second/, m)
            tg_ms = m[1]+0; tg_tok = m[2]+0; tg_rate = m[3]+0
        } else if (/total time = +([0-9.]+) ms \/ +([0-9]+) tokens/) {
            match($0, /total time = +([0-9.]+) ms \/ +([0-9]+) tokens/, m)
            tot_ms = m[1]+0; tot_tok = m[2]+0
            printf "%s,%d,%.2f,%d,%d,%.2f,%d,%d,%d\n", task, pp_tok, pp_rate, pp_ms, tg_tok, tg_rate, tg_ms, tot_tok, tot_ms
            in_block = 0
        }
    }
}' "$LOG" >>"$OUT_CSV"

echo "Wrote: $OUT_CSV"
echo

# Summary
awk -F, 'NR>1 {
    n++
    pp[n]=$3+0; tg[n]=$6+0; tot_tok[n]=$8+0; tot_ms[n]=$9+0
    pp_sum+=$3; tg_sum+=$6
}
function pct(arr, n, p,   s,i) { for(i=1;i<=n;i++) s[i]=arr[i]; asort(s); return s[int(p*n+0.5)] }
END {
    if (n==0) { print "no print_timing blocks found"; exit }
    printf "Requests: %d\n\n", n
    printf "Prompt-processing (PP tok/s):\n"
    printf "  min=%.2f  p25=%.2f  p50=%.2f  avg=%.2f  p75=%.2f  max=%.2f\n",
        pct(pp,n,0.01), pct(pp,n,0.25), pct(pp,n,0.5), pp_sum/n, pct(pp,n,0.75), pct(pp,n,0.99)
    printf "\nToken-generation (TG tok/s):\n"
    printf "  min=%.2f  p25=%.2f  p50=%.2f  avg=%.2f  p75=%.2f  max=%.2f\n",
        pct(tg,n,0.01), pct(tg,n,0.25), pct(tg,n,0.5), tg_sum/n, pct(tg,n,0.75), pct(tg,n,0.99)
    printf "\nRequest duration:\n"
    printf "  median=%.1fs  p95=%.1fs  max=%.1fs\n",
        pct(tot_ms,n,0.5)/1000, pct(tot_ms,n,0.95)/1000, pct(tot_ms,n,0.99)/1000
    printf "\nContext size (total tokens):\n"
    printf "  p50=%d  p95=%d  max=%d\n", pct(tot_tok,n,0.5), pct(tot_tok,n,0.95), pct(tot_tok,n,0.99)
}' "$OUT_CSV"
