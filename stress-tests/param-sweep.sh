#!/bin/bash
# Parameter sweep for Qwen3.5-27B Q4_K_M code editing quality
# Restarts llama-server with different params, runs multi-turn edit tests
# Designed to run overnight — outputs results to a log file
#
# Usage: ./param-sweep.sh [results-file]

RESULTS_FILE="${1:-/path/to/param-sweep-results.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="$(dirname "$SCRIPT_DIR")"
MODEL="/mnt/storage/models/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled/Qwen3.5-27B.Q4_K_M.gguf"
BUILD_DIR="$HELPER_DIR/builds/rocm"
SERVER="$BUILD_DIR/bin/llama-server"
PROXY="$HELPER_DIR/llama-deep-proxy.mjs"
DEEP_LOG="/path/to/llama-deep.log"
HOST="127.0.0.1"
BACKEND_PORT=40802
PROXY_PORT=40801
API_KEY="ollama-local"
BASE_URL="http://$HOST:$PROXY_PORT"

# Fixed params
CONTEXT=113200
NGL=99
THREADS=32

# ── Test harness (Python) ──────────────────────────────────────────────────
PYTHON_TEST=$(cat << 'PYTEST'
import json, subprocess, time, sys

HOST = sys.argv[1]
API_KEY = sys.argv[2]
config_label = sys.argv[3]

tools = [
    {"name": "edit_file", "description": "Edit a file by replacing old_string with new_string exactly.",
     "input_schema": {"type": "object", "properties": {"file_path": {"type": "string"}, "old_string": {"type": "string"}, "new_string": {"type": "string"}}, "required": ["file_path", "old_string", "new_string"]}},
    {"name": "read_file", "description": "Read a file",
     "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}},
    {"name": "write_file", "description": "Write content to a file",
     "input_schema": {"type": "object", "properties": {"file_path": {"type": "string"}, "content": {"type": "string"}}, "required": ["file_path", "content"]}}
]

system = "You are a coding assistant. Always use tools for file operations. Use edit_file to modify existing files — provide the exact old_string to match and the new_string to replace it with."

ts_file = '''import express from "express";
import { Pool } from "pg";

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

interface Todo {
  id: number;
  title: string;
  completed: boolean;
  created_at: Date;
}

const app = express();
app.use(express.json());

app.get("/todos", async (req, res) => {
  const result = await pool.query("SELECT * FROM todos ORDER BY created_at DESC");
  res.json(result.rows);
});

app.post("/todos", async (req, res) => {
  const { title } = req.body;
  const result = await pool.query(
    "INSERT INTO todos (title, completed) VALUES ($1, false) RETURNING *",
    [title]
  );
  res.status(201).json(result.rows[0]);
});

app.put("/todos/:id", async (req, res) => {
  const { id } = req.params;
  const { title, completed } = req.body;
  const result = await pool.query(
    "UPDATE todos SET title = $1, completed = $2 WHERE id = $3 RETURNING *",
    [title, completed, id]
  );
  res.json(result.rows[0]);
});

app.delete("/todos/:id", async (req, res) => {
  const { id } = req.params;
  await pool.query("DELETE FROM todos WHERE id = $1", [id]);
  res.status(204).send();
});

app.listen(3000, () => {
  console.log("Server running on port 3000");
});'''

TYPOS = ['cosnt','retrun','reqbody','pooquery','titl ','complet ','reatlt','pool.quert','req.restd','catcch','funciton','resutl','respnse','awiat','asnyc']

def send(messages):
    req = {"model": "test", "max_tokens": 4096, "stream": False, "system": system, "messages": messages, "tools": tools}
    with open("/tmp/sweep_req.json", "w") as f: json.dump(req, f)
    r = subprocess.run(["curl", "-s", "--max-time", "300", f"{HOST}/v1/messages",
        "-H", f"x-api-key: {API_KEY}", "-H", "Content-Type: application/json",
        "-H", "anthropic-version: 2023-06-01", "-d", "@/tmp/sweep_req.json"], capture_output=True, text=True)
    try: return json.loads(r.stdout)
    except: return {"error": {"message": f"parse error: {r.stdout[:100]}"}}

def run_test(prompt):
    """Multi-turn read->edit test. Returns (passed, details_dict)"""
    msgs = [{"role": "user", "content": f"Read /project/src/server.ts then: {prompt}"}]
    t0 = time.time()
    r1 = send(msgs)
    if r1.get("error"): return (False, {"error": r1["error"]["message"]})

    tu1 = [c for c in r1.get("content", []) if c["type"] == "tool_use"]
    if not tu1: return (False, {"error": "no_tool_t1"})

    msgs.append({"role": "assistant", "content": r1["content"]})
    msgs.append({"role": "user", "content": [{"type": "tool_result", "tool_use_id": tu1[0]["id"], "content": ts_file}]})

    r2 = send(msgs)
    elapsed = time.time() - t0
    if r2.get("error"): return (False, {"error": r2["error"]["message"], "time": elapsed})

    tu2 = [c for c in r2.get("content", []) if c["type"] == "tool_use"]
    if not tu2:
        text = " ".join([c.get("text","") for c in r2.get("content",[]) if c["type"]=="text"])
        return (False, {"error": "no_tool_t2", "text": text[:100], "time": elapsed})

    t = tu2[0]; inp = t.get("input", {})
    old_s = inp.get("old_string", "") if t["name"] == "edit_file" else ""
    new_s = inp.get("new_string", "") if t["name"] == "edit_file" else inp.get("content", "")

    match = old_s in ts_file if t["name"] == "edit_file" else True
    typos = [p for p in TYPOS if p in new_s]

    return (
        match and not typos and t["name"] in ("edit_file", "write_file"),
        {"tool": t["name"], "match": match, "typos": typos, "time": elapsed,
         "old_preview": repr(old_s[:80]) if not match else None,
         "new_preview": new_s[:100] if typos else None}
    )

tests = [
    "Add input validation to POST /todos: title must be a non-empty string, return 400 if invalid.",
    "The PUT /todos/:id doesn't check if todo exists. Fix it to return 404 if not found.",
    "Add try/catch error handling to GET /todos. Return 500 with error message on database failure.",
]

passed = 0
total = len(tests)
details = []

for i, prompt in enumerate(tests):
    ok, d = run_test(prompt)
    if ok: passed += 1
    d["test"] = i + 1
    d["passed"] = ok
    details.append(d)

result = {
    "config": config_label,
    "passed": passed,
    "total": total,
    "score": f"{passed}/{total}",
    "details": details
}
print(json.dumps(result))
PYTEST
)

# ── Server management ──────────────────────────────────────────────────────

kill_server() {
    pkill -f "llama-server.*$BACKEND_PORT" 2>/dev/null
    pkill -f "llama-deep-proxy.*$PROXY_PORT" 2>/dev/null
    sleep 2
}

start_server() {
    local label="$1"
    shift
    local extra_args=("$@")

    kill_server
    > "$DEEP_LOG"

    export ROCBLAS_USE_HIPBLASLT=1
    export HSA_XNACK=1
    export LD_LIBRARY_PATH="$BUILD_DIR/bin:$BUILD_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    local cmd=(
        "$SERVER" -m "$MODEL"
        -ngl $NGL -c $CONTEXT -fa on
        --threads $THREADS --no-mmap -dio
        --timeout 3600 --host $HOST --port $BACKEND_PORT
        --api-key "$API_KEY" --parallel 1 --kv-unified
        -ctk q8_0 -ctv q8_0
        "${extra_args[@]}"
    )

    "${cmd[@]}" > /tmp/llama-server-sweep.log 2>&1 &
    local server_pid=$!

    # Start proxy
    node "$PROXY" $PROXY_PORT $BACKEND_PORT "$DEEP_LOG" > /dev/null 2>&1 &

    # Wait for ready
    for i in $(seq 1 120); do
        sleep 1
        if curl -s --max-time 2 "http://$HOST:$BACKEND_PORT/health" 2>/dev/null | grep -q '"ok"'; then
            echo "  Server ready ($i s) — $label"
            return 0
        fi
        if ! kill -0 $server_pid 2>/dev/null; then
            echo "  Server died — $label"
            return 1
        fi
    done
    echo "  Server timeout — $label"
    return 1
}

