#!/bin/bash
# Parameter sweep v2 — tests at HIGH CONTEXT (30K, 60K, 90K tokens)
# Restarts llama-server with different params, runs multi-turn edit tests
# at each context level to find where quality degrades.
#
# Usage: ./param-sweep-v2.sh [results-file]

RESULTS_FILE="${1:-/path/to/param-sweep-v2-results.log}"
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
CONTEXT=113200
NGL=99
THREADS=32

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

TYPOS = ['cosnt','retrun','reqbody','pooquery','titl ','complet ','reatlt','pool.quert','req.restd','catcch','funciton','resutl','respnse','awiat','asnyc','requst','boddy','stattus']

def send(messages):
    req = {"model": "test", "max_tokens": 4096, "stream": False, "system": system, "messages": messages, "tools": tools}
    with open("/tmp/sweep_req.json", "w") as f: json.dump(req, f)
    r = subprocess.run(["curl", "-s", "--max-time", "600", f"{HOST}/v1/messages",
        "-H", f"x-api-key: {API_KEY}", "-H", "Content-Type: application/json",
        "-H", "anthropic-version: 2023-06-01", "-d", "@/tmp/sweep_req.json"], capture_output=True, text=True)
    try: return json.loads(r.stdout)
    except: return {"error": {"message": f"parse error: {r.stdout[:200]}"}}

def make_padding(n_pairs):
    """Generate realistic multi-turn coding conversation padding"""
    pad = []
    topics = [
        ("How do I handle database migrations in a Node.js project?",
         "Database migrations in Node.js can be managed using tools like Knex.js, TypeORM, or Prisma. Here's a typical approach: 1) Create migration files that describe schema changes, 2) Use an 'up' function for applying changes and 'down' for rollbacks, 3) Track applied migrations in a metadata table. For example with Knex: `knex migrate:make create_users_table` creates a migration file."),
        ("What's the difference between SQL JOIN types?",
         "INNER JOIN returns only matching rows from both tables. LEFT JOIN returns all rows from the left table and matching rows from the right (nulls where no match). RIGHT JOIN is the opposite. FULL OUTER JOIN returns all rows from both tables. CROSS JOIN produces a cartesian product of all rows."),
        ("Explain the event loop in Node.js",
         "The Node.js event loop processes callbacks in phases: timers (setTimeout/setInterval), pending callbacks, idle/prepare, poll (I/O), check (setImmediate), close callbacks. Microtasks (Promise.then, process.nextTick) run between phases. This single-threaded model handles concurrency through non-blocking I/O."),
        ("How do I implement rate limiting in Express?",
         "Use express-rate-limit middleware: `const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 100 }); app.use('/api/', limiter);`. For distributed systems, use a Redis store. Consider different limits for different endpoints. Return 429 status with Retry-After header."),
        ("What are the best practices for error handling in async/await?",
         "Wrap async handlers in try/catch blocks. Create custom error classes for different error types. Use a centralized error handling middleware in Express: `app.use((err, req, res, next) => {...})`. Always handle unhandled rejections: `process.on('unhandledRejection', ...)`. Log errors with context."),
    ]
    for i in range(n_pairs):
        topic = topics[i % len(topics)]
        pad.append({"role": "user", "content": f"Question {i+1}: {topic[0]}"})
        pad.append({"role": "assistant", "content": f"Answer {i+1}: {topic[1]}"})
    return pad

