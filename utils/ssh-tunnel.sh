#!/bin/bash

# SSH Tunnel Manager for remote llama-server
# Manages an SSH tunnel that forwards a remote llama-server port to localhost.
#
# Usage:
#   ssh-tunnel.sh                           # interactive — detects state and prompts
#   ssh-tunnel.sh root@1.2.3.4              # connect to specific remote
#   ssh-tunnel.sh --status                  # check tunnel status
#   ssh-tunnel.sh --stop                    # stop active tunnel
#
# Options:
#   --port <N>       Local and remote port (default: 40801)
#   --api-key <key>  API key for health check (default: ollama-local)
#   --status         Show tunnel status and exit
#   --stop           Stop active tunnel and exit

set -euo pipefail

PORT=40801
API_KEY="ollama-local"
REMOTE=""
ACTION=""

UTIL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
case "$UTIL_DIR" in
    /usr/bin|/usr/local/bin|/bin)
        # Packaged install: state lives in the launcher data dir
        ROOT_DIR="${LLAMA_LAUNCHER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/llama-launcher}"
        LAUNCHER_CMD=(llama-launcher)
        ;;
    *)
        ROOT_DIR="$(dirname "$UTIL_DIR")"
        LAUNCHER_CMD=(bash "$ROOT_DIR/llama-server-launcher.sh")
        ;;
esac
TUNNEL_HISTORY="$ROOT_DIR/.tunnel-history"
TUNNEL_PIDFILE="/tmp/llama-tunnel-${PORT}.pid"
TUNNEL_REMOTEFILE="/tmp/llama-tunnel-${PORT}.remote"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="$2"; shift 2 ;;
        --api-key) API_KEY="$2"; shift 2 ;;
        --status)  ACTION="status"; shift ;;
        --stop)    ACTION="stop"; shift ;;
        -h|--help)
            sed -n '2,/^$/{ s/^# \?//; p }' "$0"
            exit 0
            ;;
        *)
            if [[ -z "$REMOTE" ]]; then
                REMOTE="$1"
            else
                echo "Unknown argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Update pidfile/remotefile paths if port was overridden
TUNNEL_PIDFILE="/tmp/llama-tunnel-${PORT}.pid"
TUNNEL_REMOTEFILE="/tmp/llama-tunnel-${PORT}.remote"

# ── Helpers ─────────────────────────────────────────────────────────────────
tunnel_pid() {
    # Check pidfile first, verify process is still alive
    if [[ -f "$TUNNEL_PIDFILE" ]]; then
        local pid
        pid=$(cat "$TUNNEL_PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
        # Stale pidfile
        rm -f "$TUNNEL_PIDFILE" "$TUNNEL_REMOTEFILE"
    fi
    # Fallback: search for ssh process (always return 0, even if no match)
    pgrep -f "^ssh .*${PORT}:127.0.0.1:${PORT}" 2>/dev/null | head -1 || true
}

tunnel_remote() {
    if [[ -f "$TUNNEL_REMOTEFILE" ]]; then
        cat "$TUNNEL_REMOTEFILE"
        return 0
    fi
    # Fallback: parse from process args
    local pid
    pid=$(tunnel_pid) || return 1
    [[ -z "$pid" ]] && return 1
    local args
    args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
    # The remote is the last argument in "ssh -fNL port:host:port remote"
    echo "$args" | awk '{print $NF}'
}

is_tunnel_active() {
    [[ -n "$(tunnel_pid)" ]]
}

check_local_health() {
    local resp
    resp=$(curl -sf --max-time 3 \
        -H "Authorization: Bearer ${API_KEY}" \
        "http://127.0.0.1:${PORT}/health" 2>/dev/null) || return 1
    echo "$resp" | grep -q '"status"' 2>/dev/null
}

ensure_ssh_agent() {
    # If ssh-agent has at least one key loaded, we're good
    if ssh-add -l >/dev/null 2>&1; then
        return 0
    fi

    # Agent not running or empty. Try to start/load.
    local agent_status
    agent_status=$(ssh-add -l 2>&1 >/dev/null) || true

    if echo "$agent_status" | grep -q "Could not open a connection"; then
        # No agent running — start one for this session
        echo "  Starting ssh-agent for this session..."
        eval "$(ssh-agent -s)" >/dev/null
    fi

    # Still no keys loaded
    if ! ssh-add -l >/dev/null 2>&1; then
        # Without a tty, don't block on prompts — assume caller set things up
        if [[ ! -t 0 ]]; then
            echo "  No keys in agent and no tty — skipping ssh-add." >&2
            echo "  ssh may prompt or fail depending on key setup." >&2
            return 0
        fi
        echo "  No SSH keys loaded in ssh-agent."
        read -rp "  Run ssh-add to load your key now? [Y/n] " yn
        case "$yn" in
            [nN]*)
                echo "  Continuing without agent — you may be prompted for passphrase multiple times." >&2
                return 0
                ;;
            *)
                ssh-add || {
                    echo "  ssh-add failed." >&2
                    return 1
                }
                ;;
        esac
    fi
    return 0
}

