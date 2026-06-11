#!/bin/bash
# soak-test-v3b.sh — 1-hour soak test for v3b tune
# Continuously fires concurrent high-context requests at all slots
# Monitors peak GTT throughout

set -euo pipefail

UTIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$UTIL_DIR")"
API_KEY="ollama-local"
BASE_URL="http://localhost:40801"
DURATION_SECS=3600  # 1 hour
GTT_SYSFS="/sys/class/drm/card1/device/mem_info_gtt_used"
VRAM_SYSFS="/sys/class/drm/card1/device/mem_info_vram_used"

RESULT_DIR="$UTIL_DIR/benchmark-results"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/soak-v3b-$(date +%Y%m%d-%H%M%S).log"
GTT_TRACE="$RESULT_DIR/soak-v3b-gtt-trace-$(date +%Y%m%d-%H%M%S).csv"
TMPDIR_SOAK=$(mktemp -d)
trap "rm -rf $TMPDIR_SOAK; kill 0 2>/dev/null" EXIT

get_gtt_mb() { echo $(( $(cat "$GTT_SYSFS") / 1024 / 1024 )); }
get_vram_mb() { echo $(( $(cat "$VRAM_SYSFS") / 1024 / 1024 )); }

log() { echo "$@" | tee -a "$RESULT_FILE"; }

# ── GTT monitor (background, 500ms interval) ────────────────────────────────
PEAK_GTT_FILE=$(mktemp)
echo "0" > "$PEAK_GTT_FILE"

echo "elapsed_s,gtt_mb,vram_mb,combined_mb" > "$GTT_TRACE"

(
    START=$(date +%s)
    peak=0
    while true; do
        gtt=$(get_gtt_mb)
        vram=$(get_vram_mb)
        combined=$((gtt + vram))
        elapsed=$(( $(date +%s) - START ))
        echo "${elapsed},${gtt},${vram},${combined}" >> "$GTT_TRACE"
        if [ "$gtt" -gt "$peak" ]; then
            peak=$gtt
            echo "$peak" > "$PEAK_GTT_FILE"
        fi
        sleep 0.5
    done
) &
MONITOR_PID=$!

# ── Request sender ───────────────────────────────────────────────────────────
# Varies context size and content across waves to stress checkpoint divergence
WAVE=0
TOTAL_REQUESTS=0
TOTAL_FAILURES=0

send_request() {
    local id="$1"
    local ctx_tokens="$2"
    local gen_tokens="$3"
    local reqfile="$TMPDIR_SOAK/req_${id}.json"
    local respfile="$TMPDIR_SOAK/resp_${id}.json"

    python3 - "$ctx_tokens" "$gen_tokens" "$id" "$reqfile" <<'PYSCRIPT'
import json, sys, hashlib, random

ctx_tokens = int(sys.argv[1])
gen_tokens = int(sys.argv[2])
req_id = sys.argv[3]
out_path = sys.argv[4]

# Unique content per request to prevent cache sharing
seed = hashlib.md5(req_id.encode()).hexdigest()
rng = random.Random(seed)

topics = [
    "distributed systems consensus algorithms and Byzantine fault tolerance",
    "quantum computing error correction codes and topological qubits",
    "evolutionary biology and the molecular clock hypothesis",
    "category theory monads functors and natural transformations",
    "compiler optimization passes and SSA form intermediate representations",
    "differential geometry Riemannian manifolds and geodesic equations",
    "cryptographic hash functions and zero-knowledge proof systems",
    "neural architecture search and hyperparameter optimization",
]
topic = rng.choice(topics)

if ctx_tokens > 500:
    words_needed = int(ctx_tokens / 1.3)
    vocab = (
        "The analysis of " + topic + " reveals fundamental properties. "
        "Consider the theoretical framework where abstract structures emerge from "
        "compositional principles governing hierarchical representations. "
        "The interplay between local and global invariants characterizes "
        "the morphological landscape of computational phenomena. "
        "Systematic exploration of parameter spaces yields insights into "
        "convergence behavior and asymptotic complexity bounds. "
    ).split()
    # Shuffle to make each request unique
    shuffled = vocab[:]
    rng.shuffle(shuffled)
    filler = " ".join(shuffled[i % len(shuffled)] for i in range(words_needed))
    content = f"Context on {topic} (id={req_id}):\n\n{filler}\n\nProvide a detailed technical analysis of the key concepts, relationships, and implications discussed above."
else:
    prompts = [
        f"Write a detailed technical explanation of {topic}. Cover the mathematical foundations, key theorems, and practical applications.",
        f"Compare and contrast three different approaches to {topic}. Include pseudocode examples.",
        f"Design a system architecture that leverages {topic}. Include component diagrams described in text.",
    ]
    content = rng.choice(prompts)

body = {
    "model": "unused",
    "messages": [{"role": "user", "content": content}],
    "max_tokens": gen_tokens,
    "temperature": 1.0,
    "top_k": 64,
    "top_p": 0.95,
}

with open(out_path, "w") as f:
    json.dump(body, f)
PYSCRIPT

    local start_time=$(date +%s)
    local response
    response=$(curl -sf "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --max-time 900 \
        -d @"$reqfile" 2>/dev/null) || true

    local elapsed=$(( $(date +%s) - start_time ))
    local gtt_now=$(get_gtt_mb)
    local peak_now=$(cat "$PEAK_GTT_FILE")

    if [ -z "$response" ]; then
        log "  [${id}] FAILED (no response, ${elapsed}s) | GTT=${gtt_now}MB peak=${peak_now}MB"
        return 1
    fi

    echo "$response" > "$respfile"

    python3 - "$id" "$respfile" "$elapsed" "$gtt_now" "$peak_now" <<'PYSCRIPT'
import json, sys
rid = sys.argv[1]
with open(sys.argv[2]) as f:
    r = json.load(f)
elapsed = sys.argv[3]
gtt = sys.argv[4]
peak = sys.argv[5]

if "error" in r:
    print(f"  [{rid}] ERROR ({elapsed}s): {r['error'].get('message', str(r['error']))} | GTT={gtt}MB peak={peak}MB")
    sys.exit(1)

t = r.get("timings", {})
pp = t.get("prompt_per_second", 0)
tg = t.get("predicted_per_second", 0)
pn = t.get("prompt_n", 0)
tn = t.get("predicted_n", 0)
print(f"  [{rid}] {elapsed}s | pp={pp:.0f}t/s({pn}tok) tg={tg:.1f}t/s({tn}tok) | GTT={gtt}MB peak={peak}MB")
PYSCRIPT
}

# ── Main soak loop ───────────────────────────────────────────────────────────
MODEL_ID=$(curl -sf "$BASE_URL/v1/models" -H "Authorization: Bearer $API_KEY" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")

IDLE_GTT=$(get_gtt_mb)

log "════════════════════════════════════════════════════════════════"
log "  Soak Test: v3b (parallel=2, checkpoints=30)"
log "  Model: $MODEL_ID"
log "  Idle GTT: ${IDLE_GTT}MB"
log "  Duration: ${DURATION_SECS}s ($(( DURATION_SECS / 60 )) min)"
log "  GTT trace: $GTT_TRACE"
log "  Start: $(date -Iseconds)"
log "════════════════════════════════════════════════════════════════"
log ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SECS))

