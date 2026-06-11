#!/bin/bash

# Llama Server Model Launcher
# Lists models in /usr/local/share/llama.cpp/models/ and lets you select one

MODELS_DIR="/usr/local/share/llama.cpp/models"

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
HSA_XNACK=1 /path/to/llama.cpp/build/bin/llama-server \
  -m "$model_path" \
  -ngl 99 \
  -c 262144 \
  -fa on \
  --temp 1 \
  --log-verbosity 3 \
  --no-mmap \
  --timeout 3600 \
  --top-p 0.95 \
  --top-k 20 \
  --jinja \
  --port 8080 \
  --host 0.0.0.0 \
  --n-gpu-layers 99 \
  --api-key sk-local \
  --swa-full \
  --no-context-shift >> llama.log