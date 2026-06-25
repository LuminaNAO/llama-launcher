#!/usr/bin/env bash
# llamacpp-init.sh
# Configures a fresh OpenClaw install to use a local llama.cpp server.
# Run this after: build-switch.sh <branch>
#
# Usage: llamacpp-init.sh [agent-name] [--force]
#
# When an agent name is provided, targets that agent's state dir (~/.agent-name)
# instead of the default ~/.openclaw.
#
# Flags:
#   --force    Overwrite existing config even if it has non-llama.cpp providers
set -euo pipefail

FORCE=0
AGENT_NAME=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -*) echo "Unknown flag: $arg"; exit 1 ;;
        *)
            if [[ -z "$AGENT_NAME" ]]; then
                AGENT_NAME="$arg"
            else
                echo "Unknown argument: $arg"; exit 1
            fi
            ;;
    esac
done

# ─── Configuration ──────────────────────────────────────────────────────────

LLAMA_CPP_HOST="${LLAMA_CPP_HOST:-localhost}"
LLAMA_CPP_PORT="${LLAMA_CPP_PORT:-40801}"
LLAMA_CPP_API_KEY="${LLAMA_CPP_API_KEY:-ollama-local}"
LLAMA_CPP_BASE_URL="${LLAMA_CPP_BASE_URL:-}"  # constructed after interactive prompts
GATEWAY_PORT_START=40701
GATEWAY_PORT_END=40798

MODEL_PROVIDER="llama.cpp"
# All of these are auto-detected from the running server. Set env vars to override.
MODEL_ID="${MODEL_ID:-}"                      # auto: /v1/models
MODEL_CONTEXT_WINDOW="${MODEL_CONTEXT_WINDOW:-}"  # auto: /slots[0].n_ctx
MODEL_MAX_TOKENS="${MODEL_MAX_TOKENS:-}"  # auto: derived from context window
MODEL_THINKING_FORMAT="${MODEL_THINKING_FORMAT:-}" # auto: /slots[0].reasoning_format
MODEL_REASONING="${MODEL_REASONING:-}"         # auto: /slots[0].reasoning_format
THINKING_DEFAULT="high"  # off | minimal | low | medium | high | xhigh | adaptive
GATEWAY_BIND="${GATEWAY_BIND:-}"   # loopback | lan
GATEWAY_PASSWORD="${GATEWAY_PASSWORD:-}" # optional fixed password for LAN/VPN gateway auth
SESSION_IDLE_MINUTES="${SESSION_IDLE_MINUTES:-129600}" # 90 days; avoids daily session reset

# ─── Helpers ────────────────────────────────────────────────────────────────
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[33m[WARN]\e[0m  %s\n' "$*"; }
error() { printf '\e[31m[ERROR]\e[0m %s\n' "$*" >&2; exit 1; }

port_in_use() {
    local port="$1"
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

find_free_port() {
    local preferred="$1"
    local start="$2"
    local end="$3"

    if ! port_in_use "$preferred"; then
        echo "$preferred"
        return 0
    fi

    local p
    for p in $(seq "$start" "$end"); do
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done

    return 1
}

is_gateway_port_range() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge "$GATEWAY_PORT_START" ]] && [[ "$port" -le "$GATEWAY_PORT_END" ]]
}

generate_gateway_port() {
    local port
    while true; do
        port=$(shuf -i "${GATEWAY_PORT_START}-${GATEWAY_PORT_END}" -n 1)
        if ! port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
}

normalize_gateway_bind() {
    local value
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

    case "$value" in
        1|local|localhost|loopback|machine)
            echo "loopback"
            ;;
        2|lan|network)
            echo "lan"
            ;;
        *)
            return 1
            ;;
    esac
}

detect_lan_ip() {
    local ip
    ip=$(ip -o -4 addr show scope global 2>/dev/null \
        | awk '$2 !~ /^(lo|docker|br-|veth|cni|flannel|virbr|podman)/ { split($4, a, "/"); print a[1]; exit }')
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    hostname -I 2>/dev/null | awk '{ print $1 }'
}

detect_lan_cidr() {
    ip -o -4 addr show scope global 2>/dev/null \
        | awk '$2 !~ /^(lo|docker|br-|veth|cni|flannel|virbr|podman)/ { print $4; exit }'
}

