#!/bin/bash
# GPU Utilization Monitor
# Logs GPU usage at regular intervals during stress tests.
# Detects extended idle periods and reports them.
#
# Usage:
#   ./gpu-monitor.sh [interval_seconds] [logfile]
#   ./gpu-monitor.sh start       # start in background, prints PID
#   ./gpu-monitor.sh stop        # stop background monitor
#   ./gpu-monitor.sh report [logfile]  # analyze a log file
#
# Examples:
#   ./gpu-monitor.sh start                          # 2s interval, default log
#   ./gpu-monitor.sh report /tmp/gpu-util.log       # analyze log
#   ./gpu-monitor.sh 1 /tmp/my-gpu.log              # foreground, 1s interval

INTERVAL="${1:-2}"
LOGFILE="${2:-/tmp/gpu-util.log}"
PIDFILE="/tmp/gpu-monitor.pid"
IDLE_THRESHOLD=5  # percent — below this is "idle"

case "$1" in
    start)
        LOGFILE="${2:-/tmp/gpu-util.log}"
        INTERVAL="${3:-2}"
        > "$LOGFILE"
        nohup bash -c "
            while true; do
                ts=\$(date +%H:%M:%S)
                use=\$(rocm-smi --showuse 2>/dev/null | grep 'GPU use' | head -1 | grep -oP '\d+')
                [ -z \"\$use\" ] && use=\$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
                [ -z \"\$use\" ] && use=0
                echo \"\$ts \$use\" >> \"$LOGFILE\"
                sleep $INTERVAL
            done
        " > /dev/null 2>&1 &
        echo $! > "$PIDFILE"
        echo "GPU monitor started (PID: $(cat $PIDFILE), log: $LOGFILE, interval: ${INTERVAL}s)"
        ;;
    stop)
        if [ -f "$PIDFILE" ]; then
            kill $(cat "$PIDFILE") 2>/dev/null
            rm -f "$PIDFILE"
            echo "GPU monitor stopped"
        else
            echo "No monitor running"
        fi
        ;;
    report)
        LOGFILE="${2:-/tmp/gpu-util.log}"
        if [ ! -f "$LOGFILE" ]; then
            echo "Log file not found: $LOGFILE"
            exit 1
        fi

        total=0; idle_count=0; max_use=0; sum_use=0
        idle_start=""; idle_periods=0; max_idle_duration=0
        prev_time=""

        while read -r ts use; do
            [ -z "$use" ] && continue
            use_int=${use%%.*}
            total=$((total + 1))
            sum_use=$((sum_use + use_int))
            [ "$use_int" -gt "$max_use" ] && max_use=$use_int

            if [ "$use_int" -le "$IDLE_THRESHOLD" ]; then
                idle_count=$((idle_count + 1))
                [ -z "$idle_start" ] && idle_start="$ts"
            else
                if [ -n "$idle_start" ]; then
                    idle_periods=$((idle_periods + 1))
                    idle_start=""
                fi
            fi
        done < "$LOGFILE"

        if [ "$total" -eq 0 ]; then
            echo "No data in log"
            exit 1
        fi

        avg=$((sum_use / total))
        idle_pct=$((idle_count * 100 / total))
        first_ts=$(head -1 "$LOGFILE" | cut -d' ' -f1)
        last_ts=$(tail -1 "$LOGFILE" | cut -d' ' -f1)

        echo "GPU Utilization Report: $LOGFILE"
        echo "─────────────────────────────────"
        echo "Period:       $first_ts — $last_ts"
        echo "Samples:      $total"
        echo "Avg usage:    ${avg}%"
        echo "Peak usage:   ${max_use}%"
        echo "Idle samples: $idle_count ($idle_pct%)"
        echo "Idle periods: $idle_periods (threshold: <=${IDLE_THRESHOLD}%)"
        ;;
    *)
        # Foreground mode
        echo "Monitoring GPU (interval: ${INTERVAL}s, log: ${LOGFILE})"
        echo "Press Ctrl+C to stop"
        > "$LOGFILE"
        while true; do
            ts=$(date +%H:%M:%S)
            use=$(rocm-smi --showuse 2>/dev/null | grep 'GPU use' | head -1 | grep -oP '\d+')
            [ -z "$use" ] && use=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
            [ -z "$use" ] && use=0
            echo "$ts $use" | tee -a "$LOGFILE"
            sleep "$INTERVAL"
        done
        ;;
esac
