#!/bin/bash
# Code-editing quality test — tests model's ability to correctly modify existing code
# Uses /v1/messages (Anthropic API format) with tool_use
#
# Checks for: typos in identifiers, hallucinated APIs, malformed tool calls,
# semantic correctness of edits
#
# Usage: ./code-edit-quality.sh [host:port] [api-key]

HOST="${1:-localhost:8080}"
API_KEY="${2:-ollama-local}"
BASE_URL="http://$HOST"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
TMPDIR_TEST=$(mktemp -d)
trap "rm -rf $TMPDIR_TEST" EXIT

echo -e "${YELLOW}Code-Editing Quality Test${NC}"
echo -e "${YELLOW}Server: $BASE_URL${NC}"
echo ""

if ! curl -s --max-time 5 "$BASE_URL/health" | grep -q '"ok"'; then
    echo -e "${RED}Server not responding on $BASE_URL${NC}"
    exit 1
fi

# Generate all payloads with Python (avoids quoting hell)
python3 - "$TMPDIR_TEST" << 'PYEOF'
import json, sys, os

tmpdir = sys.argv[1]

tools = [
    {
        "name": "edit_file",
        "description": "Edit a file by replacing old_string with new_string. The old_string must match exactly.",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Path to the file to edit"},
                "old_string": {"type": "string", "description": "The exact string to find and replace"},
                "new_string": {"type": "string", "description": "The replacement string"}
            },
            "required": ["file_path", "old_string", "new_string"]
        }
    },
    {
        "name": "write_file",
        "description": "Write content to a file, creating or overwriting it",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Path to the file to write"},
                "content": {"type": "string", "description": "Content to write"}
            },
            "required": ["file_path", "content"]
        }
    },
    {
        "name": "read_file",
        "description": "Read a file from the filesystem",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the file to read"}
            },
            "required": ["path"]
        }
    }
]

system = "You are a coding assistant. When asked to edit code, use the edit_file tool with the exact old_string that needs to be replaced and the new_string to replace it with. Use write_file only when creating new files. Always use tools rather than describing changes."

buggy_service = '''// File: /project/src/user-service.ts
import { db } from "./database";

interface User {
  id: string;
  name: string;
  email: string;
  role: "admin" | "user" | "guest";
}

export class UserService {
  async getUser(id: string): Promise<User> {
    const user = await db.users.findOne({ id });
    return {
      id: user.id,
      name: user.name,
      email: user.email,
      role: user.role,
    };
  }

  async updateUser(id: string, data: Partial<User>): Promise<User> {
    const user = await db.users.findOne({ id });
    Object.assign(user, data);
    await db.users.save(user);
    return user;
  }

  async deleteUser(id: string): Promise<void> {
    await db.users.deleteOne({ id });
  }
}'''

callback_code = '''// File: /project/src/api-client.ts
import { config } from "./config";

export function fetchUserData(userId: string) {
  return fetch(config.apiUrl + "/users/" + userId)
    .then(function(response) {
      if (!response.ok) {
        throw new Error("HTTP " + response.status);
      }
      return response.json();
    })
    .then(function(data) {
      return {
        id: data.id,
        name: data.name,
        posts: data.posts.map(function(p: any) {
          return { title: p.title, date: new Date(p.created_at) };
        })
      };
    })
    .then(function(user) {
      console.log("Fetched user:", user.name);
      return user;
    });
}'''

rename_code = '''// File: /project/src/report-generator.ts
export function generateReport(data: any[]) {
  const usr = data.filter(d => d.type === "user");
  const activeUsr = usr.filter(u => u.active);
  const usrCount = activeUsr.length;

  return {
    totalUsers: usrCount,
    users: activeUsr.map(u => ({
      name: u.name,
      lastLogin: u.lastLogin,
    })),
    summary: `Found ${usrCount} active users out of ${usr.length} total`,
  };
}'''

untyped_code = '''// File: /project/src/cache.ts
export class SimpleCache {
  private store = new Map();
  private ttls = new Map();

  set(key, value, ttlMs) {
    this.store.set(key, value);
    if (ttlMs) {
      const expiry = Date.now() + ttlMs;
      this.ttls.set(key, expiry);
    }
  }

  get(key) {
    const expiry = this.ttls.get(key);
    if (expiry && Date.now() > expiry) {
      this.store.delete(key);
      this.ttls.delete(key);
      return undefined;
    }
    return this.store.get(key);
  }

  has(key) {
    return this.get(key) !== undefined;
  }

  delete(key) {
    this.store.delete(key);
    this.ttls.delete(key);
  }

  clear() {
    this.store.clear();
    this.ttls.clear();
  }
}'''

