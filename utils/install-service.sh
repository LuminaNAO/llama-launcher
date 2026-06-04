#!/bin/bash

# Llama Server Systemd Service Installer
# Installs a system service that starts llama-server at boot.
#
# Usage:
#   sudo ./utils/install-service.sh [--seed <N>] [--uninstall]
#
# Must be run with sudo. The service will run as the user who invoked sudo.

set -e

UTIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$UTIL_DIR")"
CONFIG_FILE="$ROOT_DIR/.llama-launcher-config"
SERVICE_NAME="llama-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DEFAULT_MODELS_DIR="/usr/local/share/llama.cpp/models"

# ── Argument parsing ──────────────────────────────────────────────────────────
SEED=42
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed) SEED="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Sudo check ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run with sudo."
    echo "  sudo $0 $*"
    exit 1
fi

# Recover the actual invoking user (not root)
INSTALL_USER="${SUDO_USER:-}"
if [ -z "$INSTALL_USER" ]; then
    echo "ERROR: Could not determine invoking user. Run via sudo, not as root directly."
    exit 1
fi
INSTALL_HOME=$(getent passwd "$INSTALL_USER" | cut -d: -f6)

echo "Installing service as user: $INSTALL_USER"
echo ""

# ── Uninstall path ────────────────────────────────────────────────────────────
if [ "$UNINSTALL" -eq 1 ]; then
    if [ ! -f "$SERVICE_FILE" ]; then
        echo "No service file found at $SERVICE_FILE — nothing to uninstall."
        exit 0
    fi
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo "Service removed."
    exit 0
fi

# ── Load config ───────────────────────────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
    eval "$(cat "$CONFIG_FILE")"
fi
MODELS_DIR="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"

# ── Scan model folders ────────────────────────────────────────────────────────
scan_model_folders() {
    local dir="$1"
    model_folders=()
    for folder in "$dir"/*/; do
        [ ! -d "$folder" ] && continue
        local fname="$(basename "$folder")"
        [[ "$fname" == "downloading" ]] && continue
        if find "$folder" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | grep -zqv "mmproj"; then
            model_folders+=("$fname")
        fi
    done
}

scan_model_folders "$MODELS_DIR"

if [ ${#model_folders[@]} -eq 0 ]; then
    echo "ERROR: No model folders found in $MODELS_DIR"
    echo "Set LLAMACPP_MODELS_DIR in $CONFIG_FILE and try again."
    exit 1
fi

# ── Select model ──────────────────────────────────────────────────────────────
# Use saved default if available (format: folder/filename)
selected_model=""
MODEL_FOLDER=""

if [ -n "${LLAMACPP_DEFAULT_MODEL:-}" ]; then
    # Default can be "folder/file.gguf" or legacy "file.gguf"
    if [[ "$LLAMACPP_DEFAULT_MODEL" == */* ]]; then
        def_folder="${LLAMACPP_DEFAULT_MODEL%%/*}"
        def_file="${LLAMACPP_DEFAULT_MODEL#*/}"
        if [ -f "$MODELS_DIR/$def_folder/$def_file" ]; then
            echo "Using saved default model: $LLAMACPP_DEFAULT_MODEL"
            selected_model="$def_file"
            MODEL_FOLDER="$MODELS_DIR/$def_folder"
        fi
    fi
    if [ -z "$selected_model" ]; then
        echo "WARNING: Saved default model '$LLAMACPP_DEFAULT_MODEL' not found, prompting for selection."
    fi
fi

