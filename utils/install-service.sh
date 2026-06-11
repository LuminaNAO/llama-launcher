#!/bin/bash

# Llama Server Systemd Service Installer
# Installs a user or system service using the same build/model/tune/proxy/HDD-cache
# flow as llama-server-launcher.sh.
#
# Usage:
#   ./utils/install-service.sh [--seed <N>] [--uninstall] [--no-start]
#   sudo ./utils/install-service.sh --system [--seed <N>] [--uninstall] [--no-start]

set -euo pipefail

UTIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$UTIL_DIR")"
CONFIG_FILE="$ROOT_DIR/.llama-launcher-config"
SERVICE_NAME="llama-server"
DEFAULT_MODELS_DIR="/usr/local/share/llama.cpp/models"

SEED=1320
UNINSTALL=0
NO_START=0
INSTALL_MODE="user"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed) SEED="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        --no-start) NO_START=1; shift ;;
        --system) INSTALL_MODE="system"; shift ;;
        --user) INSTALL_MODE="user"; shift ;;
        -h|--help)
            sed -n '2,/^$/{ s/^# \?//; p }' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$INSTALL_MODE" = "system" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: --system installs must be run with sudo."
        echo "  sudo $0 --system"
        exit 1
    fi
    INSTALL_USER="${SUDO_USER:-}"
    if [ -z "$INSTALL_USER" ] || [ "$INSTALL_USER" = "root" ]; then
        echo "ERROR: Run system installs via sudo from the target user, not as root directly."
        exit 1
    fi
    INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    SERVICE_DIR="/etc/llama-launcher"
    SYSTEMCTL=(systemctl)
    SERVICE_SCOPE_LABEL="system"
    SERVICE_WANTED_BY="multi-user.target"
    SERVICE_UNIT_AFTER="After=network-online.target"
    SERVICE_UNIT_WANTS="Wants=network-online.target"
else
    if [ "$EUID" -eq 0 ]; then
        echo "ERROR: User service installs should not run as root."
        echo "       Use ./utils/install-service.sh, or pass --system explicitly."
        exit 1
    fi
    INSTALL_USER="$(whoami)"
    INSTALL_HOME="$HOME"
    SERVICE_DIR="$HOME/.config/llama-launcher"
    SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
    SYSTEMCTL=(systemctl --user)
    SERVICE_SCOPE_LABEL="user"
    SERVICE_WANTED_BY="default.target"
    SERVICE_UNIT_AFTER=""
    SERVICE_UNIT_WANTS=""
fi
START_SCRIPT="$SERVICE_DIR/${SERVICE_NAME}-start.sh"

if [ -z "$INSTALL_HOME" ] || [ ! -d "$INSTALL_HOME" ]; then
    echo "ERROR: Could not determine home directory for $INSTALL_USER"
    exit 1
fi

quote_sh() {
    printf '%q' "$1"
}

config_set() {
    local key="$1"
    local value="$2"
    local line tmp

    line="$key=$(quote_sh "$value")"
    tmp="$(mktemp)"
    touch "$CONFIG_FILE"
    awk -v key="$key" -v line="$line" '
        BEGIN { done = 0 }
        $0 ~ "^" key "=" {
            if (!done) {
                print line
                done = 1
            }
            next
        }
        { print }
        END {
            if (!done) {
                print line
            }
        }
    ' "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    if [ "$INSTALL_MODE" = "system" ]; then
        chown "$INSTALL_USER":"$INSTALL_USER" "$CONFIG_FILE" 2>/dev/null || true
    fi
}

canonical_build_type() {
    case "$1" in
        rocm-mtp)   printf '%s\n' "rocm" ;;
        vulkan-mtp) printf '%s\n' "vulkan" ;;
        *)          printf '%s\n' "$1" ;;
    esac
}

prompt_number() {
    local label="$1"
    local default="$2"
    local min="$3"
    local max="$4"
    local value

    read -rp "$label [$default]: " value
    value="${value:-$default}"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo "ERROR: Invalid value: $value"
        exit 1
    fi
    printf '%s\n' "$value"
}