run_tests() {
    local label="$1"
    local result
    result=$(python3 -c "$PYTHON_TEST" "$BASE_URL" "$API_KEY" "$label" 2>/dev/null)
    echo "$result"
}

# ── Main sweep ─────────────────────────────────────────────────────────────

echo "Parameter Sweep — $(date)" | tee "$RESULTS_FILE"
echo "Model: $MODEL" | tee -a "$RESULTS_FILE"
echo "Context: $CONTEXT" | tee -a "$RESULTS_FILE"
echo "========================================" | tee -a "$RESULTS_FILE"

# Define sweep configs: label, extra server args
# Phase 1: Temperature sweep (baseline top_k=20, top_p=0.95)
CONFIGS=(
    "temp=0.1,k=20,p=0.95|--temp 0.1 --top-k 20 --top-p 0.95"
    "temp=0.15,k=20,p=0.95|--temp 0.15 --top-k 20 --top-p 0.95"
    "temp=0.2,k=20,p=0.95|--temp 0.2 --top-k 20 --top-p 0.95"
    "temp=0.3,k=20,p=0.95|--temp 0.3 --top-k 20 --top-p 0.95"
    "temp=0.4,k=20,p=0.95|--temp 0.4 --top-k 20 --top-p 0.95"
    "temp=0.5,k=20,p=0.95|--temp 0.5 --top-k 20 --top-p 0.95"
    # Phase 2: top_k sweep (best temp from phase 1, assume 0.3 for now)
    "temp=0.3,k=5,p=0.95|--temp 0.3 --top-k 5 --top-p 0.95"
    "temp=0.3,k=10,p=0.95|--temp 0.3 --top-k 10 --top-p 0.95"
    "temp=0.3,k=40,p=0.95|--temp 0.3 --top-k 40 --top-p 0.95"
    # Phase 3: top_p sweep
    "temp=0.3,k=20,p=0.9|--temp 0.3 --top-k 20 --top-p 0.9"
    "temp=0.3,k=20,p=1.0|--temp 0.3 --top-k 20 --top-p 1.0"
    # Phase 4: min_p sweep
    "temp=0.3,k=20,p=0.95,minp=0|--temp 0.3 --top-k 20 --top-p 0.95 --min-p 0"
    "temp=0.3,k=20,p=0.95,minp=0.1|--temp 0.3 --top-k 20 --top-p 0.95 --min-p 0.1"
    "temp=0.3,k=20,p=0.95,minp=0.15|--temp 0.3 --top-k 20 --top-p 0.95 --min-p 0.15"
    # Phase 5: Light repeat penalty (to see if small values are ok)
    "temp=0.3,k=20,rep=1.02|--temp 0.3 --top-k 20 --top-p 0.95 --repeat-penalty 1.02 --repeat-last-n 64"
    "temp=0.3,k=20,rep=1.05|--temp 0.3 --top-k 20 --top-p 0.95 --repeat-penalty 1.05 --repeat-last-n 64"
    # Phase 6: Light DRY
    "temp=0.3,k=20,dry=0.1|--temp 0.3 --top-k 20 --top-p 0.95 --dry-multiplier 0.1 --dry-base 1.75 --dry-allowed-length 2 --dry-penalty-last-n 256"
    "temp=0.3,k=20,dry=0.3|--temp 0.3 --top-k 20 --top-p 0.95 --dry-multiplier 0.3 --dry-base 1.75 --dry-allowed-length 2 --dry-penalty-last-n 256"
    # Phase 7: KV cache types (does f16 or q4_0 matter?)
    "temp=0.3,k=20,kv=f16|--temp 0.3 --top-k 20 --top-p 0.95 -ctk f16 -ctv f16"
    "temp=0.3,k=20,kv=q4_0|--temp 0.3 --top-k 20 --top-p 0.95 -ctk q4_0 -ctv q4_0"
    # Phase 8: Context size (does reducing help quality?)
    "temp=0.3,k=20,ctx=70k|--temp 0.3 --top-k 20 --top-p 0.95"
    # Phase 9: JINJA on vs off
    "temp=0.3,k=20,jinja=on|--temp 0.3 --top-k 20 --top-p 0.95 --jinja"
    # Phase 10: Reasoning budget
    "temp=0.3,k=20,reason=on|--temp 0.3 --top-k 20 --top-p 0.95 --reasoning on --reasoning-budget 8192"
)