detect_gateway_origin_hosts() {
    local hosts
    hosts=$(ip -o -4 addr show scope global 2>/dev/null \
        | awk '
            $2 !~ /^(lo|docker|br-|veth|cni|flannel|virbr|podman)/ {
                split($4, a, "/");
                if (a[1] != "" && a[1] !~ /^127\./ && !seen[a[1]]++) print a[1];
            }
        ')
    if [[ -n "$hosts" ]]; then
        printf '%s\n' "$hosts"
        return 0
    fi

    hostname -I 2>/dev/null \
        | tr ' ' '\n' \
        | awk '$1 != "" && $1 !~ /^127\./ && !seen[$1]++ { print $1 }'
}

join_lines() {
    awk 'NF { out = out ? out ", " $0 : $0 } END { print out }'
}

config_string_or_empty() {
    local path="$1"
    local file="$2"

    jq -r "${path} | strings" "$file" 2>/dev/null || true
}

systemd_set_env() {
    local file="$1"
    local key="$2"
    local value="$3"
    local after_key="${4:-}"
    local tmp="${file}.tmp"

    if grep -q "^Environment=${key}=" "$file"; then
        awk -v key="$key" -v value="$value" '
            $0 ~ "^Environment=" key "=" {
                print "Environment=" key "=" value
                next
            }
            { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
        return
    fi

    if [[ -n "$after_key" ]] && grep -q "^Environment=${after_key}=" "$file"; then
        awk -v key="$key" -v value="$value" -v after_key="$after_key" '
            { print }
            $0 ~ "^Environment=" after_key "=" {
                print "Environment=" key "=" value
            }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
        return
    fi

    awk -v key="$key" -v value="$value" '
        /^\[Install\]/ && !inserted {
            print "Environment=" key "=" value
            inserted = 1
        }
        { print }
        END {
            if (!inserted) print "Environment=" key "=" value
        }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Derive state dir from agent name
if [[ -n "$AGENT_NAME" ]]; then
    OPENCLAW_STATE_DIR="$HOME/.$AGENT_NAME"
    AGENT_SERVICE_NAME="${AGENT_NAME}-gateway"
    AGENT_CMD_NAME="$AGENT_NAME"
    info "Agent mode: $AGENT_NAME (state: $OPENCLAW_STATE_DIR)"
else
    OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
    AGENT_SERVICE_NAME="openclaw-gateway"
    AGENT_CMD_NAME="openclaw"
fi
export OPENCLAW_STATE_DIR

# ─── Interactive prompts ────────────────────────────────────────────────────
if [[ -z "$LLAMA_CPP_BASE_URL" ]]; then
    printf '\e[36m[INPUT]\e[0m Inference server address [%s]: ' "$LLAMA_CPP_HOST"
    read -r user_host
    [[ -n "$user_host" ]] && LLAMA_CPP_HOST="$user_host"

    printf '\e[36m[INPUT]\e[0m Inference server port [%s]: ' "$LLAMA_CPP_PORT"
    read -r user_port
    [[ -n "$user_port" ]] && LLAMA_CPP_PORT="$user_port"

    LLAMA_CPP_BASE_URL="http://${LLAMA_CPP_HOST}:${LLAMA_CPP_PORT}"
    info "Inference URL: ${LLAMA_CPP_BASE_URL}"
fi

DEFAULT_CONTEXT=131072
if [[ -z "$MODEL_CONTEXT_WINDOW" ]]; then
    printf '\e[36m[INPUT]\e[0m Max context window in tokens [%s]: ' "$DEFAULT_CONTEXT"
    read -r user_ctx
    if [[ -n "$user_ctx" ]]; then
        MODEL_CONTEXT_WINDOW="$user_ctx"
        info "Context window set to: ${MODEL_CONTEXT_WINDOW}"
    else
        MODEL_CONTEXT_WINDOW="$DEFAULT_CONTEXT"
        info "Context window set to: ${MODEL_CONTEXT_WINDOW} (default)"
    fi
fi

# ─── Subagent server prompts ───────────────────────────────────────────────
# Subagents can optionally be routed to a separate llama-server instance.
# Default: same host/port as the main server (subagent provider still gets
# written so the agent can see the full config).
SUBAGENT_HOST="${SUBAGENT_HOST:-$LLAMA_CPP_HOST}"
SUBAGENT_PORT="${SUBAGENT_PORT:-$LLAMA_CPP_PORT}"
SUBAGENT_API_KEY="${SUBAGENT_API_KEY:-$LLAMA_CPP_API_KEY}"
SUBAGENT_BASE_URL="${SUBAGENT_BASE_URL:-}"
SUBAGENT_MODEL_ID="${SUBAGENT_MODEL_ID:-}"
SUBAGENT_CONTEXT_WINDOW="${SUBAGENT_CONTEXT_WINDOW:-$MODEL_CONTEXT_WINDOW}"
SUBAGENT_MAX_TOKENS="${SUBAGENT_MAX_TOKENS:-}"
SUBAGENT_PROVIDER="llama.cpp-subagent"

if [[ -z "$SUBAGENT_BASE_URL" ]]; then
    printf '\n'
    info "── Subagent inference server ──"
    info "Subagents can use a separate llama-server. Press Enter to use the same server."
    printf '\e[36m[INPUT]\e[0m Subagent server address [%s]: ' "$SUBAGENT_HOST"
    read -r user_sub_host
    [[ -n "$user_sub_host" ]] && SUBAGENT_HOST="$user_sub_host"

    printf '\e[36m[INPUT]\e[0m Subagent server port [%s]: ' "$SUBAGENT_PORT"
    read -r user_sub_port
    [[ -n "$user_sub_port" ]] && SUBAGENT_PORT="$user_sub_port"

    SUBAGENT_BASE_URL="http://${SUBAGENT_HOST}:${SUBAGENT_PORT}"
    info "Subagent inference URL: ${SUBAGENT_BASE_URL}"
fi

# If subagent points to same endpoint as main, reuse provider name to avoid duplication
if [[ "$SUBAGENT_BASE_URL" == "$LLAMA_CPP_BASE_URL" ]]; then
    SUBAGENT_SAME_SERVER=1
    info "Subagent uses same server as main agent."
else
    SUBAGENT_SAME_SERVER=0
    info "Subagent uses separate server: ${SUBAGENT_BASE_URL}"
fi

OPENCLAW_CONFIG="$OPENCLAW_STATE_DIR/openclaw.json"
AGENT_DIR="$OPENCLAW_STATE_DIR/agents/main/agent"

# ─── Environment setup ───────────────────────────────────────────────────────
# Source nvm so node/openclaw are on PATH regardless of how this script is run
if [ -f "$HOME/.nvm/nvm.sh" ]; then
    source "$HOME/.nvm/nvm.sh"
elif [ -f /usr/share/nvm/init-nvm.sh ]; then
    source /usr/share/nvm/init-nvm.sh
fi

export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
    *":$PNPM_HOME:"*) ;;
    *) export PATH="$PNPM_HOME:$PATH" ;;
esac

# ─── Pre-flight checks ───────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    error "'jq' is required. Install: sudo pacman -S jq  (or your distro's equivalent)"
fi

if ! command -v curl &>/dev/null; then
    error "'curl' is required. Install: sudo pacman -S curl"
fi

# Resolve the openclaw entrypoint — call node directly instead of relying on
# the pnpm shim which can break (self-referencing wrapper on pnpm v10+).
FREECLAW_DIR="${FREECLAW_DIR:-$HOME/code/freeclaw}"
OPENCLAW_ENTRYPOINT="$FREECLAW_DIR/dist/index.js"
OPENCLAW_NODE=$(which node)
if [[ ! -f "$OPENCLAW_ENTRYPOINT" ]]; then
    error "Freeclaw entrypoint not found: $OPENCLAW_ENTRYPOINT (run build-switch.sh first)"
fi
openclaw_cmd() { OPENCLAW_STATE_DIR="$OPENCLAW_STATE_DIR" "$OPENCLAW_NODE" "$OPENCLAW_ENTRYPOINT" "$@"; }

# Check for existing config
if [[ -f "$OPENCLAW_CONFIG" ]]; then
    if grep -q '"llama.cpp"' "$OPENCLAW_CONFIG" 2>/dev/null; then
        warn "llama.cpp provider already configured — re-applying..."
    elif [[ "$FORCE" -eq 1 ]]; then
        warn "--force set: overwriting existing config at $OPENCLAW_CONFIG"
    else
        error "$OPENCLAW_CONFIG exists with other config. Use --force to overwrite, or remove manually: rm -rf $OPENCLAW_STATE_DIR"
    fi
fi

# ─── Gateway access prompt ───────────────────────────────────────────────────
if [[ -n "$GATEWAY_BIND" ]]; then
    GATEWAY_BIND_NORMALIZED=$(normalize_gateway_bind "$GATEWAY_BIND") \
        || error "Invalid GATEWAY_BIND='$GATEWAY_BIND' (use loopback or lan)"
    GATEWAY_BIND="$GATEWAY_BIND_NORMALIZED"
else
    EXISTING_GATEWAY_BIND=""
    if [[ -f "$OPENCLAW_CONFIG" ]]; then
        EXISTING_GATEWAY_BIND=$(jq -r '.gateway.bind // empty' "$OPENCLAW_CONFIG" 2>/dev/null || echo "")
    fi
    if ! DEFAULT_GATEWAY_BIND=$(normalize_gateway_bind "${EXISTING_GATEWAY_BIND:-lan}" 2>/dev/null); then
        DEFAULT_GATEWAY_BIND="lan"
    fi

    printf '\n'
    info "── Gateway TUI access ──"
    info "1) Local machine only (127.0.0.1)"
    info "2) Any machine on the LAN"
    printf '\e[36m[INPUT]\e[0m Gateway access [1=local, 2=LAN; default %s]: ' "$DEFAULT_GATEWAY_BIND"
    read -r user_gateway_access
    if [[ -z "$user_gateway_access" ]]; then
        GATEWAY_BIND="$DEFAULT_GATEWAY_BIND"
    elif GATEWAY_BIND_NORMALIZED=$(normalize_gateway_bind "$user_gateway_access"); then
        GATEWAY_BIND="$GATEWAY_BIND_NORMALIZED"
    else
        error "Invalid gateway access choice: $user_gateway_access"
    fi
fi
if [[ "$GATEWAY_BIND" == "loopback" ]]; then
    info "Gateway TUI access: local machine only"
else
    info "Gateway TUI access: any machine on the LAN"
fi

# ─── Connect to llama.cpp ────────────────────────────────────────────────────
info "Checking llama.cpp server at ${LLAMA_CPP_BASE_URL}..."
MODELS_RESPONSE=$(curl -sf "${LLAMA_CPP_BASE_URL}/v1/models" \
    -H "Authorization: Bearer ${LLAMA_CPP_API_KEY}") \
    || error "Cannot reach llama.cpp at ${LLAMA_CPP_BASE_URL}. Is the server running?"
info "llama.cpp server is reachable."

# Auto-detect model ID from the server if not explicitly set
if [[ -z "$MODEL_ID" ]]; then
    MODEL_ID=$(echo "$MODELS_RESPONSE" | jq -r '.data[0].id // empty')
    if [[ -z "$MODEL_ID" ]]; then
        error "Could not detect a model from llama.cpp. Set MODEL_ID explicitly."
    fi
    info "Auto-detected model: ${MODEL_ID}"
else
    info "Using configured model: ${MODEL_ID}"
fi

MODEL_NAME="${MODEL_NAME:-${MODEL_ID}}"
MODEL_REF="${MODEL_PROVIDER}/${MODEL_ID}"

# ─── Auto-detect server capabilities ────────────────────────────────────────
# Poll /slots and /props to detect context window, reasoning format, and caps.
SLOTS_RESPONSE=$(curl -sf "${LLAMA_CPP_BASE_URL}/slots" \
    -H "Authorization: Bearer ${LLAMA_CPP_API_KEY}" 2>/dev/null || echo "[]")
PROPS_RESPONSE=$(curl -sf "${LLAMA_CPP_BASE_URL}/props" \
    -H "Authorization: Bearer ${LLAMA_CPP_API_KEY}" 2>/dev/null || echo "{}")

# Context window — already set by interactive prompt or env var
info "Using context window: ${MODEL_CONTEXT_WINDOW}"

# Max output tokens — derive from context window for local inference (no cost concern).
# Use half the context window, capped at 65536, so there's room for prompt + history.
if [[ -z "$MODEL_MAX_TOKENS" ]]; then
    # 16K gives ample room for thinking + output without VRAM pressure.
    # Thinking tokens count against maxTokens, so 8K was too tight.
    MODEL_MAX_TOKENS=16384
    info "Auto-detected max output tokens: ${MODEL_MAX_TOKENS} (from ${MODEL_CONTEXT_WINDOW} ctx)"
else
    info "Using configured max output tokens: ${MODEL_MAX_TOKENS}"
fi

# Reasoning format detection — check both /slots and /props since the response
# structure varies by llama.cpp version and JINJA setting.
# With JINJA=0, /slots returns minimal data (no reasoning_format field) and /props
# reports reasoning_format="none" in default_generation_settings even when the PEG
# parser handles reasoning natively. The reliable indicator is
# chat_template_caps.supports_preserve_reasoning from /props.
SLOT_REASONING=$(echo "$SLOTS_RESPONSE" | jq -r '.[0].reasoning_format // "none"' 2>/dev/null)
SLOT_REASONING="${SLOT_REASONING:-none}"
PROPS_REASONING=$(echo "$PROPS_RESPONSE" | jq -r '.default_generation_settings.params.reasoning_format // "none"' 2>/dev/null)
PROPS_REASONING="${PROPS_REASONING:-none}"
SUPPORTS_REASONING=$(echo "$PROPS_RESPONSE" | jq -r '.chat_template_caps.supports_preserve_reasoning // false' 2>/dev/null)

# Use whichever source reports a non-none reasoning format
DETECTED_REASONING="none"
if [[ "$SLOT_REASONING" != "none" ]]; then
    DETECTED_REASONING="$SLOT_REASONING"
elif [[ "$PROPS_REASONING" != "none" ]]; then
    DETECTED_REASONING="$PROPS_REASONING"
fi

if [[ -z "$MODEL_REASONING" ]]; then
    if [[ "$DETECTED_REASONING" != "none" ]]; then
        MODEL_REASONING=true
        info "Auto-detected reasoning: enabled (format: ${DETECTED_REASONING})"
    elif [[ "$SUPPORTS_REASONING" == "true" ]]; then
        MODEL_REASONING=true
        info "Auto-detected reasoning: enabled (template supports reasoning)"
    else
        MODEL_REASONING=false
        info "Auto-detected reasoning: disabled"
    fi
fi

# Detect model family from model ID for thinking format selection
MODEL_ID_LOWER=$(echo "$MODEL_ID" | tr '[:upper:]' '[:lower:]')
if [[ "$MODEL_ID_LOWER" == *gemma-4* ]] || [[ "$MODEL_ID_LOWER" == *gemma4* ]]; then
    MODEL_FAMILY="gemma4"
elif [[ "$MODEL_ID_LOWER" == *qwen* ]]; then
    MODEL_FAMILY="qwen"
else
    MODEL_FAMILY="unknown"
fi

if [[ -z "$MODEL_THINKING_FORMAT" ]]; then
    if [[ "$DETECTED_REASONING" != "none" ]]; then
        # Server handles thinking natively via reasoning_format — don't double-parse
        MODEL_THINKING_FORMAT=""
        info "Thinking format: server-native (${DETECTED_REASONING}), no client-side parsing"
    elif [[ "$MODEL_FAMILY" == "gemma4" ]] && [[ "$SUPPORTS_REASONING" == "true" ]]; then
        # Gemma 4 with JINJA=0: PEG parser (peg-gemma4) handles thinking natively
        # via <|channel>thought...<channel|> tags. The /props reasoning_format may
        # report "none" but the PEG parser extracts reasoning regardless.
        MODEL_THINKING_FORMAT=""
        info "Thinking format: server-native (peg-gemma4 parser), no client-side parsing"
    elif [[ "$MODEL_FAMILY" == "gemma4" ]]; then
        # Gemma 4 but template doesn't support reasoning — likely an older llama.cpp build
        MODEL_THINKING_FORMAT=""
        warn "Gemma 4 detected but server may not support reasoning!"
        warn "Ensure llama.cpp build supports Gemma 4 PEG parser (b8000+)."
        warn "Add REASONING=on to the model config or pass --reasoning on."
    elif [[ "$MODEL_FAMILY" == "qwen" ]]; then
        # Qwen uses <think>...</think> tags — openclaw can parse these client-side
        MODEL_THINKING_FORMAT="qwen"
        info "Thinking format: client-side qwen (server reasoning not active)"
    else
        # Unknown model — try qwen format as a safe fallback (most common tag format)
        MODEL_THINKING_FORMAT="qwen"
        info "Thinking format: client-side qwen (fallback for unknown model family)"
    fi
fi
info "Model family: ${MODEL_FAMILY}"

# ─── Subagent server auto-detection ─────────────────────────────────────────
if [[ "$SUBAGENT_SAME_SERVER" -eq 1 ]]; then
    # Same server — reuse main model settings, provider name stays llama.cpp
    SUBAGENT_PROVIDER="$MODEL_PROVIDER"
    SUBAGENT_MODEL_ID="$MODEL_ID"
    SUBAGENT_MODEL_NAME="$MODEL_NAME"
    SUBAGENT_CONTEXT_WINDOW="$MODEL_CONTEXT_WINDOW"
    SUBAGENT_MAX_TOKENS="$MODEL_MAX_TOKENS"
    SUBAGENT_REASONING="$MODEL_REASONING"
    SUBAGENT_THINKING_FORMAT="$MODEL_THINKING_FORMAT"
    SUBAGENT_FAMILY="$MODEL_FAMILY"
    info "Subagent model: ${SUBAGENT_MODEL_ID} (same as main)"
else
    info "Checking subagent llama.cpp server at ${SUBAGENT_BASE_URL}..."
    SUBAGENT_MODELS_RESPONSE=$(curl -sf --connect-timeout 10 "${SUBAGENT_BASE_URL}/v1/models" \
        -H "Authorization: Bearer ${SUBAGENT_API_KEY}" 2>/dev/null) \
        || { warn "Cannot reach subagent server at ${SUBAGENT_BASE_URL} — it may be busy."; \
             warn "Continuing with config anyway (server can come online later)."; \
             SUBAGENT_MODELS_RESPONSE=""; }

    if [[ -z "$SUBAGENT_MODEL_ID" ]] && [[ -n "$SUBAGENT_MODELS_RESPONSE" ]]; then
        SUBAGENT_MODEL_ID=$(echo "$SUBAGENT_MODELS_RESPONSE" | jq -r '.data[0].id // empty')
    fi
    if [[ -z "$SUBAGENT_MODEL_ID" ]]; then
        warn "Could not auto-detect subagent model. Using main model ID as placeholder."
        SUBAGENT_MODEL_ID="$MODEL_ID"
    else
        info "Subagent auto-detected model: ${SUBAGENT_MODEL_ID}"
    fi
    SUBAGENT_MODEL_NAME="${SUBAGENT_MODEL_ID}"

    # Auto-detect subagent server capabilities
    SUBAGENT_SLOTS=$(curl -sf --connect-timeout 10 "${SUBAGENT_BASE_URL}/slots" \
        -H "Authorization: Bearer ${SUBAGENT_API_KEY}" 2>/dev/null || echo "[]")
    SUBAGENT_PROPS=$(curl -sf --connect-timeout 10 "${SUBAGENT_BASE_URL}/props" \
        -H "Authorization: Bearer ${SUBAGENT_API_KEY}" 2>/dev/null || echo "{}")

    # Subagent max tokens
    if [[ -z "$SUBAGENT_MAX_TOKENS" ]]; then
        SUBAGENT_MAX_TOKENS=16384
    fi

    # Subagent reasoning detection (same logic as main)
    SUB_SLOT_REASONING=$(echo "$SUBAGENT_SLOTS" | jq -r '.[0].reasoning_format // "none"' 2>/dev/null)
    SUB_PROPS_REASONING=$(echo "$SUBAGENT_PROPS" | jq -r '.default_generation_settings.params.reasoning_format // "none"' 2>/dev/null)
    SUB_SUPPORTS_REASONING=$(echo "$SUBAGENT_PROPS" | jq -r '.chat_template_caps.supports_preserve_reasoning // false' 2>/dev/null)

    SUB_DETECTED_REASONING="none"
    [[ "$SUB_SLOT_REASONING" != "none" ]] && SUB_DETECTED_REASONING="$SUB_SLOT_REASONING"
    [[ "$SUB_DETECTED_REASONING" == "none" ]] && [[ "$SUB_PROPS_REASONING" != "none" ]] && SUB_DETECTED_REASONING="$SUB_PROPS_REASONING"

    SUBAGENT_REASONING=false
    if [[ "$SUB_DETECTED_REASONING" != "none" ]]; then
        SUBAGENT_REASONING=true
    elif [[ "$SUB_SUPPORTS_REASONING" == "true" ]]; then
        SUBAGENT_REASONING=true
    fi

    # Subagent model family + thinking format
    SUB_ID_LOWER=$(echo "$SUBAGENT_MODEL_ID" | tr '[:upper:]' '[:lower:]')
    if [[ "$SUB_ID_LOWER" == *gemma-4* ]] || [[ "$SUB_ID_LOWER" == *gemma4* ]]; then
        SUBAGENT_FAMILY="gemma4"
    elif [[ "$SUB_ID_LOWER" == *qwen* ]]; then
        SUBAGENT_FAMILY="qwen"
    else
        SUBAGENT_FAMILY="unknown"
    fi

    SUBAGENT_THINKING_FORMAT=""
    if [[ "$SUB_DETECTED_REASONING" != "none" ]]; then
        SUBAGENT_THINKING_FORMAT=""
    elif [[ "$SUBAGENT_FAMILY" == "gemma4" ]] && [[ "$SUB_SUPPORTS_REASONING" == "true" ]]; then
        SUBAGENT_THINKING_FORMAT=""
    elif [[ "$SUBAGENT_FAMILY" == "qwen" ]]; then
        SUBAGENT_THINKING_FORMAT="qwen"
    else
        SUBAGENT_THINKING_FORMAT="qwen"
    fi

    info "Subagent reasoning: ${SUBAGENT_REASONING}, family: ${SUBAGENT_FAMILY}"
fi

SUBAGENT_MODEL_REF="${SUBAGENT_PROVIDER}/${SUBAGENT_MODEL_ID}"
info "Primary model ref: ${MODEL_REF}"
info "Subagent model ref: ${SUBAGENT_MODEL_REF}"

# ─── Gateway port ────────────────────────────────────────────────────────────
# The systemd service (written by build-switch.sh) hardcodes the gateway port.
# Use that as the source of truth to avoid config/service port mismatches.
# If the chosen port is held by another user's process, pick a free one instead.
GATEWAY_SERVICE_FILE="$HOME/.config/systemd/user/${AGENT_SERVICE_NAME}.service"
SERVICE_PORT=""
if [[ -f "$GATEWAY_SERVICE_FILE" ]]; then
    SERVICE_PORT=$(grep -oP 'OPENCLAW_GATEWAY_PORT=\K[0-9]+' "$GATEWAY_SERVICE_FILE" 2>/dev/null || echo "")
fi
if [[ -n "$SERVICE_PORT" ]] && is_gateway_port_range "$SERVICE_PORT"; then
    GATEWAY_PORT="$SERVICE_PORT"
    info "Using gateway port from service file: ${GATEWAY_PORT}"
elif [[ -n "$SERVICE_PORT" ]]; then
    warn "Service gateway port ${SERVICE_PORT} is outside ${GATEWAY_PORT_START}-${GATEWAY_PORT_END}; assigning a new port"
elif [[ -f "$OPENCLAW_CONFIG" ]]; then
    EXISTING_PORT=$(jq -r '.gateway.port // empty' "$OPENCLAW_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$EXISTING_PORT" ]] && is_gateway_port_range "$EXISTING_PORT"; then
        GATEWAY_PORT="$EXISTING_PORT"
        info "Reusing existing config port: ${GATEWAY_PORT}"
    elif [[ -n "$EXISTING_PORT" ]]; then
        warn "Config gateway port ${EXISTING_PORT} is outside ${GATEWAY_PORT_START}-${GATEWAY_PORT_END}; assigning a new port"
    fi
