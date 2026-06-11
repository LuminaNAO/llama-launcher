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
#   --tune <name>    Select a specific tune (e.g., "64gb", "128gb") — skips tune menu
#   --seed <N>       Override the random seed (default: 42)
#   --context <N>    Override context size
#   --parallel <N>   Override number of parallel slots
#   --proxy          Enable the deep-logging proxy (default: off)
#   --log            Tee output to ~/llama.log (default: off)
#   --no-proxy       (deprecated, no-op; proxy is now off by default)
#   --no-log         (deprecated, no-op; logging is now off by default)
#   --save           Save effective launch settings as a per-model config
#
# Subcommands:
#   stop             Gracefully stop a running llama-server (and deep proxy)
#
# Per-model configs are stored in model-configs/<model-name>.conf and
# automatically loaded when that model is selected. CLI flags override
# saved configs. Use --save to persist tuned settings.

# ── Subcommand: stop ────────────────────────────────────────────────────────
if [[ "${1:-}" == "stop" ]]; then
    stopped=0
    for pat in "bin/llama-server" "llama-deep-proxy.mjs"; do
        pids="$(pgrep -f "$pat" || true)"
        if [[ -n "$pids" ]]; then
            echo "🛑 SIGINT -> $pat (pids: $pids)"
            # shellcheck disable=SC2086
            kill -INT $pids
            stopped=1
        fi
    done
    if [[ "$stopped" -eq 0 ]]; then
        echo "ℹ️  No running llama-server or deep proxy found."
        exit 0
    fi
    # Wait up to 10s for clean exit, then escalate to SIGTERM
    for _ in $(seq 1 20); do
        sleep 0.5
        pgrep -f "bin/llama-server|llama-deep-proxy.mjs" >/dev/null || { echo "✅ Stopped."; exit 0; }
    done
    echo "⚠️  Still running after 10s — sending SIGTERM."
    pkill -TERM -f "bin/llama-server|llama-deep-proxy.mjs" || true
    exit 0
fi

SEED=1320
CONTEXT_OVERRIDE=""
PARALLEL_OVERRIDE=""
SAVE_CONFIG=0
ARG_BUILD_TYPE=""
ARG_MODEL_PATH=""
ARG_TUNE=""
NO_PROXY=1
NO_LOG=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed) SEED="$2"; shift 2 ;;
        --context) CONTEXT_OVERRIDE="$2"; shift 2 ;;
        --parallel) PARALLEL_OVERRIDE="$2"; shift 2 ;;
        --save) SAVE_CONFIG=1; shift ;;
        --build) ARG_BUILD_TYPE="$2"; shift 2 ;;
        --model) ARG_MODEL_PATH="$2"; shift 2 ;;
        --tune) ARG_TUNE="$2"; shift 2 ;;
        --proxy) NO_PROXY=0; shift ;;
        --log) NO_LOG=0; shift ;;
        --no-proxy) NO_PROXY=1; shift ;;
        --no-log) NO_LOG=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.llama-launcher-config"
LLAMA_LAUNCHER_DIR="$SCRIPT_DIR"
LAUNCH_HISTORY="$SCRIPT_DIR/.launch-history"