# Test definitions: (id, name, prompt, code_snippet, context_pad_pairs, check_type)
tests = [
    # Baseline
    (1, "T1: Fix null bug in getUser", "Here is a TypeScript file with a bug. The getUser method crashes when the user is not found because it tries to access properties on null. Fix it by adding a null check that throws a proper error.\n\n" + buggy_service, 0, "null_check"),
    (2, "T2: Add getByEmail method", "Add a getByEmail(email: string) method to this UserService class. It should query db.users.findOne({ email }) and return the user, throwing an error if not found.\n\n" + buggy_service, 0, "add_method"),
    (3, "T3: Refactor callbacks to async/await", "Refactor this function to use async/await instead of .then() callback chains. Keep the same logic and error handling.\n\n" + callback_code, 0, "async_refactor"),
    (4, "T4: Rename usr to userRecords", "Rename the variable 'usr' to 'userRecords' throughout this file. Also rename 'activeUsr' to 'activeUserRecords' and 'usrCount' to 'userRecordCount'. Make sure all references are updated.\n\n" + rename_code, 0, "rename"),
    (5, "T5: Add TypeScript types", "Add proper TypeScript type annotations to this SimpleCache class. The key should be string, value should be generic type T. Add types to all method parameters and return types.\n\n" + untyped_code, 0, "types"),
    # 20K context
    (6, "T6: Fix null bug (20K ctx)", "Here is a TypeScript file with a bug. The getUser method crashes when the user is not found because it tries to access properties on null. Fix it by adding a null check that throws a proper error.\n\n" + buggy_service, 100, "null_check"),
    (7, "T7: Refactor async/await (20K ctx)", "Refactor this function to use async/await instead of .then() callback chains. Keep the same logic and error handling.\n\n" + callback_code, 100, "async_refactor"),
    (8, "T8: Add TypeScript types (20K ctx)", "Add proper TypeScript type annotations to this SimpleCache class. The key should be string, value should be generic type T. Add types to all method parameters and return types.\n\n" + untyped_code, 100, "types"),
    # 50K context
    (9, "T9: Fix null bug (50K ctx)", "Here is a TypeScript file with a bug. The getUser method crashes when the user is not found because it tries to access properties on null. Fix it by adding a null check that throws a proper error.\n\n" + buggy_service, 250, "null_check"),
    (10, "T10: Refactor async/await (50K ctx)", "Refactor this function to use async/await instead of .then() callback chains. Keep the same logic and error handling.\n\n" + callback_code, 250, "async_refactor"),
    (11, "T11: Rename variables (50K ctx)", "Rename the variable 'usr' to 'userRecords' throughout this file. Also rename 'activeUsr' to 'activeUserRecords' and 'usrCount' to 'userRecordCount'. Make sure all references are updated.\n\n" + rename_code, 250, "rename"),
    # 80K context
    (12, "T12: Fix null bug (80K ctx)", "Here is a TypeScript file with a bug. The getUser method crashes when the user is not found because it tries to access properties on null. Fix it by adding a null check that throws a proper error.\n\n" + buggy_service, 400, "null_check"),
    (13, "T13: Add method (80K ctx)", "Add a getByEmail(email: string) method to this UserService class. It should query db.users.findOne({ email }) and return the user, throwing an error if not found.\n\n" + buggy_service, 400, "add_method"),
    (14, "T14: Add TypeScript types (80K ctx)", "Add proper TypeScript type annotations to this SimpleCache class. The key should be string, value should be generic type T. Add types to all method parameters and return types.\n\n" + untyped_code, 400, "types"),
]