# Context sizes to cycle through — mix of sizes to stress checkpoints
CTX_SIZES=(1000 4000 16000 64000 128000 200000 250000)
GEN_SIZES=(200 500 500 500 500 500 200)

while [ "$(date +%s)" -lt "$END_TIME" ]; do
    WAVE=$((WAVE + 1))
    ELAPSED=$(( $(date +%s) - START_TIME ))
    REMAINING=$(( END_TIME - $(date +%s) ))
    PEAK_NOW=$(cat "$PEAK_GTT_FILE")
    GTT_NOW=$(get_gtt_mb)

    # Pick context size for this wave (cycle through sizes)
    CTX_IDX=$(( (WAVE - 1) % ${#CTX_SIZES[@]} ))
    CTX=${CTX_SIZES[$CTX_IDX]}
    GEN=${GEN_SIZES[$CTX_IDX]}

    log "── Wave $WAVE (${ELAPSED}s elapsed, ${REMAINING}s left) | ctx=${CTX} | GTT=${GTT_NOW}MB peak=${PEAK_NOW}MB ──"

    # Fire 2 concurrent requests (matching parallel=2)
    pids=()
    for slot in 0 1; do
        send_request "w${WAVE}s${slot}" "$CTX" "$GEN" &
        pids+=($!)
        TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
    done

    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
        fi
    done

    log ""

    # Brief pause between waves to let checkpoints settle
    sleep 2
done

# ── Final report ─────────────────────────────────────────────────────────────
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

FINAL_GTT=$(get_gtt_mb)
PEAK_GTT=$(cat "$PEAK_GTT_FILE")

log "════════════════════════════════════════════════════════════════"
log "  SOAK TEST RESULTS"
log "════════════════════════════════════════════════════════════════"
log "  Tune:             v3b (parallel=2, checkpoints=30)"
log "  Duration:         ${DURATION_SECS}s"
log "  Waves:            $WAVE"
log "  Total requests:   $TOTAL_REQUESTS"
log "  Failures:         $TOTAL_FAILURES"
log ""
log "  Idle GTT:         ${IDLE_GTT} MB ($(( IDLE_GTT / 1024 )) GB)"
log "  Final GTT:        ${FINAL_GTT} MB ($(( FINAL_GTT / 1024 )) GB)"
log "  Peak GTT:         ${PEAK_GTT} MB ($(( PEAK_GTT / 1024 )) GB)"
log "  GTT delta:        $(( PEAK_GTT - IDLE_GTT )) MB from idle"
log ""
if [ "$PEAK_GTT" -le 51200 ]; then
    log "  ✅ VERDICT: PASS — peak ${PEAK_GTT}MB within 50GB limit"
else
    log "  ❌ VERDICT: FAIL — peak ${PEAK_GTT}MB exceeds 50GB limit"
fi
log "════════════════════════════════════════════════════════════════"
log ""
log "Results: $RESULT_FILE"
log "GTT trace: $GTT_TRACE"
