#!/bin/bash
# Freeclaw integration stress test — uses /v1/messages (Anthropic API format)
# Tests tool calling the way Freeclaw actually sends requests.
#
# Usage: ./freeclaw-tool-stress.sh [port] [api-key] [levels...]
# Default levels: 0 2000 5000 10000 20000 35000 45000 60000 80000 100000 110000 120000

PORT="${1:-40801}"
API_KEY="${2:-ollama-local}"
shift 2 2>/dev/null

LEVELS=("${@:-0 2000 5000 10000 20000 35000 45000 60000 80000 100000 110000 120000}")
if [ ${#LEVELS[@]} -eq 0 ] || [ "${LEVELS[0]}" = "" ]; then
    LEVELS=(0 2000 5000 10000 20000 35000 45000 60000 80000 100000 110000 120000)
fi

BASE_URL="http://localhost:$PORT"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf $TMPDIR_TEST" EXIT

echo -e "${YELLOW}Freeclaw Integration Stress Test${NC}"
echo -e "${YELLOW}API: /v1/messages (Anthropic format)${NC}"
echo -e "${YELLOW}Port: $PORT${NC}"
echo ""

# Check server health
if ! curl -s --max-time 5 "$BASE_URL/health" | grep -q '"ok"'; then
    echo -e "${RED}Server not responding on $BASE_URL${NC}"
    exit 1
fi

echo -e "${YELLOW}Pregenerating ${#LEVELS[@]} payloads...${NC}"

python3 - "$TMPDIR_TEST" "${LEVELS[@]}" << 'PYEOF'
import json, sys, os

tmpdir = sys.argv[1]
levels = [int(x) for x in sys.argv[2:]]

# Anthropic-format tools (input_schema, not parameters)
tools = [
    {
        "name": "read_file",
        "description": "Read a file from the filesystem",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute file path to read"}
            },
            "required": ["path"]
        }
    },
    {
        "name": "write_file",
        "description": "Write content to a file on the filesystem",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute file path to write"},
                "content": {"type": "string", "description": "Content to write to the file"}
            },
            "required": ["path", "content"]
        }
    },
    {
        "name": "run_command",
        "description": "Execute a shell command and return its output",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Shell command to execute"}
            },
            "required": ["command"]
        }
    }
]

system_prompt = "You are a helpful coding assistant. When the user asks you to perform filesystem or shell operations, use the appropriate tools. Always use tools when available rather than describing what you would do."