if [ -z "$selected_model" ]; then
    echo "Model families in $MODELS_DIR:"
    echo ""
    for i in "${!model_folders[@]}"; do
        folder="${model_folders[$i]}"
        quant_count=0
        while IFS= read -r -d '' file; do
            name="$(basename "$file")"
            [[ "$name" == *mmproj* ]] && continue
            [[ "$name" =~ -[0-9]+-of-[0-9]+\.gguf$ ]] && ! [[ "$name" =~ -00001-of-[0-9]+\.gguf$ ]] && continue
            quant_count=$((quant_count + 1))
        done < <(find "$MODELS_DIR/$folder" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)
        printf "  %d) %s  [%d quant(s)]\n" $((i+1)) "$folder" "$quant_count"
    done
    echo ""
    read -rp "Select model family [1-${#model_folders[@]}]: " folder_sel
    if ! [[ "$folder_sel" =~ ^[0-9]+$ ]] || [ "$folder_sel" -lt 1 ] || [ "$folder_sel" -gt ${#model_folders[@]} ]; then
        echo "ERROR: Invalid selection"
        exit 1
    fi

    selected_folder="${model_folders[$((folder_sel-1))]}"
    MODEL_FOLDER="$MODELS_DIR/$selected_folder"

    # Scan quants within folder
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
                printf "  %d) %s  [split: %d parts]\n" $((i+1)) "$name" "$((10#$total))"
            else
                printf "  %d) %s\n" $((i+1)) "$name"
            fi
        done
        echo ""
        read -rp "Select quant [1-${#quants[@]}]: " quant_sel
        if ! [[ "$quant_sel" =~ ^[0-9]+$ ]] || [ "$quant_sel" -lt 1 ] || [ "$quant_sel" -gt ${#quants[@]} ]; then
            echo "ERROR: Invalid selection"
            exit 1
        fi
        selected_model="${quants[$((quant_sel-1))]}"
    fi

    # Save as default for next install (folder/file format)
    save_default="$(basename "$MODEL_FOLDER")/$selected_model"
    if grep -q "^LLAMACPP_DEFAULT_MODEL=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^LLAMACPP_DEFAULT_MODEL=.*|LLAMACPP_DEFAULT_MODEL=$save_default|" "$CONFIG_FILE"
    else
        echo "LLAMACPP_DEFAULT_MODEL=$save_default" >> "$CONFIG_FILE"
    fi
fi

MODEL_PATH="$MODEL_FOLDER/$selected_model"

# ── Resolve build ─────────────────────────────────────────────────────────────
BUILD_TYPE="${LLAMACPP_BUILD_TYPE:-rocm}"
BUILD_DIR="$ROOT_DIR/builds/$BUILD_TYPE"
SERVER_BIN="$BUILD_DIR/bin/llama-server"

if [ ! -f "$SERVER_BIN" ]; then
    echo "ERROR: llama-server not found at $SERVER_BIN"
    echo "Set LLAMACPP_BUILD_TYPE in $CONFIG_FILE and try again."
    exit 1
fi

# ── Load per-model config ────────────────────────────────────────────────────
MODEL_CONFIG_DIR="$ROOT_DIR/model-configs"
selected_folder_name="$(basename "$MODEL_FOLDER")"
JINJA=1  # default: enable jinja

for conf in \
    "$MODEL_CONFIG_DIR/${selected_folder_name}.conf" \
    "$MODEL_CONFIG_DIR/${selected_model%.gguf}.conf" \
    "$MODEL_CONFIG_DIR/$(echo "${selected_model%.gguf}" | sed 's/-00001-of-[0-9]*//' ).conf"; do
    if [ -f "$conf" ]; then
        echo "Loading config: $(basename "$conf")"
        source "$conf"
        break
    fi
done

if [ "$JINJA" -eq 1 ]; then
    JINJA_FLAG="--jinja"
else
    JINJA_FLAG=""
    echo "  (jinja disabled for this model)"
fi

# ── RAM profile (mirrors launcher logic) ─────────────────────────────────────
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))

if [ "$TOTAL_RAM_GB" -ge 112 ]; then
    CONTEXT=488576; PARALLEL=2; CACHE_RAM=40960
    CACHE_TYPE_K="q8_0"; CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=4096; CHECKPOINT_MAX=64
    PROFILE="128gb"
elif [ "$TOTAL_RAM_GB" -ge 48 ]; then
    CONTEXT=122144; PARALLEL=2; CACHE_RAM=8192
    CACHE_TYPE_K="q8_0"; CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=8192; CHECKPOINT_MAX=32
    PROFILE="64gb"
else
    CONTEXT=61072; PARALLEL=1; CACHE_RAM=4096
    CACHE_TYPE_K="q8_0"; CACHE_TYPE_V="q8_0"
    CHECKPOINT_INTERVAL=8192; CHECKPOINT_MAX=16
    PROFILE="minimal"
fi

# ── ROCm env vars ─────────────────────────────────────────────────────────────
case "$BUILD_TYPE" in
    rocm)
        ENV_BLOCK="Environment=ROCBLAS_USE_HIPBLASLT=1
Environment=HSA_XNACK=1
Environment=LD_LIBRARY_PATH=${BUILD_DIR}/bin:${BUILD_DIR}/lib"
        ;;
    vulkan)
        ENV_BLOCK="Environment=VK_ICD_FILENAMES="
        ;;
    *)
        ENV_BLOCK=""
        ;;
esac

# ── Warn if overwriting ───────────────────────────────────────────────────────
if [ -f "$SERVICE_FILE" ]; then
    echo "WARNING: Service file already exists at $SERVICE_FILE — overwriting."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
fi

# ── Build ExecStart command ───────────────────────────────────────────────────
EXEC_CMD="$SERVER_BIN \\
  -m $MODEL_PATH \\
  -ngl 99 \\
  -c $CONTEXT \\
  -fa on \\
  --temp 0.3 \\
  --top-p 0.95 \\
  --top-k 20 \\
  --threads $(nproc) \\
  --no-mmap \\
  --timeout 3600 \\
  --host 0.0.0.0 \\
  --port 40801 \\
  --api-key ollama-local"

if [ -n "$JINJA_FLAG" ]; then
    EXEC_CMD="$EXEC_CMD \\
  $JINJA_FLAG"
fi

EXEC_CMD="$EXEC_CMD \\
  --parallel $PARALLEL \\
  --kv-unified \\
  --cache-ram $CACHE_RAM \\
  -ctk $CACHE_TYPE_K \\
  -ctv $CACHE_TYPE_V \\
  --checkpoint-every-n-tokens $CHECKPOINT_INTERVAL \\
  --ctx-checkpoints $CHECKPOINT_MAX \\
  --seed $SEED"

# ── Write service file ────────────────────────────────────────────────────────
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=llama.cpp inference server
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
User=$INSTALL_USER
WorkingDirectory=$ROOT_DIR
${ENV_BLOCK}
ExecStart=$EXEC_CMD
StandardOutput=append:$INSTALL_HOME/llama.log
StandardError=append:$INSTALL_HOME/llama.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ── Enable and start ──────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo ""
echo "Service installed and started."
echo "  Profile:  $PROFILE (${TOTAL_RAM_GB} GB RAM detected)"
echo "  Model:    $selected_model"
echo "  Backend:  $BUILD_TYPE"
echo "  Seed:     $SEED"
echo "  Log:      $INSTALL_HOME/llama.log"
echo ""
echo "  systemctl status $SERVICE_NAME"
echo "  journalctl -u $SERVICE_NAME -f"
echo "  sudo $0 --uninstall"
