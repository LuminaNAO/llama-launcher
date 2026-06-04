#!/bin/bash
# metrics-sampler.sh — CSV sampler for driver runs. Captures memory + GPU state
# every INTERVAL seconds. Run alongside crash-watch for full visibility.
#
# Usage: ./metrics-sampler.sh start [interval_sec=15] [label]
#        ./metrics-sampler.sh stop
#        ./metrics-sampler.sh parse <csv_file>   # summary stats
#
# Output: $HOME/llama-crash-watch/metrics-<label>-<timestamp>.csv

set -uo pipefail

LOG_DIR="${CRASH_WATCH_DIR:-$HOME/llama-crash-watch}"
PID_FILE="$LOG_DIR/metrics-sampler.pid"
mkdir -p "$LOG_DIR"

usage() {
    echo "Usage: $0 {start|stop|run|parse} [args]" >&2
    exit 2
}

sample_loop() {
    local interval="${1:-15}"
    local label="${2:-run}"
    local log_file="$LOG_DIR/metrics-${label}-$(date +%Y%m%d-%H%M%S).csv"

    echo "# metrics-sampler started $(date -Iseconds) interval=${interval}s label=$label" >"$log_file"
    echo "ts,mem_free_gb,mem_avail_gb,anon_gb,swap_used_gb,zswap_gb,llama_rss_gb,llama_vmswap_gb,llama_vmlck_gb,psi_some_10,psi_some_60,psi_full_10,psi_full_60,gpu_power_w,gpu_sclk_mhz,gpu_use_pct" >>"$log_file"

    while :; do
        local ts mem_free mem_avail anon swap_used zswap llama_rss llama_vmswap llama_vmlck
        ts=$(date +%s)
        mem_free=$(awk '/MemFree/ {printf "%.2f", $2/1048576}' /proc/meminfo)
        mem_avail=$(awk '/MemAvailable/ {printf "%.2f", $2/1048576}' /proc/meminfo)
        anon=$(awk '/AnonPages/ {printf "%.2f", $2/1048576}' /proc/meminfo)
        swap_used=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf "%.2f",(t-f)/1048576}' /proc/meminfo)
        zswap=$(awk '/Zswap:/ && !/Max/ {printf "%.2f", $2/1048576}' /proc/meminfo)

        local pid
        pid=$(pgrep -x llama-server | head -1)
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            llama_rss=$(awk '/VmRSS/ {printf "%.2f", $2/1048576}' "/proc/$pid/status" 2>/dev/null || echo "-")
            llama_vmswap=$(awk '/VmSwap/ {printf "%.2f", $2/1048576}' "/proc/$pid/status" 2>/dev/null || echo "-")
            llama_vmlck=$(awk '/VmLck/ {printf "%.2f", $2/1048576}' "/proc/$pid/status" 2>/dev/null || echo "-")
        else
            llama_rss="-"; llama_vmswap="-"; llama_vmlck="-"
        fi

        # PSI — some/full avg10 + avg60
        local psi_some_10 psi_some_60 psi_full_10 psi_full_60
        psi_some_10=$(awk '/^some/ {gsub("avg10=",""); print $2; exit}' /proc/pressure/memory)
        psi_some_60=$(awk '/^some/ {gsub("avg60=",""); print $3; exit}' /proc/pressure/memory)
        psi_full_10=$(awk '/^full/ {gsub("avg10=",""); print $2; exit}' /proc/pressure/memory)
        psi_full_60=$(awk '/^full/ {gsub("avg60=",""); print $3; exit}' /proc/pressure/memory)

        # GPU
        local gpu_power gpu_sclk gpu_use
        gpu_power=$(rocm-smi -P 2>/dev/null | grep -oP 'Package Power \(W\): \K[0-9]+\.[0-9]+' | head -1)
        gpu_sclk=$(rocm-smi --showclocks 2>/dev/null | grep -oP 'sclk clock level.*\(\K[0-9]+' | head -1)
        gpu_use=$(rocm-smi --showuse 2>/dev/null | grep -oP 'GPU use \(%\): \K[0-9]+' | head -1)
        : "${gpu_power:=-}"; : "${gpu_sclk:=-}"; : "${gpu_use:=-}"

        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "$ts" "$mem_free" "$mem_avail" "$anon" "$swap_used" "$zswap" \
            "$llama_rss" "$llama_vmswap" "$llama_vmlck" \
            "$psi_some_10" "$psi_some_60" "$psi_full_10" "$psi_full_60" \
            "$gpu_power" "$gpu_sclk" "$gpu_use" >>"$log_file"
        sync -d "$log_file" 2>/dev/null || true
        sleep "$interval"
    done
}