# ── Launch history: quick relaunch ──────────────────────────────────────────
# Show recent launches if no CLI args were given (fully interactive mode)
if [[ -z "$ARG_BUILD_TYPE" && -z "$ARG_MODEL_PATH" && -z "$ARG_TUNE" && -f "$LAUNCH_HISTORY" ]]; then
    # Read up to 5 most recent unique launches (newest first)
    recent=()
    while IFS=$'\t' read -r ts build model tune extras; do
        entry="${build}${model}${tune}"
        # Deduplicate (latest flags win for a given build+model+tune)
        dup=0
        for r in "${recent[@]}"; do
            [[ "$r" == "$entry" ]] && { dup=1; break; }
        done
        [[ "$dup" -eq 1 ]] && continue
        recent+=("$entry")
        recent_build+=("$build")
        recent_model+=("$model")
        recent_tune+=("$tune")
        recent_extras+=("$extras")
        [[ ${#recent[@]} -ge 5 ]] && break
    done < <(tac "$LAUNCH_HISTORY")

    if [[ ${#recent[@]} -gt 0 ]]; then
        echo "🕐 Recent launches:"
        for i in "${!recent[@]}"; do
            tune_display="${recent_tune[$i]}"
            [[ -z "$tune_display" ]] && tune_display="(no tune)"
            extras_display="${recent_extras[$i]}"
            [[ -n "$extras_display" ]] && extras_display="  [$extras_display]"
            printf "  %d) %-12s  %-40s  %s%s\n" $((i+1)) "${recent_build[$i]}" "$(basename "${recent_model[$i]}")" "$tune_display" "$extras_display"
        done
        echo "  0) New launch"
        echo ""
        read -rp "Relaunch? [0=new, default=1]: " hist_sel
        hist_sel="${hist_sel:-1}"
        if [[ "$hist_sel" =~ ^[1-9]$ ]] && [[ "$hist_sel" -le ${#recent[@]} ]]; then
            idx=$((hist_sel - 1))
            ARG_BUILD_TYPE="${recent_build[$idx]}"
            ARG_MODEL_PATH="${recent_model[$idx]}"
            [[ -n "${recent_tune[$idx]}" ]] && ARG_TUNE="${recent_tune[$idx]}"
            # Apply saved flag state (only explicit opt-ins)
            extras="${recent_extras[$idx]}"
            [[ " $extras " == *" --log "* ]] && NO_LOG=0
            [[ " $extras " == *" --proxy "* ]] && NO_PROXY=0
            echo ""
            echo "🔄 Relaunching: $ARG_BUILD_TYPE / $(basename "$ARG_MODEL_PATH") / ${ARG_TUNE:-(no tune)}${extras:+  [$extras]}"
            echo ""
        fi
    fi
fi

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

# ── Load per-model config (with tune selection) ─────────────────────────────
MODEL_CONFIG_DIR="$SCRIPT_DIR/model-configs"
selected_folder_name="$(basename "$MODEL_FOLDER")"

# Find all config files matching this model
# Matches: folder-name.conf, folder-name.*.conf (e.g., .64gb.conf)
tune_configs=()
tune_names=()
tune_suggested=-1

TOTAL_RAM_MB_DETECT=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB_DETECT=$((TOTAL_RAM_MB_DETECT / 1024))

# Collect configs: model-specific first, then family tunes
# Config filename format: <model-name>.<tune-name>.conf
# "Model-specific" = conf_model matches the folder name exactly
# "Family" = conf_model is a prefix of the folder name (shorter match)
_specific_configs=()
_specific_names=()
_family_configs=()
_family_names=()
for conf in "$MODEL_CONFIG_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    conf_base="$(basename "$conf" .conf)"
    conf_model="${conf_base%%.*}"
    if [[ "$selected_folder_name" == "$conf_model" ]]; then
        # Exact match — model-specific tune
        tune_label=$(grep -m1 '^# Tune:' "$conf" 2>/dev/null | sed 's/^# Tune: *//')
        [ -z "$tune_label" ] && tune_label="$conf_base"
        _specific_configs+=("$conf")
        _specific_names+=("$tune_label")
    elif [[ "$selected_folder_name" == "$conf_model"* ]]; then
        # Prefix match — family tune
        tune_label=$(grep -m1 '^# Tune:' "$conf" 2>/dev/null | sed 's/^# Tune: *//')
        [ -z "$tune_label" ] && tune_label="$conf_base"
        _family_configs+=("$conf")
        _family_names+=("$tune_label")
    fi
done
# Model-specific tunes first
for i in "${!_specific_configs[@]}"; do
    tune_configs+=("${_specific_configs[$i]}")
    tune_names+=("${_specific_names[$i]}")
done
# Then family tunes (with a separator marker)
TUNE_FAMILY_SPLIT=${#tune_configs[@]}
for i in "${!_family_configs[@]}"; do
    tune_configs+=("${_family_configs[$i]}")
    tune_names+=("${_family_names[$i]}")
done

HAS_MODEL_CONFIG=0
if [ ${#tune_configs[@]} -eq 0 ]; then
    echo "📋 Config: none (using system profile)"
    echo "   Expected: model-configs/${selected_folder_name}.conf"
    echo "   Save one with: $(basename "$0") --save"
elif [ -n "$ARG_TUNE" ]; then
    # --tune passed on CLI: find matching tune
    found=0
    for i in "${!tune_names[@]}"; do
        if [[ "${tune_names[$i]}" == *"$ARG_TUNE"* ]] || [[ "$(basename "${tune_configs[$i]}")" == *"$ARG_TUNE"* ]]; then
            MODEL_CONFIG_FILE="${tune_configs[$i]}"
            echo "📋 Tune: ${tune_names[$i]} ($(basename "$MODEL_CONFIG_FILE"))"
            source "$MODEL_CONFIG_FILE"
            HAS_MODEL_CONFIG=1
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "❌ No tune matching '$ARG_TUNE' found. Available:"
        for i in "${!tune_names[@]}"; do
            echo "   - ${tune_names[$i]} ($(basename "${tune_configs[$i]}"))"
        done
        exit 1
    fi
else
    # Show matching tunes (or all tunes if "browse all" selected)
    show_all_tunes=0

    while true; do
        # Auto-suggest: pick the tune whose name contains the closest RAM tier
        tune_suggested=-1
        for i in "${!tune_names[@]}"; do
            name="${tune_names[$i]}"
            if [ "$TOTAL_RAM_GB_DETECT" -ge 112 ] && [[ "$name" == *128gb* ]]; then
                tune_suggested=$i
            elif [ "$TOTAL_RAM_GB_DETECT" -ge 48 ] && [ "$TOTAL_RAM_GB_DETECT" -lt 112 ] && [[ "$name" == *64gb* ]]; then
                tune_suggested=$i
            fi
        done

        echo ""
        if [ "$show_all_tunes" -eq 1 ]; then
            echo "🎛️  All available tunes:"
        else
            echo "🎛️  Available tunes for $selected_folder_name:"
        fi
        for i in "${!tune_names[@]}"; do
            # Show separator between model-specific and family tunes
            if [ "$i" -eq "$TUNE_FAMILY_SPLIT" ] && [ "$TUNE_FAMILY_SPLIT" -gt 0 ] && [ "$show_all_tunes" -eq 0 ]; then
                echo "  ── base model family tunes ──"
            fi
            local_suggested=""
            if [ "$i" -eq "$tune_suggested" ]; then
                local_suggested=" ← suggested for ${TOTAL_RAM_GB_DETECT}GB system"
            fi
            # Show key params from config
            tune_ctx=$(grep -m1 '^CONTEXT=' "${tune_configs[$i]}" | cut -d= -f2)
            tune_par=$(grep -m1 '^PARALLEL=' "${tune_configs[$i]}" | cut -d= -f2)
            tune_cp=$(grep -m1 '^CHECKPOINT_MAX=' "${tune_configs[$i]}" | cut -d= -f2)
            printf "  %d) %-30s [ctx=%s, parallel=%s, checkpoints=%s]%s\n" \
                $((i+1)) "${tune_names[$i]}" "${tune_ctx:-?}" "${tune_par:-?}" "${tune_cp:-?}" "$local_suggested"
        done
        if [ "$show_all_tunes" -eq 0 ]; then
            echo "  a) Browse all tunes"
        fi
        echo "  0) None (use system profile)"
        echo ""

        default_sel=$((tune_suggested + 1))
        if [ "$default_sel" -le 0 ]; then default_sel=1; fi
        read -rp "Select tune [1-${#tune_configs[@]}, a=all, 0=none, default=$default_sel]: " tune_sel

        # "Browse all" — reload with every config in the directory
        if [[ "$tune_sel" == "a" || "$tune_sel" == "A" ]] && [ "$show_all_tunes" -eq 0 ]; then
            tune_configs=()
            tune_names=()
            for conf in "$MODEL_CONFIG_DIR"/*.conf; do
                [ -f "$conf" ] || continue
                conf_base="$(basename "$conf" .conf)"
                tune_label=$(grep -m1 '^# Tune:' "$conf" 2>/dev/null | sed 's/^# Tune: *//')
                if [ -z "$tune_label" ]; then
                    tune_label="$conf_base"
                fi
                tune_configs+=("$conf")
                tune_names+=("$tune_label")
            done
            show_all_tunes=1
            continue
        fi

        tune_sel="${tune_sel:-$default_sel}"

        if [ "$tune_sel" = "0" ]; then
            echo "📋 Tune: none (using system profile)"
            break
        fi

        if ! [[ "$tune_sel" =~ ^[0-9]+$ ]] || [ "$tune_sel" -lt 1 ] || [ "$tune_sel" -gt ${#tune_configs[@]} ]; then
            echo "❌ Invalid selection"
            exit 1
        fi

        MODEL_CONFIG_FILE="${tune_configs[$((tune_sel-1))]}"
        echo "📋 Tune: ${tune_names[$((tune_sel-1))]} ($(basename "$MODEL_CONFIG_FILE"))"
        source "$MODEL_CONFIG_FILE"
        HAS_MODEL_CONFIG=1
        break
    done
fi

# ── Auto-detect vision projector ─────────────────────────────────────────────
# Searches the same folder as the selected model — no prefix matching needed
MMPROJ=""
mmproj_matches=()
while IFS= read -r -d '' file; do
    mmproj_matches+=("$file")
done < <(find "$MODEL_FOLDER" -maxdepth 1 -name "*mmproj*.gguf" -print0 2>/dev/null)

if [ ${#mmproj_matches[@]} -ge 1 ]; then
    echo ""
    echo "👁️  Vision projector(s) found:"
    for i in "${!mmproj_matches[@]}"; do
        printf "  %d) %s\n" $((i+1)) "$(basename "${mmproj_matches[$i]}")"
    done
    echo "  0) None (text-only)"
    echo ""
    read -rp "Enable vision? [0=no, 1=yes, default=0]: " mmproj_sel
    mmproj_sel="${mmproj_sel:-0}"
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
    # Model config already set values — fill in anything it didn't set with sane defaults.
    CONTEXT="${CONTEXT:-32768}"
    PARALLEL="${PARALLEL:-1}"
    CACHE_RAM="${CACHE_RAM:-8192}"
    CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
    CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"
    CHECKPOINT_INTERVAL="${CHECKPOINT_INTERVAL:-4096}"
    CHECKPOINT_MAX="${CHECKPOINT_MAX:-32}"
    NGL="${NGL:-99}"
    TEMP="${TEMP:-0.3}"
    TOP_P="${TOP_P:-0.95}"
    TOP_K="${TOP_K:-20}"
    THREADS="${THREADS:-$(nproc)}"
    NO_MMAP="${NO_MMAP:-1}"
    DIO="${DIO:-1}"
    TIMEOUT="${TIMEOUT:-3600}"
    HOST="${HOST:-0.0.0.0}"
    PORT="${PORT:-40801}"
    API_KEY="${API_KEY:-ollama-local}"
    KV_UNIFIED="${KV_UNIFIED:-1}"
    FLASH_ATTN="${FLASH_ATTN:-1}"

    echo "📋 Profile: per-model (${CONTEXT} ctx, ${CACHE_TYPE_K} KV, ${CACHE_RAM} MiB cache ceiling, ${PARALLEL} slots)"
# CACHE_RAM semantics (see docs/CACHE-RAM.md): host-memory heap ceiling in MiB.
# Not disk, not pre-allocated — self-shrinks on bad_alloc. Under RAM pressure,
# cache pages spill to swap via the kernel VM subsystem (~200× faster than cold
# PP even when fully swapped). Size it aspirationally; the OS gates the real usage.
elif [ "$TOTAL_RAM_GB" -ge 112 ]; then
    CONTEXT=488576
    PARALLEL=2
    CACHE_RAM=102400   # 100 GiB ceiling; real usage capped by RAM + swap
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=4096
    CHECKPOINT_MAX=64
    echo "📋 Profile: 128 GB (488k context, q8_0 KV, 100 GiB cache ceiling, 2 slots)"
elif [ "$TOTAL_RAM_GB" -ge 48 ]; then
    CONTEXT=131072
    PARALLEL=1
    CACHE_RAM=40960    # 40 GiB ceiling — swap still absorbs overflow
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=4096
    CHECKPOINT_MAX=32
    echo "📋 Profile: 64 GB (131k context, q8_0 KV, 40 GiB cache ceiling, 1 slot)"
else
    CONTEXT=61072
    PARALLEL=1
    CACHE_RAM=16384    # 16 GiB ceiling
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=8192
    CHECKPOINT_MAX=16
    echo "📋 Profile: minimal (61k context, q8_0 KV, 16 GiB cache ceiling, 1 slot)"
    echo "⚠️  Low RAM — using minimal settings"
fi

# ── Apply defaults for all tuneable params (system profiles don't set these) ──
NGL="${NGL:-99}"
TEMP="${TEMP:-0.3}"
TOP_P="${TOP_P:-0.95}"
TOP_K="${TOP_K:-20}"
THREADS="${THREADS:-$(nproc)}"
NO_MMAP="${NO_MMAP:-1}"
DIO="${DIO:-1}"
TIMEOUT="${TIMEOUT:-3600}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-40801}"
API_KEY="${API_KEY:-ollama-local}"
KV_UNIFIED="${KV_UNIFIED:-1}"
FLASH_ATTN="${FLASH_ATTN:-1}"

# ── Reasoning / thinking (auto by default) ──────────────────────────────────
REASONING="${REASONING:-auto}"
REASONING_BUDGET="${REASONING_BUDGET:--1}"

# ── Anti-repeat sampling (disabled by default) ─────────────────────────────
REPEAT_PENALTY="${REPEAT_PENALTY:-1.0}"
REPEAT_LAST_N="${REPEAT_LAST_N:-64}"
PRESENCE_PENALTY="${PRESENCE_PENALTY:-0.0}"
FREQUENCY_PENALTY="${FREQUENCY_PENALTY:-0.0}"
DRY_MULTIPLIER="${DRY_MULTIPLIER:-0.0}"
DRY_BASE="${DRY_BASE:-1.75}"
DRY_ALLOWED_LENGTH="${DRY_ALLOWED_LENGTH:-2}"
DRY_PENALTY_LAST_N="${DRY_PENALTY_LAST_N:--1}"

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
CONFIG_TEMPLATE=$(cat <<'CONFTEMPLATE'
# Per-model launch config for: __MODEL__
# __GENERATED__
# Edit these values and they'll be loaded automatically on next launch.
# CLI flags (--context, --parallel) override these settings.

# ── Context & Scheduling ────────────────────────────────────────────────────
CONTEXT=__CONTEXT__
PARALLEL=__PARALLEL__

# ── KV Cache ────────────────────────────────────────────────────────────────
CACHE_RAM=__CACHE_RAM__
CACHE_TYPE_K=__CACHE_TYPE_K__
CACHE_TYPE_V=__CACHE_TYPE_V__
KV_UNIFIED=__KV_UNIFIED__

# ── Checkpoints ─────────────────────────────────────────────────────────────
CHECKPOINT_INTERVAL=__CHECKPOINT_INTERVAL__
CHECKPOINT_MAX=__CHECKPOINT_MAX__

# ── GPU Offload ─────────────────────────────────────────────────────────────
NGL=__NGL__
FLASH_ATTN=__FLASH_ATTN__

# ── Sampling ────────────────────────────────────────────────────────────────
TEMP=__TEMP__
TOP_P=__TOP_P__
TOP_K=__TOP_K__

# ── Anti-repeat ─────────────────────────────────────────────────────────
# REPEAT_PENALTY=__REPEAT_PENALTY__
# REPEAT_LAST_N=__REPEAT_LAST_N__
# PRESENCE_PENALTY=__PRESENCE_PENALTY__
# FREQUENCY_PENALTY=__FREQUENCY_PENALTY__
# DRY_MULTIPLIER=__DRY_MULTIPLIER__
# DRY_BASE=__DRY_BASE__
# DRY_ALLOWED_LENGTH=__DRY_ALLOWED_LENGTH__
# DRY_PENALTY_LAST_N=__DRY_PENALTY_LAST_N__

# ── Server ──────────────────────────────────────────────────────────────────
HOST=__HOST__
PORT=__PORT__
API_KEY=__API_KEY__
TIMEOUT=__TIMEOUT__
THREADS=__THREADS__

# ── I/O & Memory ────────────────────────────────────────────────────────────
NO_MMAP=__NO_MMAP__
DIO=__DIO__

# ── Template ────────────────────────────────────────────────────────────────
# Set JINJA=0 to disable --jinja (e.g. for Gemma 4 models)
# JINJA=1

# ── Extra ───────────────────────────────────────────────────────────────────
# Append arbitrary flags to the server command:
# EXTRA_ARGS="--flag value"
CONFTEMPLATE
)

fill_config_template() {
    echo "$CONFIG_TEMPLATE" \
        | sed "s|__MODEL__|$selected_model|g" \
        | sed "s|__GENERATED__|$1|g" \
        | sed "s|__CONTEXT__|$CONTEXT|g" \
        | sed "s|__PARALLEL__|$PARALLEL|g" \
        | sed "s|__CACHE_RAM__|$CACHE_RAM|g" \
        | sed "s|__CACHE_TYPE_K__|$CACHE_TYPE_K|g" \
        | sed "s|__CACHE_TYPE_V__|$CACHE_TYPE_V|g" \
        | sed "s|__KV_UNIFIED__|$KV_UNIFIED|g" \
        | sed "s|__CHECKPOINT_INTERVAL__|$CHECKPOINT_INTERVAL|g" \
        | sed "s|__CHECKPOINT_MAX__|$CHECKPOINT_MAX|g" \
        | sed "s|__NGL__|$NGL|g" \
        | sed "s|__FLASH_ATTN__|$FLASH_ATTN|g" \
        | sed "s|__TEMP__|$TEMP|g" \
        | sed "s|__TOP_P__|$TOP_P|g" \
        | sed "s|__TOP_K__|$TOP_K|g" \
        | sed "s|__HOST__|$HOST|g" \
        | sed "s|__PORT__|$PORT|g" \
        | sed "s|__API_KEY__|$API_KEY|g" \
        | sed "s|__TIMEOUT__|$TIMEOUT|g" \
        | sed "s|__THREADS__|$THREADS|g" \
        | sed "s|__NO_MMAP__|$NO_MMAP|g" \
        | sed "s|__DIO__|$DIO|g"
}

if [ "$HAS_MODEL_CONFIG" -eq 0 ] && [ "$SAVE_CONFIG" -eq 0 ]; then
    mkdir -p "$MODEL_CONFIG_DIR"
    MODEL_CONFIG_FILE="$MODEL_CONFIG_DIR/${selected_folder_name}.conf"
    fill_config_template "Auto-generated from ${TOTAL_RAM_GB} GB system profile: $(date -Iseconds)" > "$MODEL_CONFIG_FILE"
    echo "💾 Auto-saved config: model-configs/${selected_folder_name}.conf"
fi

# ── Save per-model config if requested ───────────────────────────────────────
if [ "$SAVE_CONFIG" -eq 1 ]; then
    mkdir -p "$MODEL_CONFIG_DIR"
    fill_config_template "Generated: $(date -Iseconds)" > "$MODEL_CONFIG_FILE"
    echo "💾 Saved model config: $MODEL_CONFIG_FILE"
fi

# ── Deep logging proxy ──────────────────────────────────────────────────────
# The proxy listens on PORT (public) and forwards to INTERNAL_PORT (llama-server).
# Both request and response bodies are tee-d to ~/llama-deep.log.
INTERNAL_PORT="${INTERNAL_PORT:-40802}"
DEEP_LOG="$HOME/llama-deep.log"
PROXY_SCRIPT="$SCRIPT_DIR/llama-deep-proxy.mjs"

if [ "$NO_PROXY" -eq 1 ]; then
    # No proxy — llama-server binds directly to the public port
    INTERNAL_PORT="$PORT"
    LLAMA_BIND_HOST="$HOST"
    echo ""
    echo "🚀 Launching llama-server..."
    echo "   llama-server on port $PORT (no proxy)"
    echo ""
else
    echo ""
    echo "🚀 Launching llama-server..."
    echo "   llama-server on internal port $INTERNAL_PORT"
    echo "   proxy on public port $PORT -> $INTERNAL_PORT"
    echo "   deep log: $DEEP_LOG"
    echo ""
fi

# ── Build launch flags from tuneable variables ──────────────────────────────
MMAP_FLAG=""
[ "$NO_MMAP" = "1" ] && MMAP_FLAG="--no-mmap"
DIO_FLAG=""
[ "$DIO" = "1" ] && DIO_FLAG="-dio"
KV_UNIFIED_FLAG="--no-kv-unified"
[ "$KV_UNIFIED" = "1" ] && KV_UNIFIED_FLAG="--kv-unified"
FA_FLAG=""
[ "$FLASH_ATTN" = "1" ] && FA_FLAG="-fa on"

# ── Reasoning flags (only add if non-default) ──────────────────────────────
REASONING_FLAGS=""
[ "$REASONING" != "auto" ] && REASONING_FLAGS="$REASONING_FLAGS --reasoning $REASONING"
[ "$REASONING_BUDGET" != "-1" ] && REASONING_FLAGS="$REASONING_FLAGS --reasoning-budget $REASONING_BUDGET"

# ── Anti-repeat flags (only add if non-default) ──────────────────────────
REPEAT_FLAGS=""
[ "$REPEAT_PENALTY" != "1.0" ] && REPEAT_FLAGS="$REPEAT_FLAGS --repeat-penalty $REPEAT_PENALTY --repeat-last-n $REPEAT_LAST_N"
[ "$PRESENCE_PENALTY" != "0.0" ] && REPEAT_FLAGS="$REPEAT_FLAGS --presence-penalty $PRESENCE_PENALTY"
[ "$FREQUENCY_PENALTY" != "0.0" ] && REPEAT_FLAGS="$REPEAT_FLAGS --frequency-penalty $FREQUENCY_PENALTY"
[ "$DRY_MULTIPLIER" != "0.0" ] && REPEAT_FLAGS="$REPEAT_FLAGS --dry-multiplier $DRY_MULTIPLIER --dry-base $DRY_BASE --dry-allowed-length $DRY_ALLOWED_LENGTH --dry-penalty-last-n $DRY_PENALTY_LAST_N"

# ── Start deep-logging proxy ────────────────────────────────────────────────
PROXY_PID=""
cleanup_proxy() {
    if [ -n "$PROXY_PID" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill "$PROXY_PID" 2>/dev/null
        wait "$PROXY_PID" 2>/dev/null
    fi
}
trap cleanup_proxy EXIT

if [ "$NO_PROXY" -eq 0 ]; then
    node "$PROXY_SCRIPT" "$PORT" "$INTERNAL_PORT" "$DEEP_LOG" &
    PROXY_PID=$!

    # Give the proxy a moment to bind
    sleep 0.3
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "❌ Deep-logging proxy failed to start"
        exit 1
    fi
    echo "✅ Deep-logging proxy running (PID $PROXY_PID)"
    echo ""
fi

# ── Log this launch to history ─────────────────────────────────────────────
_tune_log=""
[[ -n "${MODEL_CONFIG_FILE:-}" ]] && _tune_log="$(grep -m1 '^# Tune:' "$MODEL_CONFIG_FILE" 2>/dev/null | sed 's/^# Tune: *//')"
_extras_log=""
[[ "$NO_LOG" -eq 0 ]] && _extras_log+="--log "
[[ "$NO_PROXY" -eq 0 ]] && _extras_log+="--proxy "
_extras_log="${_extras_log% }"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$BUILD_TYPE" "$model_path" "$_tune_log" "$_extras_log" >> "$LAUNCH_HISTORY"

# ── Launch llama-server ─────────────────────────────────────────────────────
LAUNCH_CMD=("$LLAMACPP_SERVER_PATH"
  -m "$model_path"
  -ngl "$NGL"
  -c "$CONTEXT"
  ${FA_FLAG:+$FA_FLAG}
  --temp "$TEMP"
  --top-p "$TOP_P"
  --top-k "$TOP_K"
  --threads "$THREADS"
  ${MMAP_FLAG:+$MMAP_FLAG}
  ${DIO_FLAG:+$DIO_FLAG}
  --timeout "$TIMEOUT"
  --host "${LLAMA_BIND_HOST:-127.0.0.1}"
  --port "$INTERNAL_PORT"
  --api-key "$API_KEY"
  ${JINJA_FLAG:+$JINJA_FLAG}
  --parallel "$PARALLEL"
  ${KV_UNIFIED_FLAG:+$KV_UNIFIED_FLAG}
  --cache-ram "$CACHE_RAM"
  -ctk "$CACHE_TYPE_K"
  -ctv "$CACHE_TYPE_V"
  --checkpoint-every-n-tokens "$CHECKPOINT_INTERVAL"
  --ctx-checkpoints "$CHECKPOINT_MAX"
  --seed "$SEED"
  ${MLOCK_FLAG:+$MLOCK_FLAG}
  ${MMPROJ:+--mmproj "$MMPROJ"}
  ${REASONING_FLAGS:+$REASONING_FLAGS}
  ${REPEAT_FLAGS:+$REPEAT_FLAGS}
  ${EXTRA_ARGS:+$EXTRA_ARGS}
)

if [ "$NO_LOG" -eq 1 ]; then
    "${LAUNCH_CMD[@]}" 2>&1
else
    "${LAUNCH_CMD[@]}" 2>&1 | tee -a "$HOME/llama.log"
fi
