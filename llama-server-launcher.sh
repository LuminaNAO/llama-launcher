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
#   --build <type>   Build type (cpu, rocm, vulkan, system, etc.) — skips build
#                    selection; "system" uses the package-installed llama-server
#   --model <path>   Full path to .gguf model file — skips model selection
#   --tune <name>    Select a specific tune (e.g., "64gb", "128gb") — skips tune menu
#   --seed <N>       Override the random seed (default: 42)
#   --force          Skip all dependency and version checks (yq etc.)
#   --context <N>    Override context size
#   --parallel <N>   Override number of parallel slots
#   --port <N>       Public port (default: from tune or 40801)
#   --internal-port <N>  llama-server port behind the proxy (default: 40802)
#   --hdd-cache      Enable disk-backed slot cache for this launch; forces
#                    CACHE_RAM=0 and uses tune/default SLOT_SAVE_PATH
#   --no-hdd-cache   Disable disk-backed slot cache for this launch
#   --min-free-gb N  Minimum free disk space the proxy preserves on the
#                    slot-cache partition (default 100). Triggers LRU
#                    eviction of oldest slot files (across all sibling
#                    model dirs) before each save.
#   --max-total-slots-gb N
#                    Cap on total bytes across all model slot dirs at the
#                    slot-cache root (default 200). Same LRU eviction.
#   --proxy          Enable the proxy (default: off). Required for slot
#                    save/restore. Slot mgmt lines log to console.
#   --log            Tee server stdout/stderr to llama.log (in repo dir; default: off)
#   --deep-log       With --proxy: also persist request/response BODIES to
#                    llama-deep.log (in repo dir; default: off, since the file grows fast).
#                    Useful for diagnostics / debugging template issues.
#   --save           Save effective launch settings as a per-model config
#   --waterfall      Run ONLY the llama-waterfall failover proxy (no local
#                    inference). Routes across endpoints in waterfall.conf,
#                    fastest first. [agent] table on --port (default 40800),
#                    [subagent] table on 40810.
#                    See docs/WATERFALL.md; dashboard: llama-waterfall tui
#
# Subcommands:
#   stop             Gracefully stop a running llama-server (and deep proxy)
#
# Per-model tunes are stored in model-configs/<model-name>[.<tune>].yaml and
# automatically loaded when that model is selected. CLI flags override
# saved tunes. Use --save to persist tuned settings.

canonical_build_type() {
    case "$1" in
        rocm-mtp)   printf '%s\n' "rocm" ;;
        vulkan-mtp) printf '%s\n' "vulkan" ;;
        *)          printf '%s\n' "$1" ;;
    esac
}

# ── Subcommand: stop ────────────────────────────────────────────────────────
# Stop order matters when slot-save-path is in use: the proxy needs to POST
# its final save to a still-alive server. Stop proxy first, wait for it to
# exit cleanly (max 20s), THEN stop server.
if [[ "${1:-}" == "stop" ]]; then
    _stop_pat() {
        local pat="$1" timeout="$2"
        local pids
        pids="$(pgrep -f "$pat" || true)"
        if [[ -z "$pids" ]]; then return 0; fi
        echo "🛑 SIGINT -> $pat (pids: $pids)"
        # shellcheck disable=SC2086
        kill -INT $pids
        local i
        for ((i=0; i<timeout*2; i++)); do
            sleep 0.5
            pgrep -f "$pat" >/dev/null || { echo "  ✅ $pat stopped"; return 0; }
        done
        echo "  ⚠️  $pat still running after ${timeout}s — sending SIGTERM"
        pkill -TERM -f "$pat" || true
        for ((i=0; i<10; i++)); do
            sleep 0.5
            pgrep -f "$pat" >/dev/null || return 0
        done
        echo "  ⚠️  $pat still running — sending SIGKILL"
        pkill -KILL -f "$pat" || true
        return 0
    }
    # Proxy first (so it can save its slot), then server
    _stop_pat "llama-deep-proxy.mjs" 20
    _stop_pat "bin/llama-server" 10
    if pgrep -f "bin/llama-server|llama-deep-proxy.mjs" >/dev/null; then
        echo "❌ Some processes still running"; exit 1
    fi
    echo "✅ Stopped."
    exit 0
fi

# ── Subcommand / multi-name invocation: log (follow the log) ────────────────
# When the script (or a symlink to it) is invoked as "llama-launcher-log",
# or when run as "llama-launcher log", this tails the repo-local llama.log.
# This lets you install a dedicated `llama-launcher-log` command alongside
# `llama-launcher`.
progname="$(basename "$0" 2>/dev/null || echo "")"
if [[ "$progname" == *llama-launcher-log* ]] || [[ "${1:-}" == "log" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
    case "$SCRIPT_DIR" in
        /usr/bin|/usr/local/bin|/bin)
            LOG_FILE="${LLAMA_LAUNCHER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/llama-launcher}/llama.log"
            ;;
        *)
            LOG_FILE="$SCRIPT_DIR/llama.log"
            ;;
    esac
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "❌ No log file at $LOG_FILE"
        echo "   Run the launcher at least once with logging enabled"
        echo "   (preset 2/3/4 or --log / --deep-log)."
        exit 1
    fi
    if [[ "${1:-}" == "log" ]]; then
        shift
    fi
    exec tail -f "$LOG_FILE" "$@"
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
NO_DEEP_LOG=1
ARG_PORT=""
ARG_INTERNAL_PORT=""
PORT_FLAGS_TOUCHED=0
HDD_CACHE_MODE="default"
HDD_CACHE_TOUCHED=0
MIN_FREE_GB_TOUCHED=0
MAX_TOTAL_SLOTS_GB_TOUCHED=0
FORCE_SKIP_CHECKS=0  # --force: skip dependency/version checks (yq etc.)
LOG_FLAGS_TOUCHED=0  # tracks whether any of --proxy/--log/--deep-log was passed on CLI;
                     # used to decide whether to show the interactive logging-mode prompt
ORIGINAL_ARGC=$#
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed) SEED="$2"; shift 2 ;;
        --context) CONTEXT_OVERRIDE="$2"; shift 2 ;;
        --parallel) PARALLEL_OVERRIDE="$2"; shift 2 ;;
        --save) SAVE_CONFIG=1; shift ;;
        --force) FORCE_SKIP_CHECKS=1; shift ;;
        --build) ARG_BUILD_TYPE="$2"; shift 2 ;;
        --model) ARG_MODEL_PATH="$2"; shift 2 ;;
        --tune) ARG_TUNE="$2"; shift 2 ;;
        --port) ARG_PORT="$2"; PORT_FLAGS_TOUCHED=1; shift 2 ;;
        --internal-port) ARG_INTERNAL_PORT="$2"; PORT_FLAGS_TOUCHED=1; shift 2 ;;
        --hdd-cache) HDD_CACHE_MODE="on"; HDD_CACHE_TOUCHED=1; shift ;;
        --min-free-gb) MIN_FREE_GB="$2"; MIN_FREE_GB_TOUCHED=1; shift 2 ;;
        --max-total-slots-gb) MAX_TOTAL_SLOTS_GB="$2"; MAX_TOTAL_SLOTS_GB_TOUCHED=1; shift 2 ;;
        --no-hdd-cache) HDD_CACHE_MODE="off"; HDD_CACHE_TOUCHED=1; shift ;;
        --proxy) NO_PROXY=0; LOG_FLAGS_TOUCHED=1; shift ;;
        --log) NO_LOG=0; LOG_FLAGS_TOUCHED=1; shift ;;
        --deep-log) NO_DEEP_LOG=0; LOG_FLAGS_TOUCHED=1; shift ;;
        --waterfall) WATERFALL_MODE=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
case "$SCRIPT_DIR" in
    /usr/bin|/usr/local/bin|/bin)
        PACKAGED_INSTALL=1
        LLAMA_LAUNCHER_DIR="${LLAMA_LAUNCHER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/llama-launcher}"
        LLAMA_LAUNCHER_LIB_DIR="${LLAMA_LAUNCHER_LIB_DIR:-/usr/lib/llama-launcher}"
        BUNDLED_MODEL_CONFIG_DIR="${LLAMA_LAUNCHER_MODEL_CONFIG_DIR:-/usr/share/llama-launcher/model-configs}"
        ;;
    *)
        PACKAGED_INSTALL=0
        LLAMA_LAUNCHER_DIR="$SCRIPT_DIR"
        LLAMA_LAUNCHER_LIB_DIR="$SCRIPT_DIR"
        BUNDLED_MODEL_CONFIG_DIR="$SCRIPT_DIR/model-configs"
        ;;
esac
mkdir -p "$LLAMA_LAUNCHER_DIR"

# ── Waterfall-only mode: run the failover proxy, no local inference ─────────
# Routes traffic across the endpoints in waterfall.conf (fastest first,
# cascade on failure): [agent] table on ARG_PORT, [subagent] on 40810.
# See docs/WATERFALL.md. Drive it with: llama-waterfall tui
if [ "${WATERFALL_MODE:-0}" -eq 1 ]; then
    exec node "$LLAMA_LAUNCHER_LIB_DIR/llama-waterfall.mjs" serve "${ARG_PORT:-40800}" \
        --config "$LLAMA_LAUNCHER_DIR/waterfall.conf" \
        --socket "$LLAMA_LAUNCHER_DIR/waterfall.sock"
fi