for level in levels:
    messages = []
    if level > 0:
        # Pad with realistic-looking coding conversation
        for i in range(level // 100):
            messages.append({
                "role": "user",
                "content": f"Explain concept {i+1} about distributed systems and the CAP theorem."
            })
            messages.append({
                "role": "assistant",
                "content": f"Concept {i+1}: The CAP theorem states you can only have two of three properties: Consistency, Availability, and Partition tolerance."
            })

    messages.append({
        "role": "user",
        "content": "Read the file at /tmp/test-input.txt and tell me what's in it."
    })

    req = {
        "model": "test",
        "max_tokens": 2048,
        "stream": False,
        "system": system_prompt,
        "messages": messages,
        "tools": tools
    }

    outfile = os.path.join(tmpdir, f"req_{level}.json")
    with open(outfile, "w") as f:
        json.dump(req, f)
    print(f"  {level}: {os.path.getsize(outfile) // 1024}K")

PYEOF

echo -e "${YELLOW}Payloads ready. Firing tests...${NC}\n"

# Test both non-streaming and streaming
for mode in "sync" "stream"; do
    echo -e "${YELLOW}=== Mode: $mode ===${NC}"
    FAILURES=0

    for level in "${LEVELS[@]}"; do
        label="${level}"
        [ "$level" -eq 0 ] && label="baseline"
        [ "$level" -ge 1000 ] && label="$((level/1000))K"

        reqfile="$TMPDIR_TEST/req_${level}.json"

        # For streaming mode, set stream=true
        if [ "$mode" = "stream" ]; then
            tmpfile="$TMPDIR_TEST/req_${level}_stream.json"
            python3 -c "import json,sys; r=json.load(open(sys.argv[1])); r['stream']=True; json.dump(r, open(sys.argv[2],'w'))" "$reqfile" "$tmpfile"
            reqfile="$tmpfile"
        fi

        printf "${YELLOW}%-10s${NC} " "~${label}:"

        start_ns=$(date +%s%N)

        if [ "$mode" = "stream" ]; then
            # For streaming, collect all SSE events and parse
            response=$(curl -s --max-time 300 "$BASE_URL/v1/messages" \
                -H "x-api-key: $API_KEY" \
                -H "Content-Type: application/json" \
                -H "anthropic-version: 2023-06-01" \
                -d @"$reqfile" 2>&1)
            elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))

            # Parse SSE: look for tool_use content blocks and stop_reason
            has_tool=$(echo "$response" | grep -c '"type":"tool_use"')
            stop_reason=$(echo "$response" | grep 'message_delta' | grep -oP '"stop_reason":"[^"]*"' | tail -1)
            tool_name=$(echo "$response" | grep 'content_block_start.*tool_use' | grep -oP '"name":"[^"]*"' | head -1)
            out_tok=$(echo "$response" | grep 'message_delta' | grep -oP '"output_tokens":(\d+)' | tail -1 | grep -oP '\d+')
            error=$(echo "$response" | grep '"error"' | head -1)
            content_text=$(echo "$response" | grep 'content_block_start.*"type":"text"' | head -1)
        else
            response=$(curl -s --max-time 300 "$BASE_URL/v1/messages" \
                -H "x-api-key: $API_KEY" \
                -H "Content-Type: application/json" \
                -H "anthropic-version: 2023-06-01" \
                -d @"$reqfile" 2>&1)
            elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))

            has_tool=$(echo "$response" | jq '[.content[] | select(.type=="tool_use")] | length' 2>/dev/null)
            stop_reason=$(echo "$response" | jq -r '.stop_reason // "?"' 2>/dev/null)
            tool_name=$(echo "$response" | jq -r '[.content[] | select(.type=="tool_use") | .name] | join(", ")' 2>/dev/null)
            out_tok=$(echo "$response" | jq -r '.usage.output_tokens // "?"' 2>/dev/null)
            error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
            content_text=$(echo "$response" | jq -r '[.content[] | select(.type=="text") | .text] | join("")' 2>/dev/null)
        fi

        if [ -n "$error" ]; then
            printf "${RED}ERROR: %s${NC} (%dms)\n" "$error" "$elapsed_ms"
            FAILURES=$((FAILURES + 1))
            continue
        fi

        # Check for analysis tag leakage
        has_analysis=0
        echo "$content_text" | grep -qE '<analysis>' 2>/dev/null && has_analysis=1

        if [ "${has_tool:-0}" -ge 1 ] && [ "$stop_reason" != "\"stop_reason\":\"end_turn\"" ] || [ "$stop_reason" = "tool_use" ]; then
            if [ "$has_analysis" -eq 1 ]; then
                printf "${YELLOW}PASS+LEAK${NC} tool=[%s] out=%s %dms (analysis tags leaked)\n" "$tool_name" "$out_tok" "$elapsed_ms"
            else
                printf "${GREEN}PASS${NC} tool=[%s] out=%s %dms\n" "$tool_name" "$out_tok" "$elapsed_ms"
            fi
        elif [ "${has_tool:-0}" -ge 1 ]; then
            printf "${GREEN}PASS${NC} tool=[%s] stop=%s out=%s %dms\n" "$tool_name" "$stop_reason" "$out_tok" "$elapsed_ms"
        else
            printf "${RED}FAIL${NC} no tool_use, stop=%s out=%s %dms\n" "$stop_reason" "$out_tok" "$elapsed_ms"
            if [ -n "$content_text" ]; then
                echo "  Content: $(echo "$content_text" | head -c 200)"
            fi
            FAILURES=$((FAILURES + 1))
        fi
    done

    echo -e "\n${YELLOW}Mode $mode done. Failures: ${FAILURES}${NC}\n"
done

echo -e "${YELLOW}All tests complete.${NC}"