def run_test(prompt, context_pairs):
    """Multi-turn read->edit test with context padding. Returns (passed, details_dict)"""
    # Start with padding
    msgs = make_padding(context_pairs)
    msgs.append({"role": "user", "content": f"Read /project/src/server.ts then: {prompt}"})

    t0 = time.time()
    r1 = send(msgs)
    if r1.get("error"): return (False, {"error": r1["error"]["message"]})

    tu1 = [c for c in r1.get("content", []) if c["type"] == "tool_use"]
    if not tu1:
        text = " ".join([c.get("text","") for c in r1.get("content",[]) if c["type"]=="text"])
        return (False, {"error": "no_tool_t1", "text": text[:80]})

    msgs.append({"role": "assistant", "content": r1["content"]})
    msgs.append({"role": "user", "content": [{"type": "tool_result", "tool_use_id": tu1[0]["id"], "content": ts_file}]})

    r2 = send(msgs)
    elapsed = time.time() - t0
    if r2.get("error"): return (False, {"error": r2["error"]["message"], "time": elapsed})

    tu2 = [c for c in r2.get("content", []) if c["type"] == "tool_use"]
    if not tu2:
        text = " ".join([c.get("text","") for c in r2.get("content",[]) if c["type"]=="text"])
        return (False, {"error": "no_tool_t2", "text": text[:80], "time": elapsed})

    t = tu2[0]; inp = t.get("input", {})
    old_s = inp.get("old_string", "") if t["name"] == "edit_file" else ""
    new_s = inp.get("new_string", "") if t["name"] == "edit_file" else inp.get("content", "")

    match = old_s in ts_file if t["name"] == "edit_file" else True
    typos = [p for p in TYPOS if p in new_s]

    # Also check for garbled characters (brackets/parens swapped, etc)
    garbled = []
    for bad in ['} =>', '} =', '(}', '{)', 'req.restd', 'reqbody', 'res.statu(', 'pool.quer(']:
        if bad in new_s:
            garbled.append(bad)

    passed = match and not typos and not garbled and t["name"] in ("edit_file", "write_file")

    return (passed, {
        "tool": t["name"], "match": match, "typos": typos, "garbled": garbled,
        "time": elapsed,
        "old_preview": repr(old_s[:80]) if not match else None,
        "new_preview": new_s[:120] if (typos or garbled) else None
    })

# Context levels: pairs of messages → approximate token count
# Each pair is ~100 tokens, so 150 pairs ≈ 15K, 300 ≈ 30K, 450 ≈ 45K
CONTEXT_LEVELS = [
    (0, "baseline"),
    (150, "~30K"),
    (300, "~60K"),
    (450, "~90K"),
]

test_prompt = "Add input validation to POST /todos: title must be a non-empty string, return 400 if invalid."

results = {"config": config_label, "levels": {}}

for n_pairs, level_name in CONTEXT_LEVELS:
    ok, d = run_test(test_prompt, n_pairs)
    d["level"] = level_name
    d["passed"] = ok
    d["context_pairs"] = n_pairs
    results["levels"][level_name] = d

    status = "PASS" if ok else "FAIL"
    detail = ""
    if not ok:
        if d.get("typos"): detail = f" typos={d['typos']}"
        elif d.get("garbled"): detail = f" garbled={d['garbled']}"
        elif not d.get("match", True): detail = f" !match"
        elif d.get("error"): detail = f" {d['error'][:60]}"
    time_s = d.get("time", 0)
    print(f"  {level_name:>10}: {status}{detail} ({time_s:.0f}s)", flush=True)

total_pass = sum(1 for v in results["levels"].values() if v["passed"])
results["score"] = f"{total_pass}/{len(CONTEXT_LEVELS)}"
print(json.dumps(results))
PYTEST
)

kill_server() {
    pkill -f "llama-server.*$BACKEND_PORT" 2>/dev/null
    pkill -f "llama-deep-proxy.*$PROXY_PORT" 2>/dev/null
    sleep 2
}

start_server() {
    label="$1"
    shift
    extra_args=("$@")

    kill_server
    > "$DEEP_LOG"

    export ROCBLAS_USE_HIPBLASLT=1
    export HSA_XNACK=1
    export LD_LIBRARY_PATH="$BUILD_DIR/bin:$BUILD_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    cmd=(
        "$SERVER" -m "$MODEL"
        -ngl $NGL -c $CONTEXT -fa on
        --threads $THREADS --no-mmap -dio
        --timeout 3600 --host $HOST --port $BACKEND_PORT
        --api-key "$API_KEY" --parallel 1 --kv-unified
        -ctk q8_0 -ctv q8_0
        "${extra_args[@]}"
    )

    "${cmd[@]}" > /tmp/llama-server-sweep.log 2>&1 &
    server_pid=$!

    node "$PROXY" $PROXY_PORT $BACKEND_PORT "$DEEP_LOG" > /dev/null 2>&1 &

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
    label="$1"
    python3 -c "$PYTHON_TEST" "$BASE_URL" "$API_KEY" "$label" 2>/dev/null
}