CONFIG_FILE="$LLAMA_LAUNCHER_DIR/.llama-launcher-config"
LAUNCH_HISTORY="$LLAMA_LAUNCHER_DIR/.launch-history"
LLAMA_LOG_FILE="$LLAMA_LAUNCHER_DIR/llama.log"
DEEP_LOG="$LLAMA_LAUNCHER_DIR/llama-deep.log"
MODEL_CONFIG_DIR="$LLAMA_LAUNCHER_DIR/model-configs"
DEFAULT_MODELS_DIR="$HOME/llama-launcher/models"
DEFAULT_SLOTS_DIR="$HOME/llama-launcher/slots"
DOWNLOAD_MODEL_SCRIPT="${LLAMA_LAUNCHER_DOWNLOAD_MODEL:-}"
if [[ -z "$DOWNLOAD_MODEL_SCRIPT" || ! -x "$DOWNLOAD_MODEL_SCRIPT" ]]; then
    DOWNLOAD_MODEL_SCRIPT=""
    for _download_model_candidate in \
        "$LLAMA_LAUNCHER_LIB_DIR/download-model.sh" \
        "$LLAMA_LAUNCHER_DIR/download-model.sh" \
        "$SCRIPT_DIR/download-model.sh" \
        "$HOME/.local/bin/llama-download-model" \
        "$HOME/.local/bin/download-model.sh"; do
        if [[ -x "$_download_model_candidate" ]]; then
            DOWNLOAD_MODEL_SCRIPT="$_download_model_candidate"
            break
        fi
    done
    unset _download_model_candidate
fi
if [[ -z "$DOWNLOAD_MODEL_SCRIPT" ]]; then
    DOWNLOAD_MODEL_SCRIPT="$(command -v llama-download-model 2>/dev/null || true)"
fi
if [[ -z "$DOWNLOAD_MODEL_SCRIPT" ]]; then
    DOWNLOAD_MODEL_SCRIPT="$(command -v download-model.sh 2>/dev/null || true)"
fi
if [[ -z "$DOWNLOAD_MODEL_SCRIPT" ]]; then
    DOWNLOAD_MODEL_SCRIPT="$LLAMA_LAUNCHER_LIB_DIR/download-model.sh"
fi

AUTHOR_BEST_PICKS_FILE=""
for _author_pick_candidate in \
    "$BUNDLED_MODEL_CONFIG_DIR/author-best-picks.sh" \
    "$MODEL_CONFIG_DIR/author-best-picks.sh" \
    "$LLAMA_LAUNCHER_LIB_DIR/model-configs/author-best-picks.sh" \
    "$SCRIPT_DIR/model-configs/author-best-picks.sh"; do
    if [[ -f "$_author_pick_candidate" ]]; then
        AUTHOR_BEST_PICKS_FILE="$_author_pick_candidate"
        break
    fi
done
unset _author_pick_candidate

# yq (Python jq-wrapper, 3.x) is required to read tunes; fail loudly up
# front instead of erroring after a long build or model download.
if [ "$FORCE_SKIP_CHECKS" -eq 1 ]; then
    echo "⚠️  --force: skipping dependency and version checks"
elif ! command -v yq >/dev/null 2>&1; then
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  MISSING DEPENDENCY: yq — llama-launcher cannot read tunes     ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo "Install yq (the Python jq-wrapper YAML processor, 3.x) and re-run:"
    echo "    Arch/CachyOS:   sudo pacman -S yq        (NOT go-yq)"
    echo "    Debian/Ubuntu:  sudo apt install yq"
    echo "    pipx:           pipx install yq"
    exit 1
fi
# Judge yq by behavior, not version string: Arch's python-yq can report
# "yq 0.0.0" (build lost its SCM version metadata) while working fine.
if [ "$FORCE_SKIP_CHECKS" -eq 0 ]; then
    _yq_version="$(yq --version 2>/dev/null || true)"
    _yq_probe="$(printf 'settings:\n  PORT: "40801"\n' | yq -r '.settings.PORT // ""' 2>/dev/null || true)"
    if [[ "$_yq_version" == *mikefarah* || "$_yq_probe" != "40801" ]]; then
        echo "╔══════════════════════════════════════════════════════════════════╗"
        echo "║  ⚠️  INCOMPATIBLE yq — llama-launcher cannot read tunes            ║"
        echo "╚══════════════════════════════════════════════════════════════════╝"
        echo "Found: ${_yq_version:-unknown}"
        echo "Needed: the Python jq-wrapper yq (kislyuk/yq; go-yq is not compatible)."
        echo "    Arch/CachyOS:   sudo pacman -S yq        (NOT go-yq)"
        echo "    Debian/Ubuntu:  sudo apt install yq"
        echo "    pipx:           pipx install yq"
        exit 1
    fi
    unset _yq_version _yq_probe
fi

if [[ -f "$AUTHOR_BEST_PICKS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$AUTHOR_BEST_PICKS_FILE"
fi
AUTHOR_BEST_PICK_NAME="${AUTHOR_BEST_PICK_NAME:-Qwen3.6-27B-MTP 64GB coding}"
AUTHOR_BEST_PICK_REPO="${AUTHOR_BEST_PICK_REPO:-unsloth/Qwen3.6-27B-MTP-GGUF}"
AUTHOR_BEST_PICK_GGUF="${AUTHOR_BEST_PICK_GGUF:-Qwen3.6-27B-UD-Q4_K_XL.gguf}"
AUTHOR_BEST_PICK_TUNE="${AUTHOR_BEST_PICK_TUNE:-Qwen3.6-27B-MTP.64gb-q4-140k-coding-v1.yaml}"

# Load installer defaults early so non-interactive launches also see them.
# Explicit environment variables still win over the repo-local config.
_env_models_dir="${LLAMACPP_MODELS_DIR:-}"
_env_slot_save_path="${LLAMACPP_SLOT_SAVE_PATH:-}"
_cli_min_free_gb="${MIN_FREE_GB:-}"
_cli_max_total_slots_gb="${MAX_TOTAL_SLOTS_GB:-}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi
[ -n "$_env_models_dir" ] && LLAMACPP_MODELS_DIR="$_env_models_dir"
[ -n "$_env_slot_save_path" ] && LLAMACPP_SLOT_SAVE_PATH="$_env_slot_save_path"
[ "$MIN_FREE_GB_TOUCHED" -eq 1 ] && MIN_FREE_GB="$_cli_min_free_gb"
[ "$MAX_TOTAL_SLOTS_GB_TOUCHED" -eq 1 ] && MAX_TOTAL_SLOTS_GB="$_cli_max_total_slots_gb"
unset _env_models_dir _env_slot_save_path _cli_min_free_gb _cli_max_total_slots_gb

config_quote() {
    printf '%q' "$1"
}

config_set() {
    local key="$1"
    local value="$2"
    local line tmp

    line="$key=$(config_quote "$value")"
    tmp="$(mktemp)"
    if [ ! -f "$CONFIG_FILE" ]; then
        {
            echo "# llama-launcher settings"
            echo "# Edited by llama-launcher Settings."
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

config_default() {
    local key="$1"
    local value="$2"
    if [ -z "${!key:-}" ]; then
        printf -v "$key" '%s' "$value"
        config_set "$key" "$value"
    fi
}

prompt_config_path() {
    local key="$1"
    local label="$2"
    local default="$3"
    local value

    read -rp "$label [${!key:-$default}]: " value
    value="${value:-${!key:-$default}}"
    value="${value/#\~/$HOME}"
    value="${value%/}"
    printf -v "$key" '%s' "$value"
    config_set "$key" "$value"
    if [ ! -d "$value" ]; then
        read -rp "Create $value? [Y/n] " _create_dir
        _create_dir="${_create_dir:-y}"
        if [[ "$_create_dir" =~ ^[Yy]$ ]]; then
            mkdir -p "$value"
        fi
    fi
}

prompt_config_number() {
    local key="$1"
    local label="$2"
    local default="$3"
    local min="$4"
    local max="$5"
    local value

    read -rp "$label [${!key:-$default}]: " value
    value="${value:-${!key:-$default}}"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo "Invalid value: $value"
        return 1
    fi
    printf -v "$key" '%s' "$value"
    config_set "$key" "$value"
}

prompt_config_text() {
    local key="$1"
    local label="$2"
    local default="$3"
    local value

    read -rp "$label [${!key:-$default}]: " value
    value="${value:-${!key:-$default}}"
    printf -v "$key" '%s' "$value"
    config_set "$key" "$value"
}

settings_menu() {
    local default_models="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"
    local default_slots="${LLAMACPP_SLOT_SAVE_PATH:-$DEFAULT_SLOTS_DIR}"
    local choice build_default

    config_default LLAMACPP_MODELS_DIR "$default_models"
    config_default LLAMACPP_SLOT_SAVE_PATH "$default_slots"
    config_default MIN_FREE_GB "${MIN_FREE_GB:-100}"
    config_default MAX_TOTAL_SLOTS_GB "${MAX_TOTAL_SLOTS_GB:-200}"
    config_default PORT "${PORT:-40801}"
    config_default INTERNAL_PORT "${INTERNAL_PORT:-40802}"
    config_default HOST "${HOST:-0.0.0.0}"
    config_default API_KEY "${API_KEY:-ollama-local}"
    config_default LOG_COLORS "${LOG_COLORS:-1}"

    while true; do
        build_default="${LLAMACPP_BUILD_TYPE:-prompt each launch}"
        echo ""
        echo "Settings ($CONFIG_FILE)"
        echo "  1) Models directory          ${LLAMACPP_MODELS_DIR:-}"
        echo "  2) HDD cache slot save dir   ${LLAMACPP_SLOT_SAVE_PATH:-}"
        echo "  3) HDD cache min free GB     ${MIN_FREE_GB:-100}"
        echo "  4) HDD cache max total GB    ${MAX_TOTAL_SLOTS_GB:-200}"
        echo "  5) Public port               ${PORT:-40801}"
        echo "  6) Internal port             ${INTERNAL_PORT:-40802}"
        echo "  7) Bind host                 ${HOST:-0.0.0.0}"
        echo "  8) API key                   ${API_KEY:-ollama-local}"
        echo "  9) Log colors                ${LOG_COLORS:-1}"
        echo " 10) Default build type        $build_default"
        echo "  0) Back"
        echo ""
        read -rp "Select setting: " choice
        case "$choice" in
            1) prompt_config_path LLAMACPP_MODELS_DIR "Models directory" "$DEFAULT_MODELS_DIR" ;;
            2)
                default_slots="${LLAMACPP_SLOT_SAVE_PATH:-$DEFAULT_SLOTS_DIR}"
                prompt_config_path LLAMACPP_SLOT_SAVE_PATH "HDD cache slot save directory" "$default_slots"
                ;;
            3) prompt_config_number MIN_FREE_GB "HDD slot-cache minimum free disk GB" 100 0 100000 ;;
            4) prompt_config_number MAX_TOTAL_SLOTS_GB "HDD slot-cache maximum total GB" 200 0 100000 ;;
            5) prompt_config_number PORT "Public port" 40801 1 65535 ;;
            6) prompt_config_number INTERNAL_PORT "Internal port" 40802 1 65535 ;;
            7) prompt_config_text HOST "Bind host" "0.0.0.0" ;;
            8) prompt_config_text API_KEY "API key" "ollama-local" ;;
            9) prompt_config_number LOG_COLORS "Log colors (1 on, 0 off)" 1 0 1 ;;
            10)
                read -rp "Default build type (blank = prompt each launch) [${LLAMACPP_BUILD_TYPE:-}]: " choice
                if [ -z "$choice" ]; then
                    LLAMACPP_BUILD_TYPE=""
                    config_set LLAMACPP_BUILD_TYPE ""
                else
                    LLAMACPP_BUILD_TYPE="$(canonical_build_type "$choice")"
                    config_set LLAMACPP_BUILD_TYPE "$LLAMACPP_BUILD_TYPE"
                fi
                ;;
            0|"") break ;;
            *) echo "Invalid selection" ;;
        esac
    done
}

