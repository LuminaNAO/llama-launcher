#!/bin/bash

# Benchmark llama.cpp servers
# Interactive model selection, same as launcher

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
LLAMA_LAUNCHER_DIR="$SCRIPT_DIR"

# Config file for storing user-selected models path
CONFIG_FILE="$HOME/.llama-launcher-config"

# Default path
DEFAULT_MODELS_DIR="/usr/local/share/llama.cpp/models"

# Load config from previous session if it exists
if [ -f "$CONFIG_FILE" ]; then
    eval "$(cat "$CONFIG_FILE")"
    export LLAMACPP_MODELS_DIR
    MODELS_DIR="$LLAMACPP_MODELS_DIR"
    echo "📝 Using saved path: $MODELS_DIR"
    echo ""
else
    MODELS_DIR="$DEFAULT_MODELS_DIR"
    echo "📝 No saved path, using default: $MODELS_DIR"
    echo ""
fi

# Force re-evaluation of MODELS_DIR from environment
MODELS_DIR="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"

# Check if we have models at the current path
models=()
while IFS= read -r -d '' file; do
    models+=("$(basename "$file")")
done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)

if [ ${#models[@]} -eq 0 ]; then
    echo -e "${RED}❌ No .gguf models found at $MODELS_DIR${NC}"
    echo ""
    read -rp "Enter path to models directory: " new_path
    # Save to config for next time
    echo "LLAMACPP_MODELS_DIR=$new_path" > "$CONFIG_FILE"
    echo "✅ Path saved to $CONFIG_FILE for next launch"
    echo ""
    # Update MODELS_DIR for current session
    MODELS_DIR="$new_path"
    # Re-scan models
    models=()
    while IFS= read -r -d '' file; do
        models+=("$(basename "$file")")
    done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)
fi

# Force re-evaluation of MODELS_DIR from environment
MODELS_DIR="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"

# Determine build type (rocm, vulkan, or default)
BUILD_TYPE="${LLAMACPP_BUILD_TYPE:-rocm}"

# Find llama-server based on build type
BUILD_DIR="$LLAMA_LAUNCHER_DIR/builds/$BUILD_TYPE"
LLAMACPP_SERVER_PATH="$BUILD_DIR/bin/llama-server"

# Check if server exists
if [ ! -f "$LLAMACPP_SERVER_PATH" ]; then
    echo -e "${RED}❌ llama-server not found for $BUILD_TYPE${NC}"
    echo ""
    echo "Available builds:"
    if [ -d "$LLAMA_LAUNCHER_DIR/builds" ]; then
        for dir in "$LLAMA_LAUNCHER_DIR"/builds/*/; do
            if [ -d "$dir" ]; then
                backend=$(basename "$dir")
                if [ -f "$dir/bin/llama-server" ]; then
                    echo -e "  ${GREEN}✅ $backend${NC}"
                else
                    echo -e "  ${YELLOW}⚠️  $backend (not built)${NC}"
                fi
            fi
        done
    else
        echo -e "  ${RED}❌ No builds directory found${NC}"
    fi
    echo ""
    echo "Build a backend first:"
    echo "  cd $LLAMA_LAUNCHER_DIR"
    echo "  ./build.sh $BUILD_TYPE"
    exit 1
fi

# List available models
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} llama.cpp Benchmark${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Backend: ${GREEN}$BUILD_TYPE${NC}"
echo -e "Models dir: ${YELLOW}$MODELS_DIR${NC}"
echo ""
echo -e "${BLUE}Available models:${NC}"
echo ""

for i in "${!models[@]}"; do
    printf "%d) %s\n" $((i+1)) "${models[$i]}"
done
echo ""

# Ask user to select
read -rp "Select model [1-${#models[@]}]: " selection

# Validate selection
if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#models[@]} ]; then
    echo -e "${RED}❌ Invalid selection${NC}"
    exit 1
fi

# Get selected model
selected_model="${models[$((selection-1))]}"
MODEL_PATH="${MODELS_DIR}/${selected_model}"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} llama.cpp Benchmark${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Backend: ${GREEN}$BUILD_TYPE${NC}"
echo -e "Model:   $MODEL_PATH"
echo -e "Server:  $LLAMACPP_SERVER_PATH"
echo ""
echo -e "${BLUE}========================================${NC}"
echo ""

# Start server in background
echo -e "${YELLOW}Starting llama-server...${NC}"
export LLAMACPP_BUILD_TYPE="$BUILD_TYPE"

case "$BUILD_TYPE" in
    rocm)
        export ROCBLAS_USE_HIPBLASLT=1
        export HSA_XNACK=1
        ;;
    vulkan)
        export VK_ICD_FILENAMES=""
        ;;
esac

# Start server
"$LLAMACPP_SERVER_PATH" \
  -m "$MODEL_PATH" \
  -ngl 99 \
  -c 122144 \
  -fa on \
  --temp 0.3 \
  --top-p 0.95 \
  --top-k 20 \
  --threads $(nproc) \
  --no-mmap \
  --host 0.0.0.0 \
  --port 40801 \
  --api-key ollama-local \
  --jinja \
  --swa-full \
  > "$HOME/llama-server-$BUILD_TYPE.log" 2>&1 &

SERVER_PID=$!

# Wait for server to start
echo -e "${YELLOW}Waiting for server to start...${NC}"
sleep 5

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}❌ Server failed to start${NC}"
    echo ""
    echo "Check logs:"
    echo "  cat $HOME/llama-server-$BUILD_TYPE.log"
    exit 1
fi

echo -e "${GREEN}✅ Server running (PID: $SERVER_PID)${NC}"
echo ""

# Benchmark function
benchmark() {
    local test_name="$1"
    local prompt="$2"
    local max_tokens="$3"

    echo -e "${BLUE}Test: $test_name${NC}"
    echo -e "Prompt: $prompt"
    echo -e "Max tokens: $max_tokens"
    echo ""

    # Start timer
    START_TIME=$(date +%s.%N)

    # Send request with timeout
    response=$(curl -s -m 300 -X POST http://localhost:40801/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ollama-local" \
        -d "{
            \"model\": \"$(basename "$MODEL_PATH")\",
            \"messages\": [
                {\"role\": \"user\", \"content\": \"$prompt\"}
            ],
            \"max_tokens\": $max_tokens,
            \"temperature\": 0.3,
            \"top_p\": 0.95,
            \"top_k\": 20
        }")

    # End timer
    END_TIME=$(date +%s.%N)
    DURATION=$(awk "BEGIN {print $END_TIME - $START_TIME}")

    # Extract tokens per second
    tokens_per_sec=$(awk "BEGIN {print $max_tokens / $DURATION}")

    # Extract completion tokens from response using jq
    completion_tokens=$(echo "$response" | jq -r '.completion_tokens // 0' 2>/dev/null || echo "0")

    # Extract total tokens from response using jq
    total_tokens=$(echo "$response" | jq -r '.total_tokens // 0' 2>/dev/null || echo "0")

    echo -e "Duration: ${YELLOW}${DURATION}s${NC}"
    echo -e "Tokens generated: ${GREEN}${completion_tokens}${NC}"
    echo -e "Total tokens: ${GREEN}${total_tokens}${NC}"
    echo -e "Tokens/sec: ${GREEN}${tokens_per_sec}${NC}"
    echo ""

    # Print first 200 chars of response
    if echo "$response" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
        echo -e "Response preview:"
        echo "$response" | jq -r '.choices[0].message.content' | cut -c1-200
        echo "..."
    else
        echo -e "Response preview: (error parsing response)"
        echo "$response" | head -c 200
        echo "..."
    fi
    echo ""

    # Save results
    echo "$BUILD_TYPE|$test_name|$DURATION|$completion_tokens|$total_tokens|$tokens_per_sec" >> "$HOME/benchmark-results.csv"

    echo -e "${BLUE}----------------------------------------${NC}"
    echo ""
}

# Run benchmarks
echo -e "${BLUE}Running benchmarks...${NC}"
echo ""

# Set timeout for the entire benchmark (in seconds)
BENCHMARK_TIMEOUT=600

# Run benchmarks with timeout
(
    benchmark "Short response" "What is 2+2?" 100
    benchmark "Medium response" "Explain quantum computing in simple terms." 500
    benchmark "Long response" "Write a detailed essay about the history of artificial intelligence." 1000
) &
BENCHMARK_PID=$!

# Wait for benchmarks to complete or timeout
if ! wait $BENCHMARK_PID; then
    echo -e "${YELLOW}⚠️  Benchmark timed out or failed${NC}"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

# Stop server
echo -e "${YELLOW}Stopping server...${NC}"
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true

echo -e "${GREEN}✅ Benchmark complete${NC}"
echo ""
echo "Results saved to: $HOME/benchmark-results.csv"
echo ""
echo "Summary:"
echo "  Backend | Test | Duration | Tokens | Total | Tokens/sec"
cat "$HOME/benchmark-results.csv" | column -t -s '|'