fi
GATEWAY_PORT="${GATEWAY_PORT:-$(generate_gateway_port)}"

# Verify chosen port isn't held by another user's process
if port_in_use "$GATEWAY_PORT"; then
    # Port is in use — check if it's ours (our systemd service) or someone else's
    systemctl --user stop "$AGENT_SERVICE_NAME" 2>/dev/null || true
    sleep 1
    if port_in_use "$GATEWAY_PORT"; then
        # Still in use after stopping our service — another user holds it
        OLD_PORT="$GATEWAY_PORT"
        for p in $(seq "$GATEWAY_PORT_START" "$GATEWAY_PORT_END"); do
            if ! port_in_use "$p"; then
                GATEWAY_PORT="$p"
                break
            fi
        done
        if [[ "$GATEWAY_PORT" == "$OLD_PORT" ]]; then
            error "No free gateway port found in ${GATEWAY_PORT_START}-${GATEWAY_PORT_END}"
        fi
        warn "Port ${OLD_PORT} held by another process — switching to ${GATEWAY_PORT}"
    fi
fi

if [[ "$GATEWAY_BIND" == "lan" ]]; then
    if systemctl is-active --quiet ufw 2>/dev/null; then
        warn "ufw is active; LAN clients may time out unless the local service range is allowed."
        warn "Run: sudo ufw allow from <your-lan-cidr> to any port 40700:40900 proto tcp"
        warn "Example: sudo ufw allow from <your-network>/24 to any port 40700:40900 proto tcp"
    fi