for tid, name, prompt, pad, check_type in tests:
    messages = []
    for i in range(pad):
        messages.append({"role": "user", "content": f"Explain concept {i+1} about software architecture patterns and design principles in distributed systems."})
        messages.append({"role": "assistant", "content": f"Concept {i+1}: Software architecture involves organizing code into maintainable, scalable structures. Key patterns include MVC for separation of concerns, CQRS for read/write optimization, and event sourcing for audit trails."})
    messages.append({"role": "user", "content": prompt})

    req = {
        "model": "test",
        "max_tokens": 4096,
        "stream": False,
        "system": system,
        "messages": messages,
        "tools": tools
    }

    outfile = os.path.join(tmpdir, f"req_{tid}.json")
    with open(outfile, "w") as f:
        json.dump(req, f)

    meta = {"id": tid, "name": name, "check_type": check_type, "pad": pad}
    with open(os.path.join(tmpdir, f"meta_{tid}.json"), "w") as f:
        json.dump(meta, f)

    sz = os.path.getsize(outfile)
    print(f"  {name}: {sz // 1024}K payload")

print(f"TOTAL_TESTS={len(tests)}")
PYEOF

echo ""

TOTAL_TESTS=$(ls "$TMPDIR_TEST"/req_*.json 2>/dev/null | wc -l)
PASS=0
FAIL=0
DETAILS=""
CURRENT_SECTION=""

