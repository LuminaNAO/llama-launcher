#!/bin/bash

# Llama Server Model Launcher
# Lists models in $LLAMACPP_MODELS_DIR and lets you select one
# Override paths via environment variables if needed:
#   export LLAMACPP_MODELS_DIR=/path/to/models
#   export LLAMACPP_SERVER_PATH=/path/to/llama-server
#   export LLAMACPP_BUILD_TYPE=rocm|vulkan|debug|release
#
# Options:
#   --seed <N>      Override the random seed (default: 42)
#   --mmproj <path> Path to vision projector GGUF for multimodal models

SEED=42
MMPROJ=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed)   SEED="$2";   shift 2 ;;
        --mmproj) MMPROJ="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

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
scan_models() {
    local dir="$1"
    models=()
    while IFS= read -r -d '' file; do
        name="$(basename "$file")"
        # Skip non-first split files (e.g. -00002-of-00006.gguf)
        if [[ "$name" =~ -[0-9]+-of-[0-9]+\.gguf$ ]] && ! [[ "$name" =~ -00001-of-[0-9]+\.gguf$ ]]; then
            continue
        fi
        models+=("$name")
    done < <(find "$dir" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)
}

scan_models "$MODELS_DIR"

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
    scan_models "$MODELS_DIR"
fi

# Force re-evaluation of MODELS_DIR from environment
MODELS_DIR="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"

# Discover llama.cpp builds dynamically
LLAMA_LAUNCHER_DIR="$SCRIPT_DIR"
LLAMACPP_DIR="$LLAMA_LAUNCHER_DIR/llama.cpp"

# Determine build type (rocm, vulkan, or default)
BUILD_TYPE="${LLAMACPP_BUILD_TYPE:-rocm}"
BUILD_DIR="$LLAMA_LAUNCHER_DIR/builds/$BUILD_TYPE"

LLAMACPP_SERVER_PATH="$BUILD_DIR/bin/llama-server"

# Verify server exists, prompt interactively if not
if [ ! -f "$LLAMACPP_SERVER_PATH" ]; then
    echo "⚠️  llama-server not found at $LLAMACPP_SERVER_PATH"
    echo ""

    # Collect available builds
    available_builds=()
    if [ -d "$LLAMA_LAUNCHER_DIR/builds" ]; then
        for dir in "$LLAMA_LAUNCHER_DIR"/builds/*/; do
            if [ -f "$dir/bin/llama-server" ]; then
                available_builds+=("$(basename "$dir")")
            fi
        done
    fi

    if [ ${#available_builds[@]} -gt 0 ]; then
        echo "Available builds:"
        for i in "${!available_builds[@]}"; do
            printf "  %d) %s\n" $((i+1)) "${available_builds[$i]}"
        done
        echo ""
        read -rp "Select build [1-${#available_builds[@]}]: " build_sel
        if [[ "$build_sel" =~ ^[0-9]+$ ]] && [ "$build_sel" -ge 1 ] && [ "$build_sel" -le ${#available_builds[@]} ]; then
            BUILD_TYPE="${available_builds[$((build_sel-1))]}"
            BUILD_DIR="$LLAMA_LAUNCHER_DIR/builds/$BUILD_TYPE"
            LLAMACPP_SERVER_PATH="$BUILD_DIR/bin/llama-server"
        else
            echo "❌ Invalid selection"; exit 1
        fi
    else
        echo "No builds found in $LLAMA_LAUNCHER_DIR/builds/"
        echo ""
        read -rp "Enter path to llama-server binary (or 'q' to quit): " server_path
        if [ "$server_path" = "q" ]; then exit 0; fi
        if [ -f "$server_path" ]; then
            LLAMACPP_SERVER_PATH="$server_path"
            BUILD_DIR="$(dirname "$(dirname "$server_path")")"
            BUILD_TYPE="custom"
        else
            echo "❌ File not found: $server_path"; exit 1
        fi
    fi

    # Save selection for next time
    echo "LLAMACPP_BUILD_TYPE=$BUILD_TYPE" >> "$CONFIG_FILE"
    echo "✅ Build type '$BUILD_TYPE' saved to $CONFIG_FILE"
    echo ""
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
    name="${models[$i]}"
    if [[ "$name" =~ -00001-of-([0-9]+)\.gguf$ ]]; then
        total="${BASH_REMATCH[1]}"
        printf "%d) %s  [split: %d parts]\n" $((i+1)) "$name" "$((10#$total))"
    else
        printf "%d) %s\n" $((i+1)) "$name"
    fi
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
if [ -n "$MMPROJ" ]; then
    if [ ! -f "$MMPROJ" ]; then
        echo "❌ mmproj file not found: $MMPROJ"
        exit 1
    fi
    echo "   Mmproj: $MMPROJ"
fi
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

# ── Detect system RAM and select profile ──────────────────────────────────
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))

# Reserve 20 GB for system
RESERVE_GB=20

echo ""
echo "🖥️  System RAM: ${TOTAL_RAM_GB} GB (reserving ${RESERVE_GB} GB for system)"

if [ "$TOTAL_RAM_GB" -ge 112 ]; then
    # ── 128 GB profile ────────────────────────────────────────────────────
    # Tuned for Qwen3.5-35B-A3B-BF16 on 128GB systems
    # Model weights: ~67 GB. KV cache (q8_0, 488k): ~5 GB. Leaves ~36 GB free.
    # q8_0 KV: negligible quality loss, halves cache memory vs f16
    # 488k unified context: two slots share pool, each can use up to full 488k
    # 40 GB cache ceiling: holds many sessions warm, only allocated on demand
    # Fine checkpoints: 4096-token intervals for precise cache restore
    PROFILE="128gb"
    CONTEXT=488576
    PARALLEL=2
    CACHE_RAM=40960
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=4096
    CHECKPOINT_MAX=64
    echo "📋 Profile: 128 GB (488k context, q8_0 KV, 40 GB cache, 2 slots)"
elif [ "$TOTAL_RAM_GB" -ge 48 ]; then
    # ── 64 GB profile ─────────────────────────────────────────────────────
    # Placeholder — requires a smaller model. Will be tuned separately.
    PROFILE="64gb"
    CONTEXT=122144
    PARALLEL=2
    CACHE_RAM=8192
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=8192
    CHECKPOINT_MAX=32
    echo "📋 Profile: 64 GB (122k context, q8_0 KV, 8 GB cache, 2 slots)"
    echo "⚠️  64 GB profile not yet tuned — using conservative defaults"
else
    # ── Fallback ──────────────────────────────────────────────────────────
    PROFILE="minimal"
    CONTEXT=61072
    PARALLEL=1
    CACHE_RAM=4096
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=8192
    CHECKPOINT_MAX=16
    echo "📋 Profile: minimal (61k context, q8_0 KV, 4 GB cache, 1 slot)"
    echo "⚠️  Low RAM — using minimal settings"
fi

echo ""

"$LLAMACPP_SERVER_PATH" \
  -m "$model_path" \
  -ngl 99 \
  -c "$CONTEXT" \
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
  --parallel "$PARALLEL" \
  --kv-unified \
  --cache-ram "$CACHE_RAM" \
  -ctk "$CACHE_TYPE_K" \
  -ctv "$CACHE_TYPE_V" \
  --checkpoint-every-n-tokens "$CHECKPOINT_INTERVAL" \
  --ctx-checkpoints "$CHECKPOINT_MAX" \
  --seed "$SEED" \
  ${MMPROJ:+--mmproj "$MMPROJ"} \
  --swa-full 2>&1 | tee -a $HOME/llama.log