fi

# ─── Step 1: Base gateway config ────────────────────────────────────────────
# Write directly via jq instead of 4 separate `openclaw config set` calls,
# each of which spawns a full Node.js process (~2-3s each).
mkdir -p "$OPENCLAW_STATE_DIR"
[[ -f "$OPENCLAW_CONFIG" ]] || echo '{}' > "$OPENCLAW_CONFIG"
info "Configuring gateway (mode=local, bind=${GATEWAY_BIND}, port=${GATEWAY_PORT}, tls=enabled)..."
if [[ "$GATEWAY_BIND" == "lan" ]]; then
    GATEWAY_ORIGIN_HOSTS_JSON=$(detect_gateway_origin_hosts \
        | jq -R -s -c 'split("\n") | map(select(length > 0)) | unique')
else
    GATEWAY_ORIGIN_HOSTS_JSON="[]"
fi
CONTROL_UI_ALLOWED_ORIGINS=$(jq -c -n \
    --arg port "$GATEWAY_PORT" \
    --argjson hosts "$GATEWAY_ORIGIN_HOSTS_JSON" \
    '[
        "https://localhost:\($port)",
        "https://127.0.0.1:\($port)"
    ] + ($hosts | map("https://\(.)" + ":\($port)") )')
jq --arg mode "local" \
   --arg bind "$GATEWAY_BIND" \
   --argjson port "$GATEWAY_PORT" \
   --arg thinkDefault "$THINKING_DEFAULT" \
   --argjson sessionIdleMinutes "$SESSION_IDLE_MINUTES" \
   --argjson controlUiOrigins "$CONTROL_UI_ALLOWED_ORIGINS" \
   --arg authMode "$(if [[ "$GATEWAY_BIND" == "lan" ]]; then echo "token-password"; else echo "token"; fi)" \
   '.gateway.mode = $mode |
    .gateway.bind = $bind |
    .gateway.port = $port |
    .gateway.auth.mode = $authMode |
    .gateway.tls.enabled = true |
    .gateway.tls.autoGenerate = true |
    del(.gateway.tailscale) |
    .gateway.controlUi.allowedOrigins = (
        reduce ($controlUiOrigins[]) as $origin
            ([]; if any(.[]; ascii_downcase == ($origin | ascii_downcase)) then . else . + [$origin] end)
    ) |
    .gateway.controlUi.dangerouslyDisableDeviceAuth = true |
    .gateway.controlUi.allowInsecureAuth = false |
    .session.reset.mode = "idle" |
    .session.reset.idleMinutes = $sessionIdleMinutes |
    .agents.defaults.thinkingDefault = $thinkDefault' \
   "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"
