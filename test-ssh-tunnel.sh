#!/bin/bash

# End-to-end tests for ssh-tunnel.sh using expect
# Tests all states: tunnel on/off, remote reachable/unreachable, server up/down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL_SCRIPT="$SCRIPT_DIR/ssh-tunnel.sh"
HISTORY_FILE="$SCRIPT_DIR/.tunnel-history"
HISTORY_BACKUP=""

# Real remote for live tests — set via env or default
REMOTE="${TEST_REMOTE:-root@203.0.113.136}"
PORT="${TEST_PORT:-40801}"
API_KEY="${TEST_API_KEY:-ollama-local}"

PIDFILE="/tmp/llama-tunnel-${PORT}.pid"
REMOTEFILE="/tmp/llama-tunnel-${PORT}.remote"

PASS=0
FAIL=0
TESTS=()

# ── Helpers ─────────────────────────────────────────────────────────────────
pass() { PASS=$((PASS+1)); TESTS+=("PASS: $1"); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TESTS+=("FAIL: $1 — $2"); echo "  FAIL: $1 — $2"; }

cleanup_tunnel() {
    pkill -f "^ssh .*${PORT}:127.0.0.1:${PORT}" 2>/dev/null || true
    rm -f "$PIDFILE" "$REMOTEFILE"
    sleep 1
}

backup_history() {
    if [[ -f "$HISTORY_FILE" ]]; then
        HISTORY_BACKUP=$(cat "$HISTORY_FILE")
    fi
    rm -f "$HISTORY_FILE"
}

restore_history() {
    if [[ -n "${HISTORY_BACKUP:-}" ]]; then
        echo "$HISTORY_BACKUP" > "$HISTORY_FILE"
    else
        rm -f "$HISTORY_FILE"
    fi
}