yes_no() {
    local label="$1"
    local default="${2:-n}"
    local suffix="[y/N]"
    local ans
    [ "$default" = "y" ] && suffix="[Y/n]"
    read -rp "$label $suffix " ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

if [ "$UNINSTALL" -eq 1 ]; then
    "${SYSTEMCTL[@]}" stop "$SERVICE_NAME" 2>/dev/null || true
    "${SYSTEMCTL[@]}" disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$START_SCRIPT"
    rmdir "$SERVICE_DIR" 2>/dev/null || true
    "${SYSTEMCTL[@]}" daemon-reload
    echo "$SERVICE_SCOPE_LABEL service removed."
    exit 0
fi

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

echo "Installing $SERVICE_SCOPE_LABEL service as user: $INSTALL_USER"
echo ""

# ── Build selection ─────────────────────────────────────────────────────────
available_builds=()
if [ -d "$ROOT_DIR/builds" ]; then
    for dir in "$ROOT_DIR"/builds/*/; do
        [ -f "$dir/bin/llama-server" ] || continue
        build_name="$(basename "$dir")"
        case "$build_name" in
            rocm-mtp|vulkan-mtp)
                base_name="${build_name%-mtp}"
                [ -f "$ROOT_DIR/builds/$base_name/bin/llama-server" ] && continue
                ;;
        esac
        available_builds+=("$build_name")
    done
fi

if [ ${#available_builds[@]} -eq 0 ]; then
    echo "ERROR: No builds found in $ROOT_DIR/builds/"
    echo "Run: bash build-llamacpp.sh [rocm|vulkan|cuda]"
    exit 1
elif [ -n "${LLAMACPP_BUILD_TYPE:-}" ] && [ -f "$ROOT_DIR/builds/$LLAMACPP_BUILD_TYPE/bin/llama-server" ]; then
    BUILD_TYPE="$(canonical_build_type "$LLAMACPP_BUILD_TYPE")"
    echo "Using configured build: $BUILD_TYPE"
elif [ ${#available_builds[@]} -eq 1 ]; then
    BUILD_TYPE="$(canonical_build_type "${available_builds[0]}")"
    echo "Using only available build: $BUILD_TYPE"
else
    echo "Available builds:"
    for i in "${!available_builds[@]}"; do
        printf "  %d) %s\n" $((i + 1)) "${available_builds[$i]}"
    done
    echo ""
    build_sel="$(prompt_number "Select build" 1 1 "${#available_builds[@]}")"
    BUILD_TYPE="$(canonical_build_type "${available_builds[$((build_sel - 1))]}")"
fi
config_set LLAMACPP_BUILD_TYPE "$BUILD_TYPE"

BUILD_DIR="$ROOT_DIR/builds/$BUILD_TYPE"
SERVER_BIN="$BUILD_DIR/bin/llama-server"
if [ ! -x "$SERVER_BIN" ]; then
    echo "ERROR: llama-server not executable: $SERVER_BIN"
    exit 1
fi

# ── Model selection ─────────────────────────────────────────────────────────
MODELS_DIR="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"
MODELS_DIR="${MODELS_DIR%/}"
if [ ! -d "$MODELS_DIR" ]; then
    echo "ERROR: Models directory not found: $MODELS_DIR"
    echo "Set it with llama-launcher Settings or ./install.sh first."
    exit 1
fi

scan_model_folders() {
    local dir="$1"
    model_folders=()
    for folder in "$dir"/*/; do
        [ -d "$folder" ] || continue
        fname="$(basename "$folder")"
        [[ "$fname" == "downloading" ]] && continue
        if find "$folder" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | grep -zqv "mmproj"; then
            model_folders+=("$fname")
        fi
    done
}