check_remote_ssh() {
    # No BatchMode — allow interactive prompts if the key isn't in ssh-agent.
    # Capture stderr so failures surface instead of silently dropping the error.
    local err_file
    err_file=$(mktemp)
    local out
    out=$(ssh $SSH_OPTS -o ConnectTimeout=10 "$1" 'echo ok' 2>"$err_file") || true
    if echo "$out" | grep -q ok; then
        rm -f "$err_file"
        return 0
    fi
    # Failed — show the error
    if [[ -s "$err_file" ]]; then
        echo "  SSH error:" >&2
        sed 's/^/    /' "$err_file" >&2
    fi
    rm -f "$err_file"
    return 1
}

check_remote_llama() {
    local err_file
    err_file=$(mktemp)
    local out
    out=$(ssh $SSH_OPTS -o ConnectTimeout=10 "$1" \
        "curl -sf --max-time 3 -H 'Authorization: Bearer ${API_KEY}' http://127.0.0.1:${PORT}/health" 2>"$err_file") || true
    if echo "$out" | grep -q '"status"'; then
        rm -f "$err_file"
        return 0
    fi
    if [[ -s "$err_file" ]]; then
        echo "  Remote health check error:" >&2
        sed 's/^/    /' "$err_file" >&2
    fi
    rm -f "$err_file"
    return 1
}

stop_tunnel() {
    local pid
    pid=$(tunnel_pid)
    if [[ -z "$pid" ]]; then
        echo "No active tunnel found."
        return 0
    fi
    local remote
    remote=$(tunnel_remote) || remote="unknown"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$TUNNEL_PIDFILE" "$TUNNEL_REMOTEFILE"
    echo "Tunnel to ${remote} stopped (pid ${pid})."
}

stop_local_server() {
    local pids
    pids=$(pgrep -f "llama-server.*${PORT}" 2>/dev/null || true)
    [[ -z "$pids" ]] && return 0

    echo ""
    echo "Local llama-server detected on port ${PORT} (pid: ${pids})."
    read -rp "Stop local server to free port? [y/N] " yn
    case "$yn" in
        [yY]*)
            kill $pids 2>/dev/null
            sleep 2
            for pid in $pids; do
                if kill -0 "$pid" 2>/dev/null; then
                    echo "  Force killing pid ${pid}..."
                    kill -9 "$pid" 2>/dev/null
                fi
            done
            echo "  Local server stopped."
            return 0
            ;;
        *)
            echo "  Aborted."
            return 1
            ;;
    esac
}

save_history() {
    local remote="$1"
    local ts
    ts=$(date +%s)
    echo -e "${ts}\t${remote}\t${PORT}" >> "$TUNNEL_HISTORY"
}

start_tunnel() {
    local remote="$1"

    echo "Starting SSH tunnel: localhost:${PORT} -> ${remote}:${PORT}"
    ssh $SSH_OPTS -fNL "${PORT}:127.0.0.1:${PORT}" "$remote"
    sleep 2

    local pid
    pid=$(pgrep -f "^ssh .*${PORT}:127.0.0.1:${PORT}" 2>/dev/null | head -1)
    if [[ -n "$pid" ]]; then
        # Save pid and remote for reliable lookup
        echo "$pid" > "$TUNNEL_PIDFILE"
        echo "$remote" > "$TUNNEL_REMOTEFILE"
        echo "Tunnel active (pid ${pid})."
        save_history "$remote"
        if check_local_health; then
            echo "Health check passed — remote llama-server reachable on localhost:${PORT}."
        else
            echo "Warning: tunnel is up but health check failed. Server may still be loading."
        fi
    else
        echo "Error: tunnel failed to start." >&2
        exit 1
    fi
}

