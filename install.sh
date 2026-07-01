#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TARGET="$SCRIPT_DIR/llama-server-launcher.sh"
CONFIG_FILE="$SCRIPT_DIR/.llama-launcher-config"
DEFAULT_MODELS_DIR="$HOME/llama-launcher/models"
AUTHOR_BEST_PICKS_FILE="$SCRIPT_DIR/model-configs/author-best-picks.sh"

if [[ -f "$AUTHOR_BEST_PICKS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$AUTHOR_BEST_PICKS_FILE"
fi

if [[ ! -x "$TARGET" ]]; then
    echo "ERROR: Launcher not found or not executable: $TARGET"
    exit 1
fi
DOWNLOAD_TARGET="$SCRIPT_DIR/download-model.sh"
if [[ ! -x "$DOWNLOAD_TARGET" ]]; then
    echo "ERROR: Downloader not found or not executable: $DOWNLOAD_TARGET"
    exit 1
fi
BUILD_TARGET="$SCRIPT_DIR/build-llamacpp.sh"
if [[ ! -x "$BUILD_TARGET" ]]; then
    echo "ERROR: Builder not found or not executable: $BUILD_TARGET"
    exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: llama-launcher YAML tunes require yq (the Python jq-wrapper YAML processor)."
    echo "Install yq and re-run install.sh."
    exit 1
fi
_yq_version="$(yq --version 2>/dev/null || true)"
if [[ "$_yq_version" != yq\ 3.* ]]; then
    echo "ERROR: llama-launcher YAML tunes require the Python/jq-wrapper yq 3.x; found: ${_yq_version:-unknown}"
    exit 1
fi
unset _yq_version

_env_models_dir="${LLAMACPP_MODELS_DIR:-}"
_env_slot_save_path="${LLAMACPP_SLOT_SAVE_PATH:-}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi
[ -n "$_env_models_dir" ] && LLAMACPP_MODELS_DIR="$_env_models_dir"
[ -n "$_env_slot_save_path" ] && LLAMACPP_SLOT_SAVE_PATH="$_env_slot_save_path"
unset _env_models_dir _env_slot_save_path

expand_path() {
    local path="$1"
    path="${path/#\~/$HOME}"
    printf '%s\n' "$path"
}

quote_sh() {
    printf '%q' "$1"
}

config_set() {
    local key="$1"
    local value="$2"
    local line tmp

    line="$key=$(quote_sh "$value")"
    tmp="$(mktemp)"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        {
            echo "# llama-launcher installer config"
            echo "# This file is sourced by install.sh, download-model.sh, and llama-server-launcher.sh."
        } > "$CONFIG_FILE"
    fi
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
}

write_config() {
    local models_dir="$1"
    local slot_dir="$2"

    config_set LLAMACPP_MODELS_DIR "$models_dir"
    config_set LLAMACPP_SLOT_SAVE_PATH "$slot_dir"
}

usable_models_dir_for_candidate() {
    local dir="$1"
    local gguf=""
    [[ -d "$dir" ]] || return 1

    # Preferred shape: <models-dir>/<model-folder>/*.gguf
    gguf="$(find "$dir" -mindepth 2 -maxdepth 2 -type f -name "*.gguf" -print -quit 2>/dev/null || true)"
    if [[ -n "$gguf" ]]; then
        printf '%s\n' "$dir"
        return 0
    fi

    # Hugging Face cache shape is usually deeper:
    # ~/.cache/huggingface/hub/models--owner--repo/snapshots/<rev>/*.gguf
    gguf="$(find "$dir" -maxdepth 5 -type f -name "*.gguf" -print -quit 2>/dev/null || true)"
    if [[ -n "$gguf" ]]; then
        dirname "$(dirname "$gguf")"
        return 0
    fi

    return 1
}

gguf_count_under() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo 0; return; }
    find "$dir" -maxdepth 5 -type f -name "*.gguf" 2>/dev/null | wc -l | tr -d ' '
}

candidate_label() {
    local dir="$1"
    local count
    count="$(gguf_count_under "$dir")"
    if [[ "$count" -gt 0 ]]; then
        printf '%s  (%s GGUF file(s))\n' "$dir" "$count"
    else
        printf '%s\n' "$dir"
    fi
}