wait_for_remote_server() {
    local max=60
    for ((i=0; i<max; i++)); do
        if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$REMOTE" \
            "curl -sf --max-time 2 -H 'Authorization: Bearer ${API_KEY}' http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q '"status"'; then
            return 0
        fi
        sleep 5
    done
    return 1
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
echo "=== SSH Tunnel E2E Tests ==="
echo "Remote: ${REMOTE}"
echo "Port:   ${PORT}"
echo ""

# Start clean
cleanup_tunnel
backup_history

# ── Test 1: --help ──────────────────────────────────────────────────────────
echo "[Test 1] --help flag"
out=$("$TUNNEL_SCRIPT" --help 2>&1) || true
if echo "$out" | grep -q "SSH Tunnel Manager"; then
    pass "--help prints usage"
else
    fail "--help prints usage" "unexpected output"
fi

# ── Test 2: --status with no tunnel ─────────────────────────────────────────
echo "[Test 2] --status with no tunnel active"
out=$("$TUNNEL_SCRIPT" --status --port "$PORT" 2>&1) || true
if echo "$out" | grep -q "No active tunnel"; then
    pass "--status reports no tunnel"
else
    fail "--status reports no tunnel" "$out"
fi

# ── Test 3: --stop with no tunnel ──────────────────────────────────────────
echo "[Test 3] --stop with no tunnel active"
out=$("$TUNNEL_SCRIPT" --stop --port "$PORT" 2>&1) || true
if echo "$out" | grep -q "No active tunnel"; then
    pass "--stop with no tunnel is graceful"
else
    fail "--stop with no tunnel is graceful" "got: '$out'"
fi

# ── Test 4: Connect to unreachable host ────────────────────────────────────
echo "[Test 4] Connect to unreachable SSH host"
out=$("$TUNNEL_SCRIPT" --port "$PORT" root@192.0.2.1 2>&1) || true
if echo "$out" | grep -q "cannot reach"; then
    pass "unreachable host detected"
else
    fail "unreachable host detected" "$out"
fi

# ── Test 5: Wait for remote server ────────────────────────────────────────
echo "[Test 5] Waiting for remote llama-server..."
if wait_for_remote_server; then
    pass "remote server is up"
else
    fail "remote server is up" "timed out"
    echo "  Skipping live tests."
    restore_history
    echo ""
    echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
    [[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
fi

sleep 2

# ── Test 6: CLI connect to live remote ─────────────────────────────────────
echo "[Test 6] CLI connect: ssh-tunnel.sh ${REMOTE}"
out=$("$TUNNEL_SCRIPT" --port "$PORT" --api-key "$API_KEY" "$REMOTE" 2>&1) || true
if echo "$out" | grep -q "Tunnel active"; then
    pass "tunnel started via CLI"
else
    fail "tunnel started via CLI" "$out"
fi

# ── Test 7: Health check through tunnel ────────────────────────────────────
echo "[Test 7] Health check through tunnel"
health=$(curl -sf --max-time 3 -H "Authorization: Bearer ${API_KEY}" \
    "http://127.0.0.1:${PORT}/health" 2>/dev/null) || health=""
if echo "$health" | grep -q '"status"'; then
    pass "health check through tunnel"
else
    fail "health check through tunnel" "got: $health"
fi

# ── Test 8: --status with active tunnel ────────────────────────────────────
echo "[Test 8] --status with active tunnel"
out=$("$TUNNEL_SCRIPT" --status --port "$PORT" 2>&1) || true
if echo "$out" | grep -q "Tunnel active"; then
    pass "--status reports active tunnel"
else
    fail "--status reports active tunnel" "$out"
fi

# ── Test 9: Pidfile and remotefile exist ──────────────────────────────────
echo "[Test 9] Pidfile and remotefile created"
if [[ -f "$PIDFILE" && -f "$REMOTEFILE" ]]; then
    stored_remote=$(cat "$REMOTEFILE")
    if [[ "$stored_remote" == "$REMOTE" ]]; then
        pass "pidfile and remotefile correct"
    else
        fail "pidfile and remotefile correct" "remote mismatch: $stored_remote"
    fi
else
    fail "pidfile and remotefile correct" "files missing"
fi

# ── Test 10: History was saved ─────────────────────────────────────────────
echo "[Test 10] History entry saved"
if [[ -f "$HISTORY_FILE" ]] && grep -q "$REMOTE" "$HISTORY_FILE"; then
    pass "history entry saved"
else
    fail "history entry saved" "no entry in $HISTORY_FILE"
fi

# ── Test 11: Interactive — tunnel active, user declines ────────────────────
echo "[Test 11] Interactive — tunnel active, user declines disconnect"
out=$(expect -c "
    set timeout 10
    spawn $TUNNEL_SCRIPT --port $PORT --api-key $API_KEY
    expect \"Stop tunnel and switch back to local?\"
    send \"n\r\"
    expect eof
    catch wait result
" 2>&1) || true
if echo "$out" | grep -q "Tunnel remains active"; then
    pass "interactive keep tunnel"
else
    fail "interactive keep tunnel" "$out"
fi

# Verify tunnel still alive
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    pass "tunnel still alive after decline"
else
    fail "tunnel still alive after decline" "tunnel died"
fi

# ── Test 12: Interactive — tunnel active, user accepts ─────────────────────
echo "[Test 12] Interactive — tunnel active, user accepts disconnect"
out=$(expect -c "
    set timeout 10
    spawn $TUNNEL_SCRIPT --port $PORT --api-key $API_KEY
    expect \"Stop tunnel and switch back to local?\"
    send \"y\r\"
    expect eof
    catch wait result
" 2>&1) || true
if echo "$out" | grep -q "stopped\|Switched to local"; then
    pass "interactive stop tunnel"
else
    fail "interactive stop tunnel" "$out"
fi
sleep 1

# Verify tunnel is gone
if ! pgrep -f "^ssh .*${PORT}:127.0.0.1:${PORT}" >/dev/null 2>&1; then
    pass "tunnel stopped after accept"
else
    fail "tunnel stopped after accept" "tunnel still running"
    cleanup_tunnel
fi

sleep 2

# ── Test 13: --stop with active tunnel ────────────────────────────────────
echo "[Test 13] --stop with active tunnel"
sleep 20  # Let SSH rate limit reset after rapid reconnects in tests 11-12
# Reconnect (retry with exponential backoff in case of SSH rate limit)
connect_out=""
delay=5
for attempt in 1 2 3 4 5; do
    connect_out=$("$TUNNEL_SCRIPT" --port "$PORT" --api-key "$API_KEY" "$REMOTE" 2>&1) || true
    if echo "$connect_out" | grep -q "Tunnel active"; then
        break
    fi
    sleep "$delay"
    delay=$((delay * 2))
done
sleep 2
out=$("$TUNNEL_SCRIPT" --stop --port "$PORT" 2>&1) || true
if echo "$out" | grep -q "stopped"; then
    pass "--stop kills active tunnel"
else
    fail "--stop kills active tunnel" "connect: $connect_out | stop: $out"
fi
sleep 3

# ── Test 14: Interactive — history offers recent connection ───────────────
echo "[Test 14] Interactive — history offers recent connection"
out=$(expect -c "
    set timeout 20
    spawn $TUNNEL_SCRIPT --port $PORT --api-key $API_KEY
    expect {
        \"Recent connections:\" {
            expect \"Select\"
            send \"1\r\"
            expect eof
        }
        timeout {
            send_user \"TIMEOUT\\n\"
        }
    }
    catch wait result
" 2>&1) || true
if echo "$out" | grep -q "Recent connections.*${REMOTE}\|Tunnel active"; then
    pass "history offers recent connection"
elif echo "$out" | grep -q "Recent connections"; then
    pass "history offers recent connection"
else
    fail "history offers recent connection" "$out"
fi
cleanup_tunnel
sleep 5

# ── Test 15: Connect when remote llama-server is down (wrong port) ────────
echo "[Test 15] Connect when remote llama-server is down (simulated via wrong port)"
sleep 20  # Let SSH rate limit reset
out=""
delay=5
for attempt in 1 2 3 4 5; do
    out=$("$TUNNEL_SCRIPT" --port 49999 --api-key "$API_KEY" "$REMOTE" 2>&1) || true
    # "no llama-server responding" = SSH worked, port had nothing listening — SUCCESS
    if echo "$out" | grep -q "no llama-server responding"; then
        break
    fi
    # "cannot reach" = SSH rate-limited — retry with backoff
    sleep "$delay"
    delay=$((delay * 2))
done
if echo "$out" | grep -q "no llama-server responding"; then
    pass "detects remote server down"
else
    fail "detects remote server down" "$out"
fi

# ── Test 16: Interactive — no history, prompts for address ────────────────
echo "[Test 16] Interactive — no history, prompts for remote"
# Temporarily remove history
mv "$HISTORY_FILE" "${HISTORY_FILE}.bak" 2>/dev/null || true
out=$(expect -c "
    set timeout 15
    spawn $TUNNEL_SCRIPT --port $PORT --api-key $API_KEY
    expect \"Remote server\"
    send \"$REMOTE\r\"
    expect eof
    catch wait result
" 2>&1) || true
mv "${HISTORY_FILE}.bak" "$HISTORY_FILE" 2>/dev/null || true
if echo "$out" | grep -q "Tunnel active\|Remote server"; then
    pass "prompts for address when no history"
else
    fail "prompts for address when no history" "$out"
fi
cleanup_tunnel
sleep 3

# ── Summary ─────────────────────────────────────────────────────────────────
restore_history

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
echo ""
for t in "${TESTS[@]}"; do
    echo "  $t"
done

[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
