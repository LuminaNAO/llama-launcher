#!/bin/bash

# Llama Server Model Launcher
# Lists models in $LLAMACPP_MODELS_DIR and lets you select one
# Override paths via environment variables if needed:
#   export LLAMACPP_MODELS_DIR=/path/to/models
#   export LLAMACPP_SERVER_PATH=/path/to/llama-server

# Config file for storing user-selected models path
CONFIG_FILE="$HOME/.llama-launcher-config"

# Default paths (can be overridden via environment variables)
# Note: LLAMACPP_MODELS_DIR is set via config file or environment variable
MODELS_DIR="${LLAMACPP_MODELS_DIR:-/usr/local/share/llama.cpp/models}"

# Check if we have models at the current path, if not prompt for new path
check_and_prompt_path() {
    local models=()
    while IFS= read -r -d '' file; do
        models+=("$(basename "$file")")
    done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)
    
    if [ ${#models[@]} -eq 0 ]; then
        echo "❌ No .gguf models found at $MODELS_DIR"
        echo ""
        read -rp "Enter path to models directory: " new_path
        MODELS_DIR="$new_path"
        # Save to config for next time
        echo "LLAMACPP_MODELS_DIR=$new_path" > "$CONFIG_FILE"
        echo "✅ Path saved to $CONFIG_FILE for next launch"
        echo ""
    fi
}

# Load config from previous session if it exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    export LLAMACPP_MODELS_DIR
    echo "📝 Using saved path: $MODELS_DIR"
    echo ""
fi

# Check if we have models at the current path, if not prompt for new path
check_and_prompt_path

# Find llama.cpp repo and server dynamically
LLAMACPP_BASE="$(dirname "$(readlink -f "$0")")/../llama.cpp"
LLAMACPP_SERVER_PATH="${LLAMACPP_BASE}/build/bin/llama-server"

# Verify server exists, exit with helpful message if not
if [ ! -f "$LLAMACPP_SERVER_PATH" ]; then
    echo "❌ llama-server not found at $LLAMACPP_SERVER_PATH"
    echo "   Expected llama.cpp repo at: $LLAMACPP_BASE"
    exit 1
fi

echo "🔍 Scanning models in $MODELS_DIR..."
echo ""

# Get list of .gguf files
models=()
while IFS= read -r -d '' file; do
    models+=("$(basename "$file")")
done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)

if [ ${#models[@]} -eq 0 ]; then
    echo "❌ No .gguf models found in $MODELS_DIR"
    echo "   Please run the launcher again to set the correct path"
    exit 1
fi

echo "Found ${#models[@]} model(s):"
echo ""
for i in "${!models[@]}"; do
    printf "%d) %s\n" $((i+1)) "${models[$i]}"
done
echo ""

# Ask user to select
read -rp "Select model [1-${#models[@]}]: " selection

# Validate selection
if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#models[@]} ]; then
    echo "❌ Invalid selection"
    exit 1
fi

# Get selected model
selected_model="${models[$((selection-1))]}"
model_path="${MODELS_DIR}/${selected_model}"

echo ""
echo "🚀 Starting llama-server with model: $selected_model"
echo ""

## Run llama-server with the selected model
#export ROCBLAS_USE_HIPBLASLT=1
#export GGML_HIP_FORCE_MMQ=1
#export HSA_XNACK=1
#export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
#"$LLAMACPP_SERVER_PATH" \
#  -m "$model_path" \
#  -ngl 99 \
#  -c 122144 \
#  -fa on \
#  --temp 0.6 \
#  --top-p 0.95 \
#  --top-k 20 \
#  --threads $(nproc) \
#  --no-mmap \
#  --timeout 3600 \
#  --host 0.0.0.0 \
#  --port 40801 \
#  --api-key ollama-local \
#  --jinja \
#  --swa-full &>> $HOME/llama.log

## Optimal environment for RDNA 3.5 / Strix Halo
#export ROCBLAS_USE_HIPBLASLT=1
#export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=0 # Disable experimental for stability
#
#"$LLAMACPP_SERVER_PATH" \
#  -m "$model_path" \
#  -ngl 99 \
#  -c 122144 \
#  -fa on \
#  --temp 0.6 \
#  --top-p 0.95 \
#  --top-k 20 \
#  --threads 16 \
#  --no-mmap \
#  --host 0.0.0.0 \
#  --port 40801 \
#  --api-key ollama-local \
#  --jinja \
#  --no-warmup &>> $HOME/llama.log

# Run llama-server with the selected model
export ROCBLAS_USE_HIPBLASLT=1
export HSA_XNACK=1
"$LLAMACPP_SERVER_PATH" \
  -m "$model_path" \
  -ngl 99 \
  -c 122144 \
  -fa on \
  --temp 0.3 \
  --top-p 0.95 \
  --top-k 20 \
  --threads $(nproc) \
  --no-mmap \
  --timeout 3600 \
  --host 0.0.0.0 \
  --port 40801 \
  --api-key ollama-local \
  --jinja \
  --swa-full 2>&1 | tee -a $HOME/llama.log