scan_model_folders "$MODELS_DIR"
if [ ${#model_folders[@]} -eq 0 ]; then
    echo "ERROR: No model folders found in $MODELS_DIR"
    exit 1
fi

echo ""
echo "Model families in $MODELS_DIR:"
for i in "${!model_folders[@]}"; do
    folder="${model_folders[$i]}"
    quant_count=0
    has_vision=""
    while IFS= read -r -d '' file; do
        name="$(basename "$file")"
        [[ "$name" == *mmproj* ]] && { has_vision=" 👁️"; continue; }
        [[ "$name" =~ -[0-9]+-of-[0-9]+\.gguf$ ]] && ! [[ "$name" =~ -00001-of-[0-9]+\.gguf$ ]] && continue
        quant_count=$((quant_count + 1))
    done < <(find "$MODELS_DIR/$folder" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)
    printf "  %d) %s  [%d quant(s)]%s\n" $((i + 1)) "$folder" "$quant_count" "$has_vision"
done
echo ""
folder_sel="$(prompt_number "Select model" 1 1 "${#model_folders[@]}")"
selected_folder="${model_folders[$((folder_sel - 1))]}"
MODEL_FOLDER="$MODELS_DIR/$selected_folder"

quants=()
while IFS= read -r -d '' file; do
    name="$(basename "$file")"
    [[ "$name" == *mmproj* ]] && continue
    [[ "$name" =~ -[0-9]+-of-[0-9]+\.gguf$ ]] && ! [[ "$name" =~ -00001-of-[0-9]+\.gguf$ ]] && continue
    quants+=("$name")
done < <(find "$MODEL_FOLDER" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)

if [ ${#quants[@]} -eq 0 ]; then
    echo "ERROR: No model files in $MODEL_FOLDER"
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
            printf "  %d) %s  [split: %d parts]\n" $((i + 1)) "$name" "$((10#$total))"
        else
            printf "  %d) %s\n" $((i + 1)) "$name"
        fi
    done
    echo ""
    quant_sel="$(prompt_number "Select quant" 1 1 "${#quants[@]}")"
    selected_model="${quants[$((quant_sel - 1))]}"
fi

MODEL_PATH="$MODEL_FOLDER/$selected_model"
config_set LLAMACPP_DEFAULT_MODEL "$(basename "$MODEL_FOLDER")/$selected_model"

# ── Tune selection ──────────────────────────────────────────────────────────
MODEL_CONFIG_DIR="$ROOT_DIR/model-configs"
selected_folder_name="$(basename "$MODEL_FOLDER")"
TUNE_KEYS=(
    CONTEXT PARALLEL
    CACHE_RAM CACHE_TYPE_K CACHE_TYPE_V KV_UNIFIED
    SLOT_SAVE_PATH MIN_FREE_GB MAX_TOTAL_SLOTS_GB
    CHECKPOINT_MIN_STEP CHECKPOINT_MAX
    NGL FLASH_ATTN
    TEMP TOP_P TOP_K
    HOST PORT API_KEY TIMEOUT THREADS
    NO_MMAP DIO
    JINJA LOG_COLORS
    REASONING REASONING_BUDGET
    REPEAT_PENALTY REPEAT_LAST_N PRESENCE_PENALTY FREQUENCY_PENALTY
    DRY_MULTIPLIER DRY_BASE DRY_ALLOWED_LENGTH DRY_PENALTY_LAST_N
    EXTRA_ARGS
)

require_yq() {
    local version
    if ! command -v yq >/dev/null 2>&1; then
        echo "ERROR: YAML tunes require yq (the Python jq-wrapper YAML processor)."
        exit 1
    fi
    version="$(yq --version 2>/dev/null || true)"
    if [[ "$version" != yq\ 3.* ]]; then
        echo "ERROR: YAML tunes require the Python/jq-wrapper yq 3.x; found: ${version:-unknown}"
        exit 1
    fi
}

tune_yq() {
    local file="$1"
    local expr="$2"
    local value
    value="$(yq -r "$expr" "$file" 2>/dev/null || true)"
    [ "$value" = "null" ] && value=""
    printf '%s\n' "$value"
}

tune_label() {
    local file="$1"
    local label
    label="$(tune_yq "$file" '.name // ""')"
    [ -z "$label" ] && label="$(basename "$file" .yaml)"
    [ "$label" = "$(basename "$file")" ] && label="$(basename "$file" .yml)"
    printf '%s\n' "$label"
}

tune_setting() {
    tune_yq "$1" ".settings.$2 // \"\""
}

load_tune() {
    local file="$1"
    local key value kind
    kind="$(tune_yq "$file" '.kind // ""')"
    if [ "$kind" != "llama-launcher-tune" ]; then
        echo "ERROR: Invalid tune file: $(basename "$file")"
        exit 1
    fi
    for key in "${TUNE_KEYS[@]}"; do
        value="$(tune_setting "$file" "$key")"
        if [ -n "$value" ]; then
            printf -v "$key" '%s' "$value"
        fi
    done
}

require_yq
tune_configs=()
tune_names=()
_specific_configs=()
_specific_names=()
_family_configs=()
_family_names=()

shopt -s nullglob
for conf in "$MODEL_CONFIG_DIR"/*.yaml "$MODEL_CONFIG_DIR"/*.yml; do
    [ -f "$conf" ] || continue
    conf_base="$(basename "$conf")"
    conf_base="${conf_base%.yaml}"
    conf_base="${conf_base%.yml}"
    conf_model="${conf_base%%.*}"
    if [[ "$selected_folder_name" == "$conf_model" ]]; then
        label="$(tune_label "$conf")"
        _specific_configs+=("$conf")
        _specific_names+=("$label")
    elif [[ "$selected_folder_name" == "$conf_model"* ]]; then
        label="$(tune_label "$conf")"
        _family_configs+=("$conf")
        _family_names+=("$label")
    fi
done
shopt -u nullglob
for i in "${!_specific_configs[@]}"; do
    tune_configs+=("${_specific_configs[$i]}")
    tune_names+=("${_specific_names[$i]}")
done
TUNE_FAMILY_SPLIT=${#tune_configs[@]}
for i in "${!_family_configs[@]}"; do
    tune_configs+=("${_family_configs[$i]}")
    tune_names+=("${_family_names[$i]}")
done

HAS_MODEL_CONFIG=0
MODEL_CONFIG_FILE=""
TOTAL_RAM_MB_DETECT="$(free -m | awk '/^Mem:/{print $2}')"
TOTAL_RAM_GB_DETECT=$((TOTAL_RAM_MB_DETECT / 1024))

if [ ${#tune_configs[@]} -gt 0 ]; then
    tune_suggested=-1
    for i in "${!tune_names[@]}"; do
        name="${tune_names[$i]}"
        if [ "$TOTAL_RAM_GB_DETECT" -ge 112 ] && [[ "$name" == *128gb* ]]; then
            tune_suggested=$i
        elif [ "$TOTAL_RAM_GB_DETECT" -ge 48 ] && [ "$TOTAL_RAM_GB_DETECT" -lt 112 ] && [[ "$name" == *64gb* ]]; then
            tune_suggested=$i
        fi
    done
    default_sel=$((tune_suggested + 1))
    [ "$default_sel" -le 0 ] && default_sel=1

    echo ""
    echo "Available tunes for $selected_folder_name:"
    for i in "${!tune_names[@]}"; do
        if [ "$i" -eq "$TUNE_FAMILY_SPLIT" ] && [ "$TUNE_FAMILY_SPLIT" -gt 0 ]; then
            echo "  -- base model family tunes --"
        fi
        suggested=""
        [ "$i" -eq "$tune_suggested" ] && suggested=" <- suggested for ${TOTAL_RAM_GB_DETECT}GB system"
        tune_ctx="$(tune_setting "${tune_configs[$i]}" CONTEXT)"
        tune_par="$(tune_setting "${tune_configs[$i]}" PARALLEL)"
        tune_cp="$(tune_setting "${tune_configs[$i]}" CHECKPOINT_MAX)"
        printf "  %d) %-30s [ctx=%s, parallel=%s, checkpoints=%s]%s\n" \
            $((i + 1)) "${tune_names[$i]}" "${tune_ctx:-?}" "${tune_par:-?}" "${tune_cp:-?}" "$suggested"
    done
    echo "  0) None (system profile)"
    echo ""
    tune_sel="$(prompt_number "Select tune" "$default_sel" 0 "${#tune_configs[@]}")"
    if [ "$tune_sel" -gt 0 ]; then
        MODEL_CONFIG_FILE="${tune_configs[$((tune_sel - 1))]}"
        echo "Loading tune: ${tune_names[$((tune_sel - 1))]} ($(basename "$MODEL_CONFIG_FILE"))"
        load_tune "$MODEL_CONFIG_FILE"
        HAS_MODEL_CONFIG=1
    fi
else
    echo "No tune found for $selected_folder_name; using system profile."
fi

# ── Vision projector ────────────────────────────────────────────────────────
MMPROJ=""
mmproj_matches=()
while IFS= read -r -d '' file; do
    mmproj_matches+=("$file")
done < <(find "$MODEL_FOLDER" -maxdepth 1 -name "*mmproj*.gguf" -print0 2>/dev/null)

if [ ${#mmproj_matches[@]} -gt 0 ]; then
    echo ""
    echo "Vision projectors:"
    for i in "${!mmproj_matches[@]}"; do
        printf "  %d) %s\n" $((i + 1)) "$(basename "${mmproj_matches[$i]}")"
    done
    echo "  0) None"
    echo ""
    mmproj_sel="$(prompt_number "Enable vision" 0 0 "${#mmproj_matches[@]}")"
    if [ "$mmproj_sel" -gt 0 ]; then
        MMPROJ="${mmproj_matches[$((mmproj_sel - 1))]}"
    fi
fi

# ── Effective launch values ─────────────────────────────────────────────────
TOTAL_RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))

if [ "$HAS_MODEL_CONFIG" -eq 1 ]; then
    CONTEXT="${CONTEXT:-32768}"
    PARALLEL="${PARALLEL:-1}"
    CACHE_RAM="${CACHE_RAM:-8192}"
    CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
    CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"
    CHECKPOINT_MIN_STEP="${CHECKPOINT_MIN_STEP:-2048}"
    CHECKPOINT_MAX="${CHECKPOINT_MAX:-32}"
    echo "Profile: per-model (${CONTEXT} ctx, ${CACHE_TYPE_K}/${CACHE_TYPE_V} KV, ${PARALLEL} slot(s))"
elif [ "$TOTAL_RAM_GB" -ge 112 ]; then
    CONTEXT=488576; PARALLEL=2; CACHE_RAM=102400; CACHE_TYPE_K=q8_0; CACHE_TYPE_V=q8_0
    CHECKPOINT_MIN_STEP=8192; CHECKPOINT_MAX=64
    echo "Profile: 128 GB system"
elif [ "$TOTAL_RAM_GB" -ge 48 ]; then
    CONTEXT=131072; PARALLEL=1; CACHE_RAM=40960; CACHE_TYPE_K=q8_0; CACHE_TYPE_V=q8_0
    CHECKPOINT_MIN_STEP=4096; CHECKPOINT_MAX=32
    echo "Profile: 64 GB system"
else
    CONTEXT=61072; PARALLEL=1; CACHE_RAM=16384; CACHE_TYPE_K=q8_0; CACHE_TYPE_V=q8_0
    CHECKPOINT_MIN_STEP=4096; CHECKPOINT_MAX=16
    echo "Profile: minimal system"
fi

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
INTERNAL_PORT="${INTERNAL_PORT:-40802}"
API_KEY="${API_KEY:-ollama-local}"
KV_UNIFIED="${KV_UNIFIED:-1}"
FLASH_ATTN="${FLASH_ATTN:-1}"
LOG_COLORS="${LOG_COLORS:-1}"
JINJA="${JINJA:-1}"
REASONING="${REASONING:-auto}"
REASONING_BUDGET="${REASONING_BUDGET:--1}"
REPEAT_PENALTY="${REPEAT_PENALTY:-1.0}"
REPEAT_LAST_N="${REPEAT_LAST_N:-64}"
PRESENCE_PENALTY="${PRESENCE_PENALTY:-0.0}"
FREQUENCY_PENALTY="${FREQUENCY_PENALTY:-0.0}"
DRY_MULTIPLIER="${DRY_MULTIPLIER:-0.0}"
DRY_BASE="${DRY_BASE:-1.75}"
DRY_ALLOWED_LENGTH="${DRY_ALLOWED_LENGTH:-2}"
DRY_PENALTY_LAST_N="${DRY_PENALTY_LAST_N:--1}"
MIN_FREE_GB="${MIN_FREE_GB:-100}"
MAX_TOTAL_SLOTS_GB="${MAX_TOTAL_SLOTS_GB:-200}"
SLOT_SAVE_PATH="${SLOT_SAVE_PATH:-}"

echo ""
PORT="$(prompt_number "Public port" "$PORT" 1 65535)"
INTERNAL_PORT="$(prompt_number "Internal server port" "$INTERNAL_PORT" 1 65535)"
if [ "$PORT" = "$INTERNAL_PORT" ]; then
    echo "ERROR: Public port and internal server port must differ."
    exit 1
fi

_default_slot_save_path="${LLAMACPP_SLOT_SAVE_PATH:-$(dirname "$MODELS_DIR")/llama-slots}"
echo ""
echo "HDD cache:"
echo "  1) Tune/default     ${SLOT_SAVE_PATH:-off}"
echo "  2) Enable           ${SLOT_SAVE_PATH:-$_default_slot_save_path}"
echo "  3) Disable"
hdd_sel="$(prompt_number "Choice" 1 1 3)"
case "$hdd_sel" in
    1) ;;
    2) SLOT_SAVE_PATH="${SLOT_SAVE_PATH:-$_default_slot_save_path}"; CACHE_RAM=0 ;;
    3) SLOT_SAVE_PATH="" ;;
esac

NO_PROXY=0
NO_DEEP_LOG=1
if [ -n "$SLOT_SAVE_PATH" ]; then
    echo "Proxy: enabled (required for HDD cache)"
else
    echo ""
    if yes_no "Enable proxy anyway?" y; then
        NO_PROXY=0
    else
        NO_PROXY=1
        INTERNAL_PORT="$PORT"
    fi
fi
if [ "$NO_PROXY" -eq 0 ]; then
    if yes_no "Enable deep body log at $ROOT_DIR/llama-deep.log?" n; then
        NO_DEEP_LOG=0
    fi
fi

LOG_FILE="$ROOT_DIR/llama.log"
DEEP_LOG="$ROOT_DIR/llama-deep.log"
PROXY_SCRIPT="$ROOT_DIR/llama-deep-proxy.mjs"
NODE_BIN="$(command -v node || true)"
if [ "$NO_PROXY" -eq 0 ] && [ -z "$NODE_BIN" ]; then
    echo "ERROR: node is required for proxy mode but was not found on PATH."
    exit 1
fi
MODEL_BASENAME="$(basename "$MODEL_PATH" .gguf)"
EFFECTIVE_SLOT_SAVE_PATH=""
if [ -n "$SLOT_SAVE_PATH" ]; then
    EFFECTIVE_SLOT_SAVE_PATH="$SLOT_SAVE_PATH/$MODEL_BASENAME"
    mkdir -p "$EFFECTIVE_SLOT_SAVE_PATH"
    if [ "$INSTALL_MODE" = "system" ]; then
        chown -R "$INSTALL_USER":"$INSTALL_USER" "$SLOT_SAVE_PATH" 2>/dev/null || true
    fi
fi

mkdir -p "$SERVICE_DIR" "$(dirname "$SERVICE_FILE")"

# ── Write service start wrapper ─────────────────────────────────────────────
cat > "$START_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

export HOME=$(quote_sh "$INSTALL_HOME")
export ROCBLAS_USE_HIPBLASLT=1
export HSA_XNACK=1
export LD_LIBRARY_PATH=$(quote_sh "$BUILD_DIR/bin:$BUILD_DIR/lib")

LOG_FILE=$(quote_sh "$LOG_FILE")
DEEP_LOG=$(quote_sh "$DEEP_LOG")
SERVER_BIN=$(quote_sh "$SERVER_BIN")
PROXY_SCRIPT=$(quote_sh "$PROXY_SCRIPT")
NODE_BIN=$(quote_sh "$NODE_BIN")
MODEL_PATH=$(quote_sh "$MODEL_PATH")
MMPROJ=$(quote_sh "$MMPROJ")
NO_PROXY=$NO_PROXY
NO_DEEP_LOG=$NO_DEEP_LOG
PORT=$PORT
INTERNAL_PORT=$INTERNAL_PORT
API_KEY=$(quote_sh "$API_KEY")
EFFECTIVE_SLOT_SAVE_PATH=$(quote_sh "$EFFECTIVE_SLOT_SAVE_PATH")
MIN_FREE_GB=$MIN_FREE_GB
MAX_TOTAL_SLOTS_GB=$MAX_TOTAL_SLOTS_GB

PROXY_PID=""
cleanup() {
    if [ -n "\$PROXY_PID" ] && kill -0 "\$PROXY_PID" 2>/dev/null; then
        kill "\$PROXY_PID" 2>/dev/null || true
        wait "\$PROXY_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ "\$NO_PROXY" -eq 0 ]; then
    proxy_args=("\$PORT" "\$INTERNAL_PORT")
    if [ "\$NO_DEEP_LOG" -eq 0 ]; then
        proxy_args+=("\$DEEP_LOG")
    else
        proxy_args+=("/dev/null")
    fi
    proxy_args+=(--llama-log-file "\$LOG_FILE" --api-key "\$API_KEY")
    if [ -n "\$EFFECTIVE_SLOT_SAVE_PATH" ]; then
        mkdir -p "\$EFFECTIVE_SLOT_SAVE_PATH"
        proxy_args+=(--slot-cache-dir "\$EFFECTIVE_SLOT_SAVE_PATH" --min-free-gb "\$MIN_FREE_GB" --max-total-slots-gb "\$MAX_TOTAL_SLOTS_GB")
    fi
    "\$NODE_BIN" "\$PROXY_SCRIPT" "\${proxy_args[@]}" --stdout-is-llama-log &
    PROXY_PID=\$!
    sleep 0.3
    if ! kill -0 "\$PROXY_PID" 2>/dev/null; then
        echo "proxy failed to start"
        exit 1
    fi
fi

server_args=(
  -m "\$MODEL_PATH"
  -ngl "$NGL"
  -c "$CONTEXT"
  --parallel "$PARALLEL"
  --cache-ram "$CACHE_RAM"
  -ctk "$CACHE_TYPE_K"
  -ctv "$CACHE_TYPE_V"
  --checkpoint-min-step "$CHECKPOINT_MIN_STEP"
  --ctx-checkpoints "$CHECKPOINT_MAX"
  --seed "$SEED"
  --temp "$TEMP"
  --top-p "$TOP_P"
  --top-k "$TOP_K"
  --threads "$THREADS"
  --timeout "$TIMEOUT"
  --host "$HOST"
  --port "\$INTERNAL_PORT"
  --api-key "\$API_KEY"
)
[ "$FLASH_ATTN" = "1" ] && server_args+=(-fa on)
[ "$KV_UNIFIED" = "1" ] && server_args+=(--kv-unified) || server_args+=(--no-kv-unified)
[ "$NO_MMAP" = "1" ] && server_args+=(--no-mmap)
[ "$DIO" = "1" ] && server_args+=(-dio)
[ "$JINJA" = "1" ] && server_args+=(--jinja)
[ "$LOG_COLORS" = "0" ] && server_args+=(--log-colors off) || server_args+=(--log-colors on)
[ -n "\$MMPROJ" ] && server_args+=(--mmproj "\$MMPROJ")
[ -n "\$EFFECTIVE_SLOT_SAVE_PATH" ] && server_args+=(--slot-save-path "\$EFFECTIVE_SLOT_SAVE_PATH")
if [ "\$(ulimit -l 2>/dev/null || echo 0)" = "unlimited" ]; then
    server_args+=(--mlock)
fi
[ "$REASONING" != "auto" ] && server_args+=(--reasoning "$REASONING")
[ "$REASONING_BUDGET" != "-1" ] && server_args+=(--reasoning-budget "$REASONING_BUDGET")
[ "$REPEAT_PENALTY" != "1.0" ] && server_args+=(--repeat-penalty "$REPEAT_PENALTY" --repeat-last-n "$REPEAT_LAST_N")
[ "$PRESENCE_PENALTY" != "0.0" ] && server_args+=(--presence-penalty "$PRESENCE_PENALTY")
[ "$FREQUENCY_PENALTY" != "0.0" ] && server_args+=(--frequency-penalty "$FREQUENCY_PENALTY")
[ "$DRY_MULTIPLIER" != "0.0" ] && server_args+=(--dry-multiplier "$DRY_MULTIPLIER" --dry-base "$DRY_BASE" --dry-allowed-length "$DRY_ALLOWED_LENGTH" --dry-penalty-last-n "$DRY_PENALTY_LAST_N")

exec "\$SERVER_BIN" "\${server_args[@]}"
EOF
chmod 0755 "$START_SCRIPT"

case "${BUILD_TYPE%%-*}" in
    rocm)
        ENV_BLOCK="Environment=ROCBLAS_USE_HIPBLASLT=1
Environment=HSA_XNACK=1
Environment=LD_LIBRARY_PATH=${BUILD_DIR}/bin:${BUILD_DIR}/lib"
        ;;
    vulkan)
        ENV_BLOCK="Environment=LD_LIBRARY_PATH=${BUILD_DIR}/bin:${BUILD_DIR}/lib"
        ;;
    *)
        ENV_BLOCK="Environment=LD_LIBRARY_PATH=${BUILD_DIR}/bin:${BUILD_DIR}/lib"
        ;;
esac

if [ -f "$SERVICE_FILE" ]; then
    echo "Stopping existing $SERVICE_NAME service before overwrite."
    "${SYSTEMCTL[@]}" stop "$SERVICE_NAME" 2>/dev/null || true
fi

if [ "$INSTALL_MODE" = "system" ]; then
    SERVICE_USER_LINE="User=$INSTALL_USER"
    SERVICE_MEMLOCK_LINE="LimitMEMLOCK=infinity"
else
    SERVICE_USER_LINE=""
    SERVICE_MEMLOCK_LINE="# LimitMEMLOCK is controlled by user manager/login limits"
fi

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=llama-launcher managed llama-server
$SERVICE_UNIT_AFTER
$SERVICE_UNIT_WANTS

[Service]
Type=simple
$SERVICE_USER_LINE
WorkingDirectory=$ROOT_DIR
$ENV_BLOCK
ExecStart=/bin/bash $START_SCRIPT
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=on-failure
RestartSec=10
TimeoutStopSec=45
KillSignal=SIGINT
$SERVICE_MEMLOCK_LINE
LimitNOFILE=1048576

[Install]
WantedBy=$SERVICE_WANTED_BY
EOF

if ! "${SYSTEMCTL[@]}" daemon-reload; then
    echo "ERROR: systemd $SERVICE_SCOPE_LABEL manager is not available."
    if [ "$INSTALL_MODE" = "user" ]; then
        echo "Try logging in with a normal user session, or enable lingering:"
        echo "  loginctl enable-linger $INSTALL_USER"
    fi
    exit 1
fi
"${SYSTEMCTL[@]}" enable "$SERVICE_NAME"
if [ "$NO_START" -eq 0 ]; then
    "${SYSTEMCTL[@]}" restart "$SERVICE_NAME"
fi

echo ""
echo "$SERVICE_SCOPE_LABEL service installed."
echo "  User:       $INSTALL_USER"
echo "  Build:      $BUILD_TYPE"
echo "  Model:      $selected_model"
if [ -n "$MODEL_CONFIG_FILE" ]; then
    echo "  Tune:       $(basename "$MODEL_CONFIG_FILE")"
else
    echo "  Tune:       system profile"
fi
echo "  Public:     http://$HOST:$PORT"
if [ "$NO_PROXY" -eq 0 ]; then
    echo "  Proxy:      on (:${PORT} -> :${INTERNAL_PORT})"
else
    echo "  Proxy:      off"
fi
if [ -n "$EFFECTIVE_SLOT_SAVE_PATH" ]; then
    echo "  HDD cache:  $EFFECTIVE_SLOT_SAVE_PATH"
else
    echo "  HDD cache:  off"
fi
echo "  Log:        $LOG_FILE"
echo ""
if [ "$INSTALL_MODE" = "system" ]; then
    echo "  systemctl status $SERVICE_NAME"
    echo "  journalctl -u $SERVICE_NAME -f"
    echo "  sudo $0 --system --uninstall"
else
    echo "  systemctl --user status $SERVICE_NAME"
    echo "  journalctl --user -u $SERVICE_NAME -f"
    echo "  $0 --uninstall"
    echo ""
    echo "For boot without an active login session, enable lingering:"
    echo "  loginctl enable-linger $INSTALL_USER"
fi
