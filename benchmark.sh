#!/bin/bash
# benchmark.sh — Benchmark llama.cpp inference at various context sizes
# Usage:  benchmark.sh <label>
# Env vars:
#   BASE_URL  default http://localhost:40801 — target server
#   API_KEY   default ollama-local           — bearer token
#   MAX_CTX   default 128000                 — skip tests whose prompt > MAX_CTX

set -euo pipefail

LABEL="${1:?Usage: benchmark.sh <label>}"
API_KEY="${API_KEY:-ollama-local}"
BASE_URL="${BASE_URL:-http://localhost:40801}"
MAX_CTX="${MAX_CTX:-128000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
RESULTS_FILE="$RESULTS_DIR/bench-${LABEL}-$(date +%Y%m%d-%H%M%S).jsonl"
TMPDIR_BENCH=$(mktemp -d)
trap "rm -rf $TMPDIR_BENCH" EXIT

mkdir -p "$RESULTS_DIR"

echo "=== Benchmark: $LABEL ==="
echo "Results: $RESULTS_FILE"
echo ""

# Check server is up
if ! curl -sf "$BASE_URL/health" > /dev/null 2>&1; then
    echo "❌ Server not responding on $BASE_URL"
    exit 1
fi

# Get model info
MODEL=$(curl -sf "$BASE_URL/v1/models" -H "Authorization: Bearer $API_KEY" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
echo "Model: $MODEL"
echo ""

run_test() {
    local test_name="$1"
    local context_tokens="$2"
    local gen_tokens="$3"

    if [ "$context_tokens" -gt "$MAX_CTX" ]; then
        printf "  %-25s SKIPPED (ctx > MAX_CTX=%s)\n" "$test_name..." "$MAX_CTX"
        return 0
    fi

    printf "  %-25s " "$test_name..."

    # Build the request JSON via python to handle escaping properly
    python3 - "$MODEL" "$context_tokens" "$gen_tokens" "$TMPDIR_BENCH/request.json" <<'PYSCRIPT'
import json, sys

model = sys.argv[1]
ctx_tokens = int(sys.argv[2])
gen_tokens = int(sys.argv[3])
out_path = sys.argv[4]

if ctx_tokens > 100:
    words_needed = int(ctx_tokens / 1.3)
    base = "The quick brown fox jumps over the lazy dog while birds sing in the trees nearby and the wind blows gently through the meadow carrying the scent of wildflowers across the rolling hills toward the distant mountains where snow caps glisten in the afternoon sunlight creating a breathtaking panorama of natural beauty that stretches as far as the eye can see".split()
    filler = " ".join(base[i % len(base)] for i in range(words_needed))
    content = f"Here is some reference text:\n\n{filler}\n\nNow count from 1 to 200, one number per line."
else:
    content = "Count from 1 to 200, one number per line."

body = {
    "model": model,
    "messages": [{"role": "user", "content": content}],
    "max_tokens": gen_tokens,
    "temperature": 0.1,
}

with open(out_path, "w") as f:
    json.dump(body, f)
PYSCRIPT

    # Send request
    local response
    response=$(curl -sf "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --max-time 1800 \
        -d @"$TMPDIR_BENCH/request.json" 2>/dev/null) || { echo "FAILED (curl)"; return 1; }

    # Parse response
    echo "$response" > "$TMPDIR_BENCH/response.json"
    python3 - "$test_name" "$context_tokens" "$TMPDIR_BENCH/response.json" "$RESULTS_FILE" <<'PYSCRIPT'
import json, sys

test_name = sys.argv[1]
target_ctx = int(sys.argv[2])
resp_path = sys.argv[3]
results_path = sys.argv[4]

with open(resp_path) as f:
    r = json.load(f)

if "error" in r:
    print(f"FAILED: {r['error']}")
    sys.exit(1)

t = r.get("timings", {})
pp = t.get("prompt_per_second", 0)
tg = t.get("predicted_per_second", 0)
pn = t.get("prompt_n", 0)
tn = t.get("predicted_n", 0)
pm = t.get("prompt_ms", 0)
tm = t.get("predicted_ms", 0)

print(f"pp={pp:.1f} tok/s ({pn} tok) | tg={tg:.1f} tok/s ({tn} tok)")

entry = {
    "test": test_name,
    "target_ctx": target_ctx,
    "actual_prompt_tokens": pn,
    "gen_tokens": tn,
    "prompt_tok_s": round(pp, 2),
    "gen_tok_s": round(tg, 2),
    "prompt_ms": round(pm),
    "gen_ms": round(tm),
}
with open(results_path, "a") as f:
    f.write(json.dumps(entry) + "\n")
PYSCRIPT
}

# Write header
python3 -c "
import json
header = {'type': 'header', 'label': '$LABEL', 'model': '$MODEL', 'timestamp': '$(date -Iseconds)'}
with open('$RESULTS_FILE', 'w') as f:
    f.write(json.dumps(header) + '\n')
"

echo "── Short context (prompt < 100 tokens) ──"
run_test "short-gen50" 0 50
run_test "short-gen200" 0 200
run_test "short-gen500" 0 500
echo ""

echo "── Medium context (~4k prompt) ──"
run_test "med4k-gen200" 4000 200
run_test "med4k-gen500" 4000 500
echo ""

echo "── Large context (~16k prompt) ──"
run_test "large16k-gen200" 16000 200
run_test "large16k-gen500" 16000 500
echo ""

echo "── XL context (~64k prompt) ──"
run_test "xl64k-gen200" 64000 200
run_test "xl64k-gen500" 64000 500
echo ""

echo "── XXL context (~128k prompt) ──"
run_test "xxl128k-gen500" 128000 500
echo ""

echo "── XXXL context (~192k prompt) ──"
run_test "xxxl192k-gen500" 192000 500
echo ""

echo "── Max context (~256k prompt) ──"
run_test "max256k-gen500" 256000 500
echo ""

echo ""
echo "=== Summary ==="
python3 - "$RESULTS_FILE" <<'PYSCRIPT'
import json, sys

results = []
with open(sys.argv[1]) as f:
    for line in f:
        r = json.loads(line)
        if r.get("type") == "header":
            continue
        results.append(r)

print(f"{'Test':<25} {'Prompt':>8} {'PP tok/s':>10} {'TG tok/s':>10}")
print("-" * 58)
for r in results:
    print(f"{r['test']:<25} {r['actual_prompt_tokens']:>8} {r['prompt_tok_s']:>10.1f} {r['gen_tok_s']:>10.1f}")
PYSCRIPT
echo ""
echo "Results: $RESULTS_FILE"
