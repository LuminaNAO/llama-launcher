#!/bin/bash
# Benchmark llama.cpp backends: vulkan, rocm (gfx1151), rocm-gfx1100
# Uses llama-bench for consistent prompt/gen throughput comparison.
#
# Usage: ./benchmark-backends.sh [model-path]

set -euo pipefail

UTIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$UTIL_DIR")"
MODEL="${1:-/mnt/storage/models/google_gemma-4-31B-it/google_gemma-4-31B-it-Q6_K_L.gguf}"
RESULTS_DIR="$UTIL_DIR/benchmark-results"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_FILE="$RESULTS_DIR/bench-$TIMESTAMP.txt"

mkdir -p "$RESULTS_DIR"

if [ ! -f "$MODEL" ]; then
    echo "Model not found: $MODEL"
    exit 1
fi

# Reduced context for benchmark speed — comparing backends, not context depth
CONTEXT=16384
CACHE_TYPE_K="q8_0"
CACHE_TYPE_V="q8_0"
THREADS="$(nproc)"

# Test configurations: prompt lengths and generation lengths
# pp = prompt processing, tg = text generation
PROMPT_SIZES="512,2048,8192"
GEN_SIZE="128"

BACKENDS=(
    "vulkan|Vulkan (generic)|"
    "rocm|ROCm gfx1151 (native Strix Halo)|ROCBLAS_USE_HIPBLASLT=1 HSA_XNACK=1"
    "rocm-gfx1100|ROCm gfx1100 (7900 series target)|ROCBLAS_USE_HIPBLASLT=1 HSA_XNACK=1"
)

echo "========================================================================" | tee "$RESULTS_FILE"
echo "BACKEND BENCHMARK — $(date)" | tee -a "$RESULTS_FILE"
echo "========================================================================" | tee -a "$RESULTS_FILE"
echo "Model: $(basename "$MODEL")" | tee -a "$RESULTS_FILE"
echo "Context: $CONTEXT | KV: $CACHE_TYPE_K | Threads: $THREADS" | tee -a "$RESULTS_FILE"
echo "Prompt sizes: $PROMPT_SIZES | Gen: $GEN_SIZE tokens" | tee -a "$RESULTS_FILE"
echo "System RAM: $(free -g | awk '/Mem:/{print $2}') GB" | tee -a "$RESULTS_FILE"
echo "========================================================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

for entry in "${BACKENDS[@]}"; do
    IFS='|' read -r build_dir label env_vars <<< "$entry"

    BENCH_BIN="$ROOT_DIR/builds/$build_dir/bin/llama-bench"
    if [ ! -f "$BENCH_BIN" ]; then
        echo "SKIP: $label — $BENCH_BIN not found" | tee -a "$RESULTS_FILE"
        echo "" | tee -a "$RESULTS_FILE"
        continue
    fi

    echo "── $label ──" | tee -a "$RESULTS_FILE"

    # Set backend-specific env vars
    if [ "$build_dir" = "vulkan" ]; then
        export LD_LIBRARY_PATH="$ROOT_DIR/builds/$build_dir/bin:$ROOT_DIR/builds/$build_dir/lib"
    else
        export LD_LIBRARY_PATH="$ROOT_DIR/builds/$build_dir/bin:$ROOT_DIR/builds/$build_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        for var in $env_vars; do
            export "$var"
        done
    fi

    # Run llama-bench
    # -p: prompt sizes to test (comma-separated)
    # -n: generation length
    # -ngl 99: offload everything to GPU
    # -fa 1: flash attention on
    # -t: threads
    echo "  Running..." | tee -a "$RESULTS_FILE"

    if output=$("$BENCH_BIN" \
        -m "$MODEL" \
        -p "$PROMPT_SIZES" \
        -n "$GEN_SIZE" \
        -ngl 99 \
        -fa 1 \
        -t "$THREADS" \
        -ctk "$CACHE_TYPE_K" \
        -ctv "$CACHE_TYPE_V" \
        -r 2 \
        2>&1); then
        echo "$output" | tee -a "$RESULTS_FILE"
    else
        echo "  FAILED:" | tee -a "$RESULTS_FILE"
        echo "$output" | tail -20 | tee -a "$RESULTS_FILE"
    fi

    echo "" | tee -a "$RESULTS_FILE"

    # Brief pause to let GPU cool / memory settle
    sleep 5
done

echo "========================================================================" | tee -a "$RESULTS_FILE"
echo "Results saved: $RESULTS_FILE" | tee -a "$RESULTS_FILE"
