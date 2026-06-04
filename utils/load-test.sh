#!/bin/bash
# load-test.sh — Fire diverse concurrent requests at llama-server
# Monitors slot usage, timing, and throughput

set -euo pipefail

API_KEY="ollama-local"
BASE_URL="http://localhost:40801"
UTIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$UTIL_DIR")"
RESULTS_DIR="$UTIL_DIR/benchmark-results"
TMPDIR_LOAD=$(mktemp -d)
trap "rm -rf $TMPDIR_LOAD" EXIT

GTT_SYSFS=$(ls /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | head -1)
get_gtt_mb() { echo $(( $(cat "$GTT_SYSFS") / 1024 / 1024 )); }

MODEL=$(curl -sf "$BASE_URL/v1/models" -H "Authorization: Bearer $API_KEY" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)

echo "=== Load Test ==="
echo "Model: $MODEL"
echo "Start GTT: $(get_gtt_mb) MB"
echo ""

send_request() {
    local label="$1"
    local prompt="$2"
    local max_tokens="$3"
    local outfile="$TMPDIR_LOAD/${label}.json"

    local start_time=$(date +%s%N)

    python3 -c "
import json
body = {
    'model': '$MODEL',
    'messages': [{'role': 'user', 'content': '''$prompt'''}],
    'max_tokens': $max_tokens,
    'temperature': 0.3,
}
print(json.dumps(body))
" > "$TMPDIR_LOAD/${label}_req.json"

    local response
    response=$(curl -sf "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --max-time 600 \
        -d @"$TMPDIR_LOAD/${label}_req.json" 2>/dev/null)

    local end_time=$(date +%s%N)
    local elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    if [ -z "$response" ]; then
        echo "  [$label] FAILED (no response)"
        return 1
    fi

    echo "$response" > "$outfile"

    python3 - "$label" "$outfile" "$elapsed_ms" <<'PYSCRIPT'
import json, sys
label = sys.argv[1]
with open(sys.argv[2]) as f:
    r = json.load(f)
elapsed = int(sys.argv[3])

if "error" in r:
    print(f"  [{label}] ERROR: {r['error'].get('message', r['error'])}")
    sys.exit(1)

t = r.get("timings", {})
pp = t.get("prompt_per_second", 0)
tg = t.get("predicted_per_second", 0)
pn = t.get("prompt_n", 0)
tn = t.get("predicted_n", 0)
content = r.get("choices", [{}])[0].get("message", {}).get("content", "")
preview = content[:80].replace("\n", " ")

print(f"  [{label}] {elapsed/1000:.1f}s | pp={pp:.0f} tok/s ({pn} tok) | tg={tg:.1f} tok/s ({tn} tok) | \"{preview}...\"")
PYSCRIPT
}

# ── Wave 1: Two concurrent short requests ────────────────────────────────────
echo "── Wave 1: Two concurrent short requests ──"
send_request "w1-code" "Write a Python function that checks if a string is a valid IPv4 address. Just the code, no explanation." 300 &
send_request "w1-reason" "What is 17 * 23 + 456 - 89? Show your working step by step." 200 &
wait
echo "  GTT after wave 1: $(get_gtt_mb) MB"
echo ""

# ── Wave 2: Two concurrent medium requests ───────────────────────────────────
echo "── Wave 2: Two concurrent medium requests ──"
send_request "w2-creative" "Write a short story (200 words) about a robot learning to paint. Make it emotionally resonant." 400 &
send_request "w2-explain" "Explain how transformer attention mechanisms work, including multi-head attention and the QKV matrices. Be thorough but accessible." 500 &
wait
echo "  GTT after wave 2: $(get_gtt_mb) MB"
echo ""

# ── Wave 3: One long context + one short (slot contention) ───────────────────
echo "── Wave 3: Long context + short (slot contention) ──"

# Build a ~10k token prompt
python3 -c "
words = 'The quick brown fox jumps over the lazy dog while birds sing in the trees nearby and the wind blows gently through the meadow carrying the scent of wildflowers across the rolling hills'.split()
filler = ' '.join(words[i % len(words)] for i in range(8000))
print(filler)
" > "$TMPDIR_LOAD/long_context.txt"

LONG_CTX=$(cat "$TMPDIR_LOAD/long_context.txt")
send_request "w3-long" "Here is some text:\n\n${LONG_CTX}\n\nSummarise the themes in 3 bullet points." 200 &
sleep 1
send_request "w3-short" "What is the capital of Australia?" 50 &
wait
echo "  GTT after wave 3: $(get_gtt_mb) MB"
echo ""

# ── Wave 4: Rapid fire sequential (cache reuse test) ─────────────────────────
echo "── Wave 4: Rapid fire sequential (5 quick requests) ──"
for i in 1 2 3 4 5; do
    send_request "w4-rapid-$i" "In one sentence, what is the ${i}th planet from the sun?" 50
done
echo "  GTT after wave 4: $(get_gtt_mb) MB"
echo ""

# ── Wave 5: Two heavy generation requests ────────────────────────────────────
echo "── Wave 5: Two heavy generation (1000 tokens each) ──"
send_request "w5-essay" "Write a detailed essay about the history of computing, from Babbage to modern GPUs. Cover key milestones." 1000 &
send_request "w5-code-long" "Write a complete implementation of a binary search tree in Rust, including insert, delete, search, and in-order traversal. Include tests." 1000 &
wait
echo "  GTT after wave 5: $(get_gtt_mb) MB"
echo ""

# ── Wave 6: Stress test — fire 4 at once (exceeds 2 slots) ──────────────────
echo "── Wave 6: 4 concurrent requests (exceeds 2 slots) ──"
send_request "w6-a" "List the first 20 prime numbers." 100 &
send_request "w6-b" "Translate to French: The weather is beautiful today and I would like to go for a walk in the park." 100 &
send_request "w6-c" "What are the SOLID principles in software engineering? One sentence each." 300 &
send_request "w6-d" "Write a haiku about debugging code." 50 &
wait
echo "  GTT after wave 6: $(get_gtt_mb) MB"
echo ""

echo "=== Load Test Complete ==="
echo "Final GTT: $(get_gtt_mb) MB"
echo ""

# Check server health after all that
health=$(curl -sf "$BASE_URL/health" 2>/dev/null)
echo "Server health: $health"