info "Control UI origins: $(echo "$CONTROL_UI_ALLOWED_ORIGINS" | jq -r 'join(", ")')"
if [[ "$GATEWAY_BIND" == "lan" ]]; then
    info "LAN Control UI device pairing is disabled; remote clients must provide both gateway token and password."
fi
info "Default thinking level: ${THINKING_DEFAULT}"
info "Session reset: idle after ${SESSION_IDLE_MINUTES} minutes (~90 days)"

GATEWAY_TOKEN=$(config_string_or_empty '.gateway.auth.token // empty' "$OPENCLAW_CONFIG")
GATEWAY_AUTH_PASSWORD=$(config_string_or_empty '.gateway.auth.password // empty' "$OPENCLAW_CONFIG")
if [[ -z "$GATEWAY_TOKEN" ]]; then
    GATEWAY_TOKEN=$(openssl rand -hex 24)
    jq --arg token "$GATEWAY_TOKEN" '.gateway.auth.token = $token' \
        "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"
    info "Generated gateway auth token."
fi
if [[ "$GATEWAY_BIND" == "lan" ]]; then
    if [[ -n "$GATEWAY_PASSWORD" ]]; then
        GATEWAY_AUTH_PASSWORD="$GATEWAY_PASSWORD"
    fi
    if [[ -z "$GATEWAY_AUTH_PASSWORD" ]]; then
        GATEWAY_AUTH_PASSWORD=$(openssl rand -hex 24)
        info "Generated gateway auth password."
    fi
    jq --arg password "$GATEWAY_AUTH_PASSWORD" '.gateway.auth.password = $password' \
        "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"
fi

# ─── Step 2: Register llama.cpp provider ─────────────────────────────────────
# Write directly to config via jq — `openclaw config set` with bracket notation
# (models.providers["llama.cpp"]) stores the brackets as part of the key name,
# producing a broken key in the JSON.
info "Registering provider '${MODEL_PROVIDER}' with model '${MODEL_ID}'..."

