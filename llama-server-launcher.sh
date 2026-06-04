#!/bin/bash

# Llama Server Model Launcher
# Interactive launcher for llama.cpp server with per-model configs.
#
# Usage:
#   llama-server-launcher.sh                          # fully interactive
#   llama-server-launcher.sh --build rocm             # skip build selection
#   llama-server-launcher.sh --model /path/to/model   # skip model selection
#   llama-server-launcher.sh --build rocm --model /path/to/model  # non-interactive
#
# Options:
#   --build <type>   Build type (rocm, vulkan, etc.) — skips build selection
#   --model <path>   Full path to .gguf model file — skips model selection
#   --seed <N>       Override the random seed (default: 42)
#   --context <N>    Override context size
#   --parallel <N>   Override number of parallel slots
#   --save           Save effective launch settings as a per-model config
#
# Per-model configs are stored in model-configs/<model-name>.conf and
# automatically loaded when that model is selected. CLI flags override
# saved configs. Use --save to persist tuned settings.

SEED=42
CONTEXT_OVERRIDE=""
PARALLEL_OVERRIDE=""
SAVE_CONFIG=0
ARG_BUILD_TYPE=""
ARG_MODEL_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed) SEED="$2"; shift 2 ;;
        --context) CONTEXT_OVERRIDE="$2"; shift 2 ;;
        --parallel) PARALLEL_OVERRIDE="$2"; shift 2 ;;
        --save) SAVE_CONFIG=1; shift ;;
        --build) ARG_BUILD_TYPE="$2"; shift 2 ;;
        --model) ARG_MODEL_PATH="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.llama-launcher-config"
LLAMA_LAUNCHER_DIR="$SCRIPT_DIR"

# ── Build type selection ─────────────────────────────────────────────────────

if [ -n "$ARG_BUILD_TYPE" ]; then
    # Build type passed via CLI
    BUILD_TYPE="$ARG_BUILD_TYPE"