echo "Parameter Sweep v2 — HIGH CONTEXT — $(date)" | tee "$RESULTS_FILE"
echo "Model: $(basename $MODEL)" | tee -a "$RESULTS_FILE"
echo "Context: $CONTEXT" | tee -a "$RESULTS_FILE"
echo "Tests at: baseline, ~30K, ~60K, ~90K tokens" | tee -a "$RESULTS_FILE"
echo "========================================" | tee -a "$RESULTS_FILE"

# Focused configs — the ones that actually matter
CONFIGS=(
    # Baseline (user's current working config)
    "baseline:t=0.3,k=20|--temp 0.3 --top-k 20 --top-p 0.95"
    # Temperature
    "t=0.1,k=20|--temp 0.1 --top-k 20 --top-p 0.95"
    "t=0.2,k=20|--temp 0.2 --top-k 20 --top-p 0.95"
    "t=0.5,k=20|--temp 0.5 --top-k 20 --top-p 0.95"
    # top_k
    "t=0.3,k=5|--temp 0.3 --top-k 5 --top-p 0.95"
    "t=0.3,k=10|--temp 0.3 --top-k 10 --top-p 0.95"
    "t=0.3,k=40|--temp 0.3 --top-k 40 --top-p 0.95"
    # min_p (interesting - can replace top_k)
    "t=0.3,k=20,minp=0.1|--temp 0.3 --top-k 20 --top-p 0.95 --min-p 0.1"
    "t=0.3,k=0,minp=0.1|--temp 0.3 --top-k 0 --top-p 1.0 --min-p 0.1"
    # DRY at values that might cause issues at high context
    "t=0.3,k=20,dry=0.3|--temp 0.3 --top-k 20 --top-p 0.95 --dry-multiplier 0.3 --dry-base 1.75 --dry-allowed-length 2 --dry-penalty-last-n 256"
    "t=0.3,k=20,dry=0.8|--temp 0.3 --top-k 20 --top-p 0.95 --dry-multiplier 0.8 --dry-base 1.75 --dry-allowed-length 2 --dry-penalty-last-n 512"
    # Repeat penalty
    "t=0.3,k=20,rep=1.05|--temp 0.3 --top-k 20 --top-p 0.95 --repeat-penalty 1.05 --repeat-last-n 256"
    # The old v3 config (to reproduce the original failure)
    "v3:t=0.7,k=40,dry=0.8,rep=1.05|--temp 0.7 --top-k 40 --top-p 0.95 --repeat-penalty 1.05 --repeat-last-n 256 --dry-multiplier 0.8 --dry-base 1.75 --dry-allowed-length 2 --dry-penalty-last-n 512"
    # KV cache
    "t=0.3,k=20,kv=q4_0|--temp 0.3 --top-k 20 --top-p 0.95 -ctk q4_0 -ctv q4_0"
    "t=0.3,k=20,kv=f16|--temp 0.3 --top-k 20 --top-p 0.95 -ctk f16 -ctv f16"
)

TOTAL_CONFIGS=${#CONFIGS[@]}
echo "Configs: $TOTAL_CONFIGS (x4 context levels = $((TOTAL_CONFIGS * 4)) tests)" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

for idx in "${!CONFIGS[@]}"; do
    IFS='|' read -r label args <<< "${CONFIGS[$idx]}"
    IFS=' ' read -ra extra <<< "$args"

    echo "[$((idx+1))/$TOTAL_CONFIGS] $label" | tee -a "$RESULTS_FILE"

    if start_server "$label" "${extra[@]}"; then
        result=$(run_tests "$label")
        score=$(echo "$result" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['score'])" 2>/dev/null)
        echo "  Score: $score" | tee -a "$RESULTS_FILE"
        echo "$result" >> "$RESULTS_FILE"
        echo "" >> "$RESULTS_FILE"
    else
        echo "  Score: SERVER_FAIL" | tee -a "$RESULTS_FILE"
        echo "" >> "$RESULTS_FILE"
    fi
done

kill_server

echo "========================================" | tee -a "$RESULTS_FILE"
echo "Sweep v2 complete — $(date)" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"
echo "SUMMARY:" | tee -a "$RESULTS_FILE"
grep -E '^\[|Score:' "$RESULTS_FILE" | paste - - | sed 's/\[.*\] //;s/  Score: / → /' | tee -a "$RESULTS_FILE"