PROVIDER_JSON=$(jq -n \
    --arg baseUrl    "$LLAMA_CPP_BASE_URL" \
    --arg apiKey     "$LLAMA_CPP_API_KEY" \
    --arg modelId    "$MODEL_ID" \
    --arg modelName  "$MODEL_NAME" \
    --argjson ctxWin "$MODEL_CONTEXT_WINDOW" \
    --argjson maxTok "$MODEL_MAX_TOKENS" \
    --arg thinkFmt   "$MODEL_THINKING_FORMAT" \
    --argjson reasoning "$MODEL_REASONING" \
    '{
        baseUrl: $baseUrl,
        apiKey:  $apiKey,
        api:     "anthropic-messages",
        models: [{
            id:        $modelId,
            name:      $modelName,
            reasoning: $reasoning,
            input:     ["text"],
            cost:      {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
            contextWindow: $ctxWin,
            maxTokens:     $maxTok,
            compat: (
                if $thinkFmt != "" then {thinkingFormat: $thinkFmt} else {} end
            )
        }]
    }')

jq --arg provider "$MODEL_PROVIDER" \
   --argjson entry "$PROVIDER_JSON" \
   '.models.providers[$provider] = $entry' \
   "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"

# Set the selected local model as the primary agent model. Preserve existing
# model fallbacks and allowlist entries, but make this init run authoritative
# for the default model selection.
info "Setting primary default model: ${MODEL_REF}"
jq --arg modelRef "$MODEL_REF" \
   '.agents.defaults.model = (
        (if (.agents.defaults.model | type) == "object" then .agents.defaults.model else {} end)
        + { primary: $modelRef }
    ) |
    .agents.defaults.models = (
        (if (.agents.defaults.models | type) == "object" then .agents.defaults.models else {} end)
        + { ($modelRef): ((.agents.defaults.models[$modelRef] // {}) | if type == "object" then . else {} end) }
    )' \
   "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"

# Register subagent provider (separate entry when using a different server)
if [[ "$SUBAGENT_SAME_SERVER" -eq 0 ]]; then
    info "Registering subagent provider '${SUBAGENT_PROVIDER}' with model '${SUBAGENT_MODEL_ID}'..."
    SUBAGENT_PROVIDER_JSON=$(jq -n \
        --arg baseUrl    "$SUBAGENT_BASE_URL" \
        --arg apiKey     "$SUBAGENT_API_KEY" \
        --arg modelId    "$SUBAGENT_MODEL_ID" \
        --arg modelName  "$SUBAGENT_MODEL_NAME" \
        --argjson ctxWin "$SUBAGENT_CONTEXT_WINDOW" \
        --argjson maxTok "$SUBAGENT_MAX_TOKENS" \
        --arg thinkFmt   "$SUBAGENT_THINKING_FORMAT" \
        --argjson reasoning "$SUBAGENT_REASONING" \
        '{
            baseUrl: $baseUrl,
            apiKey:  $apiKey,
            api:     "anthropic-messages",
            models: [{
                id:        $modelId,
                name:      $modelName,
                reasoning: $reasoning,
                input:     ["text"],
                cost:      {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
                contextWindow: $ctxWin,
                maxTokens:     $maxTok,
                compat: (
                    if $thinkFmt != "" then {thinkingFormat: $thinkFmt} else {} end
                )
            }]
        }')

    jq --arg provider "$SUBAGENT_PROVIDER" \
       --argjson entry "$SUBAGENT_PROVIDER_JSON" \
       '.models.providers[$provider] = $entry' \
       "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"
fi

# Set the global subagent default model
info "Setting subagent default model: ${SUBAGENT_MODEL_REF}"
jq --arg subModel "$SUBAGENT_MODEL_REF" \
   '.agents.defaults.subagents.model = $subModel |
    .agents.defaults.models[$subModel] = {}' \
   "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"

# ─── Step 2b: Isolate signal-cli HTTP daemon ──────────────────────────────────
# A local httpUrl (especially the signal-cli default 127.0.0.1:8080) can attach
# this gateway to another user's already-running signal-cli daemon. If Signal is
# configured locally, make FreeClaw spawn its own daemon on a free port instead.
SIGNAL_CONFIGURED=$(jq -r '
    if (.channels.signal? | type) == "object" and (.channels.signal.enabled // true) != false then
        "yes"
    else
        "no"
    end
' "$OPENCLAW_CONFIG" 2>/dev/null || echo "no")

if [[ "$SIGNAL_CONFIGURED" == "yes" ]]; then
    SIGNAL_EXTERNAL=$(jq -r '
        def external:
            (.httpEndpointFile? // "") != "" or (.archiveRaw? != null);
        def any_account_external:
            (.accounts? // {} | to_entries | any(.value | type == "object" and external));
        if (.channels.signal | external) or (.channels.signal | any_account_external) then
            "yes"
        else
            "no"
        end
    ' "$OPENCLAW_CONFIG" 2>/dev/null || echo "no")

    SIGNAL_LOCAL_HTTP=$(jq -r '
        def local_url:
            type == "string" and test("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:[0-9]+)?/?$");
        def local_config:
            ((.httpUrl? | local_url) or ((.httpUrl? // "") == ""));
        def any_account_local:
            (.accounts? // {} | to_entries | any(.value | type == "object" and local_config));
        if (.channels.signal | local_config) or (.channels.signal | any_account_local) then
            "yes"
        else
            "no"
        end
    ' "$OPENCLAW_CONFIG" 2>/dev/null || echo "no")

    SIGNAL_CLI_PATH=$(jq -r '.channels.signal.cliPath // "signal-cli"' "$OPENCLAW_CONFIG" 2>/dev/null || echo "signal-cli")
    if [[ "$SIGNAL_EXTERNAL" == "yes" ]]; then
        info "Signal uses an external endpoint/supervisor; leaving Signal daemon config unchanged."
    elif [[ "$SIGNAL_LOCAL_HTTP" == "yes" ]] && command -v "$SIGNAL_CLI_PATH" &>/dev/null; then
        EXISTING_SIGNAL_PORT=$(jq -r '
            .channels.signal.httpPort //
            (.channels.signal.httpUrl // "" | try capture(":(?<port>[0-9]+)(/)?$").port? catch null | tonumber?) //
            8080
        ' "$OPENCLAW_CONFIG" 2>/dev/null || echo "8080")
        SIGNAL_HTTP_PORT=$(find_free_port "$EXISTING_SIGNAL_PORT" 18080 18180) \
            || error "No free signal-cli HTTP port found in 18080-18180"
        SIGNAL_HTTP_HOST="127.0.0.1"

        if [[ "$SIGNAL_HTTP_PORT" != "$EXISTING_SIGNAL_PORT" ]]; then
            warn "Signal HTTP port ${EXISTING_SIGNAL_PORT} is already in use — switching to ${SIGNAL_HTTP_PORT}"
        else
            info "Signal HTTP port: ${SIGNAL_HTTP_PORT}"
        fi

        jq --arg host "$SIGNAL_HTTP_HOST" --argjson port "$SIGNAL_HTTP_PORT" '
            def local_url:
                type == "string" and test("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:[0-9]+)?/?$");
            def should_patch:
                ((.httpEndpointFile? // "") == "") and
                (.archiveRaw? == null) and
                ((.httpUrl? | local_url) or ((.httpUrl? // "") == ""));
            def patch_signal:
                if type == "object" and should_patch then
                    .httpHost = $host |
                    .httpPort = $port |
                    .autoStart = true |
                    del(.httpUrl)
                else
                    .
                end;
            .channels.signal |= (
                patch_signal |
                if (.accounts? | type) == "object" then
                    .accounts |= with_entries(.value |= patch_signal)
                else
                    .
                end
            )
        ' "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"
        info "Configured Signal to auto-start its own signal-cli daemon at ${SIGNAL_HTTP_HOST}:${SIGNAL_HTTP_PORT}"
    elif [[ "$SIGNAL_LOCAL_HTTP" == "yes" ]]; then
        warn "Signal is configured locally but '$SIGNAL_CLI_PATH' was not found; leaving Signal daemon config unchanged."
    fi
fi

# ─── Step 3: Gateway service & auth token ────────────────────────────────────
# For named agents, build-switch.sh already wrote the systemd service file.
# We just need to ensure an auth token exists and is embedded in the service.
# For the default (no agent name), fall back to `openclaw gateway install`.
info "Setting up gateway service..."
systemctl --user stop "$AGENT_SERVICE_NAME" 2>/dev/null || true
# Kill ALL stale gateway processes — orphans from previous installs hold the port
# and cause the new gateway to crash-loop. Must happen before gateway install.
OLD_GW_PIDS=$(pgrep -f "openclaw.*gateway|openclaw-gatewa" 2>/dev/null || true)
if [[ -n "$OLD_GW_PIDS" ]]; then
    warn "Killing stale gateway processes: $(echo $OLD_GW_PIDS | tr '\n' ' ')"
    kill -9 $OLD_GW_PIDS 2>/dev/null || true
    sleep 1
fi
mkdir -p "$HOME/.config/systemd/user"

if [[ -n "$AGENT_NAME" ]]; then
    # Named agent: service file written by build-switch.sh — just ensure token
    GATEWAY_TOKEN=$(config_string_or_empty '.gateway.auth.token // empty' "$OPENCLAW_CONFIG")
    if [[ -z "$GATEWAY_TOKEN" ]]; then
        GATEWAY_TOKEN=$(openssl rand -hex 32)
        jq --arg token "$GATEWAY_TOKEN" '.gateway.auth.token = $token' \
            "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"
        info "Generated gateway auth token."
    fi
    # Embed token in the service file
    if [[ -f "$GATEWAY_SERVICE_FILE" ]]; then
        systemd_set_env "$GATEWAY_SERVICE_FILE" "OPENCLAW_GATEWAY_TOKEN" "$GATEWAY_TOKEN" "OPENCLAW_GATEWAY_PORT"
        info "Embedded gateway token in service env."
    else
        error "Service file not found: $GATEWAY_SERVICE_FILE — run build-switch.sh first"
    fi
else
    # Default install: let openclaw handle service creation
    openclaw_cmd gateway install --force
    GATEWAY_TOKEN=$(config_string_or_empty '.gateway.auth.token // empty' "$OPENCLAW_CONFIG")
    if [[ -z "$GATEWAY_TOKEN" ]]; then
        GATEWAY_TOKEN=$(openssl rand -hex 32)
        jq --arg token "$GATEWAY_TOKEN" '.gateway.auth.token = $token' \
            "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"
        info "Replaced unresolved gateway auth token SecretRef with a generated local token."
    fi
    if [[ -f "$GATEWAY_SERVICE_FILE" ]]; then
        systemd_set_env "$GATEWAY_SERVICE_FILE" "OPENCLAW_GATEWAY_TOKEN" "$GATEWAY_TOKEN" "OPENCLAW_GATEWAY_PORT"
        info "Re-embedded gateway token in service env."
    fi
fi

# Ensure service file port matches the resolved GATEWAY_PORT (may have changed
# if the original port was held by another user).
if [[ -f "$GATEWAY_SERVICE_FILE" ]]; then
    sed -i "s|--port [0-9]*|--port ${GATEWAY_PORT}|" "$GATEWAY_SERVICE_FILE"
    sed -i "s|OPENCLAW_GATEWAY_PORT=[0-9]*|OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}|" "$GATEWAY_SERVICE_FILE"
fi

# ─── V8 compile cache ─────────────────────────────────────────────────────
# The 5.8MB reply bundle causes a 40+ second event loop block on first load
# because V8 has to parse/compile it. NODE_COMPILE_CACHE persists compiled
# bytecode across runs, eliminating the block after the first invocation.
# Without this, the gateway WS handshake times out because the client can't
# process messages while V8 is compiling.
V8_CACHE_DIR="$HOME/.openclaw/v8-compile-cache"
mkdir -p "$V8_CACHE_DIR"

# Add to systemd service
if [[ -f "$GATEWAY_SERVICE_FILE" ]]; then
    systemd_set_env "$GATEWAY_SERVICE_FILE" "NODE_COMPILE_CACHE" "$V8_CACHE_DIR" "OPENCLAW_GATEWAY_PORT"
fi

# Add to user profile so CLI invocations also use the cache
PROFILE_FILE="$HOME/.profile"
if [[ -f "$PROFILE_FILE" ]] && ! grep -q "NODE_COMPILE_CACHE" "$PROFILE_FILE"; then
    printf '\n# V8 compile cache for openclaw (speeds up startup)\nexport NODE_COMPILE_CACHE="%s"\n' \
        "$V8_CACHE_DIR" >> "$PROFILE_FILE"
    info "Added NODE_COMPILE_CACHE to ~/.profile"
fi
# Also export for the current session
export NODE_COMPILE_CACHE="$V8_CACHE_DIR"

# Pre-warm the V8 compile cache by loading the heavy module once.
# This takes ~3s for the initial parse + ~40s for deferred compilation.
# After this, subsequent loads complete in <3s with no event loop block.
OPENCLAW_BIN=$(command -v openclaw_cmd 2>/dev/null || command -v openclaw 2>/dev/null || true)
if [[ -n "$OPENCLAW_BIN" ]]; then
    OPENCLAW_DIST_DIR=$(dirname "$(readlink -f "$OPENCLAW_BIN")")/../dist
    if [[ -d "$OPENCLAW_DIST_DIR" ]]; then
        # Find the reply chunk (the 5.8MB bundle that causes the block)
        REPLY_CHUNK=$(ls "$OPENCLAW_DIST_DIR"/reply-*.js 2>/dev/null | head -1)
        if [[ -n "$REPLY_CHUNK" ]]; then
            info "Pre-warming V8 compile cache (this takes ~45s on first run)..."
            # Use dynamic import() to match how the bundle is loaded (ESM)
            timeout 90 node --input-type=module -e "await import('$REPLY_CHUNK')" 2>/dev/null || true
            info "V8 compile cache warmed."
        fi
    fi
fi

# ─── Step 4: Write agent auth-profiles.json ──────────────────────────────────
mkdir -p "$AGENT_DIR"
SUBAGENT_DIR="$OPENCLAW_STATE_DIR/agents/main/subagent"
info "Writing auth-profiles.json..."
if [[ "$SUBAGENT_SAME_SERVER" -eq 0 ]]; then
    # Main agent gets both providers
    jq -n \
        --arg provider    "$MODEL_PROVIDER" \
        --arg key         "$LLAMA_CPP_API_KEY" \
        --arg subProvider "$SUBAGENT_PROVIDER" \
        --arg subKey      "$SUBAGENT_API_KEY" \
        '{
            version: 1,
            profiles: {
                (($provider) + ":default"): {
                    type:     "api_key",
                    provider: $provider,
                    key:      $key
                },
                (($subProvider) + ":default"): {
                    type:     "api_key",
                    provider: $subProvider,
                    key:      $subKey
                }
            }
        }' > "$AGENT_DIR/auth-profiles.json"

    # Subagent needs its own auth-profiles.json with the subagent provider
    mkdir -p "$SUBAGENT_DIR"
    info "Writing subagent auth-profiles.json..."
    jq -n \
        --arg provider    "$MODEL_PROVIDER" \
        --arg key         "$LLAMA_CPP_API_KEY" \
        --arg subProvider "$SUBAGENT_PROVIDER" \
        --arg subKey      "$SUBAGENT_API_KEY" \
        '{
            version: 1,
            profiles: {
                (($provider) + ":default"): {
                    type:     "api_key",
                    provider: $provider,
                    key:      $key
                },
                (($subProvider) + ":default"): {
                    type:     "api_key",
                    provider: $subProvider,
                    key:      $subKey
                }
            }
        }' > "$SUBAGENT_DIR/auth-profiles.json"
else
    jq -n \
        --arg provider "$MODEL_PROVIDER" \
        --arg key      "$LLAMA_CPP_API_KEY" \
        '{
            version: 1,
            profiles: {
                (($provider) + ":default"): {
                    type:     "api_key",
                    provider: $provider,
                    key:      $key
                }
            }
        }' > "$AGENT_DIR/auth-profiles.json"
fi

# ─── Step 5: Merge llama.cpp into agent models.json ──────────────────────────
info "Updating agent models.json..."
MODELS_JSON="$AGENT_DIR/models.json"

MODEL_ENTRY=$(jq -n \
    --arg baseUrl    "$LLAMA_CPP_BASE_URL" \
    --arg apiKey     "$LLAMA_CPP_API_KEY" \
    --arg modelId    "$MODEL_ID" \
    --arg modelName  "$MODEL_NAME" \
    --argjson ctxWin "$MODEL_CONTEXT_WINDOW" \
    --argjson maxTok "$MODEL_MAX_TOKENS" \
    --arg thinkFmt   "$MODEL_THINKING_FORMAT" \
    --argjson reasoning "$MODEL_REASONING" \
    '{
        baseUrl: $baseUrl,
        apiKey:  $apiKey,
        api:     "anthropic-messages",
        models: [{
            id:        $modelId,
            name:      $modelName,
            reasoning: $reasoning,
            input:     ["text"],
            cost:      {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
            contextWindow: $ctxWin,
            maxTokens:     $maxTok,
            compat: (
                if $thinkFmt != "" then {thinkingFormat: $thinkFmt} else {} end
            )
        }]
    }')

if [[ -f "$MODELS_JSON" ]]; then
    jq --arg provider "$MODEL_PROVIDER" \
       --argjson entry "$MODEL_ENTRY" \
       '.providers[$provider] = $entry' \
       "$MODELS_JSON" > "$MODELS_JSON.tmp" && mv "$MODELS_JSON.tmp" "$MODELS_JSON"
else
    jq -n \
       --arg provider "$MODEL_PROVIDER" \
       --argjson entry "$MODEL_ENTRY" \
       '{ providers: { ($provider): $entry } }' > "$MODELS_JSON"
fi

# Add subagent provider to agent models.json (when using a separate server)
if [[ "$SUBAGENT_SAME_SERVER" -eq 0 ]]; then
    info "Adding subagent provider to agent models.json..."
    SUBAGENT_MODEL_ENTRY=$(jq -n \
        --arg baseUrl    "$SUBAGENT_BASE_URL" \
        --arg apiKey     "$SUBAGENT_API_KEY" \
        --arg modelId    "$SUBAGENT_MODEL_ID" \
        --arg modelName  "$SUBAGENT_MODEL_NAME" \
        --argjson ctxWin "$SUBAGENT_CONTEXT_WINDOW" \
        --argjson maxTok "$SUBAGENT_MAX_TOKENS" \
        --arg thinkFmt   "$SUBAGENT_THINKING_FORMAT" \
        --argjson reasoning "$SUBAGENT_REASONING" \
        '{
            baseUrl: $baseUrl,
            apiKey:  $apiKey,
            api:     "anthropic-messages",
            models: [{
                id:        $modelId,
                name:      $modelName,
                reasoning: $reasoning,
                input:     ["text"],
                cost:      {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
                contextWindow: $ctxWin,
                maxTokens:     $maxTok,
                compat: (
                    if $thinkFmt != "" then {thinkingFormat: $thinkFmt} else {} end
                )
            }]
        }')

    jq --arg provider "$SUBAGENT_PROVIDER" \
       --argjson entry "$SUBAGENT_MODEL_ENTRY" \
       '.providers[$provider] = $entry' \
       "$MODELS_JSON" > "$MODELS_JSON.tmp" && mv "$MODELS_JSON.tmp" "$MODELS_JSON"
fi

# ─── Step 5b: Apply node_modules patches ──────────────────────────────────────
# Run all patch-*.sh scripts from the freeclaw repo. These patch node_modules
# for local inference (SDK timeouts, thinking budgets, etc).
# build-switch.sh also runs these during build, but re-running here ensures
# patches survive a standalone pnpm install.
PATCH_COUNT=0
for patch in "$FREECLAW_DIR"/scripts/patch-*.sh; do
    if [[ -x "$patch" ]]; then
        info "Applying patch: $(basename "$patch")"
        bash "$patch"
        PATCH_COUNT=$((PATCH_COUNT + 1))
    fi
done
if [[ $PATCH_COUNT -eq 0 ]]; then
    warn "No patch scripts found in $FREECLAW_DIR/scripts/ — node_modules may need manual patching"
fi

# ─── Step 5c: Clean up orphaned agents and stale locks ───────────────────────
ORPHANS=$(pgrep -f "openclaw-agent" 2>/dev/null || true)
if [[ -n "$ORPHANS" ]]; then
    warn "Killing orphaned openclaw-agent processes: $ORPHANS"
    kill -9 $ORPHANS 2>/dev/null || true
    sleep 1
fi
STALE_LOCKS=$(find "$OPENCLAW_STATE_DIR/agents" -name "*.lock" 2>/dev/null || true)
if [[ -n "$STALE_LOCKS" ]]; then
    warn "Removing stale session locks..."
    rm -f $STALE_LOCKS
fi

# ─── Step 5e: Configure local embedding provider ─────────────────────────────
# node-llama-cpp is installed as an optionalDependency. Point memory search at
# it so semantic recall works without any cloud API keys.
CURRENT_MEM_PROVIDER=$(jq -r '.agents.defaults.memorySearch.provider // empty' "$OPENCLAW_CONFIG" 2>/dev/null || true)
if [[ -z "$CURRENT_MEM_PROVIDER" ]] || [[ "$FORCE" -eq 1 ]]; then
    jq '.agents.defaults.memorySearch.provider = "local"' \
        "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"
    info "Memory search provider set to: local (node-llama-cpp)"
    info "Embedding model will be downloaded on first use (~600MB)"
else
    info "Memory search provider already set to: $CURRENT_MEM_PROVIDER (skipping — use --force to override)"
fi

# ─── Step 6: Start gateway ───────────────────────────────────────────────────
info "Starting gateway service..."
systemctl --user daemon-reload
systemctl --user restart "${AGENT_SERVICE_NAME}.service"

# ─── Step 7: Verify ──────────────────────────────────────────────────────────
info "Waiting for gateway to come up..."
sleep 5

if ! systemctl --user is-active "${AGENT_SERVICE_NAME}.service" &>/dev/null; then
    error "Gateway failed to start. Logs: journalctl --user -u ${AGENT_SERVICE_NAME}.service -n 30"
fi

info "Gateway is running."
if [[ -n "$AGENT_NAME" ]]; then
    "$HOME/.local/bin/$AGENT_CMD_NAME" gateway status --deep 2>&1 | grep -E "RPC probe|Runtime:|Gateway:" || true
else
    openclaw_cmd gateway status --deep 2>&1 | grep -E "RPC probe|Runtime:|Gateway:" || true
fi

info ""
info "=== Setup complete ==="
info "Provider        : ${MODEL_PROVIDER}"
info "Model           : ${MODEL_ID}"
info "Endpoint        : ${LLAMA_CPP_BASE_URL}"
info "Gateway port    : ${GATEWAY_PORT}"
if [[ "$GATEWAY_BIND" == "loopback" ]]; then
    info "Gateway URL     : https://127.0.0.1:${GATEWAY_PORT}/"
else
    GATEWAY_URL_HOSTS=$(detect_gateway_origin_hosts)
    if [[ -n "$GATEWAY_URL_HOSTS" ]]; then
        while IFS= read -r gateway_url_host; do
            [[ -n "$gateway_url_host" ]] && info "Gateway URL     : https://${gateway_url_host}:${GATEWAY_PORT}/"
        done <<< "$GATEWAY_URL_HOSTS"
    fi
fi
info ""
info "Subagent provider : ${SUBAGENT_PROVIDER}"
info "Subagent model    : ${SUBAGENT_MODEL_ID}"
info "Subagent endpoint : ${SUBAGENT_BASE_URL}"
info "Subagent ref      : ${SUBAGENT_MODEL_REF}"
info ""
info "Run '$AGENT_CMD_NAME tui' to start chatting."