for tid in $(seq 1 $TOTAL_TESTS); do
    meta=$(cat "$TMPDIR_TEST/meta_${tid}.json")
    name=$(echo "$meta" | jq -r '.name')
    check_type=$(echo "$meta" | jq -r '.check_type')
    pad=$(echo "$meta" | jq -r '.pad')

    # Section headers
    case "$tid" in
        1) echo -e "${YELLOW}=== Baseline (no context padding) ===${NC}" ;;
        6) echo -e "\n${YELLOW}=== With ~20K context padding ===${NC}" ;;
        9) echo -e "\n${YELLOW}=== With ~50K context padding ===${NC}" ;;
        12) echo -e "\n${YELLOW}=== With ~80K context padding ===${NC}" ;;
    esac

    printf "${CYAN}%-45s${NC} " "$name"

    start_ns=$(date +%s%N)
    response=$(curl -s --max-time 180 "$BASE_URL/v1/messages" \
        -H "x-api-key: $API_KEY" \
        -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -d @"$TMPDIR_TEST/req_${tid}.json" 2>&1)
    elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))

    echo "$response" > "$TMPDIR_TEST/resp_${tid}.json"

    # Check for errors
    error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$error" ]; then
        printf "${RED}ERROR${NC} %s (%dms)\n" "$error" "$elapsed_ms"
        FAIL=$((FAIL + 1))
        DETAILS+="  $name: server error: $error\n"
        continue
    fi

    # Extract tool calls
    tool_uses=$(echo "$response" | jq '[.content[] | select(.type=="tool_use")]' 2>/dev/null)
    num_tools=$(echo "$tool_uses" | jq 'length' 2>/dev/null)
    text_content=$(echo "$response" | jq -r '[.content[] | select(.type=="text") | .text] | join("")' 2>/dev/null)
    stop_reason=$(echo "$response" | jq -r '.stop_reason // "?"' 2>/dev/null)

    if [ "${num_tools:-0}" -eq 0 ]; then
        printf "${RED}FAIL${NC} no tool call, stop=%s (%dms)\n" "$stop_reason" "$elapsed_ms"
        [ -n "$text_content" ] && echo "    $(echo "$text_content" | head -c 120)"
        FAIL=$((FAIL + 1))
        DETAILS+="  $name: no tool_use in response\n"
        continue
    fi

    # Validate based on check type
    tool_name=$(echo "$tool_uses" | jq -r '.[0].name' 2>/dev/null)
    input_json=$(echo "$tool_uses" | jq '.[0].input' 2>/dev/null)

    # Get the code content from the tool response
    if [ "$tool_name" = "edit_file" ]; then
        code_output=$(echo "$input_json" | jq -r '.new_string // empty' 2>/dev/null)
        old_str=$(echo "$input_json" | jq -r '.old_string // empty' 2>/dev/null)
        file_path=$(echo "$input_json" | jq -r '.file_path // empty' 2>/dev/null)
    elif [ "$tool_name" = "write_file" ]; then
        code_output=$(echo "$input_json" | jq -r '.content // empty' 2>/dev/null)
        file_path=$(echo "$input_json" | jq -r '.file_path // empty' 2>/dev/null)
        old_str=""
    else
        code_output=""
        file_path=""
        old_str=""
    fi

    # Common typo check
    typo_found=""
    for pattern in funciton retrun cosnt lenegth udpate proimse calback requst respnse mesage awiat asnyc asynv; do
        if echo "$code_output" | grep -qi "$pattern"; then
            typo_found+="$pattern "
        fi
    done

    result_msg=""
    check_pass=true

    case "$check_type" in
        null_check)
            if [ "$tool_name" != "edit_file" ]; then
                result_msg="used $tool_name instead of edit_file"
                check_pass=false
            elif ! echo "$code_output" | grep -qiE '(if\s*\(!?\s*user|user\s*[!=]==?\s*(null|undefined)|user\?\.|user\s*&&|!user|\?\?\s*null|throw)'; then
                result_msg="no null check: $(echo "$code_output" | head -c 80)"
                check_pass=false
            elif [ -n "$typo_found" ]; then
                result_msg="typos: $typo_found"
                check_pass=false
            else
                result_msg="null check added via $tool_name"
            fi
            ;;
        add_method)
            if echo "$code_output" | grep -qE '(getByEmail|findByEmail|getUserByEmail)'; then
                if [ -n "$typo_found" ]; then
                    result_msg="typos: $typo_found"
                    check_pass=false
                else
                    result_msg="method added via $tool_name"
                fi
            else
                result_msg="method not found: $(echo "$code_output" | head -c 80)"
                check_pass=false
            fi
            ;;
        async_refactor)
            if ! echo "$code_output" | grep -qE '(async|await)'; then
                result_msg="no async/await"
                check_pass=false
            elif echo "$code_output" | grep -qE '\.then\s*\('; then
                result_msg="still has .then() callbacks"
                check_pass=false
            elif [ -n "$typo_found" ]; then
                result_msg="typos: $typo_found"
                check_pass=false
            else
                result_msg="async/await conversion correct"
            fi
            ;;
        rename)
            all_code="$code_output"
            # Check across all tool calls
            for i in $(seq 1 $((num_tools - 1))); do
                extra=$(echo "$tool_uses" | jq -r ".[$i].input.new_string // empty" 2>/dev/null)
                all_code+="$extra"
            done
            if echo "$all_code" | grep -q 'userRecords'; then
                if [ -n "$typo_found" ]; then
                    result_msg="typos: $typo_found"
                    check_pass=false
                else
                    result_msg="$num_tools edit(s), renamed correctly"
                fi
            else
                result_msg="'userRecords' not in output"
                check_pass=false
            fi
            ;;
        types)
            if echo "$code_output" | grep -qE '(:\s*(string|number|boolean|void|Promise|Record|Map|Set|Array|T)\b|<T>|interface\s|type\s)'; then
                for bad in 'Int32' 'Float64' 'uint' 'i32' 'u32' 'Vec<' 'HashMap' 'Option<' 'Result<'; do
                    if echo "$code_output" | grep -q "$bad"; then
                        result_msg="hallucinated type: $bad"
                        check_pass=false
                        break
                    fi
                done
                if $check_pass; then
                    if [ -n "$typo_found" ]; then
                        result_msg="typos: $typo_found"
                        check_pass=false
                    else
                        result_msg="TS types added via $tool_name"
                    fi
                fi
            else
                result_msg="no type annotations: $(echo "$code_output" | head -c 80)"
                check_pass=false
            fi
            ;;
    esac

    if $check_pass; then
        printf "${GREEN}PASS${NC} (%dms) %s\n" "$elapsed_ms" "$result_msg"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${NC} (%dms) %s\n" "$elapsed_ms" "$result_msg"
        FAIL=$((FAIL + 1))
        DETAILS+="  $name: $result_msg\n"
    fi
done

echo ""
echo -e "${YELLOW}════════════════════════════════════${NC}"
echo -e "${YELLOW}Results: $PASS/$TOTAL_TESTS passed, $FAIL failed${NC}"
echo -e "${YELLOW}════════════════════════════════════${NC}"

if [ $FAIL -gt 0 ]; then
    echo -e "\n${RED}Failures:${NC}"
    echo -e "$DETAILS"
fi

# Copy responses for analysis
SAVE_DIR="/tmp/code-edit-results-$(date +%Y%m%d-%H%M%S)"
cp -r "$TMPDIR_TEST" "$SAVE_DIR" 2>/dev/null
echo -e "\nResponses saved: $SAVE_DIR"
