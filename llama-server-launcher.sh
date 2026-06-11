#!/bin/bash

# Llama Server Model Launcher
# Lists models in $LLAMACPP_MODELS_DIR and lets you select one
# Override paths via environment variables if needed:
#   export LLAMACPP_MODELS_DIR=/path/to/models
#   export LLAMACPP_SERVER_PATH=/path/to/llama-server

# Default paths (can be overridden via environment variables)
MODELS_DIR="${LLAMACPP_MODELS_DIR:-/usr/local/share/llama.cpp/models}"
#LLAMACPP_SERVER_PATH="${LLAMACPP_SERVER_PATH:-$(dirname "$(readlink -f "$0")")/../../llama.cpp/build/bin/llama-server}"
LLAMACPP_SERVER_PATH="/srv/shared/git/llama.cpp/build/bin/llama-server"

echo "🔍 Scanning models in $MODELS_DIR..."
echo ""

# Get list of .gguf files
models=()
while IFS= read -r -d '' file; do
    models+=("$(basename "$file")")
done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0)

if [ ${#models[@]} -eq 0 ]; then
    echo "❌ No .gguf models found in $MODELS_DIR"
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

# Run llama-server with the selected model
export ROCBLAS_USE_HIPBLASLT=1
export GGML_HIP_FORCE_MMQ=1
export HSA_XNACK=1
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
"$LLAMACPP_SERVER_PATH" \
  -m "$model_path" \
  -ngl 99 \
  -c 122144 \
  -fa on \
  --temp 0.7 \
  --top-p 0.95 \
  --top-k 20 \
  --threads $(nproc) \
  --no-mmap \
  --timeout 3600 \
  --host 0.0.0.0 \
  --port 40801 \
  --api-key ollama-local \
  --jinja \
  --swa-full &> $HOME/llama.log
