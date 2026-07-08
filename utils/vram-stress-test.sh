#!/bin/bash
# vram-stress-test.sh — Measure actual peak VRAM under concurrent high-context load
#
# This script properly benchmarks a tune by:
#   1. Launching llama-server with the specified config
#   2. Polling VRAM/GTT every 500ms in background
#   3. Firing concurrent requests that fill ALL slots at high context
#   4. Reporting peak VRAM, not napkin math
#
# Usage:
#   vram-stress-test.sh --build vulkan --model /path/to/model.gguf --tune <tune-name>
#   vram-stress-test.sh --build vulkan --model /path/to/model.gguf --tune <tune-name> --vram-limit 50000
#
# Options:
#   --build <type>      Build type (rocm, vulkan)
#   --model <path>      Path to .gguf model
#   --tune <name>       Tune name to test
#   --vram-limit <MB>   Abort and fail if VRAM exceeds this (default: 51200 = 50 GB)
#   --context-fill <N>  Target prompt tokens per slot (default: 200000)
#   --gen-tokens <N>    Tokens to generate per request (default: 500)
#   --skip-launch       Don't launch server (assume already running)

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
RESULTS_DIR="$UTIL_DIR/benchmark-results"
mkdir -p "$RESULTS_DIR"

# Defaults
BUILD_TYPE=""
MODEL_PATH=""
TUNE_NAME=""
VRAM_LIMIT_MB=51200  # 50 GB
CONTEXT_FILL=200000
GEN_TOKENS=500
SKIP_LAUNCH=0
API_KEY="ollama-local"
BASE_URL="http://localhost:40801"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD_TYPE="$2"; shift 2 ;;
        --model) MODEL_PATH="$2"; shift 2 ;;
        --tune) TUNE_NAME="$2"; shift 2 ;;
        --vram-limit) VRAM_LIMIT_MB="$2"; shift 2 ;;
        --context-fill) CONTEXT_FILL="$2"; shift 2 ;;
        --gen-tokens) GEN_TOKENS="$2"; shift 2 ;;
        --skip-launch) SKIP_LAUNCH=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── VRAM/GTT monitoring ─────────────────────────────────────────────────────
VRAM_SYSFS=$(ls /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | head -1 || true)
GTT_SYSFS=$(ls /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | head -1 || true)
VRAM_TOTAL_SYSFS=$(ls /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | head -1 || true)
GTT_TOTAL_SYSFS=$(ls /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1 || true)

get_vram_mb() {
    if [ -n "$VRAM_SYSFS" ]; then
        echo $(( $(cat "$VRAM_SYSFS") / 1024 / 1024 ))
    else
        echo 0
    fi
}

get_gtt_mb() {
    if [ -n "$GTT_SYSFS" ]; then
        echo $(( $(cat "$GTT_SYSFS") / 1024 / 1024 ))
    else
        echo 0
    fi
}

# Combined GPU memory (VRAM + GTT for APUs like Strix Halo)
get_gpu_total_mb() {
    local vram=$(get_vram_mb)
    local gtt=$(get_gtt_mb)
    echo $((vram + gtt))
}

MONITOR_LOG=$(mktemp)
PEAK_FILE=$(mktemp)
echo "0" > "$PEAK_FILE"

# Background monitor: sample every 500ms, track peak
start_vram_monitor() {
    (
        local peak_vram=0
        local peak_gtt=0
        local peak_combined=0
        while true; do
            local vram=$(get_vram_mb)
            local gtt=$(get_gtt_mb)
            local combined=$((vram + gtt))
            local ts=$(date +%H:%M:%S)
            echo "$ts vram=${vram}MB gtt=${gtt}MB combined=${combined}MB" >> "$MONITOR_LOG"

            if [ "$combined" -gt "$peak_combined" ]; then
                peak_combined=$combined
                peak_vram=$vram
                peak_gtt=$gtt
                echo "${peak_vram},${peak_gtt},${peak_combined}" > "$PEAK_FILE"
            fi

            # Check limit
            if [ "$combined" -gt "$VRAM_LIMIT_MB" ]; then
                echo "LIMIT_EXCEEDED" >> "$PEAK_FILE"
            fi

            sleep 0.5
        done
    ) &
    MONITOR_PID=$!
}