parse_csv() {
    local f="$1"
    [[ -f "$f" ]] || { echo "No file: $f" >&2; exit 1; }
    awk -F, 'BEGIN{n=0} NR>2 && $1 ~ /^[0-9]+$/ {
        n++
        mem_free_sum+=$2; mem_free[n]=$2+0
        anon_sum+=$4; anon[n]=$4+0
        swap_sum+=$5; swap[n]=$5+0
        zswap_sum+=$6; zswap[n]=$6+0
        if ($8 ~ /^[0-9]/) { llswap_sum+=$8; llswap[n]=$8+0 } else { llswap[n]=0 }
        if ($11 ~ /^[0-9]/) { psi_some_60_sum+=$11; psi_some_60[n]=$11+0 }
        if ($13 ~ /^[0-9]/) { psi_full_60_sum+=$13; psi_full_60[n]=$13+0 }
        if ($14 ~ /^[0-9]/) { power_sum+=$14; power[n]=$14+0 }
    }
    function pct(arr, n, p,   sorted, i) {
        for (i=1;i<=n;i++) sorted[i]=arr[i]
        asort(sorted)
        return sorted[int(p*n+0.5)]
    }
    END {
        if (n==0) { print "no samples"; exit }
        printf "samples: %d (%d min duration @ ~15s)\n", n, n*15/60
        printf "\nMemory:\n"
        printf "  mem_free:      avg=%.1fG  p50=%.1fG  p95=%.1fG  min=%.1fG\n", mem_free_sum/n, pct(mem_free,n,0.5), pct(mem_free,n,0.95), pct(mem_free,n,0.01)
        printf "  anon pages:    avg=%.1fG  p50=%.1fG  p95=%.1fG\n", anon_sum/n, pct(anon,n,0.5), pct(anon,n,0.95)
        printf "  swap used:     avg=%.1fG  p50=%.1fG  p95=%.1fG\n", swap_sum/n, pct(swap,n,0.5), pct(swap,n,0.95)
        printf "  zswap:         avg=%.2fG  p95=%.2fG\n", zswap_sum/n, pct(zswap,n,0.95)
        printf "  llama VmSwap:  avg=%.2fG  p95=%.2fG  max=%.2fG\n", llswap_sum/n, pct(llswap,n,0.95), pct(llswap,n,0.99)
        printf "\nPSI stall:\n"
        printf "  some avg60:    mean=%.3f%%  p95=%.3f%%\n", psi_some_60_sum/n, pct(psi_some_60,n,0.95)
        printf "  full avg60:    mean=%.3f%%  p95=%.3f%%\n", psi_full_60_sum/n, pct(psi_full_60,n,0.95)
        printf "\nGPU:\n"
        printf "  power:         avg=%.1fW  p50=%.1fW  p95=%.1fW\n", power_sum/n, pct(power,n,0.5), pct(power,n,0.95)
    }' "$f"
}

case "${1:-}" in
    start)
        shift
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "metrics-sampler already running (pid $(cat "$PID_FILE"))" >&2
            exit 1
        fi
        export LOG_DIR
        nohup bash -c "$(declare -f sample_loop); sample_loop $*" >"$LOG_DIR/metrics-sampler.stderr" 2>&1 &
        echo $! >"$PID_FILE"
        echo "metrics-sampler started pid=$(cat "$PID_FILE") log_dir=$LOG_DIR"
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            local_pid=$(cat "$PID_FILE")
            kill "$local_pid" 2>/dev/null && echo "stopped pid=$local_pid" || echo "stale pidfile" >&2
            rm -f "$PID_FILE"
        else
            echo "no pidfile" >&2
        fi
        ;;
    run)
        shift
        sample_loop "$@"
        ;;
    parse)
        shift
        parse_csv "${1:?Usage: $0 parse <csv_file>}"
        ;;
    ""|-h|--help)
        usage
        ;;
    *)
        usage
        ;;
esac