build_model_dir_candidates() {
    local seen=":"
    local candidates=()

    add_candidate() {
        local dir="$1"
        [[ -n "$dir" ]] || return 0
        dir="$(expand_path "$dir")"
        dir="${dir%/}"
        [[ ":$seen:" == *":$dir:"* ]] && return 0
        seen="${seen}${dir}:"
        candidates+=("$dir")
    }

    add_candidate "${LLAMACPP_MODELS_DIR:-}"
    add_candidate "$DEFAULT_MODELS_DIR"
    add_candidate "$HOME/.local/share/llama.cpp/models"
    add_candidate "$SCRIPT_DIR/models"
    add_candidate "/mnt/storage/models"

    if [[ -n "${HUGGINGFACE_HUB_CACHE:-}" ]]; then
        add_candidate "$HUGGINGFACE_HUB_CACHE"
    fi
    if [[ -n "${HF_HOME:-}" ]]; then
        add_candidate "$HF_HOME/hub"
    fi
    add_candidate "$HOME/.cache/huggingface/hub"

    for dir in "${candidates[@]}"; do
        printf '%s\0' "$dir"
    done
}

autodetect_models_dir() {
    local seen=":"
    local candidates=()
    while IFS= read -r -d '' dir; do
        local usable=""
        usable="$(usable_models_dir_for_candidate "$dir" || true)"
        [[ -n "$usable" ]] || continue
        usable="${usable%/}"
        [[ ":$seen:" == *":$usable:"* ]] && continue
        seen="${seen}${usable}:"
        candidates+=("$usable")
    done < <(build_model_dir_candidates)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1
    fi

    for dir in "${candidates[@]}"; do
        if [[ "$dir" != "$HOME/.cache/huggingface/hub" && "$dir" != */hub ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done

    printf '%s\n' "${candidates[0]}"
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local suffix="[y/N]"
    [[ "$default" == "y" ]] && suffix="[Y/n]"
    local ans
    read -rp "$prompt $suffix " ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

prompt_path() {
    local prompt="$1"
    local default="$2"
    local value
    read -rp "$prompt [$default]: " value
    value="${value:-$default}"
    expand_path "$value"
}

setup_environment() {
    local current_models="${LLAMACPP_MODELS_DIR:-}"
    local current_slots="${LLAMACPP_SLOT_SAVE_PATH:-}"
    local detected_models=""
    local models_dir=""
    local slot_dir=""

    echo "llama-launcher environment"
    echo ""

    if [[ -n "$current_models" ]]; then
        echo "Models directory is already set:"
        echo "  LLAMACPP_MODELS_DIR=$current_models"
        models_dir="$current_models"
        if ! prompt_yes_no "Keep this models directory?" y; then
            models_dir=""
        fi
    fi

    if [[ -z "$models_dir" ]]; then
        detected_models="$(autodetect_models_dir || true)"
        if [[ -n "$detected_models" ]]; then
            echo "Detected GGUF models under:"
            echo "  $(candidate_label "$detected_models")"
            if prompt_yes_no "Use this as LLAMACPP_MODELS_DIR?" y; then
                models_dir="$detected_models"
            fi
        fi
    fi

    if [[ -z "$models_dir" ]]; then
        echo ""
        echo "Common model locations:"
        local dirs=()
        while IFS= read -r -d '' dir; do
            dirs+=("$dir")
        done < <(build_model_dir_candidates)
        for i in "${!dirs[@]}"; do
            printf "  %d) %s\n" $((i + 1)) "$(candidate_label "${dirs[$i]}")"
        done
        echo "  0) Enter a custom path"
        echo ""
        local choice
        read -rp "Models directory choice [default=1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" == "0" ]]; then
            models_dir="$(prompt_path "Enter models directory" "$HOME/.local/share/llama.cpp/models")"
        elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#dirs[@]} ]]; then
            models_dir="${dirs[$((choice - 1))]}"
        else
            echo "ERROR: Invalid selection"
            exit 1
        fi
    fi

    models_dir="$(expand_path "$models_dir")"
    models_dir="${models_dir%/}"

    if [[ ! -d "$models_dir" ]]; then
        if prompt_yes_no "Create models directory $models_dir?" y; then
            mkdir -p "$models_dir"
        else
            echo "ERROR: Models directory does not exist: $models_dir"
            exit 1
        fi
    fi

    local default_slots="$HOME/llama-launcher/slots"
    if [[ -n "$current_slots" ]]; then
        echo ""
        echo "Slot save directory is already set:"
        echo "  LLAMACPP_SLOT_SAVE_PATH=$current_slots"
        slot_dir="$current_slots"
        if ! prompt_yes_no "Keep this slot save directory?" y; then
            slot_dir=""
        fi
    fi

    if [[ -z "$slot_dir" ]]; then
        slot_dir="$(prompt_path "Slot save directory" "$default_slots")"
    fi

    slot_dir="$(expand_path "$slot_dir")"
    slot_dir="${slot_dir%/}"

    if [[ ! -d "$slot_dir" ]]; then
        if prompt_yes_no "Create slot save directory $slot_dir?" y; then
            mkdir -p "$slot_dir"
        else
            echo "ERROR: Slot save directory does not exist: $slot_dir"
            exit 1
        fi
    fi

    write_config "$models_dir" "$slot_dir"
    LLAMACPP_MODELS_DIR="$models_dir"
    LLAMACPP_SLOT_SAVE_PATH="$slot_dir"

    echo ""
    echo "Saved config:"
    echo "  $CONFIG_FILE"
    echo "  LLAMACPP_MODELS_DIR=$LLAMACPP_MODELS_DIR"
    echo "  LLAMACPP_SLOT_SAVE_PATH=$LLAMACPP_SLOT_SAVE_PATH"
    echo ""
}

model_file_exists_under() {
    local models_dir="$1"
    local filename="$2"
    [[ -d "$models_dir" ]] || return 1
    find "$models_dir" -maxdepth 3 -type f -name "$filename" -print -quit 2>/dev/null | grep -q .
}

offer_author_best_pick() {
    local models_dir="${LLAMACPP_MODELS_DIR:-}"
    [[ -n "$models_dir" ]] || return 0

    echo "Author best pick:"
    echo "  $AUTHOR_BEST_PICK_NAME"
    echo "  Model: $AUTHOR_BEST_PICK_GGUF"
    echo "  Tune:  model-configs/$AUTHOR_BEST_PICK_TUNE"
    echo ""

    if model_file_exists_under "$models_dir" "$AUTHOR_BEST_PICK_GGUF"; then
        echo "Best-pick model already exists under:"
        echo "  $models_dir"
        echo ""
        return 0
    fi

    echo "The best-pick GGUF was not found under:"
    echo "  $models_dir"
    if prompt_yes_no "Download it now with download-model.sh?" y; then
        "$SCRIPT_DIR/download-model.sh" --filename "$AUTHOR_BEST_PICK_GGUF" "$AUTHOR_BEST_PICK_REPO"
    else
        echo "Skipping model download. You can run later:"
        echo "  $SCRIPT_DIR/download-model.sh --filename $AUTHOR_BEST_PICK_GGUF $AUTHOR_BEST_PICK_REPO"
    fi
    echo ""
}

detect_shell_name() {
    local shell_name=""
    if [[ -n "${SHELL:-}" ]]; then
        shell_name="$(basename "$SHELL")"
    fi
    if [[ -z "$shell_name" || "$shell_name" == "sh" ]]; then
        shell_name="$(ps -p "$PPID" -o comm= 2>/dev/null | sed 's/^-//' || true)"
    fi
    case "$shell_name" in
        bash|zsh|fish) printf '%s\n' "$shell_name" ;;
        *) printf '%s\n' "bash" ;;
    esac
}