else
    # Interactive: list available builds and let user pick
    available_builds=()
    if [ -d "$LLAMA_LAUNCHER_DIR/builds" ]; then
        for dir in "$LLAMA_LAUNCHER_DIR"/builds/*/; do
            if [ -f "$dir/bin/llama-server" ]; then
                available_builds+=("$(basename "$dir")")
            fi
        done
    fi

    if [ ${#available_builds[@]} -eq 0 ]; then
        echo "❌ No builds found in $LLAMA_LAUNCHER_DIR/builds/"
        echo "   Run build.sh first: bash build.sh [rocm|vulkan]"
        exit 1
    elif [ ${#available_builds[@]} -eq 1 ]; then
        BUILD_TYPE="${available_builds[0]}"
        echo "🔧 Using only available build: $BUILD_TYPE"
    else
        echo "Available builds:"
        for i in "${!available_builds[@]}"; do
            printf "  %d) %s\n" $((i+1)) "${available_builds[$i]}"
        done
        echo ""
        read -rp "Select build [1-${#available_builds[@]}]: " build_sel
        if [[ "$build_sel" =~ ^[0-9]+$ ]] && [ "$build_sel" -ge 1 ] && [ "$build_sel" -le ${#available_builds[@]} ]; then
            BUILD_TYPE="${available_builds[$((build_sel-1))]}"
        else
            echo "❌ Invalid selection"; exit 1
        fi
    fi
fi

BUILD_DIR="$LLAMA_LAUNCHER_DIR/builds/$BUILD_TYPE"
LLAMACPP_SERVER_PATH="$BUILD_DIR/bin/llama-server"

if [ ! -f "$LLAMACPP_SERVER_PATH" ]; then
    echo "❌ llama-server not found at $LLAMACPP_SERVER_PATH"
    echo "   Run: bash build.sh $BUILD_TYPE"
    exit 1
fi

echo "🔧 Build: $BUILD_TYPE ($LLAMACPP_SERVER_PATH)"
echo ""

# ── Model selection ──────────────────────────────────────────────────────────

if [ -n "$ARG_MODEL_PATH" ]; then
    # Model passed via CLI — resolve to absolute path
    if [ ! -f "$ARG_MODEL_PATH" ]; then
        echo "❌ Model not found: $ARG_MODEL_PATH"
        exit 1
    fi
    model_path="$(realpath "$ARG_MODEL_PATH")"
    selected_model="$(basename "$model_path")"
    MODEL_FOLDER="$(dirname "$model_path")"
    MODELS_DIR="$(dirname "$MODEL_FOLDER")"
else
    # Interactive: scan model folders and let user pick
    DEFAULT_MODELS_DIR="/usr/local/share/llama.cpp/models"

    # Load saved models dir from config
    if [ -f "$CONFIG_FILE" ]; then
        eval "$(cat "$CONFIG_FILE")"
        export LLAMACPP_MODELS_DIR
    fi
    MODELS_DIR="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"

    # Scan for model folders (each folder = one model family)
    scan_model_folders() {
        local dir="$1"
        model_folders=()
        for folder in "$dir"/*/; do
            [ ! -d "$folder" ] && continue
            local fname="$(basename "$folder")"
            # Skip downloading/ or other non-model dirs
            [[ "$fname" == "downloading" ]] && continue
            # Must contain at least one .gguf that isn't an mmproj
            if find "$folder" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | grep -zqv "mmproj"; then
                model_folders+=("$fname")
            fi
        done
    }

    scan_model_folders "$MODELS_DIR"

    # If no model folders found, prompt for a new path
    if [ ${#model_folders[@]} -eq 0 ]; then
        echo "❌ No model folders found at $MODELS_DIR"
        echo ""
        read -rp "Enter path to models directory: " new_path
        echo "LLAMACPP_MODELS_DIR=$new_path" > "$CONFIG_FILE"
        echo "✅ Path saved to $CONFIG_FILE for next launch"
        echo ""
        MODELS_DIR="$new_path"
        scan_model_folders "$MODELS_DIR"
    fi

    if [ ${#model_folders[@]} -eq 0 ]; then
        echo "❌ No model folders found in $MODELS_DIR"
        exit 1
    fi

    echo "📂 Models in $MODELS_DIR:"
    echo ""
    for i in "${!model_folders[@]}"; do
        folder="${model_folders[$i]}"
        # Count quants (non-mmproj, non-split-continuation .gguf files)
        quant_count=0
        has_vision=""
        while IFS= read -r -d '' file; do
            name="$(basename "$file")"
            [[ "$name" == *mmproj* ]] && { has_vision=" 👁️"; continue; }
            [[ "$name" =~ -[0-9]+-of-[0-9]+\.gguf$ ]] && ! [[ "$name" =~ -00001-of-[0-9]+\.gguf$ ]] && continue
            quant_count=$((quant_count + 1))
        done < <(find "$MODELS_DIR/$folder" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)
        printf "  %d) %s  [%d quant(s)]%s\n" $((i+1)) "$folder" "$quant_count" "$has_vision"
    done
    echo ""

    read -rp "Select model [1-${#model_folders[@]}]: " folder_sel

    if ! [[ "$folder_sel" =~ ^[0-9]+$ ]] || [ "$folder_sel" -lt 1 ] || [ "$folder_sel" -gt ${#model_folders[@]} ]; then
        echo "❌ Invalid selection"
        exit 1
    fi

    selected_folder="${model_folders[$((folder_sel-1))]}"
    MODEL_FOLDER="$MODELS_DIR/$selected_folder"

    # Scan quants within the selected folder
    quants=()
    while IFS= read -r -d '' file; do
        name="$(basename "$file")"
        [[ "$name" == *mmproj* ]] && continue
        [[ "$name" =~ -[0-9]+-of-[0-9]+\.gguf$ ]] && ! [[ "$name" =~ -00001-of-[0-9]+\.gguf$ ]] && continue
        quants+=("$name")
    done < <(find "$MODEL_FOLDER" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)

    if [ ${#quants[@]} -eq 0 ]; then
        echo "❌ No model files in $MODEL_FOLDER"
        exit 1
    elif [ ${#quants[@]} -eq 1 ]; then
        selected_model="${quants[0]}"
    else
        echo ""
        echo "Available quants in $selected_folder:"
        for i in "${!quants[@]}"; do
            name="${quants[$i]}"
            if [[ "$name" =~ -00001-of-([0-9]+)\.gguf$ ]]; then
                total="${BASH_REMATCH[1]}"
                printf "  %d) %s  [split: %d parts]\n" $((i+1)) "$name" "$((10#$total))"
            else
                printf "  %d) %s\n" $((i+1)) "$name"
            fi
        done
        echo ""
        read -rp "Select quant [1-${#quants[@]}]: " quant_sel
        if ! [[ "$quant_sel" =~ ^[0-9]+$ ]] || [ "$quant_sel" -lt 1 ] || [ "$quant_sel" -gt ${#quants[@]} ]; then
            echo "❌ Invalid selection"
            exit 1
        fi
        selected_model="${quants[$((quant_sel-1))]}"
    fi

    model_path="$MODEL_FOLDER/$selected_model"
fi

echo "📦 Model: $selected_model"

# ── Load per-model config ────────────────────────────────────────────────────
# Check for config by: folder name, then model filename, then split-stripped filename
MODEL_CONFIG_DIR="$SCRIPT_DIR/model-configs"
selected_folder_name="$(basename "$MODEL_FOLDER")"
MODEL_CONFIG_FILE="$MODEL_CONFIG_DIR/${selected_folder_name}.conf"
MODEL_CONFIG_FILE_BY_FILE="$MODEL_CONFIG_DIR/${selected_model%.gguf}.conf"
MODEL_CONFIG_FILE_SPLIT="$MODEL_CONFIG_DIR/$(echo "${selected_model%.gguf}" | sed 's/-00001-of-[0-9]*//' ).conf"

HAS_MODEL_CONFIG=0
for conf in "$MODEL_CONFIG_FILE" "$MODEL_CONFIG_FILE_BY_FILE" "$MODEL_CONFIG_FILE_SPLIT"; do
    if [ -f "$conf" ]; then
        MODEL_CONFIG_FILE="$conf"
        echo "📋 Config: $(basename "$MODEL_CONFIG_FILE")"
        source "$MODEL_CONFIG_FILE"
        HAS_MODEL_CONFIG=1
        break
    fi
done
if [ "$HAS_MODEL_CONFIG" -eq 0 ]; then
    echo "📋 Config: none (using system profile)"
    echo "   Expected: model-configs/${selected_folder_name}.conf"
    echo "   Save one with: $(basename "$0") --save"
fi

# ── Auto-detect vision projector ─────────────────────────────────────────────
# Searches the same folder as the selected model — no prefix matching needed
MMPROJ=""
mmproj_matches=()
while IFS= read -r -d '' file; do
    mmproj_matches+=("$file")
done < <(find "$MODEL_FOLDER" -maxdepth 1 -name "*mmproj*.gguf" -print0 2>/dev/null)

if [ ${#mmproj_matches[@]} -eq 1 ]; then
    MMPROJ="${mmproj_matches[0]}"
    echo "👁️  Vision: $(basename "$MMPROJ")"
elif [ ${#mmproj_matches[@]} -gt 1 ]; then
    echo ""
    echo "Multiple vision projector files found:"
    for i in "${!mmproj_matches[@]}"; do
        printf "  %d) %s\n" $((i+1)) "$(basename "${mmproj_matches[$i]}")"
    done
    echo "  0) None (text-only)"
    echo ""
    read -rp "Select mmproj [0-${#mmproj_matches[@]}]: " mmproj_sel
    if [[ "$mmproj_sel" =~ ^[1-9][0-9]*$ ]] && [ "$mmproj_sel" -le ${#mmproj_matches[@]} ]; then
        MMPROJ="${mmproj_matches[$((mmproj_sel-1))]}"
        echo "👁️  Vision: $(basename "$MMPROJ")"
    else
        echo "👁️  Vision: none"
    fi
else
    echo "👁️  Vision: none"
fi

echo ""

# ── Backend environment ──────────────────────────────────────────────────────
case "$BUILD_TYPE" in
    rocm)
        export ROCBLAS_USE_HIPBLASLT=1
        export HSA_XNACK=1
        export LD_LIBRARY_PATH="$BUILD_DIR/bin:$BUILD_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ;;
    vulkan)
        # Force llama.cpp to use only the Vulkan backend libs, not system ROCm.
        # Without this, the binary auto-detects ROCm and ignores Vulkan.
        export LD_LIBRARY_PATH="$BUILD_DIR/bin:$BUILD_DIR/lib"
        ;;
    *)
        echo "⚠️  No special environment variables set for $BUILD_TYPE"
        ;;
esac

# ── Detect system RAM and select profile ─────────────────────────────────────
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))

RESERVE_GB=20

echo "🖥️  System RAM: ${TOTAL_RAM_GB} GB (reserving ${RESERVE_GB} GB for system)"

if [ "$HAS_MODEL_CONFIG" -eq 1 ]; then
    # Model config already set CONTEXT, PARALLEL, etc. — use those as base.
    # Fill in any values the config didn't set with sensible defaults.
    CONTEXT="${CONTEXT:-32768}"
    PARALLEL="${PARALLEL:-1}"
    CACHE_RAM="${CACHE_RAM:-8192}"
    CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
    CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"
    CHECKPOINT_INTERVAL="${CHECKPOINT_INTERVAL:-4096}"
    CHECKPOINT_MAX="${CHECKPOINT_MAX:-32}"

    echo "📋 Profile: per-model (${CONTEXT} ctx, ${CACHE_TYPE_K} KV, ${CACHE_RAM} MB cache, ${PARALLEL} slots)"
elif [ "$TOTAL_RAM_GB" -ge 112 ]; then
    CONTEXT=488576
    PARALLEL=2
    CACHE_RAM=30720
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=4096
    CHECKPOINT_MAX=64
    echo "📋 Profile: 128 GB (488k context, q8_0 KV, 30 GB cache, 2 slots)"
elif [ "$TOTAL_RAM_GB" -ge 48 ]; then
    CONTEXT=131072
    PARALLEL=1
    CACHE_RAM=10240
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=4096
    CHECKPOINT_MAX=32
    echo "📋 Profile: 64 GB (131k context, q8_0 KV, 10 GB cache, 1 slot)"
else
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

# ── Apply CLI overrides ──────────────────────────────────────────────────────
if [ -n "$CONTEXT_OVERRIDE" ]; then
    echo "⚙️  Context override: $CONTEXT → $CONTEXT_OVERRIDE"
    CONTEXT="$CONTEXT_OVERRIDE"
fi
if [ -n "$PARALLEL_OVERRIDE" ]; then
    echo "⚙️  Parallel override: $PARALLEL → $PARALLEL_OVERRIDE"
    PARALLEL="$PARALLEL_OVERRIDE"
fi

# ── Jinja flag (default: on, per-model configs can disable) ──────────────────
JINJA="${JINJA-1}"
if [ "$JINJA" = "1" ]; then
    JINJA_FLAG="--jinja"
    echo "🧩 Jinja: enabled"
else
    JINJA_FLAG=""
    echo "🧩 Jinja: disabled (model uses native template parser)"
fi

# ── Check mlock capability ───────────────────────────────────────────────────
MEMLOCK_KB=$(ulimit -l 2>/dev/null || echo 0)
if [ "$MEMLOCK_KB" = "unlimited" ]; then
    MLOCK_FLAG="--mlock"
    echo "🔒 mlock: enabled (memlock=unlimited) — pages pinned, swap-safe"
else
    MLOCK_FLAG=""
    MEMLOCK_MB=$((MEMLOCK_KB / 1024))
    echo "⚠️  mlock: DISABLED (memlock=${MEMLOCK_MB} MB)"
    echo "   Without mlock, the kernel can swap llama-server pages to disk,"
    echo "   causing catastrophic performance drops (< 1 tok/s observed)."
    echo "   Fix: add to /etc/security/limits.conf and re-login:"
    echo "     $(whoami)  hard  memlock  unlimited"
    echo "     $(whoami)  soft  memlock  unlimited"
fi

# ── Auto-generate config if none existed ─────────────────────────────────────
# When launching a model for the first time (no config file), save the effective
# settings so the user has a starting point to tune. Uses the folder-name
# convention so the launcher finds it automatically next time.
if [ "$HAS_MODEL_CONFIG" -eq 0 ] && [ "$SAVE_CONFIG" -eq 0 ]; then
    mkdir -p "$MODEL_CONFIG_DIR"
    MODEL_CONFIG_FILE="$MODEL_CONFIG_DIR/${selected_folder_name}.conf"
    cat > "$MODEL_CONFIG_FILE" <<CONF
# Per-model launch config for: $selected_model
# Auto-generated from ${TOTAL_RAM_GB} GB system profile: $(date -Iseconds)
# Edit these values and they'll be loaded automatically on next launch.
# CLI flags (--context, --parallel) override these settings.

CONTEXT=$CONTEXT
PARALLEL=$PARALLEL
CACHE_RAM=$CACHE_RAM
CACHE_TYPE_K=$CACHE_TYPE_K
CACHE_TYPE_V=$CACHE_TYPE_V
CHECKPOINT_INTERVAL=$CHECKPOINT_INTERVAL
CHECKPOINT_MAX=$CHECKPOINT_MAX


# Set JINJA=0 to disable --jinja (e.g. for Gemma 4 models)
# JINJA=1

# Uncomment to override additional server flags:
# EXTRA_ARGS="--flag value"
CONF
    echo "💾 Auto-saved config: model-configs/${selected_folder_name}.conf"
fi

# ── Save per-model config if requested ───────────────────────────────────────
if [ "$SAVE_CONFIG" -eq 1 ]; then
    mkdir -p "$MODEL_CONFIG_DIR"
    cat > "$MODEL_CONFIG_FILE" <<CONF
# Per-model launch config for: $selected_model
# Generated: $(date -Iseconds)
# Edit these values and they'll be loaded automatically on next launch.
# CLI flags (--context, --parallel) override these settings.

CONTEXT=$CONTEXT
PARALLEL=$PARALLEL
CACHE_RAM=$CACHE_RAM
CACHE_TYPE_K=$CACHE_TYPE_K
CACHE_TYPE_V=$CACHE_TYPE_V
CHECKPOINT_INTERVAL=$CHECKPOINT_INTERVAL
CHECKPOINT_MAX=$CHECKPOINT_MAX


# Set JINJA=0 to disable --jinja (e.g. for Gemma 4 models)
# JINJA=1

# Uncomment to override additional server flags:
# EXTRA_ARGS="--flag value"
CONF
    echo "💾 Saved model config: $MODEL_CONFIG_FILE"
fi

echo ""
echo "🚀 Launching llama-server..."
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
  -dio \
  --timeout 3600 \
  --host 0.0.0.0 \
  --port 40801 \
  --api-key ollama-local \
  ${JINJA_FLAG:+$JINJA_FLAG} \
  --parallel "$PARALLEL" \
  --kv-unified \
  --cache-ram "$CACHE_RAM" \
  -ctk "$CACHE_TYPE_K" \
  -ctv "$CACHE_TYPE_V" \
  --checkpoint-every-n-tokens "$CHECKPOINT_INTERVAL" \
  --ctx-checkpoints "$CHECKPOINT_MAX" \
  --seed "$SEED" \
  ${MLOCK_FLAG:+$MLOCK_FLAG} \
  ${MMPROJ:+--mmproj "$MMPROJ"} \
  ${EXTRA_ARGS:+$EXTRA_ARGS} \
  2>&1 | tee -a $HOME/llama.log