stop_vram_monitor() {
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
}

# ── Server management ───────────────────────────────────────────────────────
kill_server() {
    pkill -9 -f llama-server 2>/dev/null || true
    local tries=0
    while pgrep -f llama-server > /dev/null 2>&1 && [ "$tries" -lt 15 ]; do
        sleep 2
        pkill -9 -f llama-server 2>/dev/null || true
        tries=$((tries + 1))
    done
}

wait_for_server() {
    local max_wait=180
    echo -n "  Waiting for server"
    for i in $(seq 1 $max_wait); do
        if curl -sf "$BASE_URL/health" > /dev/null 2>&1; then
            echo " ready (${i}s)"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo " TIMEOUT"
    return 1
}

# ── Request helpers ─────────────────────────────────────────────────────────
TMPDIR_STRESS=$(mktemp -d)
trap "rm -rf $TMPDIR_STRESS $MONITOR_LOG $PEAK_FILE; [ $SKIP_LAUNCH -eq 0 ] && kill_server" EXIT

send_highctx_request() {
    local slot_id="$1"
    local ctx_tokens="$2"
    local gen_tokens="$3"
    local outfile="$TMPDIR_STRESS/slot${slot_id}.json"

    python3 - "$ctx_tokens" "$gen_tokens" "$TMPDIR_STRESS/slot${slot_id}_req.json" <<'PYSCRIPT'
import json, sys, hashlib

ctx_tokens = int(sys.argv[1])
gen_tokens = int(sys.argv[2])
out_path = sys.argv[3]

# Generate unique filler per slot so caches can't be shared across slots
# This forces each slot to allocate its own KV cache
words_needed = int(ctx_tokens / 1.3)
seed = hashlib.md5(out_path.encode()).hexdigest()[:8]
base_words = [
    "The", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog",
    "while", "birds", "sing", "in", "trees", "nearby", "and", "wind", "blows",
    "gently", "through", "meadow", "carrying", "scent", "of", "wildflowers",
    "across", "rolling", "hills", "toward", "distant", "mountains", "where",
    "snow", "caps", "glisten", "in", "afternoon", "sunlight", "creating",
    "breathtaking", "panorama", "natural", "beauty", "stretches", "far",
]
# Rotate words based on seed so each slot gets different content
offset = int(seed, 16) % len(base_words)
rotated = base_words[offset:] + base_words[:offset]
filler = " ".join(rotated[i % len(rotated)] for i in range(words_needed))

body = {
    "model": "unused",
    "messages": [{"role": "user", "content": f"Context (seed={seed}):\n\n{filler}\n\nWrite a detailed summary of the key themes, patterns, and notable elements found in this text. Be thorough."}],
    "max_tokens": gen_tokens,
    "temperature": 1.0,
    "top_k": 64,
    "top_p": 0.95,
}

with open(out_path, "w") as f:
    json.dump(body, f)
PYSCRIPT

    local start_time=$(date +%s%N)
    local response
    response=$(curl -sf "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --max-time 1200 \
        -d @"$TMPDIR_STRESS/slot${slot_id}_req.json" 2>/dev/null) || true

    local end_time=$(date +%s%N)
    local elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    if [ -z "$response" ]; then
        echo "  [slot-$slot_id] FAILED (no response after $((elapsed_ms/1000))s)"
        return 1
    fi

    echo "$response" > "$outfile"

    python3 - "$slot_id" "$outfile" "$elapsed_ms" <<'PYSCRIPT'
import json, sys
slot = sys.argv[1]
with open(sys.argv[2]) as f:
    r = json.load(f)
elapsed = int(sys.argv[3])

if "error" in r:
    print(f"  [slot-{slot}] ERROR: {r['error'].get('message', str(r['error']))}")
    sys.exit(1)

t = r.get("timings", {})
pp = t.get("prompt_per_second", 0)
tg = t.get("predicted_per_second", 0)
pn = t.get("prompt_n", 0)
tn = t.get("predicted_n", 0)

print(f"  [slot-{slot}] {elapsed/1000:.1f}s | pp={pp:.0f} tok/s ({pn} tok) | tg={tg:.1f} tok/s ({tn} tok)")
PYSCRIPT
}


# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="$RESULTS_DIR/vram-stress-${TUNE_NAME:-manual}-${TIMESTAMP}.txt"

echo "════════════════════════════════════════════════════════════════" | tee "$RESULT_FILE"
echo "  VRAM Stress Test" | tee -a "$RESULT_FILE"
echo "  Tune: ${TUNE_NAME:-manual}" | tee -a "$RESULT_FILE"
echo "  VRAM limit: ${VRAM_LIMIT_MB} MB ($((VRAM_LIMIT_MB / 1024)) GB)" | tee -a "$RESULT_FILE"
echo "  Context fill: ${CONTEXT_FILL} tokens per slot" | tee -a "$RESULT_FILE"
echo "  Gen tokens: ${GEN_TOKENS}" | tee -a "$RESULT_FILE"
echo "  Date: $(date -Iseconds)" | tee -a "$RESULT_FILE"
echo "════════════════════════════════════════════════════════════════" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# ── Step 0: Baseline memory ────────────────────────────────────────────────
BASELINE_VRAM=$(get_vram_mb)
BASELINE_GTT=$(get_gtt_mb)
echo "Baseline (no server): vram=${BASELINE_VRAM}MB gtt=${BASELINE_GTT}MB combined=$((BASELINE_VRAM + BASELINE_GTT))MB" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# ── Step 1: Launch server ──────────────────────────────────────────────────
if [ "$SKIP_LAUNCH" -eq 0 ]; then
    if [ -z "$BUILD_TYPE" ] || [ -z "$MODEL_PATH" ] || [ -z "$TUNE_NAME" ]; then
        echo "❌ --build, --model, and --tune are required (or use --skip-launch)"
        exit 1
    fi

    echo "── Launching server ──" | tee -a "$RESULT_FILE"
    kill_server

    > "$HOME/llama.log"
    nohup "${LAUNCHER_CMD[@]}" \
        --build "$BUILD_TYPE" \
        --model "$MODEL_PATH" \
        --tune "$TUNE_NAME" \
        > /dev/null 2>&1 &

    if ! wait_for_server; then
        echo "❌ Server failed to start" | tee -a "$RESULT_FILE"
        exit 1
    fi
else
    echo "── Using existing server ──" | tee -a "$RESULT_FILE"
    if ! curl -sf "$BASE_URL/health" > /dev/null 2>&1; then
        echo "❌ Server not responding on $BASE_URL"
        exit 1
    fi
fi

# Get server info
MODEL_ID=$(curl -sf "$BASE_URL/v1/models" -H "Authorization: Bearer $API_KEY" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")
echo "Model: $MODEL_ID" | tee -a "$RESULT_FILE"

# Read parallel slots from server health
SLOTS_INFO=$(curl -sf "$BASE_URL/health?include_slots" -H "Authorization: Bearer $API_KEY" 2>/dev/null || echo "{}")
NUM_SLOTS=$(echo "$SLOTS_INFO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    slots = d.get('slots', [])
    print(len(slots))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")
echo "Slots: $NUM_SLOTS" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# ── Step 2: Idle VRAM ──────────────────────────────────────────────────────
sleep 3  # let server settle
IDLE_VRAM=$(get_vram_mb)
IDLE_GTT=$(get_gtt_mb)
IDLE_COMBINED=$((IDLE_VRAM + IDLE_GTT))
echo "Idle (server loaded): vram=${IDLE_VRAM}MB gtt=${IDLE_GTT}MB combined=${IDLE_COMBINED}MB" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# ── Step 3: Start VRAM monitor ─────────────────────────────────────────────
start_vram_monitor
echo "── VRAM monitor started (sampling every 500ms) ──" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# ── Step 4: Phase 1 — Single slot high context ────────────────────────────
echo "── Phase 1: Single slot, ${CONTEXT_FILL} token context ──" | tee -a "$RESULT_FILE"
send_highctx_request 0 "$CONTEXT_FILL" "$GEN_TOKENS" 2>&1 | tee -a "$RESULT_FILE"

IFS=',' read -r P1_VRAM P1_GTT P1_COMBINED < "$PEAK_FILE"
echo "  Peak after phase 1: vram=${P1_VRAM}MB gtt=${P1_GTT}MB combined=${P1_COMBINED}MB" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# Check limit
if grep -q "LIMIT_EXCEEDED" "$PEAK_FILE" 2>/dev/null; then
    echo "❌ VRAM LIMIT EXCEEDED in phase 1! Peak: ${P1_COMBINED}MB > ${VRAM_LIMIT_MB}MB" | tee -a "$RESULT_FILE"
    echo "RESULT: FAIL — single slot already exceeds limit" | tee -a "$RESULT_FILE"
    stop_vram_monitor
    exit 1
fi

# ── Step 5: Phase 2 — All slots concurrent, high context ─────────────────
if [ "$NUM_SLOTS" != "unknown" ] && [ "$NUM_SLOTS" -gt 1 ]; then
    echo "── Phase 2: ALL $NUM_SLOTS slots concurrent, ${CONTEXT_FILL} token context each ──" | tee -a "$RESULT_FILE"
    echo "  (This is the real stress test — all slots filling KV cache simultaneously)" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    pids=()
    for slot in $(seq 0 $((NUM_SLOTS - 1))); do
        send_highctx_request "$slot" "$CONTEXT_FILL" "$GEN_TOKENS" >> "$RESULT_FILE" 2>&1 &
        pids+=($!)
    done

    # Wait for all slots to complete
    failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=$((failed + 1))
        fi
    done

    IFS=',' read -r P2_VRAM P2_GTT P2_COMBINED < "$PEAK_FILE"
    echo "" | tee -a "$RESULT_FILE"
    echo "  Peak after phase 2: vram=${P2_VRAM}MB gtt=${P2_GTT}MB combined=${P2_COMBINED}MB" | tee -a "$RESULT_FILE"
    if [ "$failed" -gt 0 ]; then
        echo "  ⚠️  $failed slot(s) failed" | tee -a "$RESULT_FILE"
    fi
    echo "" | tee -a "$RESULT_FILE"

    if grep -q "LIMIT_EXCEEDED" "$PEAK_FILE" 2>/dev/null; then
        echo "❌ VRAM LIMIT EXCEEDED in phase 2! Peak: ${P2_COMBINED}MB > ${VRAM_LIMIT_MB}MB" | tee -a "$RESULT_FILE"
        echo "RESULT: FAIL — concurrent load exceeds limit" | tee -a "$RESULT_FILE"
        stop_vram_monitor
        exit 1
    fi
fi

# ── Step 6: Phase 3 — Sustained concurrent (second wave, tests checkpoint growth) ──
if [ "$NUM_SLOTS" != "unknown" ] && [ "$NUM_SLOTS" -gt 1 ]; then
    echo "── Phase 3: Second concurrent wave (checkpoint accumulation test) ──" | tee -a "$RESULT_FILE"
    echo "  Firing $NUM_SLOTS more concurrent requests with different prompts" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    pids=()
    for slot in $(seq 0 $((NUM_SLOTS - 1))); do
        # Use offset slot IDs for different content (forces checkpoint divergence)
        send_highctx_request "$((slot + NUM_SLOTS))" "$CONTEXT_FILL" "$GEN_TOKENS" >> "$RESULT_FILE" 2>&1 &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    IFS=',' read -r P3_VRAM P3_GTT P3_COMBINED < "$PEAK_FILE"
    echo "" | tee -a "$RESULT_FILE"
    echo "  Peak after phase 3: vram=${P3_VRAM}MB gtt=${P3_GTT}MB combined=${P3_COMBINED}MB" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    if grep -q "LIMIT_EXCEEDED" "$PEAK_FILE" 2>/dev/null; then
        echo "❌ VRAM LIMIT EXCEEDED in phase 3! Peak: ${P3_COMBINED}MB > ${VRAM_LIMIT_MB}MB" | tee -a "$RESULT_FILE"
        echo "RESULT: FAIL — checkpoint growth exceeds limit" | tee -a "$RESULT_FILE"
        stop_vram_monitor
        exit 1
    fi
fi

# ── Step 7: Phase 4 — Max context (push to 256K on one slot while others run) ──
echo "── Phase 4: Max context push (256K single slot) ──" | tee -a "$RESULT_FILE"
send_highctx_request "max" 250000 200 2>&1 | tee -a "$RESULT_FILE"

IFS=',' read -r P4_VRAM P4_GTT P4_COMBINED < "$PEAK_FILE"
echo "  Peak after phase 4: vram=${P4_VRAM}MB gtt=${P4_GTT}MB combined=${P4_COMBINED}MB" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# ── Final report ───────────────────────────────────────────────────────────
stop_vram_monitor

# Read final peak
IFS=',' read -r PEAK_VRAM PEAK_GTT PEAK_COMBINED < "$PEAK_FILE"

echo "════════════════════════════════════════════════════════════════" | tee -a "$RESULT_FILE"
echo "  RESULTS" | tee -a "$RESULT_FILE"
echo "════════════════════════════════════════════════════════════════" | tee -a "$RESULT_FILE"
echo "  Tune:             ${TUNE_NAME:-manual}" | tee -a "$RESULT_FILE"
echo "  Slots:            $NUM_SLOTS" | tee -a "$RESULT_FILE"
echo "  Context fill:     $CONTEXT_FILL tokens/slot" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"
echo "  Baseline:         $((BASELINE_VRAM + BASELINE_GTT)) MB" | tee -a "$RESULT_FILE"
echo "  Idle (loaded):    ${IDLE_COMBINED} MB" | tee -a "$RESULT_FILE"
echo "  Peak VRAM:        ${PEAK_VRAM} MB" | tee -a "$RESULT_FILE"
echo "  Peak GTT:         ${PEAK_GTT} MB" | tee -a "$RESULT_FILE"
echo "  Peak combined:    ${PEAK_COMBINED} MB" | tee -a "$RESULT_FILE"
echo "  VRAM limit:       ${VRAM_LIMIT_MB} MB" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

if grep -q "LIMIT_EXCEEDED" "$PEAK_FILE" 2>/dev/null; then
    echo "  ❌ VERDICT: FAIL — peak ${PEAK_COMBINED}MB exceeds ${VRAM_LIMIT_MB}MB limit" | tee -a "$RESULT_FILE"
    VERDICT="FAIL"
else
    HEADROOM=$((VRAM_LIMIT_MB - PEAK_COMBINED))
    echo "  ✅ VERDICT: PASS — peak ${PEAK_COMBINED}MB, headroom ${HEADROOM}MB" | tee -a "$RESULT_FILE"
    VERDICT="PASS"
fi
echo "════════════════════════════════════════════════════════════════" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"
echo "Full VRAM trace: $MONITOR_LOG" | tee -a "$RESULT_FILE"
echo "Results: $RESULT_FILE" | tee -a "$RESULT_FILE"

# Copy monitor log into results
echo "" >> "$RESULT_FILE"
echo "── VRAM trace (sampled every 500ms) ──" >> "$RESULT_FILE"
cat "$MONITOR_LOG" >> "$RESULT_FILE"

[ "$VERDICT" = "FAIL" ] && exit 1
exit 0
