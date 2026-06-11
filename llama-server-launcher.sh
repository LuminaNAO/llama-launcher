#!/bin/bash

# Llama Server Model Launcher
# Lists models in $LLAMACPP_MODELS_DIR and lets you select one
# Override paths via environment variables if needed:
#   export LLAMACPP_MODELS_DIR=/path/to/models
#   export LLAMACPP_SERVER_PATH=/path/to/llama-server
#   export LLAMACPP_BUILD_TYPE=rocm|vulkan|debug|release

# Config file lives in the repo dir so it stays with the project
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.llama-launcher-config"

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

# Check if we have models at the current path, if not prompt for new path
models=()
while IFS= read -r -d '' file; do
    models+=("$(basename "$file")")
done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)

if [ ${#models[@]} -eq 0 ]; then
    echo "❌ No .gguf models found at $MODELS_DIR"
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

# Discover llama.cpp builds dynamically
LLAMA_LAUNCHER_DIR="$SCRIPT_DIR"
LLAMACPP_DIR="$LLAMA_LAUNCHER_DIR/llama.cpp"

# Determine build type (rocm, vulkan, or default)
BUILD_TYPE="${LLAMACPP_BUILD_TYPE:-rocm}"
BUILD_DIR="$LLAMA_LAUNCHER_DIR/builds/$BUILD_TYPE"

# Find llama-server based on build type
if [ "$BUILD_TYPE" = "vulkan" ]; then
    LLAMACPP_SERVER_PATH="$BUILD_DIR/bin/llama-server"
else
    # ROCm and other backends
    LLAMACPP_SERVER_PATH="$BUILD_DIR/bin/llama-server"
fi

# Verify server exists, exit with helpful message if not
if [ ! -f "$LLAMACPP_SERVER_PATH" ]; then
    echo "❌ llama-server not found at $LLAMACPP_SERVER_PATH"
    echo ""
    echo "Available builds:"
    if [ -d "$LLAMA_LAUNCHER_DIR/builds" ]; then
        for dir in "$LLAMA_LAUNCHER_DIR"/builds/*/; do
            if [ -d "$dir" ]; then
                backend=$(basename "$dir")
                if [ -f "$dir/bin/llama-server" ]; then
                    echo "  ✅ $backend"
                else
                    echo "  ⚠️  $backend (not built)"
                fi
            fi
        done
    else
        echo "  ❌ No builds directory found"
    fi
    echo ""
    echo "To build a backend, run:"
    echo "  cd $LLAMA_LAUNCHER_DIR"
    echo "  ./build.sh [rocm|vulkan]"
    echo ""
    echo "Or set LLAMACPP_BUILD_TYPE to specify which build to use:"
    echo "  export LLAMACPP_BUILD_TYPE=rocm"
    echo "  export LLAMACPP_BUILD_TYPE=vulkan"
    exit 1
fi

echo "🔍 Scanning models in $MODELS_DIR..."
echo ""

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
echo "🚀 Starting llama-server"
echo "   Backend: $BUILD_TYPE"
echo "   Build dir: $BUILD_DIR"
echo "   Model: $selected_model"
echo "   Server: $LLAMACPP_SERVER_PATH"
echo ""

# Run llama-server with the selected model
case "$BUILD_TYPE" in
    rocm)
        export ROCBLAS_USE_HIPBLASLT=1
        export HSA_XNACK=1
        export LD_LIBRARY_PATH="$BUILD_DIR/bin:$BUILD_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ;;
    vulkan)
        # Vulkan-specific environment variables if needed
        export VK_ICD_FILENAMES=""
        ;;
    *)
        echo "⚠️  No special environment variables set for $BUILD_TYPE"
        ;;
esac

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
  --swa-full 2>&1 | tee -a "$SCRIPT_DIR/llama.log"
