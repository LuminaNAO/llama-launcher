#!/bin/bash
# Tool Call Stress Test
# Tests tool calling reliability at increasing context window sizes.
# Pregenerates all payloads upfront, then fires them back-to-back
# to minimize GPU idle time between tests.
#
# Usage:
#   ./tool-call-stress.sh [port] [api_key] [levels...]
#
# Examples:
#   ./tool-call-stress.sh 40802 ollama-local           # default levels
#   ./tool-call-stress.sh 40802 ollama-local 0 50000 100000  # custom levels
#
# Output format:
#   ~LEVEL:  PASS|PARTIAL|FAIL  N tools [names] pt=PROMPT ct=COMPLETION TIMEms
#
# Exit codes:
#   0 = all tests passed (PASS or PARTIAL)
#   1 = at least one FAIL (raw template tags or no tool calls)

PORT="${1:-40802}"
API_KEY="${2:-ollama-local}"
shift 2 2>/dev/null
BASE_URL="http://localhost:$PORT"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf $TMPDIR_TEST" EXIT

# Default context levels if none specified
if [ $# -gt 0 ]; then
    LEVELS=("$@")
else
    LEVELS=(0 2000 5000 10000 20000 35000 45000 60000 80000 100000 110000 120000)
fi

echo -e "${YELLOW}Pregenerating ${#LEVELS[@]} payloads...${NC}"

python3 - "$TMPDIR_TEST" "${LEVELS[@]}" << 'PYEOF'
import json, sys, os
tmpdir = sys.argv[1]
levels = [int(x) for x in sys.argv[2:]]

tools = [
    {"type": "function", "function": {"name": "get_weather", "description": "Get weather for a location", "parameters": {"type": "object", "properties": {"location": {"type": "string"}, "units": {"type": "string", "enum": ["celsius", "fahrenheit"]}}, "required": ["location"]}}},
    {"type": "function", "function": {"name": "search_database", "description": "Search a database table", "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "table": {"type": "string"}, "limit": {"type": "integer"}}, "required": ["query", "table"]}}},
    {"type": "function", "function": {"name": "send_email", "description": "Send an email", "parameters": {"type": "object", "properties": {"to": {"type": "string"}, "subject": {"type": "string"}, "body": {"type": "string"}}, "required": ["to", "subject", "body"]}}}
]

for level in levels:
    messages = [{"role": "system", "content": "You are a helpful assistant with tools. When multiple tools are needed, call them ALL in a single response."}]
    # Generate padding conversation to fill context
    if level > 0:
        for i in range(level // 100):
            messages.append({"role": "user", "content": f"Explain concept {i+1} about distributed systems and the CAP theorem."})
            messages.append({"role": "assistant", "content": f"Concept {i+1}: CAP theorem — Consistency, Availability, Partition tolerance. Pick two. This drives database and microservice architecture decisions."})
    messages.append({"role": "user", "content": "Do three things NOW: 1) Weather in Tokyo 2) Search users table for 'Smith' 3) Send email to bob@example.com subject 'Hello' body 'Testing'. Call ALL three tools."})

    req = {"model": "test", "messages": messages, "tools": tools, "tool_choice": "auto", "parallel_tool_calls": True, "temperature": 1.0, "top_p": 0.95, "top_k": 64, "max_tokens": 2048}
    outfile = os.path.join(tmpdir, f"req_{level}.json")
    with open(outfile, 'w') as f:
        json.dump(req, f)
    print(f"  {level}: {os.path.getsize(outfile) // 1024}K")
PYEOF

echo -e "${YELLOW}Payloads ready. Firing tests...${NC}\n"

FAILURES=0

for level in "${LEVELS[@]}"; do
    label="${level}"
    [ "$level" -eq 0 ] && label="baseline"
    [ "$level" -ge 1000 ] && label="$((level/1000))K"

    reqfile="$TMPDIR_TEST/req_${level}.json"
    printf "${YELLOW}%-10s${NC} " "~${label}:"

    start_ns=$(date +%s%N)
    response=$(curl -s --max-time 300 "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d @"$reqfile" 2>&1)
    elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))

    error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$error" ]; then
        printf "${RED}ERROR: %s${NC} (%dms)\n" "$error" "$elapsed_ms"
        FAILURES=$((FAILURES + 1))
        continue
    fi

    tc=$(echo "$response" | jq -r '.choices[0].message.tool_calls // [] | length' 2>/dev/null)
    names=$(echo "$response" | jq -r '[.choices[0].message.tool_calls[]?.function.name] | join(", ")' 2>/dev/null)
    pt=$(echo "$response" | jq -r '.usage.prompt_tokens // "?"' 2>/dev/null)
    ct=$(echo "$response" | jq -r '.usage.completion_tokens // "?"' 2>/dev/null)
    content=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
    finish=$(echo "$response" | jq -r '.choices[0].finish_reason // "?"' 2>/dev/null)

    raw=0
    echo "$content" | grep -qE '<\|?(turn|channel|tool_call|tool_result)' 2>/dev/null && raw=1

    if [ "${tc:-0}" -ge 3 ] && [ "$raw" -eq 0 ]; then
        printf "${GREEN}PASS${NC} %d tools [%s] pt=%s ct=%s %dms\n" "$tc" "$names" "$pt" "$ct" "$elapsed_ms"
    elif [ "${tc:-0}" -ge 1 ] && [ "$raw" -eq 0 ]; then
        printf "${YELLOW}PARTIAL${NC} %d/3 tools [%s] pt=%s ct=%s %dms\n" "$tc" "$names" "$pt" "$ct" "$elapsed_ms"
    elif [ "$raw" -eq 1 ]; then
        printf "${RED}FAIL${NC} raw tags pt=%s ct=%s %dms\n" "$pt" "$ct" "$elapsed_ms"
        echo "  Content: $(echo "$content" | head -c 200)"
        FAILURES=$((FAILURES + 1))
    else
        printf "${RED}FAIL${NC} no tools finish=%s pt=%s %dms\n" "$finish" "$pt" "$elapsed_ms"
        [ -n "$content" ] && echo "  Content: $(echo "$content" | head -c 200)"
        FAILURES=$((FAILURES + 1))
    fi
done

echo -e "\n${YELLOW}Done. Failures: ${FAILURES}${NC}"
exit $((FAILURES > 0 ? 1 : 0))
