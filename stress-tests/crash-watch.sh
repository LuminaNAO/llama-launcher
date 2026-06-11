#!/bin/bash
# crash-watch.sh — Heartbeat logger for catching llama-server hangs.
#
# Writes a timestamped sample every INTERVAL seconds with load, free RAM,
# swap usage, llama-server RSS/state/VmLck, /health returncode, and rocm-smi
# one-line status. Uses fdatasync on every line so the last heartbeat
# survives a hard GPU hang or power cut.
#
# Usage:
#   ./crash-watch.sh start [PORT] [INTERVAL]   # background
#   ./crash-watch.sh stop                       # kill running instance
#   ./crash-watch.sh run [PORT] [INTERVAL]     # foreground

set -uo pipefail

LOG_DIR="${CRASH_WATCH_DIR:-$HOME/llama-crash-watch}"
PID_FILE="$LOG_DIR/crash-watch.pid"
mkdir -p "$LOG_DIR"

usage() {
    echo "Usage: $0 {start|stop|run} [port] [interval]" >&2
    exit 2
}

heartbeat_loop() {
    local port="${1:-40801}"
    local interval="${2:-2}"
    local log_file
    log_file="$LOG_DIR/heartbeat-$(date +%Y%m%d-%H%M%S).log"

    echo "# crash-watch started $(date -Iseconds) port=$port interval=${interval}s" >"$log_file"
    echo "# fields: ts uptime load1 mem_free_gb swap_used_gb pid rss_gb vmlck_gb state health gpu_util gpu_temp vram_used_mb gpu_power_w gpu_sclk_mhz" >>"$log_file"

    while :; do
        local ts uptime load1 mem_free_gb swap_used_gb pid rss_gb vmlck_gb state health gpu_util gpu_temp vram_used_mb
        ts=$(date +%s.%N)
        uptime=$(awk '{print $1}' /proc/uptime)
        load1=$(awk '{print $1}' /proc/loadavg)

        # Memory (GB, 1 decimal)
        mem_free_gb=$(awk '/MemAvailable/ {printf "%.1f", $2/1048576}' /proc/meminfo)
        swap_used_gb=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf "%.1f",(t-f)/1048576}' /proc/meminfo)

        # llama-server
        pid=$(pgrep -x llama-server | head -1)
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            rss_gb=$(awk '/VmRSS/ {printf "%.1f", $2/1048576}' "/proc/$pid/status" 2>/dev/null || echo "-")
            vmlck_gb=$(awk '/VmLck/ {printf "%.1f", $2/1048576}' "/proc/$pid/status" 2>/dev/null || echo "-")
            state=$(awk '/^State:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "-")
        else
            pid="-"; rss_gb="-"; vmlck_gb="-"; state="-"
        fi

        # Health probe — very short timeout so a stuck server shows up as FAIL fast
        if curl -sf --max-time 1 "http://localhost:${port}/health" >/dev/null 2>&1; then
            health="OK"
        else
            health="FAIL"
        fi

        # GPU — try rocm-smi first, fall back to '-'
        if command -v rocm-smi >/dev/null 2>&1; then
            local smi
            smi=$(rocm-smi --showuse --showtemp --showmeminfo vram --csv 2>/dev/null | grep -v '^device' | head -1)
            # Best-effort parse. Columns vary by rocm version, so use awk-friendly fallbacks.
            gpu_util=$(echo "$smi" | awk -F, '{for(i=1;i<=NF;i++) if($i ~ /%/) {print $i; exit}}')
            gpu_temp=$(rocm-smi -t 2>/dev/null | grep -oP 'Temperature.*\K[0-9]+\.[0-9]+' | head -1)
            vram_used_mb=$(rocm-smi --showmeminfo vram 2>/dev/null | grep -oP 'Used Memory.*\K[0-9]+' | head -1)
            vram_used_mb=${vram_used_mb:+$((vram_used_mb / 1048576))}
            gpu_power_w=$(rocm-smi -P 2>/dev/null | grep -oP 'Package Power \(W\): \K[0-9]+\.[0-9]+' | head -1)
            gpu_sclk_mhz=$(rocm-smi --showclocks 2>/dev/null | grep -oP 'sclk clock level.*\(\K[0-9]+' | head -1)
            gpu_util=${gpu_util:--}; gpu_temp=${gpu_temp:--}; vram_used_mb=${vram_used_mb:--}
            gpu_power_w=${gpu_power_w:--}; gpu_sclk_mhz=${gpu_sclk_mhz:--}
        else
            gpu_util="-"; gpu_temp="-"; vram_used_mb="-"; gpu_power_w="-"; gpu_sclk_mhz="-"
        fi

        printf "%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n" \
            "$ts" "$uptime" "$load1" "$mem_free_gb" "$swap_used_gb" \
            "$pid" "$rss_gb" "$vmlck_gb" "$state" "$health" \
            "$gpu_util" "$gpu_temp" "$vram_used_mb" \
            "$gpu_power_w" "$gpu_sclk_mhz" >>"$log_file"
        # Force flush — on a hard hang, the last un-flushed line is lost.
        sync -d "$log_file" 2>/dev/null || true

        sleep "$interval"
    done
}

case "${1:-}" in
    start)
        shift
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "crash-watch already running (pid $(cat "$PID_FILE"))" >&2
            exit 1
        fi
        export LOG_DIR
        nohup bash -c "$(declare -f heartbeat_loop); heartbeat_loop $*" >"$LOG_DIR/crash-watch.stderr" 2>&1 &
        echo $! >"$PID_FILE"
        echo "crash-watch started pid=$(cat "$PID_FILE") log_dir=$LOG_DIR"
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            pid=$(cat "$PID_FILE")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" && echo "stopped pid=$pid"
            else
                echo "stale pidfile, nothing running" >&2
            fi
            rm -f "$PID_FILE"
        else
            echo "no pidfile" >&2
        fi
        ;;
    run)
        shift
        heartbeat_loop "$@"
        ;;
    ""|-h|--help)
        usage
        ;;
    *)
        usage
        ;;
esac
