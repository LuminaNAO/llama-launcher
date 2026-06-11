#!/bin/bash
# tune-gemma4-v3.sh — Test all v3 candidate tunes and find one that fits in 50 GB
#
# Runs vram-stress-test.sh against v3a, v3b, v3c in order (conservative first).
# Stops and reports the best passing config.
#
# Usage:
#   tune-gemma4-v3.sh --build vulkan --model /path/to/gemma-4-26B-A4B-it-Q8_0.gguf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VRAM_LIMIT=51200  # 50 GB in MB

BUILD_TYPE=""
MODEL_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD_TYPE="$2"; shift 2 ;;
        --model) MODEL_PATH="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$BUILD_TYPE" ] || [ -z "$MODEL_PATH" ]; then
    echo "Usage: tune-gemma4-v3.sh --build <vulkan|rocm> --model /path/to/model.gguf"
    exit 1
fi

echo "══════════════════════════════════════════════════════════════════"
echo "  Gemma 4 26B-A4B v3 Tune Sweep"
echo "  VRAM limit: ${VRAM_LIMIT} MB ($((VRAM_LIMIT / 1024)) GB)"
echo "  Build: $BUILD_TYPE"
echo "  Model: $(basename "$MODEL_PATH")"
echo "══════════════════════════════════════════════════════════════════"
echo ""

# Candidates in order: conservative → aggressive
CANDIDATES=(
    "64gb-q8-262k-v3a:parallel=2, checkpoints=16 (conservative)"
    "64gb-q8-262k-v3b:parallel=2, checkpoints=30 (moderate)"
    "64gb-q8-262k-v3c:parallel=4, checkpoints=8 (aggressive)"
)

BEST_PASS=""
RESULTS=()

for entry in "${CANDIDATES[@]}"; do
    tune="${entry%%:*}"
    desc="${entry#*:}"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Testing: $tune — $desc"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if bash "$SCRIPT_DIR/vram-stress-test.sh" \
        --build "$BUILD_TYPE" \
        --model "$MODEL_PATH" \
        --tune "$tune" \
        --vram-limit "$VRAM_LIMIT"; then
        RESULTS+=("✅ $tune — PASS ($desc)")
        BEST_PASS="$tune"
    else
        RESULTS+=("❌ $tune — FAIL ($desc)")
    fi

    # Kill server between tests
    pkill -9 -f llama-server 2>/dev/null || true
    sleep 5
    echo ""
done

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  SWEEP RESULTS"
echo "══════════════════════════════════════════════════════════════════"
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo ""

if [ -n "$BEST_PASS" ]; then
    echo "  Best passing tune: $BEST_PASS"
    echo ""
    echo "  To promote as the production v3 tune:"
    echo "    cp model-configs/gemma-4-26B-A4B.${BEST_PASS}.conf \\"
    echo "       model-configs/gemma-4-26B-A4B.64gb-q8-262k-v3.conf"
else
    echo "  ❌ ALL CANDIDATES FAILED — need to reduce context or use q4 KV cache"
    echo ""
    echo "  Next steps to try:"
    echo "    - Reduce context to 131072 (128K)"
    echo "    - Switch KV cache to q4_0 (halves KV size)"
    echo "    - parallel=1 with checkpoints=8 (minimal)"
fi
echo "══════════════════════════════════════════════════════════════════"