shell_profile_path() {
    local shell_name="$1"
    case "$shell_name" in
        bash) printf '%s\n' "$HOME/.bashrc" ;;
        zsh)  printf '%s\n' "$HOME/.zshrc" ;;
        fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
        *)    printf '%s\n' "$HOME/.bashrc" ;;
    esac
}

escape_double_quotes() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '%s' "$value"
}

remove_managed_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    awk '
        /^# >>> llama-launcher >>>$/ { skip=1; next }
        /^# <<< llama-launcher <<<$/{ skip=0; next }
        !skip { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

install_shell_binding() {
    local shell_name="$1"
    local profile="$2"
    local link_dir="$3"
    local models_dir="$4"
    local slot_dir="$5"

    mkdir -p "$(dirname "$profile")"
    touch "$profile"
    remove_managed_block "$profile"

    {
        echo ""
        echo "# >>> llama-launcher >>>"
        if [[ "$shell_name" == "fish" ]]; then
            echo "set -l __llama_launcher_bin \"$(escape_double_quotes "$link_dir")\""
            echo "contains -- \$__llama_launcher_bin \$PATH; or set -gx PATH \$__llama_launcher_bin \$PATH"
            echo "set -gx LLAMACPP_MODELS_DIR \"$(escape_double_quotes "$models_dir")\""
            echo "set -gx LLAMACPP_SLOT_SAVE_PATH \"$(escape_double_quotes "$slot_dir")\""
        else
            echo "__llama_launcher_bin=\"$(escape_double_quotes "$link_dir")\""
            echo "case \":\$PATH:\" in *\":\$__llama_launcher_bin:\"*) ;; *) export PATH=\"\$__llama_launcher_bin:\$PATH\" ;; esac"
            echo "unset __llama_launcher_bin"
            echo "export LLAMACPP_MODELS_DIR=\"$(escape_double_quotes "$models_dir")\""
            echo "export LLAMACPP_SLOT_SAVE_PATH=\"$(escape_double_quotes "$slot_dir")\""
        fi
        echo "# <<< llama-launcher <<<"
    } >> "$profile"

    echo "Installed shell binding:"
    echo "  shell:   $shell_name"
    echo "  profile: $profile"
}

setup_environment
offer_author_best_pick

if [[ "$(id -u)" -eq 0 ]]; then
    LINK_DIR="/usr/local/bin"
else
    LINK_DIR="$HOME/.local/bin"
    mkdir -p "$LINK_DIR"
fi
LINK="$LINK_DIR/llama-launcher"
LOG_LINK="$LINK_DIR/llama-launcher-log"
DOWNLOAD_LINK="$LINK_DIR/llama-download-model"
DOWNLOAD_COMPAT_LINK="$LINK_DIR/download-model.sh"
BUILD_LINK="$LINK_DIR/llama-build"

if [[ -e "$LINK" || -L "$LINK" ]]; then
    if [[ -L "$LINK" && "$(readlink -f "$LINK")" == "$TARGET" ]]; then
        echo "Already installed: $LINK -> $TARGET"
    else
        echo "WARNING: $LINK exists and points elsewhere, or is a regular file."
        read -rp "Overwrite? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
        ln -sfn "$TARGET" "$LINK"
        echo "Updated: $LINK -> $TARGET"
    fi
else
    ln -s "$TARGET" "$LINK"
    echo "Installed: $LINK -> $TARGET"
fi

# Install llama-launcher-log alongside (symlink to same script; the script
# dispatches on basename "$0" or first arg "log" to do `tail -f llama.log`).
if [[ -e "$LOG_LINK" || -L "$LOG_LINK" ]]; then
    if [[ -L "$LOG_LINK" && "$(readlink -f "$LOG_LINK")" == "$TARGET" ]]; then
        echo "Already installed: $LOG_LINK -> $TARGET"
    else
        echo "WARNING: $LOG_LINK exists and points elsewhere, or is a regular file."
        read -rp "Overwrite? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
        ln -sfn "$TARGET" "$LOG_LINK"
        echo "Updated: $LOG_LINK -> $TARGET"
    fi
else
    ln -s "$TARGET" "$LOG_LINK"
    echo "Installed: $LOG_LINK -> $TARGET"
fi

for _download_link in "$DOWNLOAD_LINK" "$DOWNLOAD_COMPAT_LINK"; do
    if [[ -e "$_download_link" || -L "$_download_link" ]]; then
        if [[ -L "$_download_link" && "$(readlink -f "$_download_link")" == "$DOWNLOAD_TARGET" ]]; then
            echo "Already installed: $_download_link -> $DOWNLOAD_TARGET"
        else
            echo "WARNING: $_download_link exists and points elsewhere, or is a regular file."
            read -rp "Overwrite? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
            ln -sfn "$DOWNLOAD_TARGET" "$_download_link"
            echo "Updated: $_download_link -> $DOWNLOAD_TARGET"
        fi
    else
        ln -s "$DOWNLOAD_TARGET" "$_download_link"
        echo "Installed: $_download_link -> $DOWNLOAD_TARGET"
    fi
done
unset _download_link

if [[ -e "$BUILD_LINK" || -L "$BUILD_LINK" ]]; then
    if [[ -L "$BUILD_LINK" && "$(readlink -f "$BUILD_LINK")" == "$BUILD_TARGET" ]]; then
        echo "Already installed: $BUILD_LINK -> $BUILD_TARGET"
    else
        echo "WARNING: $BUILD_LINK exists and points elsewhere, or is a regular file."
        read -rp "Overwrite? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
        ln -sfn "$BUILD_TARGET" "$BUILD_LINK"
        echo "Updated: $BUILD_LINK -> $BUILD_TARGET"
    fi
else
    ln -s "$BUILD_TARGET" "$BUILD_LINK"
    echo "Installed: $BUILD_LINK -> $BUILD_TARGET"
fi

SHELL_NAME="$(detect_shell_name)"
PROFILE="$(shell_profile_path "$SHELL_NAME")"

if [[ "$(id -u)" -eq 0 ]]; then
    echo ""
    echo "Running as root; /usr/local/bin is normally already on PATH."
    echo "Skipping user shell profile update."
else
    install_shell_binding "$SHELL_NAME" "$PROFILE" "$LINK_DIR" "$LLAMACPP_MODELS_DIR" "$LLAMACPP_SLOT_SAVE_PATH"
fi

case ":$PATH:" in
    *":$LINK_DIR:"*) ;;
    *)
        echo ""
        echo "NOTE: $LINK_DIR is not on PATH in this shell yet."
        echo "Open a new $SHELL_NAME shell or source $PROFILE."
        ;;
esac

echo ""
echo "Run:  llama-launcher        # interactive"
echo "      llama-launcher stop   # graceful shutdown"
echo "      llama-launcher-log    # tail -f the repo-local llama.log"
echo "      llama-download-model  # download GGUF models"