TOTAL_CONFIGS=${#CONFIGS[@]}
echo "Total configs to test: $TOTAL_CONFIGS" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

for idx in "${!CONFIGS[@]}"; do
    IFS='|' read -r label args <<< "${CONFIGS[$idx]}"

    echo "[$((idx+1))/$TOTAL_CONFIGS] Testing: $label" | tee -a "$RESULTS_FILE"

    # Special handling for context override
    local_ctx=$CONTEXT
    if [[ "$label" == *"ctx=70k"* ]]; then
        local_ctx=71680
    fi

    # Parse args into array
    IFS=' ' read -ra extra <<< "$args"

    if start_server "$label" -c "$local_ctx" "${extra[@]}"; then
        result=$(run_tests "$label")
        score=$(echo "$result" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['score'])" 2>/dev/null)
        echo "  Result: $score" | tee -a "$RESULTS_FILE"
        echo "$result" >> "$RESULTS_FILE"
        echo "" >> "$RESULTS_FILE"
    else
        echo "  Result: SERVER_FAIL" | tee -a "$RESULTS_FILE"
        echo '{"config":"'"$label"'","passed":0,"total":3,"score":"SERVER_FAIL"}' >> "$RESULTS_FILE"
        echo "" >> "$RESULTS_FILE"
    fi
done

kill_server

echo "========================================" | tee -a "$RESULTS_FILE"
echo "Sweep complete — $(date)" | tee -a "$RESULTS_FILE"

# Summary
echo "" | tee -a "$RESULTS_FILE"
echo "SUMMARY:" | tee -a "$RESULTS_FILE"
grep -E '"config"|"score"' "$RESULTS_FILE" | paste - - | sed 's/.*"config": *"//;s/".*"score": *"/ → /;s/".*//' | tee -a "$RESULTS_FILE"
