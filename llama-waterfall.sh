#!/bin/bash

# llama-waterfall — thin wrapper around llama-waterfall.mjs so the proxy is
# invocable as a plain shell command, matching the other llama-* tools.
#
# Usage (all args pass straight through, see `llama-waterfall --help`):
#   llama-waterfall                    # start server if needed + open the TUI
#                                      # (q closes what it opened, Q stops all)
#   llama-waterfall stop               # stop the server and any attached TUIs
#   llama-waterfall serve [port]       # run just the failover proxy
#   llama-waterfall tui                # attach-only vim-keyed dashboard
#   llama-waterfall status [--json]    # plus pin/disable/enable/add/remove/
#                                      # move/edit/write/reload/test, each
#                                      # accepting --table agent|subagent
#
# Two routing tables: [agent] on :40800 and [subagent] on :40810.
# Full design: docs/WATERFALL.md

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
case "$SELF_DIR" in
    /usr/bin|/usr/local/bin|/bin)
        # Packaged install: the .mjs lives in the launcher lib dir
        MJS="${LLAMA_LAUNCHER_LIB_DIR:-/usr/lib/llama-launcher}/llama-waterfall.mjs"
        ;;
    *)
        # Repo checkout (or symlink into ~/.local/bin resolved back to it)
        MJS="$SELF_DIR/llama-waterfall.mjs"
        ;;
esac

if [[ ! -f "$MJS" ]]; then
    echo "llama-waterfall: cannot find llama-waterfall.mjs (looked at $MJS)" >&2
    exit 1
fi

exec node "$MJS" "$@"