# ── Status action ───────────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
    if is_tunnel_active; then
        local_remote=$(tunnel_remote) || local_remote="unknown"
        echo "Tunnel active to ${local_remote} (pid $(tunnel_pid)), port ${PORT}."
        check_local_health && echo "Health: ok" || echo "Health: unreachable"
    else
        echo "No active tunnel on port ${PORT}."
        if check_local_health; then
            echo "Local llama-server is responding on port ${PORT}."
        else
            echo "Nothing responding on port ${PORT}."
        fi
    fi
    exit 0
fi

# ── Stop action ─────────────────────────────────────────────────────────────
if [[ "$ACTION" == "stop" ]]; then
    stop_tunnel
    exit 0
fi

# ── Tunnel active — offer to disconnect ─────────────────────────────────────
if is_tunnel_active; then
    pid=$(tunnel_pid)
    remote=$(tunnel_remote) || remote="unknown"
    echo "SSH tunnel active: localhost:${PORT} -> ${remote} (pid ${pid})"

    if check_local_health; then
        echo "Remote server health: ok"
    else
        echo "Remote server health: unreachable"
    fi

    echo ""
    read -rp "Stop tunnel and switch back to local? [y/N] " yn
    case "$yn" in
        [yY]*)
            stop_tunnel
            echo "Switched to local."
            ;;
        *)
            echo "Tunnel remains active."
            ;;
    esac
    exit 0
fi

# ── No tunnel — connect to remote ──────────────────────────────────────────

# If no remote given via CLI, show history or prompt
if [[ -z "$REMOTE" ]]; then
    # Load recent unique remotes from history
    if [[ -f "$TUNNEL_HISTORY" ]]; then
        recent_remotes=()
        while IFS=$'\t' read -r ts remote port; do
            # Deduplicate
            dup=0
            for r in "${recent_remotes[@]+"${recent_remotes[@]}"}"; do
                [[ "$r" == "$remote" ]] && { dup=1; break; }
            done
            [[ "$dup" -eq 1 ]] && continue
            recent_remotes+=("$remote")
            [[ ${#recent_remotes[@]} -ge 5 ]] && break
        done < <(tac "$TUNNEL_HISTORY")

        if [[ ${#recent_remotes[@]} -gt 0 ]]; then
            echo "Recent connections:"
            for i in "${!recent_remotes[@]}"; do
                printf "  %d) %s\n" $((i+1)) "${recent_remotes[$i]}"
            done
            echo "  0) Enter new address"
            echo ""
            read -rp "Select [default=1]: " hist_sel
            hist_sel="${hist_sel:-1}"
            if [[ "$hist_sel" =~ ^[1-9]$ ]] && [[ "$hist_sel" -le ${#recent_remotes[@]} ]]; then
                REMOTE="${recent_remotes[$((hist_sel - 1))]}"
                echo ""
                echo "Selected: ${REMOTE}"
            fi
        fi
    fi

    # Still no remote — prompt for one
    if [[ -z "$REMOTE" ]]; then
        echo ""
        read -rp "Remote server (e.g. root@1.2.3.4): " REMOTE
        if [[ -z "$REMOTE" ]]; then
            echo "No remote specified. Exiting." >&2
            exit 1
        fi
    fi
fi

# ── Pre-flight checks ──────────────────────────────────────────────────────
echo ""
echo "Checking SSH agent..."
ensure_ssh_agent || exit 1
echo "  SSH agent: ok"

echo "Checking SSH connectivity to ${REMOTE}..."
if ! check_remote_ssh "$REMOTE"; then
    echo "Error: cannot reach ${REMOTE} via SSH." >&2
    exit 1
fi
echo "  SSH: ok"

echo "Checking remote llama-server on port ${PORT}..."
if ! check_remote_llama "$REMOTE"; then
    echo "Error: no llama-server responding on ${REMOTE}:${PORT}." >&2
    echo "  Start the server on the remote machine first."
    exit 1
fi
echo "  Remote server: ok"

# Check if local port is in use
if ss -tlnp 2>/dev/null | grep -q ":${PORT} " || lsof -i ":${PORT}" &>/dev/null; then
    if ! stop_local_server; then
        exit 1
    fi
fi

echo ""
start_tunnel "$REMOTE"
