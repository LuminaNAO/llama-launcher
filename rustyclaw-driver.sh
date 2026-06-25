#!/usr/bin/env bash
# rustyclaw-driver.sh
# Drives openclaw to iteratively build rustyclaw, monitoring for freeclaw failures.
# This script is the outer loop — it sends tasks, watches for failures,
# and surfaces diagnostics. Claude handles freeclaw fixes between turns.

set -euo pipefail

# ─── Env ─────────────────────────────────────────────────────────────────────
source ~/.nvm/nvm.sh 2>/dev/null || true
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) export PATH="$PNPM_HOME:$PATH" ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUSTYCLAW_DIR="$HOME/code/rustyclaw"
SESSION_FILE="$SCRIPT_DIR/.rustyclaw-session-id"
LOG_FILE="$SCRIPT_DIR/rustyclaw-driver.log"
LLAMA_LOG="$HOME/llama.log"

# ─── Config ──────────────────────────────────────────────────────────────────
MAX_CONSECUTIVE_FAILURES=3
TURN_TIMEOUT=0          # 0 = no timeout (openclaw maps to MAX_SAFE_TIMEOUT_MS)
THINKING_LEVEL="low"    # low keeps context lean; bump to medium/high if needed
AGENT="main"            # openclaw agent to use

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { printf '\e[32m[DRIVER]\e[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
warn()    { printf '\e[33m[DRIVER]\e[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
error()   { printf '\e[31m[DRIVER]\e[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
divider() { printf '\e[34m%s\e[0m\n' "─────────────────────────────────────────" | tee -a "$LOG_FILE"; }

ts() { date '+%Y-%m-%d %H:%M:%S'; }

gpu_stats() {
    rocm-smi --showuse --showmemuse 2>/dev/null \
        | grep -E "GPU use|GPU Memory" \
        | awk '{printf "%s ", $NF}' || echo "gpu-unavail"
}

gateway_alive() {
    openclaw health &>/dev/null
}

llama_log_tail() {
    tail -5 "$LLAMA_LOG" 2>/dev/null | grep -E "slot|task|cancel|error|timeout|stop|busy" || true
}

get_or_create_session() {
    if [[ -f "$SESSION_FILE" ]]; then
        cat "$SESSION_FILE"
    else
        # No session yet — first turn will create one
        echo ""
    fi
}

save_session() {
    echo "$1" > "$SESSION_FILE"
}

# ─── Send one turn to openclaw ────────────────────────────────────────────────
# Returns 0 on success, 1 on failure. Outputs the session ID to stdout on success.
send_turn() {
    local message="$1"
    local session_id="$2"

    local args=(
        agent
        --agent "$AGENT"
        --message "$message"
        --timeout "$TURN_TIMEOUT"
        --thinking "$THINKING_LEVEL"
        --json
    )
    [[ -n "$session_id" ]] && args+=(--session-id "$session_id")

    local output
    if ! output=$(openclaw "${args[@]}" 2>&1); then
        warn "openclaw output: $output"
        return 1
    fi

    # Extract session ID from JSON output for next turn
    local sid
    sid=$(echo "$output" | jq -r '.sessionId // empty' 2>/dev/null || true)
    if [[ -n "$sid" ]]; then
        save_session "$sid"
        echo "$sid"
    else
        echo "$session_id"
    fi
    return 0
}

# ─── Main loop ────────────────────────────────────────────────────────────────
run_task() {
    local task_num="$1"
    local message="$2"
    local consecutive_failures="${3:-0}"

    divider
    info "[$(ts)] Task $task_num starting"
    info "GPU: $(gpu_stats)"
    info "Message: ${message:0:120}..."

    # Snapshot llama.log position before the turn
    local llama_lines_before
    llama_lines_before=$(wc -l < "$LLAMA_LOG" 2>/dev/null || echo 0)

    local session_id
    session_id=$(get_or_create_session)

    # Check gateway is alive before sending
    if ! gateway_alive; then
        error "Gateway not responding. Run: openclaw gateway start"
        return 2   # 2 = gateway dead, caller should stop loop
    fi

    local turn_start
    turn_start=$(date +%s)

    local new_session_id
    if new_session_id=$(send_turn "$message" "$session_id"); then
        local elapsed=$(( $(date +%s) - turn_start ))
        info "[$(ts)] Task $task_num SUCCESS in ${elapsed}s (session: $new_session_id)"
        info "GPU after: $(gpu_stats)"

        # Show any llama.cpp events that fired during this turn
        local llama_events
        llama_events=$(tail -n +"$((llama_lines_before + 1))" "$LLAMA_LOG" 2>/dev/null \
            | grep -E "slot|task|cancel|error|timeout|stop|busy" || true)
        [[ -n "$llama_events" ]] && warn "llama.cpp events:\n$llama_events"

        return 0
    else
        local elapsed=$(( $(date +%s) - turn_start ))
        error "[$(ts)] Task $task_num FAILED after ${elapsed}s"

        # Dump llama.cpp log around the failure
        warn "llama.cpp tail at failure:"
        tail -20 "$LLAMA_LOG" 2>/dev/null | tee -a "$LOG_FILE" || true

        # Check if gateway is still alive
        if ! gateway_alive; then
            error "Gateway died during task. Run: openclaw gateway stop && openclaw gateway start"
            return 2
        fi

        return 1
    fi
}

# ─── Task definitions ─────────────────────────────────────────────────────────
# These are sent sequentially on the same session, building rustyclaw incrementally.
# Each task is small and concrete — keeps context focused.

SYSTEM_BRIEFING='You are extending rustyclaw: a pure Rust, local-only AI agent CLI that is already working.

Current state (already built and committed in /home/claude/code/rustyclaw/):
- src/main.rs — REPL entry point, env var config, --help flag
- src/http.rs — raw TcpStream HTTP client with SSE streaming
- src/sse.rs — SSE chunk parser for llama.cpp streaming format
- src/conversation.rs — Message/Conversation structs, context trimming
- src/tools.rs — bash + file read/write tool execution

STRICT RULES:
- Work ONLY in /home/claude/code/rustyclaw/ — touch nothing else
- Pure Rust std only — zero external crates in Cargo.toml dependencies
- Use std::thread for concurrency — never async/await/tokio
- Commit to git after every meaningful change
- Keep code minimal and readable — no over-engineering
- llama.cpp server: http://localhost:40801/v1, api-key: ollama-local

COMMIT MESSAGE CONVENTION (apply to every commit you make):
- Keep the existing subject line format (e.g. "feat: tool output panel")
- Append these trailer lines at the end of the message body:
    Built-with: freeclaw f1.0.3-dev
    Model: MiniMax-M2.7-UD-IQ4_XS (llama.cpp, 100k ctx q4 KV + rotor quants)
- These trailers let us attribute which model/harness built each commit.
  Earlier commits in this repo were built by Qwen3-27B; this session is MiniMax.

TUI RULES:
- Use ANSI escape codes directly — no external crates
- Terminal: raw mode via termios syscalls (libc via std::os::unix), or /dev/tty reads
- All TUI rendering must work in an 80x24 terminal minimum
- Use std::io::Write + flush() for immediate screen updates'

TASKS=(
    "Task 1: Add a TUI module skeleton.
- Create src/tui.rs with:
  - Terminal struct that saves/restores terminal state (raw mode via tcgetattr/tcsetattr using inline libc calls through std::os::unix::io)
  - enter_raw_mode() / exit_raw_mode() that disable echo and canonical mode
  - clear_screen(), move_cursor(row: u16, col: u16), hide_cursor(), show_cursor() using ANSI escapes written to stdout
  - A Rect struct { x: u16, y: u16, w: u16, h: u16 } for layout
  - get_terminal_size() using TIOCGWINSZ ioctl
- mod tui; in main.rs, test it compiles
- Commit as 'feat: tui skeleton with raw mode and ANSI helpers'"

    "Task 2: Build a scrollable message view.
- Add to tui.rs:
  - MessageView struct: renders a list of chat messages in a Rect, supports scrolling
  - render_messages(messages: &[Message], area: Rect, scroll_offset: usize) — wraps long lines, role-prefixed, distinct colors for user/assistant/tool
  - Use ANSI 256-color or basic 8-color only (no true-color dependency)
  - scroll_to_bottom() helper
- Wire it up: when the REPL renders, use MessageView to draw the conversation history
- Commit as 'feat: scrollable message view'"

    "Task 3: Build an input bar.
- Add to tui.rs:
  - InputBar struct: single-line input at the bottom of the terminal
  - Handles character insertion, backspace, left/right cursor movement, ctrl-a/ctrl-e (home/end)
  - render_input_bar(bar: &InputBar, area: Rect) draws the bar with a blinking cursor position marker
  - Returns the completed string on Enter, signals Ctrl-C/Ctrl-D for quit
- Wire into the REPL: replace stdin line-reading with InputBar
- Commit as 'feat: input bar with cursor movement'"

    "Task 4: Add a status bar.
- Add to tui.rs:
  - StatusBar struct: renders a single line at the top or bottom showing:
    - Current model name (truncated if needed)
    - Token count estimate for current conversation
    - Thinking indicator (spinner chars cycling while inference runs) driven by a std::thread
    - [TRIMMED] badge when context was trimmed last turn
  - Spinner runs in a background thread, sends updates via std::sync::mpsc to the render loop
- Integrate into the REPL main loop
- Commit as 'feat: status bar with spinner'"

    "Task 5: Layout manager — split the screen properly.
- Add to tui.rs:
  - Layout::vertical(areas: &[u16], total: Rect) -> Vec<Rect> — splits a Rect into vertical slices by percentage
  - Standard 3-zone layout: status bar (1 line, top) + message view (fills remaining) + input bar (3 lines, bottom)
  - Handle terminal resize: catch SIGWINCH, re-query terminal size, re-render
- Refactor the REPL to use the layout manager for all rendering
- Commit as 'feat: layout manager and resize handling'"

    "Task 6: Tool output panel.
- Add to tui.rs:
  - ToolPanel: a collapsible overlay that shows the last tool call + result
  - When a tool executes, show the panel for 2 seconds then auto-dismiss (via std::thread + mpsc)
  - Toggle with Ctrl-T to keep it pinned open
  - Renders over the message view with a box border (ASCII box drawing: +, -, |)
- Integrate into the tool execution path in main.rs / tools.rs
- Commit as 'feat: tool output panel'"

    "Task 7: Session persistence.
- Create src/session.rs:
  - save_session(conv: &Conversation, path: &str) -> Result<(), String> — serialize to newline-delimited JSON
  - load_session(path: &str) -> Result<Conversation, String> — deserialize back
  - Default session path: ~/.rustyclaw/session.json (create dir if needed)
- On startup: load last session if it exists, show message count in status bar
- On clean exit (Ctrl-D): save session
- Add --no-resume flag to start fresh
- Commit as 'feat: session persistence'"

    "Task 8: Slash commands.
- Add command dispatch to the input bar: lines starting with / are commands, not messages
- Implement:
  - /clear — clear conversation history, re-render
  - /model <name> — switch model mid-session (re-queries /v1/models to validate)
  - /save <path> — save session to custom path
  - /tokens — show token count breakdown per message in the tool panel
  - /help — show available commands in the tool panel
- Commit as 'feat: slash commands'"

    "Task 9: Multiline input mode.
- Extend InputBar:
  - Alt-Enter or Ctrl-J inserts a newline (multiline mode)
  - InputBar grows up to 6 lines max, message view shrinks accordingly via layout
  - Visual indicator showing line count when in multiline mode
  - Enter on blank last line submits; Escape cancels multiline and collapses
- Update layout manager to handle dynamic input bar height
- Commit as 'feat: multiline input mode'"

    "Task 10: Polish, integration test, final commit.
- Run cargo build --release and fix any warnings
- Test the full TUI flow end-to-end: start rustyclaw, send a message, get a streaming response, use a tool, send a slash command, save and reload session
- Fix any rendering glitches found
- Update README.md to describe TUI features and keybindings
- Final commit: 'feat: complete TUI for v0.2.0'"

    "Task 11: Actually WIRE the TUI into main.rs.

IMPORTANT CONTEXT: Current main.rs uses plain std::io::stdin().read_line() — a line-based REPL.
Tasks 1-10 built a TUI framework (Terminal, InputBar, MessageView, StatusBar, Layout) but
NONE of it is instantiated. cargo build --release emits ~45 warnings, mostly 'struct never
constructed' on these exact TUI types. This is your real task: make them actually used.

Required changes in src/main.rs:
- Import Terminal, InputBar, MessageView, StatusBar, Layout, Rect from tui
- Replace stdin().read_line() with InputBar::read_input()
- Wrap the REPL loop in Terminal::enter_raw_mode() + exit_raw_mode() on exit
- Use Layout::standard() (or similar) to compute: 1-line status bar, scrollable message view filling middle, 3-line input bar at bottom
- Render MessageView each frame as conversation updates
- Render StatusBar showing model name, token count, trimmed-badge
- Wire streaming token callbacks to push into MessageView live

Quality gate: after your change, cargo build --release must show ≤5 warnings.

Keep existing features working: slash commands, session persistence, tool panel, multiline input.

Commit as 'feat: wire TUI into REPL loop'"

    "Task 12: Add edit_file tool.

Currently src/tools.rs has bash, read_file, write_file but NO edit_file. freeclaw/openclaw
agents rely heavily on edit for precise patches. Add it.

Required:
- Add to src/tools.rs: edit_file(path, old_string, new_string) -> ToolResult
- Semantics: read file, verify old_string appears EXACTLY ONCE, replace with new_string, write back
- Errors: old_string not found, old_string found >1 times, file doesn't exist, write failed
- Register the tool in the tool definitions so the model can call it
- Update the system prompt (format_system_prompt in main.rs) to describe edit_file

Test from the rustyclaw REPL: ask it to edit a file via edit_file and verify the change landed.

Commit as 'feat: add edit_file tool for precise patches'"

    "Task 13: Context management — auto-summarize when approaching limit.

Currently conversation.rs has basic context trimming (drop oldest messages). Upgrade to
summarization: when token count > 80% of LLAMA_CONTEXT, call the LLM to summarize the
oldest half of the conversation into a single system-style message, then replace those
messages with the summary. Keeps session coherent past the context cap.

Required:
- Add fn summarize_and_compact(&mut self, http_client, model) to Conversation
- Trigger it from main loop when token estimate crosses 80% threshold
- Use a separate HTTP call with a 'summarize this conversation in under 500 tokens' prompt
- Show a [COMPACTED] badge in the status bar after it fires
- Persist compacted state in session file

Commit as 'feat: auto-summarize context near limit'"

    "Task 14: Config file support.

Currently env vars control everything. Add ~/.config/rustyclaw/config.toml support
(parse manually with std — zero deps). TOML keys:

    model = \"...\"
    context_window = 102400
    host = \"localhost\"
    port = 40801
    api_key = \"ollama-local\"
    system_prompt = \"...\"    # optional override
    allowed_tools = [\"bash\", \"read_file\", \"write_file\", \"edit_file\"]

Precedence: CLI flags > env vars > config file > built-in defaults. Create the directory
if missing on first run with sensible defaults.

Commit as 'feat: config file at ~/.config/rustyclaw/config.toml'"

    "Task 15: Final polish + v0.2.0 release.

- Fix remaining cargo warnings (target: zero warnings on cargo build --release)
- Fix the improper_ctypes warning — replace the empty 'struct libc_c_void {}' in tui.rs
  with the proper std::ffi::c_void (or a zero-sized type with explicit documentation)
- Update README.md with: new tools, config file location, TUI keybindings, example
  agent session transcript
- Bump version in Cargo.toml to 0.2.0
- Add a CHANGELOG.md capturing everything in v0.1 → v0.2

Commit as 'chore: v0.2.0 release — clean build, updated docs'"
)

# ─── Entry point ──────────────────────────────────────────────────────────────
main() {
    local start_task="${1:-1}"
    local consecutive_failures=0

    info "rustyclaw-driver starting. Log: $LOG_FILE"
    info "Session file: $SESSION_FILE"
    info "Tasks: ${#TASKS[@]} total, starting from task $start_task"
    divider

    local task_num="$start_task"
    local total="${#TASKS[@]}"

    # Prepend SYSTEM_BRIEFING to the first task we send this run so the model
    # has project context regardless of whether we start from task 1 or resume
    # mid-sequence. Subsequent tasks reuse the session-id for continuity.
    local sent_briefing=0

    while [[ "$task_num" -le "$total" ]]; do
        local i=$(( task_num - 1 ))
        local message="${TASKS[$i]}"
        if [[ "$sent_briefing" -eq 0 ]]; then
            message="$SYSTEM_BRIEFING

$message"
            sent_briefing=1
        fi

        local result=0
        run_task "$task_num" "$message" || result=$?

        if [[ "$result" -eq 2 ]]; then
            error "Gateway is dead — stopping. Fix and resume with: $0 $task_num"
            exit 1
        elif [[ "$result" -ne 0 ]]; then
            (( consecutive_failures++ )) || true
            warn "Consecutive failures: $consecutive_failures / $MAX_CONSECUTIVE_FAILURES"
            if [[ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]]; then
                error "Circuit breaker: $MAX_CONSECUTIVE_FAILURES consecutive failures."
                error "Resume after fixing with: $0 $task_num"
                exit 1
            fi
            warn "Retrying task $task_num in 5s..."
            sleep 5
            # Don't increment — retry same task
        else
            consecutive_failures=0
            (( task_num++ ))
            sleep 3
        fi
    done

    info "All tasks complete! rustyclaw should be built."
    info "Check: ls /home/claude/code/rustyclaw/"
}

main "${@}"