# ── Launch history: quick relaunch ──────────────────────────────────────────
# Show recent launches if no CLI args were given (fully interactive mode)
if [[ "$ORIGINAL_ARGC" -eq 0 && -z "$ARG_BUILD_TYPE" && -z "$ARG_MODEL_PATH" && -z "$ARG_TUNE" && -f "$LAUNCH_HISTORY" ]]; then
    # Read up to 5 most recent unique launches (newest first)
    recent=()
    while IFS=$'\t' read -r ts build model tune extras; do
        [[ "$tune" == *.conf ]] && continue
        build="$(canonical_build_type "$build")"
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
        while true; do
            echo "🕐 Recent launches:"
            for i in "${!recent[@]}"; do
                tune_display="${recent_tune[$i]}"
                [[ -z "$tune_display" ]] && tune_display="(no tune)"
                extras_display="${recent_extras[$i]}"
                [[ -n "$extras_display" ]] && extras_display="  [$extras_display]"
                printf "  %d) %-12s  %-40s  %s%s\n" $((i+1)) "${recent_build[$i]}" "$(basename "${recent_model[$i]}")" "$tune_display" "$extras_display"
            done
            echo "  0) New launch"
            echo "  s) Settings"
            echo ""
            read -rp "Relaunch? [0=new, s=settings, default=1]: " hist_sel
            hist_sel="${hist_sel:-1}"
            if [[ "$hist_sel" =~ ^[Ss]$ ]]; then
                settings_menu
                echo ""
                continue
            fi
            if [[ "$hist_sel" =~ ^[1-9]$ ]] && [[ "$hist_sel" -le ${#recent[@]} ]]; then
                idx=$((hist_sel - 1))
                ARG_BUILD_TYPE="${recent_build[$idx]}"
                ARG_MODEL_PATH="${recent_model[$idx]}"
                [[ -n "${recent_tune[$idx]}" ]] && ARG_TUNE="${recent_tune[$idx]}"
                # Apply saved flag state (only explicit opt-ins)
                extras="${recent_extras[$idx]}"
                if [[ -n "$extras" ]]; then LOG_FLAGS_TOUCHED=1; fi
                [[ " $extras " == *" --log "* ]] && NO_LOG=0
                [[ " $extras " == *" --proxy "* ]] && NO_PROXY=0
                [[ " $extras " == *" --deep-log "* ]] && NO_DEEP_LOG=0
                [[ " $extras " == *" --hdd-cache "* ]] && { HDD_CACHE_MODE="on"; HDD_CACHE_TOUCHED=1; }
                [[ " $extras " == *" --no-hdd-cache "* ]] && { HDD_CACHE_MODE="off"; HDD_CACHE_TOUCHED=1; }
                echo ""
                echo "🔄 Relaunching: $ARG_BUILD_TYPE / $(basename "$ARG_MODEL_PATH") / ${ARG_TUNE:-(no tune)}${extras:+  [$extras]}"
                echo ""
            fi
            break
        done
    fi
fi

# ── Build type selection ─────────────────────────────────────────────────────

if [ -z "$ARG_BUILD_TYPE" ] && [ -n "${LLAMACPP_BUILD_TYPE:-}" ]; then
    ARG_BUILD_TYPE="$LLAMACPP_BUILD_TYPE"
fi

if [ -n "$ARG_BUILD_TYPE" ]; then
    # Build type passed via CLI
    BUILD_TYPE="$(canonical_build_type "$ARG_BUILD_TYPE")"
    if [ "$BUILD_TYPE" != "$ARG_BUILD_TYPE" ]; then
        echo "🔧 Build alias: $ARG_BUILD_TYPE -> $BUILD_TYPE"
    fi
else
    # Interactive: list available builds and let user pick
    available_builds=()
    if [ -d "$LLAMA_LAUNCHER_DIR/builds" ]; then
        for dir in "$LLAMA_LAUNCHER_DIR"/builds/*/; do
            if [ -f "$dir/bin/llama-server" ]; then
                build_name="$(basename "$dir")"
                case "$build_name" in
                    rocm-mtp|vulkan-mtp)
                        base_name="${build_name%-mtp}"
                        [ -f "$LLAMA_LAUNCHER_DIR/builds/$base_name/bin/llama-server" ] && continue
                        ;;
                esac
                available_builds+=("$build_name")
            fi
        done
    fi

    # Package-installed llama-hdd (e.g. paru -S llama-hdd) works without any
    # local build: expose it as build type "system".
    if [ -x /usr/bin/llama-server ]; then
        available_builds+=("system")
    fi

    if [ ${#available_builds[@]} -eq 0 ]; then
        echo "❌ No builds found in $LLAMA_LAUNCHER_DIR/builds/ and no system llama-server."
        echo "   Either install the llama-hdd package, or build locally:"
        echo "   bash build-llamacpp.sh [cpu|rocm|vulkan|cuda]"
        exit 1
    elif [ ${#available_builds[@]} -eq 1 ]; then
        BUILD_TYPE="${available_builds[0]}"
        echo "🔧 Using only available build: $BUILD_TYPE"
    else
        while true; do
            echo "Available builds:"
            for i in "${!available_builds[@]}"; do
                printf "  %d) %s\n" $((i+1)) "${available_builds[$i]}"
            done
            echo "  s) Settings"
            echo ""
            read -rp "Select build [1-${#available_builds[@]}, s=settings]: " build_sel
            if [[ "$build_sel" =~ ^[Ss]$ ]]; then
                settings_menu
                echo ""
                continue
            fi
            if [[ "$build_sel" =~ ^[0-9]+$ ]] && [ "$build_sel" -ge 1 ] && [ "$build_sel" -le ${#available_builds[@]} ]; then
                BUILD_TYPE="${available_builds[$((build_sel-1))]}"
                break
            else
                echo "❌ Invalid selection"; exit 1
            fi
        done
    fi
fi

if [ "$BUILD_TYPE" = "system" ]; then
    # Package-installed llama-hdd: system binary, system libs, no BUILD_DIR.
    BUILD_DIR=""
    LLAMACPP_SERVER_PATH="/usr/bin/llama-server"
    if [ ! -x "$LLAMACPP_SERVER_PATH" ]; then
        echo "❌ No system llama-server at $LLAMACPP_SERVER_PATH"
        echo "   Install the llama-hdd package, or run: bash build-llamacpp.sh <backend>"
        exit 1
    fi
else
    BUILD_DIR="$LLAMA_LAUNCHER_DIR/builds/$BUILD_TYPE"
    LLAMACPP_SERVER_PATH="$BUILD_DIR/bin/llama-server"

    if [ ! -f "$LLAMACPP_SERVER_PATH" ]; then
        echo "❌ llama-server not found at $LLAMACPP_SERVER_PATH"
        echo "   Run: bash build-llamacpp.sh $BUILD_TYPE"
        exit 1
    fi
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
    export LLAMACPP_MODELS_DIR
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

    download_model_then_rescan() {
        local repo="$1"
        shift

        if [[ ! -x "$DOWNLOAD_MODEL_SCRIPT" ]]; then
            echo "❌ download-model.sh not found or not executable: $DOWNLOAD_MODEL_SCRIPT"
            return 1
        fi

        mkdir -p "$MODELS_DIR"
        config_set LLAMACPP_MODELS_DIR "$MODELS_DIR"
        export LLAMACPP_MODELS_DIR="$MODELS_DIR"

        "$DOWNLOAD_MODEL_SCRIPT" "$@" "$repo" || return 1
        scan_model_folders "$MODELS_DIR"
    }

    offer_model_download_or_path() {
        local heading="$1"
        local new_path hf_input

        while [ ${#model_folders[@]} -eq 0 ]; do
            echo "$heading"
            echo ""
            echo "Models directory: $MODELS_DIR"
            echo ""
            if [[ -n "${AUTHOR_BEST_PICK_REPO:-}" && -n "${AUTHOR_BEST_PICK_GGUF:-}" ]]; then
                echo "  1) Download author best pick: ${AUTHOR_BEST_PICK_NAME:-$AUTHOR_BEST_PICK_REPO} ($AUTHOR_BEST_PICK_GGUF)"
            else
                echo "  1) Download author best pick (unavailable)"
            fi
            echo "  2) Paste Hugging Face model link or owner/repo"
            echo "  3) Choose a different models directory"
            echo "  0) Quit"
            echo ""
            read -rp "Select option: " empty_model_choice

            case "$empty_model_choice" in
                1)
                    if [[ -z "${AUTHOR_BEST_PICK_REPO:-}" || -z "${AUTHOR_BEST_PICK_GGUF:-}" ]]; then
                        echo "❌ Author best-pick metadata is not available."
                        echo ""
                        continue
                    fi
                    download_model_then_rescan "$AUTHOR_BEST_PICK_REPO" --filename "$AUTHOR_BEST_PICK_GGUF" || true
                    ;;
                2)
                    read -rp "Hugging Face URL or owner/repo: " hf_input
                    hf_input="${hf_input//[$'\t\r\n']}"
                    if [[ -z "$hf_input" ]]; then
                        echo "❌ No Hugging Face repo entered."
                        echo ""
                        continue
                    fi
                    download_model_then_rescan "$hf_input" || true
                    ;;
                3)
                    read -rp "Enter path to models directory: " new_path
                    new_path="${new_path/#\~/$HOME}"
                    if [[ -z "$new_path" ]]; then
                        echo "❌ No path entered."
                        echo ""
                        continue
                    fi
                    MODELS_DIR="${new_path%/}"
                    mkdir -p "$MODELS_DIR"
                    config_set LLAMACPP_MODELS_DIR "$MODELS_DIR"
                    LLAMACPP_MODELS_DIR="$MODELS_DIR"
                    echo "✅ Path saved to $CONFIG_FILE for next launch"
                    echo ""
                    scan_model_folders "$MODELS_DIR"
                    ;;
                0|"")
                    echo "No model selected."
                    exit 1
                    ;;
                *)
                    echo "❌ Invalid option: $empty_model_choice"
                    echo ""
                    ;;
            esac

            if [ ${#model_folders[@]} -eq 0 ]; then
                echo "❌ No model folders found in $MODELS_DIR"
                echo ""
            fi
        done
    }

    scan_model_folders "$MODELS_DIR"

    # If no model folders found, check if dir exists
    if [ ${#model_folders[@]} -eq 0 ]; then
        if [ ! -d "$MODELS_DIR" ]; then
            echo "📂 No models directory found at $DEFAULT_MODELS_DIR"
            echo ""
            read -rp "Create it? (y/N) " create_choice
            if [[ "$create_choice" == [yY]* ]]; then
                mkdir -p "$MODELS_DIR"
                echo "✅ Created $MODELS_DIR"
                echo ""
                offer_model_download_or_path "No models are installed yet."
            else
                echo ""
                read -rp "Enter path to models directory: " new_path
                new_path="${new_path/#\~/$HOME}"
                config_set LLAMACPP_MODELS_DIR "$new_path"
                LLAMACPP_MODELS_DIR="$new_path"
                echo "✅ Path saved to $CONFIG_FILE for next launch"
                echo ""
                MODELS_DIR="$new_path"
                scan_model_folders "$MODELS_DIR"
                if [ ${#model_folders[@]} -eq 0 ]; then
                    offer_model_download_or_path "No models are installed yet."
                fi
            fi
        else
            echo "❌ No model folders found at $MODELS_DIR (directory is empty)"
            echo ""
            offer_model_download_or_path "No models are installed yet."
        fi
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

# ── YAML tune helpers ────────────────────────────────────────────────────────
selected_folder_name="$(basename "$MODEL_FOLDER")"

TUNE_KEYS=(
    CONTEXT PARALLEL
    CACHE_RAM CACHE_TYPE_K CACHE_TYPE_V KV_UNIFIED
    SLOT_SAVE_PATH MIN_FREE_GB MAX_TOTAL_SLOTS_GB
    CHECKPOINT_MIN_STEP CHECKPOINT_MAX SLOT_SAVE_MAX_CHECKPOINTS HDD_CACHE
    NGL FLASH_ATTN
    TEMP TOP_P TOP_K
    HOST PORT API_KEY TIMEOUT THREADS
    NO_MMAP DIO
    JINJA LOG_COLORS
    REASONING REASONING_BUDGET
    REPEAT_PENALTY REPEAT_LAST_N PRESENCE_PENALTY FREQUENCY_PENALTY
    DRY_MULTIPLIER DRY_BASE DRY_ALLOWED_LENGTH DRY_PENALTY_LAST_N
    RECOMMENDED_BACKEND
    EXTRA_ARGS
)

require_yq() {
    local version probe
    [ "${FORCE_SKIP_CHECKS:-0}" -eq 1 ] && return 0
    if ! command -v yq >/dev/null 2>&1; then
        echo "❌ YAML tunes require yq (the Python jq-wrapper YAML processor). Install yq and re-run."
        exit 1
    fi
    version="$(yq --version 2>/dev/null || true)"
    probe="$(printf 'a: "1"\n' | yq -r '.a // ""' 2>/dev/null || true)"
    if [[ "$version" == *mikefarah* || "$probe" != "1" ]]; then
        echo "❌ YAML tunes require the Python/jq-wrapper yq (kislyuk/yq); found: ${version:-unknown}"
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
        echo "❌ Invalid tune file: $(basename "$file") (kind must be llama-launcher-tune)"
        exit 1
    fi
    # backend affinity and hdd-cache preference are strictly per-tune: most
    # tunes are hardware-agnostic and must not inherit a RECOMMENDED_BACKEND
    # or HDD_CACHE loaded earlier in the session (load_tune only overwrites
    # declared keys, and the tune writer persists any non-empty variable)
    RECOMMENDED_BACKEND=""
    HDD_CACHE=""
    for key in "${TUNE_KEYS[@]}"; do
        value="$(tune_setting "$file" "$key")"
        if [ -n "$value" ]; then
            printf -v "$key" '%s' "$value"
        fi
    done
}

tune_slug() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

yaml_scalar() {
    jq -Rn --arg value "$1" '$value'
}

write_tune_yaml() {
    local file="$1"
    local name="$2"
    local generated="$3"
    local old_notes
    if [ -f "$file" ]; then
        old_notes="$(tune_yq "$file" '.metadata.notes // ""')"
    fi
    mkdir -p "$MODEL_CONFIG_DIR"
    {
        printf '%s\n' "kind: llama-launcher-tune"
        printf '%s\n' "version: 1"
        printf 'name: %s\n' "$(yaml_scalar "$name")"
        printf 'model: %s\n' "$(yaml_scalar "$selected_folder_name")"
        printf '%s\n' "metadata:"
        printf '  generated: %s\n' "$(yaml_scalar "$generated")"
        printf '%s\n' "  shareable: true"
        if [ -n "${old_notes:-}" ]; then
            printf '%s\n' "  notes: |-"
            while IFS= read -r line; do
                printf '    %s\n' "$line"
            done <<< "$old_notes"
        fi
        printf '%s\n' "settings:"
        local key value
        for key in "${TUNE_KEYS[@]}"; do
            value="${!key-}"
            [ -z "$value" ] && continue
            printf '  %s: %s\n' "$key" "$(yaml_scalar "$value")"
        done
    } > "$file"
}

seed_system_profile_values() {
    local ram_mb ram_gb
    ram_mb="$(free -m | awk '/^Mem:/{print $2}')"
    ram_gb=$((ram_mb / 1024))
    if [ "$ram_gb" -ge 112 ]; then
        CONTEXT=488576; PARALLEL=2; CACHE_RAM=102400; CACHE_TYPE_K=q8_0; CACHE_TYPE_V=q8_0
        CHECKPOINT_MIN_STEP=8192; CHECKPOINT_MAX=64
    elif [ "$ram_gb" -ge 48 ]; then
        CONTEXT=131072; PARALLEL=1; CACHE_RAM=40960; CACHE_TYPE_K=q8_0; CACHE_TYPE_V=q8_0
        CHECKPOINT_MIN_STEP=4096; CHECKPOINT_MAX=32
    else
        CONTEXT=61072; PARALLEL=1; CACHE_RAM=16384; CACHE_TYPE_K=q8_0; CACHE_TYPE_V=q8_0
        CHECKPOINT_MIN_STEP=4096; CHECKPOINT_MAX=16
    fi
    KV_UNIFIED=1; NGL=99; FLASH_ATTN=1; TEMP=0.3; TOP_P=0.95; TOP_K=20
    THREADS="$(nproc)"; NO_MMAP=1; DIO=1; TIMEOUT=3600; HOST=0.0.0.0
    PORT=40801; API_KEY=ollama-local; JINJA=1; LOG_COLORS=1
    REASONING=auto; REASONING_BUDGET=-1
    REPEAT_PENALTY=1.0; REPEAT_LAST_N=64; PRESENCE_PENALTY=0.0; FREQUENCY_PENALTY=0.0
    DRY_MULTIPLIER=0.0; DRY_BASE=1.75; DRY_ALLOWED_LENGTH=2; DRY_PENALTY_LAST_N=-1
}

prompt_tune_value() {
    local key="$1"
    local current="${!key-}"
    local value
    read -rp "$key [$current]: " value
    value="${value:-$current}"
    case "$key" in
        CONTEXT|PARALLEL|CACHE_RAM|KV_UNIFIED|MIN_FREE_GB|MAX_TOTAL_SLOTS_GB|CHECKPOINT_MIN_STEP|CHECKPOINT_MAX|SLOT_SAVE_MAX_CHECKPOINTS|NGL|FLASH_ATTN|TOP_K|PORT|TIMEOUT|THREADS|NO_MMAP|DIO|JINJA|LOG_COLORS|REPEAT_LAST_N|DRY_ALLOWED_LENGTH)
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                echo "❌ $key must be a non-negative integer"
                return 1
            fi
            ;;
        REASONING_BUDGET|DRY_PENALTY_LAST_N)
            if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
                echo "❌ $key must be an integer"
                return 1
            fi
            ;;
        TEMP|TOP_P|REPEAT_PENALTY|PRESENCE_PENALTY|FREQUENCY_PENALTY|DRY_MULTIPLIER|DRY_BASE)
            if ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                echo "❌ $key must be a number"
                return 1
            fi
            ;;
    esac
    printf -v "$key" '%s' "$value"
}

edit_tune_values() {
    local choice key
    while true; do
        echo ""
        echo "🛠️  Tune editor:"
        for i in "${!TUNE_KEYS[@]}"; do
            key="${TUNE_KEYS[$i]}"
            printf "  %2d) %-24s %s\n" $((i+1)) "$key" "${!key-}"
        done
        echo "   s) Save"
        echo "   q) Cancel"
        read -rp "Edit setting: " choice
        case "$choice" in
            s|S) return 0 ;;
            q|Q) return 1 ;;
        esac
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#TUNE_KEYS[@]} ]; then
            echo "❌ Invalid selection"
            continue
        fi
        prompt_tune_value "${TUNE_KEYS[$((choice-1))]}"
    done
}

create_tune_interactive() {
    local mode base_sel tune_name slug file
    echo ""
    echo "Create tune:"
    echo "  1) Fresh from system profile"
    echo "  2) Based on existing tune"
    read -rp "Choice [1-2, default=1]: " mode
    mode="${mode:-1}"
    if [ "$mode" = "2" ] && [ ${#tune_configs[@]} -gt 0 ]; then
        for i in "${!tune_names[@]}"; do
            printf "  %d) %s\n" $((i+1)) "${tune_names[$i]}"
        done
        read -rp "Base tune [1-${#tune_configs[@]}]: " base_sel
        if ! [[ "$base_sel" =~ ^[0-9]+$ ]] || [ "$base_sel" -lt 1 ] || [ "$base_sel" -gt ${#tune_configs[@]} ]; then
            echo "❌ Invalid selection"
            return 1
        fi
        load_tune "${tune_configs[$((base_sel-1))]}"
    else
        seed_system_profile_values
    fi
    read -rp "Tune name: " tune_name
    if [ -z "$tune_name" ]; then
        echo "❌ Tune name required"
        return 1
    fi
    slug="$(tune_slug "$tune_name")"
    file="$MODEL_CONFIG_DIR/${selected_folder_name}.${slug}.yaml"
    if [ -e "$file" ]; then
        echo "❌ Tune already exists: $(basename "$file")"
        return 1
    fi
    edit_tune_values || return 1
    write_tune_yaml "$file" "$tune_name" "Created interactively: $(date -Iseconds)"
    echo "💾 Created tune: $file"
    MODEL_CONFIG_FILE="$file"
    HAS_MODEL_CONFIG=1
}

edit_existing_tune_interactive() {
    local edit_sel file name
    if [ ${#tune_configs[@]} -eq 0 ]; then
        echo "❌ No tunes to edit"
        return 1
    fi
    for i in "${!tune_names[@]}"; do
        printf "  %d) %s\n" $((i+1)) "${tune_names[$i]}"
    done
    read -rp "Edit tune [1-${#tune_configs[@]}]: " edit_sel
    if ! [[ "$edit_sel" =~ ^[0-9]+$ ]] || [ "$edit_sel" -lt 1 ] || [ "$edit_sel" -gt ${#tune_configs[@]} ]; then
        echo "❌ Invalid selection"
        return 1
    fi
    file="${tune_configs[$((edit_sel-1))]}"
    name="${tune_names[$((edit_sel-1))]}"
    load_tune "$file"
    edit_tune_values || return 1
    write_tune_yaml "$file" "$name" "Edited interactively: $(date -Iseconds)"
    echo "💾 Updated tune: $file"
    MODEL_CONFIG_FILE="$file"
    HAS_MODEL_CONFIG=1
}

model_config_search_dirs() {
    local seen=":"
    local dir
    local cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"
    if [ -n "${LLAMA_LAUNCHER_REPO_DIR:-}" ]; then
        dir="$LLAMA_LAUNCHER_REPO_DIR/model-configs"
        if [[ -d "$dir" && ":$seen:" != *":$dir:"* ]]; then
            seen="${seen}${dir}:"
            printf '%s\0' "$dir"
        fi
    fi
    for dir in \
        "$cache_root"/yay/llama-launcher*/model-configs \
        "$cache_root"/yay/llama-launcher*/src/model-configs \
        "$cache_root"/yay/llama-launcher*/src/*/model-configs \
        "$cache_root"/paru/clone/llama-launcher*/model-configs \
        "$cache_root"/paru/clone/llama-launcher*/src/model-configs \
        "$cache_root"/paru/clone/llama-launcher*/src/*/model-configs \
        "$BUNDLED_MODEL_CONFIG_DIR" \
        "$MODEL_CONFIG_DIR" \
        "$LLAMA_LAUNCHER_LIB_DIR/model-configs" \
        "$SCRIPT_DIR/model-configs"; do
        [[ -d "$dir" ]] || continue
        [[ ":$seen:" == *":$dir:"* ]] && continue
        seen="${seen}${dir}:"
        printf '%s\0' "$dir"
    done
}

tune_match_kind() {
    local conf="$1"
    local stem tune_model
    stem="$(basename "$conf")"
    stem="${stem%.yaml}"
    stem="${stem%.yml}"

    if [[ "$stem" == "$selected_folder_name" || "$stem" == "$selected_folder_name".* ]]; then
        printf '%s\n' specific
        return 0
    fi

    tune_model="$(tune_yq "$conf" '.model // ""' 2>/dev/null || true)"
    if [[ "$tune_model" == "$selected_folder_name" ]]; then
        printf '%s\n' specific
        return 0
    fi

    if [[ -n "$tune_model" && "$selected_folder_name" == "$tune_model"* ]]; then
        printf '%s\n' family
        return 0
    fi

    if [[ "$stem" != *.* && "$selected_folder_name" == "$stem"* ]]; then
        printf '%s\n' family
        return 0
    fi

    return 1
}

collect_tunes() {
    tune_configs=()
    tune_names=()
    _specific_configs=()
    _specific_names=()
    _family_configs=()
    _family_names=()
    local conf match_kind tune_label dir
    shopt -s nullglob
    while IFS= read -r -d '' dir; do
        for conf in "$dir"/*.yaml "$dir"/*.yml; do
            [ -f "$conf" ] || continue
            match_kind="$(tune_match_kind "$conf" || true)"
            [ -n "$match_kind" ] || continue
            tune_label="$(tune_label "$conf")"
            if [ "$match_kind" = "specific" ]; then
                _specific_configs+=("$conf")
                _specific_names+=("$tune_label")
            elif [ "$match_kind" = "family" ]; then
                _family_configs+=("$conf")
                _family_names+=("$tune_label")
            fi
        done
    done < <(model_config_search_dirs)
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
}

# ── Load per-model tune (with tune selection) ───────────────────────────────
require_yq
tune_configs=()
tune_names=()
tune_suggested=-1

TOTAL_RAM_MB_DETECT=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB_DETECT=$((TOTAL_RAM_MB_DETECT / 1024))

collect_tunes

HAS_MODEL_CONFIG=0
if [ ${#tune_configs[@]} -eq 0 ]; then
    if [ -n "$ARG_TUNE" ]; then
        echo "❌ No YAML tunes found for '$ARG_TUNE'. Expected: model-configs/${selected_folder_name}[.<tune>].yaml"
        exit 1
    fi
    echo "📋 Tune: none (using system profile)"
    echo "   Expected: model-configs/${selected_folder_name}.yaml"
    echo "   Save one with: $(basename "$0") --save, or create one interactively."
    if [ "$ORIGINAL_ARGC" -eq 0 ]; then
        read -rp "Create a tune now? [y/N] " _create_tune
        if [[ "$_create_tune" =~ ^[Yy]$ ]]; then
            create_tune_interactive
        fi
    fi
elif [ -n "$ARG_TUNE" ]; then
    # --tune passed on CLI: find matching tune
    found=0
    for i in "${!tune_names[@]}"; do
        if [[ "${tune_names[$i]}" == *"$ARG_TUNE"* ]] || [[ "$(basename "${tune_configs[$i]}")" == *"$ARG_TUNE"* ]]; then
            MODEL_CONFIG_FILE="${tune_configs[$i]}"
            echo "📋 Tune: ${tune_names[$i]} ($(basename "$MODEL_CONFIG_FILE"))"
            load_tune "$MODEL_CONFIG_FILE"
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
        if [ "$show_all_tunes" -eq 0 ] && [ -n "${AUTHOR_BEST_PICK_TUNE:-}" ]; then
            for i in "${!tune_configs[@]}"; do
                if [ "$(basename "${tune_configs[$i]}")" = "$AUTHOR_BEST_PICK_TUNE" ]; then
                    tune_suggested=$i
                    break
                fi
            done
        fi
        if [ "$tune_suggested" -lt 0 ]; then
            for i in "${!tune_names[@]}"; do
                name="${tune_names[$i]}"
                if [ "$TOTAL_RAM_GB_DETECT" -ge 112 ] && [[ "$name" == *128gb* ]]; then
                    tune_suggested=$i
                elif [ "$TOTAL_RAM_GB_DETECT" -ge 48 ] && [ "$TOTAL_RAM_GB_DETECT" -lt 112 ] && [[ "$name" == *64gb* ]]; then
                    tune_suggested=$i
                fi
            done
        fi
        suggested_reason="suggested for ${TOTAL_RAM_GB_DETECT}GB system"
        if [ "$tune_suggested" -ge 0 ] && [ -n "${AUTHOR_BEST_PICK_TUNE:-}" ]; then
            if [ "$(basename "${tune_configs[$tune_suggested]}")" = "$AUTHOR_BEST_PICK_TUNE" ]; then
                suggested_reason="author best pick"
            fi
        fi

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
                local_suggested=" ← $suggested_reason"
            fi
            # Show key params from config
            tune_ctx=$(tune_setting "${tune_configs[$i]}" CONTEXT)
            tune_par=$(tune_setting "${tune_configs[$i]}" PARALLEL)
            tune_cp=$(tune_setting "${tune_configs[$i]}" CHECKPOINT_MAX)
            printf "  %d) %-30s [ctx=%s, parallel=%s, checkpoints=%s]%s\n" \
                $((i+1)) "${tune_names[$i]}" "${tune_ctx:-?}" "${tune_par:-?}" "${tune_cp:-?}" "$local_suggested"
        done
        if [ "$show_all_tunes" -eq 0 ]; then
            echo "  a) Browse all tunes"
        fi
        echo "  n) New tune"
        echo "  e) Edit tune"
        echo "  0) None (use system profile)"
        echo ""

        default_sel=$((tune_suggested + 1))
        if [ "$default_sel" -le 0 ]; then default_sel=1; fi
        read -rp "Select tune [1-${#tune_configs[@]}, a=all, n=new, e=edit, 0=none, default=$default_sel]: " tune_sel

        # "Browse all" — reload with every config in the directory
        if [[ "$tune_sel" == "a" || "$tune_sel" == "A" ]] && [ "$show_all_tunes" -eq 0 ]; then
            tune_configs=()
            tune_names=()
            shopt -s nullglob
            while IFS= read -r -d '' dir; do
                for conf in "$dir"/*.yaml "$dir"/*.yml; do
                    [ -f "$conf" ] || continue
                    tune_label="$(tune_label "$conf")"
                    tune_configs+=("$conf")
                    tune_names+=("$tune_label")
                done
            done < <(model_config_search_dirs)
            shopt -u nullglob
            show_all_tunes=1
            continue
        fi

        if [[ "$tune_sel" == "n" || "$tune_sel" == "N" ]]; then
            create_tune_interactive && break
            collect_tunes
            continue
        fi

        if [[ "$tune_sel" == "e" || "$tune_sel" == "E" ]]; then
            edit_existing_tune_interactive && break
            collect_tunes
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
        load_tune "$MODEL_CONFIG_FILE"
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
# Match on the backend prefix so tagged builds (e.g. "vulkan-rocmfpx-hdd")
# inherit the same env setup as their backend.
case "${BUILD_TYPE%%-*}" in
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
    system)
        # Package install: libs resolve via ldconfig.
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
    CHECKPOINT_MIN_STEP="${CHECKPOINT_MIN_STEP:-2048}"
    CHECKPOINT_MAX="${CHECKPOINT_MAX:-32}"
    # 0 = write all checkpoints (vanilla llama.cpp compatible); >0 needs llama-hdd
    SLOT_SAVE_MAX_CHECKPOINTS="${SLOT_SAVE_MAX_CHECKPOINTS:-0}"
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
    SLOT_SAVE_PATH="${SLOT_SAVE_PATH:-}"

    echo "📋 Profile: per-model (${CONTEXT} ctx, ${CACHE_TYPE_K} KV, ${CACHE_RAM} MiB cache ceiling, ${PARALLEL} slots)"
    # Note: actual slot dir is namespaced per-quant inside the proxy block.
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
    # 488576 / 64 ≈ 7634 → round to 8192 (ample slot for huge ctx, LRU absorbs early-ctx eviction)
    CHECKPOINT_MIN_STEP=8192
    CHECKPOINT_MAX=64
    echo "📋 Profile: 128 GB (488k context, q8_0 KV, 100 GiB cache ceiling, 2 slots)"
elif [ "$TOTAL_RAM_GB" -ge 48 ]; then
    CONTEXT=131072
    PARALLEL=1
    CACHE_RAM=40960    # 40 GiB ceiling — swap still absorbs overflow
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    # 131072 / 32 = 4096
    CHECKPOINT_MIN_STEP=4096
    CHECKPOINT_MAX=32
    echo "📋 Profile: 64 GB (131k context, q8_0 KV, 40 GiB cache ceiling, 1 slot)"
else
    CONTEXT=61072
    PARALLEL=1
    CACHE_RAM=16384    # 16 GiB ceiling
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    # 61072 / 16 ≈ 3817 → round to 4096
    CHECKPOINT_MIN_STEP=4096
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
LOG_COLORS="${LOG_COLORS:-1}"

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

# ── Auto-generate tune if none existed ──────────────────────────────────────
# First-launch tunes are YAML and are loaded through the allowlist parser above,
# not sourced as shell. This keeps future shared tune files data-only.
if [ "$HAS_MODEL_CONFIG" -eq 0 ] && [ "$SAVE_CONFIG" -eq 0 ]; then
    MODEL_CONFIG_FILE="$MODEL_CONFIG_DIR/${selected_folder_name}.yaml"
    write_tune_yaml "$MODEL_CONFIG_FILE" "$selected_folder_name" "Auto-generated from ${TOTAL_RAM_GB} GB system profile: $(date -Iseconds)"
    echo "💾 Auto-saved tune: $MODEL_CONFIG_FILE"
fi

# ── Save per-model tune if requested ─────────────────────────────────────────
if [ "$SAVE_CONFIG" -eq 1 ]; then
    if [ -z "${MODEL_CONFIG_FILE:-}" ]; then
        MODEL_CONFIG_FILE="$MODEL_CONFIG_DIR/${selected_folder_name}.yaml"
    fi
    write_tune_yaml "$MODEL_CONFIG_FILE" "$(tune_label "$MODEL_CONFIG_FILE" 2>/dev/null || printf '%s' "$selected_folder_name")" "Saved: $(date -Iseconds)"
    echo "💾 Saved model tune: $MODEL_CONFIG_FILE"
fi

# ── Deep logging proxy ──────────────────────────────────────────────────────
# The proxy listens on PORT (public) and forwards to INTERNAL_PORT (llama-server).
# Both request and response bodies are tee-d to llama-deep.log (in the repo dir).
INTERNAL_PORT="${INTERNAL_PORT:-40802}"
PROXY_SCRIPT="$LLAMA_LAUNCHER_LIB_DIR/llama-deep-proxy.mjs"

# ── Port selection (CLI flags > interactive prompt > tune/default) ──────────
if [ -n "$ARG_PORT" ]; then
    PORT="$ARG_PORT"
fi
if [ -n "$ARG_INTERNAL_PORT" ]; then
    INTERNAL_PORT="$ARG_INTERNAL_PORT"
fi
if [ "$PORT_FLAGS_TOUCHED" -eq 0 ]; then
    echo ""
    echo "🔌 Ports (or pass --port / --internal-port on CLI to skip):"
    read -rp "   Public port [default=$PORT]: " _port_in
    if [ -n "$_port_in" ]; then
        if [[ "$_port_in" =~ ^[0-9]+$ ]] && [ "$_port_in" -ge 1 ] && [ "$_port_in" -le 65535 ]; then
            PORT="$_port_in"
        else
            echo "   ⚠️  invalid port '$_port_in' — keeping $PORT"
        fi
    fi
    _default_internal="${INTERNAL_PORT:-40802}"
    read -rp "   Internal port if proxy is on [default=$_default_internal]: " _iport_in
    if [ -n "$_iport_in" ]; then
        if [[ "$_iport_in" =~ ^[0-9]+$ ]] && [ "$_iport_in" -ge 1 ] && [ "$_iport_in" -le 65535 ]; then
            INTERNAL_PORT="$_iport_in"
        else
            echo "   ⚠️  invalid port '$_iport_in' — keeping $_default_internal"
            INTERNAL_PORT="$_default_internal"
        fi
    fi
fi

# ── HDD cache policy (penultimate interactive choice) ───────────────────────
_tune_cache_ram="${CACHE_RAM:-}"
_tune_slot_save_path="${SLOT_SAVE_PATH:-}"
_default_slot_save_path="${LLAMACPP_SLOT_SAVE_PATH:-}"
if [ -z "$_default_slot_save_path" ]; then
    if [ -n "${MODELS_DIR:-}" ]; then
        _default_slot_save_path="$(dirname "$MODELS_DIR")/llama-slots"
    else
        _default_slot_save_path="$DEFAULT_SLOTS_DIR"
    fi
fi
# A tune can declare HDD_CACHE: "1" — hdd cache on by default without
# hardcoding a machine-specific SLOT_SAVE_PATH: the default slots dir fills
# in, so choice 1 (tune default) launches with the cache enabled.
case "${HDD_CACHE:-}" in
    1|[Oo][Nn]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee])
        if [ -z "$_tune_slot_save_path" ]; then
            SLOT_SAVE_PATH="$_default_slot_save_path"
            _tune_slot_save_path="$SLOT_SAVE_PATH"
        fi
        ;;
esac

if [ "$LOG_FLAGS_TOUCHED" -eq 0 ] && [ "$HDD_CACHE_TOUCHED" -eq 0 ]; then
    _tune_hdd_display="off"
    [ -n "$_tune_slot_save_path" ] && _tune_hdd_display="on ($_tune_slot_save_path)"
    echo ""
    echo "💾 HDD cache:"
    echo "   1) Tune default     CACHE_RAM=${_tune_cache_ram:-unset}, HDD=$_tune_hdd_display"
    echo "   2) Enable HDD       use ${_tune_slot_save_path:-$_default_slot_save_path}, force CACHE_RAM=0"
    echo "   3) Disable HDD      no slot save/restore; keep CACHE_RAM=${_tune_cache_ram:-unset}"
    read -rp "Choice [1-3, default=1]: " _hdd_mode
    _hdd_mode="${_hdd_mode:-1}"
    case "$_hdd_mode" in
        1) HDD_CACHE_MODE="default" ;;
        2) HDD_CACHE_MODE="on"; HDD_CACHE_TOUCHED=1 ;;
        3) HDD_CACHE_MODE="off"; HDD_CACHE_TOUCHED=1 ;;
        *) echo "   ⚠️  invalid choice '$_hdd_mode' — using tune default"
           HDD_CACHE_MODE="default" ;;
    esac
fi
if [ "$LOG_FLAGS_TOUCHED" -eq 1 ] && [ "$HDD_CACHE_TOUCHED" -eq 0 ] && [ -z "${SLOT_SAVE_PATH:-}" ]; then
    HDD_CACHE_MODE="off"
fi

case "$HDD_CACHE_MODE" in
    on)
        SLOT_SAVE_PATH="${SLOT_SAVE_PATH:-$_default_slot_save_path}"
        CACHE_RAM=0
        echo "💾 HDD cache: enabled (SLOT_SAVE_PATH=$SLOT_SAVE_PATH, CACHE_RAM=0)"
        ;;
    off)
        SLOT_SAVE_PATH=""
        echo "💾 HDD cache: disabled (CACHE_RAM=${CACHE_RAM:-unset})"
        ;;
    default|"")
        if [ -n "${SLOT_SAVE_PATH:-}" ]; then
            echo "💾 HDD cache: tune default on (SLOT_SAVE_PATH=$SLOT_SAVE_PATH, CACHE_RAM=${CACHE_RAM:-unset})"
        else
            echo "💾 HDD cache: tune default off (CACHE_RAM=${CACHE_RAM:-unset})"
        fi
        ;;
    *)
        echo "❌ Invalid HDD cache mode: $HDD_CACHE_MODE"
        exit 1
        ;;
esac

if [ -n "${SLOT_SAVE_PATH:-}" ]; then
    if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [ "$PARALLEL" -ne 1 ]; then
        echo "❌ HDD cache is currently single-slot only, but PARALLEL=$PARALLEL."
        echo "   Use --parallel 1 with HDD cache, or --no-hdd-cache to preserve multi-slot scheduling/checkpoints."
        exit 1
    fi
fi

# ── Interactive logging-mode prompt (final interactive choice) ──────────────
# Only fires when no logging flag was passed on CLI / re-applied from history.
# Default = preset 3 (proxy + log) since it's the right answer for almost any
# real use; presets 1/2/4 cover quiet/log-only/full-diagnostic.
if [ "$LOG_FLAGS_TOUCHED" -eq 0 ]; then
    echo ""
    echo "🚩 Logging mode (or pass --proxy / --log / --deep-log on CLI to skip):"
    echo "   1) None             quiet, no proxy, no log"
    echo "   2) Log only         server stdout to $LLAMA_LOG_FILE"
    echo "   3) Proxy + log      ← default; needed for slot save/restore"
    echo "   4) Full diagnostic  proxy + log + body capture ($DEEP_LOG)"
    read -rp "Choice [1-4, default=3]: " _log_mode
    _log_mode="${_log_mode:-3}"
    case "$_log_mode" in
        1) NO_PROXY=1; NO_LOG=1; NO_DEEP_LOG=1 ;;
        2) NO_PROXY=1; NO_LOG=0; NO_DEEP_LOG=1 ;;
        3) NO_PROXY=0; NO_LOG=0; NO_DEEP_LOG=1 ;;
        4) NO_PROXY=0; NO_LOG=0; NO_DEEP_LOG=0 ;;
        *) echo "   ⚠️  invalid choice '$_log_mode' — defaulting to preset 3"
           NO_PROXY=0; NO_LOG=0; NO_DEEP_LOG=1 ;;
    esac
fi

# Slot-save persistence is implemented via the proxy. If HDD cache is active,
# force-enable the proxy regardless of CLI flags or interactive choice.
if [ -n "${SLOT_SAVE_PATH:-}" ] && [ "$NO_PROXY" -eq 1 ]; then
    echo "ℹ️  HDD cache uses SLOT_SAVE_PATH=$SLOT_SAVE_PATH — auto-enabling proxy (slot save/restore needs it)"
    NO_PROXY=0
fi

if [ "$NO_PROXY" -eq 0 ] && [ "$PORT" = "${INTERNAL_PORT:-40802}" ]; then
    echo "❌ Public port and internal port must differ when proxy is on (both = $PORT)"
    exit 1
fi

if [ "$NO_PROXY" -eq 1 ]; then
    INTERNAL_PORT="$PORT"
    LLAMA_BIND_HOST="$HOST"
    _proxy_state="off"
    _deep_state="—"   # n/a without proxy
else
    _proxy_state="on  (proxy :$PORT -> server :$INTERNAL_PORT)"
    _deep_state=$([ "$NO_DEEP_LOG" -eq 0 ] && echo "on  ($DEEP_LOG)" || echo "off")
fi
_log_state=$([ "$NO_LOG" -eq 0 ] && echo "on  ($LLAMA_LOG_FILE)" || echo "off")
echo ""
echo "🚀 Launching llama-server"
echo "   proxy:    $_proxy_state"
echo "   log:      $_log_state"
echo "   deep-log: $_deep_state"
echo ""

# ── Build launch flags from tuneable variables ──────────────────────────────
MMAP_FLAG=""
[ "$NO_MMAP" = "1" ] && MMAP_FLAG="--no-mmap"
KV_UNIFIED_FLAG="--no-kv-unified"
[ "$KV_UNIFIED" = "1" ] && KV_UNIFIED_FLAG="--kv-unified"

# A tune can reference flags the resolved llama-server is too old to know
# (e.g. --slot-save-max-checkpoints predates llama-hdd's geometric thinning).
# Probe the binary's --help once and drop unsupported flags with a warning
# instead of dying on "error: invalid argument".
SERVER_HELP="$("$LLAMACPP_SERVER_PATH" --help 2>&1 || true)"
server_supports_flag() {
    [[ "$SERVER_HELP" == *"$1"* ]]
}

# Checkpoint sidecar thinning needs llama-hdd; 0 keeps vanilla compatibility.
SLOT_SAVE_MAX_CKPT_FLAG=""
if [ "${SLOT_SAVE_MAX_CHECKPOINTS:-0}" -gt 0 ] 2>/dev/null; then
    if server_supports_flag "--slot-save-max-checkpoints"; then
        SLOT_SAVE_MAX_CKPT_FLAG="--slot-save-max-checkpoints $SLOT_SAVE_MAX_CHECKPOINTS"
    else
        echo "⚠️  SLOT_SAVE_MAX_CHECKPOINTS=$SLOT_SAVE_MAX_CHECKPOINTS ignored: this llama-server"
        echo "   has no --slot-save-max-checkpoints (older llama-hdd or vanilla llama.cpp)."
    fi
fi
# Same guard for the other cache/checkpoint flags (missing from vanilla
# llama.cpp and pre-sidecar llama-hdd builds).
# A tune can declare the backend it was tuned for (RECOMMENDED_BACKEND:
# vulkan|hip|cuda|cpu). Warn when the resolved build lacks that backend's
# ggml library so a tune expecting e.g. -dev Vulkan0 isn't silently run on
# a HIP-only build with different performance characteristics.
if [ -n "${RECOMMENDED_BACKEND:-}" ] && [ "${RECOMMENDED_BACKEND,,}" != "cpu" ]; then
    rb="${RECOMMENDED_BACKEND,,}"
    case "$rb" in
        rocm) rb="hip" ;;
    esac
    # Probe bin/ and lib/ separately: ls exits nonzero if ANY argument is an
    # unmatched glob, so one combined call false-flags builds that keep their
    # libs in only one of the two dirs.
    if ! ls "$BUILD_DIR"/bin/libggml-"$rb".so* >/dev/null 2>&1 && \
       ! ls "$BUILD_DIR"/lib/libggml-"$rb".so* >/dev/null 2>&1; then
        echo "⚠️  This tune recommends the '$RECOMMENDED_BACKEND' backend, but build '$BUILD_TYPE'"
        echo "   has no libggml-$rb — it will run on whatever backends '$BUILD_TYPE' provides."
        echo "   Performance and tune EXTRA_ARGS device selections may not apply."
    fi
fi

CACHE_RAM_FLAG=""
if server_supports_flag "--cache-ram"; then
    CACHE_RAM_FLAG="--cache-ram $CACHE_RAM"
else
    echo "⚠️  CACHE_RAM=$CACHE_RAM ignored: this llama-server has no --cache-ram."
fi
CKPT_MIN_STEP_FLAG=""
if server_supports_flag "--checkpoint-min-step"; then
    CKPT_MIN_STEP_FLAG="--checkpoint-min-step $CHECKPOINT_MIN_STEP"
else
    echo "⚠️  CHECKPOINT_MIN_STEP=$CHECKPOINT_MIN_STEP ignored: this llama-server has no --checkpoint-min-step."
fi
DIO_FLAG=""
if [ "$DIO" = "1" ]; then
    if server_supports_flag "--direct-io"; then
        DIO_FLAG="-dio"
    else
        echo "⚠️  DIO=1 ignored: this llama-server has no --direct-io."
    fi
fi
CTX_CKPT_FLAG=""
if server_supports_flag "--ctx-checkpoints"; then
    CTX_CKPT_FLAG="--ctx-checkpoints $CHECKPOINT_MAX"
else
    echo "⚠️  CHECKPOINT_MAX=$CHECKPOINT_MAX ignored: this llama-server has no --ctx-checkpoints."
fi
FA_FLAG=""
[ "$FLASH_ATTN" = "1" ] && FA_FLAG="-fa on"
LOG_COLORS_FLAG="--log-colors on"
[ "$LOG_COLORS" = "0" ] && LOG_COLORS_FLAG="--log-colors off"

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
    PROXY_PID=""
}

signal_exit() {
    local sig="$1"
    local status="$2"
    echo "❌ llama-server-launcher received SIG$sig"
    cleanup_proxy
    trap - EXIT
    exit "$status"
}

trap cleanup_proxy EXIT
trap 'signal_exit TERM 143' TERM
trap 'signal_exit INT 130' INT
trap 'signal_exit HUP 129' HUP

if [ "$NO_PROXY" -eq 0 ]; then
    EFFECTIVE_DEEP_LOG="/dev/null"
    if [ "$NO_DEEP_LOG" -eq 0 ]; then
        EFFECTIVE_DEEP_LOG="$DEEP_LOG"
        echo "ℹ️  Deep log enabled (--deep-log) — bodies persisted to $DEEP_LOG"
    fi
    PROXY_ARGS=("$PORT" "$INTERNAL_PORT" "$EFFECTIVE_DEEP_LOG" --server-parallel "$PARALLEL")
    if [ "$NO_LOG" -eq 0 ]; then
        PROXY_ARGS+=(--llama-log-file "$LLAMA_LOG_FILE")
    fi
    if [ -n "${SLOT_SAVE_PATH:-}" ]; then
        # Per-quant namespacing: each .gguf file gets its own slot pool.
        # Slot files are KV cache bytes computed against specific model weights;
        # different quants of the same model produce incompatible bytes (returns
        # 400 on restore). Per-quant dirs prevent cross-quant 400 noise and let
        # each quant accumulate warm state independently.
        _model_basename="$(basename "$model_path" .gguf)"
        EFFECTIVE_SLOT_SAVE_PATH="$SLOT_SAVE_PATH/$_model_basename"
        mkdir -p "$EFFECTIVE_SLOT_SAVE_PATH"
        echo "💾 Slot save namespace: $EFFECTIVE_SLOT_SAVE_PATH"
        # One-time warning for stale flat-layout files from before namespacing
        if compgen -G "$SLOT_SAVE_PATH/*.bin" >/dev/null 2>&1; then
            _stale_count=$(ls "$SLOT_SAVE_PATH"/*.bin 2>/dev/null | wc -l)
            echo "ℹ️  Found $_stale_count flat .bin file(s) at $SLOT_SAVE_PATH/ root (pre-namespacing)."
            echo "   Not used by current launch. Clean with: rm $SLOT_SAVE_PATH/*.bin"
        fi
        # Disk-quota enforcement defaults: 100 GB free / 200 GB total budget,
        # overridable via CLI (--min-free-gb / --max-total-slots-gb) or conf
        # (MIN_FREE_GB / MAX_TOTAL_SLOTS_GB).
        PROXY_ARGS+=(--slot-cache-dir "$EFFECTIVE_SLOT_SAVE_PATH" --api-key "$API_KEY" \
                     --min-free-gb "${MIN_FREE_GB:-100}" \
                     --max-total-slots-gb "${MAX_TOTAL_SLOTS_GB:-200}")
    fi
    # Capture proxy stdout/stderr into llama.log when --log is set, so slot
    # mgmt lines (slotLog console output) and any proxy errors are persisted
    # alongside server output. Otherwise inherit terminal stdout.
    if [ "$NO_LOG" -eq 0 ]; then
        node "$PROXY_SCRIPT" "${PROXY_ARGS[@]}" --stdout-is-llama-log >> "$LLAMA_LOG_FILE" 2>&1 &
    else
        node "$PROXY_SCRIPT" "${PROXY_ARGS[@]}" &
    fi
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
[[ -n "${MODEL_CONFIG_FILE:-}" ]] && _tune_log="$(tune_label "$MODEL_CONFIG_FILE")"
_extras_log=""
[[ "$NO_LOG" -eq 0 ]] && _extras_log+="--log "
[[ "$NO_PROXY" -eq 0 ]] && _extras_log+="--proxy "
[[ "$NO_DEEP_LOG" -eq 0 ]] && _extras_log+="--deep-log "
if [ -n "${SLOT_SAVE_PATH:-}" ]; then
    _extras_log+="--hdd-cache "
elif [[ "$HDD_CACHE_MODE" == "off" ]]; then
    _extras_log+="--no-hdd-cache "
fi
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
  ${CACHE_RAM_FLAG:+$CACHE_RAM_FLAG}
  -ctk "$CACHE_TYPE_K"
  -ctv "$CACHE_TYPE_V"
  ${CKPT_MIN_STEP_FLAG:+$CKPT_MIN_STEP_FLAG}
  ${CTX_CKPT_FLAG:+$CTX_CKPT_FLAG}
  ${SLOT_SAVE_MAX_CKPT_FLAG:+$SLOT_SAVE_MAX_CKPT_FLAG}
  --seed "$SEED"
  ${MLOCK_FLAG:+$MLOCK_FLAG}
  ${MMPROJ:+--mmproj "$MMPROJ"}
  ${REASONING_FLAGS:+$REASONING_FLAGS}
  ${REPEAT_FLAGS:+$REPEAT_FLAGS}
  ${EFFECTIVE_SLOT_SAVE_PATH:+--slot-save-path "$EFFECTIVE_SLOT_SAVE_PATH"}
  $LOG_COLORS_FLAG
  ${EXTRA_ARGS:+$EXTRA_ARGS}
)

tee_status=0
if [ "$NO_LOG" -eq 1 ]; then
    "${LAUNCH_CMD[@]}" 2>&1
    server_status=$?
    launch_status=$server_status
else
    "${LAUNCH_CMD[@]}" 2>&1 | tee -a "$LLAMA_LOG_FILE"
    launch_pipe_status=("${PIPESTATUS[@]}")
    server_status="${launch_pipe_status[0]:-1}"
    tee_status="${launch_pipe_status[1]:-0}"
    launch_status=$server_status
    if [ "$launch_status" -eq 0 ] && [ "$tee_status" -ne 0 ]; then
        launch_status=$tee_status
    fi
fi

if [ "$server_status" -ne 0 ]; then
    echo "❌ llama-server exited with status $server_status"
fi
if [ "$tee_status" -ne 0 ]; then
    echo "❌ llama.log tee exited with status $tee_status"
fi

exit "$launch_status"
