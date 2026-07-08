#!/bin/bash
# bench-batch-sizes.sh — Test different -b (batch size) values
# Restarts server between each test and logs memory usage

set -euo pipefail

UTIL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
case "$UTIL_DIR" in
    /usr/bin|/usr/local/bin|/bin)
        # Packaged install: state lives in the launcher data dir
        ROOT_DIR="${LLAMA_LAUNCHER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/llama-launcher}"
        LAUNCHER_CMD=(llama-launcher)
        ;;
    *)
        ROOT_DIR="$(dirname "$UTIL_DIR")"
        LAUNCHER_CMD=(bash "$ROOT_DIR/llama-server-launcher.sh")
        ;;
esac
MODEL="/mnt/storage/models/Qwen3.5-35B-A3B-H-v2-Q8_0.gguf"
BUILD="vulkan"
RESULTS_DIR="$UTIL_DIR/benchmark-results"
SUMMARY_FILE="$RESULTS_DIR/batch-size-summary-$(date +%Y%m%d-%H%M%S).txt"

GTT_SYSFS=$(ls /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | head -1)

get_gtt_mb() {
    echo $(( $(cat "$GTT_SYSFS") / 1024 / 1024 ))
}

mkdir -p "$RESULTS_DIR"

echo "=== Batch Size Benchmark ===" | tee "$SUMMARY_FILE"
echo "Date: $(date -Iseconds)" | tee -a "$SUMMARY_FILE"
echo "Model: $(basename $MODEL)" | tee -a "$SUMMARY_FILE"
echo "" | tee -a "$SUMMARY_FILE"

for BATCH_SIZE in 512 1024 2048 4096 8192; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$SUMMARY_FILE"
    echo "Testing -b $BATCH_SIZE" | tee -a "$SUMMARY_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$SUMMARY_FILE"

    # Kill any running server
    pkill -9 -f llama-server 2>/dev/null || true
    sleep 3
    # Make sure it's really dead
    while pgrep -f llama-server > /dev/null 2>&1; do
        pkill -9 -f llama-server 2>/dev/null || true
        sleep 2
    done

    PRE_GTT=$(get_gtt_mb)
    echo "  Pre-launch GTT: ${PRE_GTT} MB" | tee -a "$SUMMARY_FILE"

    # Clear log and launch server with this batch size
    > "$HOME/llama.log"

    # Build the launch command — inject -b via EXTRA_ARGS
    export EXTRA_ARGS="-b $BATCH_SIZE"
    nohup "${LAUNCHER_CMD[@]}" \
        --build "$BUILD" \
        --model "$MODEL" \
        > /dev/null 2>&1 &

    # Wait for server to come up
    echo "  Waiting for server..." | tee -a "$SUMMARY_FILE"
    for i in $(seq 1 120); do
        if curl -sf "http://localhost:40801/health" > /dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    if ! curl -sf "http://localhost:40801/health" > /dev/null 2>&1; then
        echo "  ❌ Server failed to start with -b $BATCH_SIZE" | tee -a "$SUMMARY_FILE"
        continue
    fi

    IDLE_GTT=$(get_gtt_mb)
    echo "  Idle GTT: ${IDLE_GTT} MB" | tee -a "$SUMMARY_FILE"

    # Verify batch size
    ACTUAL_BATCH=$(grep "n_batch" "$HOME/llama.log" | head -1 || echo "unknown")
    echo "  Server config: $ACTUAL_BATCH" | tee -a "$SUMMARY_FILE"

    # Run benchmark
    LABEL="vulkan-b${BATCH_SIZE}"
    echo "  Running benchmark..." | tee -a "$SUMMARY_FILE"
    bash "$UTIL_DIR/benchmark.sh" "$LABEL" 2>&1 | tee -a "$SUMMARY_FILE"

    POST_GTT=$(get_gtt_mb)
    echo "  Post-benchmark GTT: ${POST_GTT} MB (delta: +$((POST_GTT - IDLE_GTT)) MB from idle)" | tee -a "$SUMMARY_FILE"
    echo "" | tee -a "$SUMMARY_FILE"
done

# Kill server after all tests
pkill -9 -f llama-server 2>/dev/null || true

echo "" | tee -a "$SUMMARY_FILE"
echo "=== All batch size tests complete ===" | tee -a "$SUMMARY_FILE"
echo "Summary: $SUMMARY_FILE" | tee -a "$SUMMARY_FILE"
