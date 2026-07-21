#!/bin/bash

# llama-waterfall — thin wrapper around llama-waterfall.mjs so the proxy is
# invocable as a plain shell command, matching the other llama-* tools.
#
# Usage (all args pass straight through, see `llama-waterfall` with no args):
#   llama-waterfall serve 40800        # run the failover proxy
#   llama-waterfall tui                # vim-keyed dashboard
#   llama-waterfall status [--json]    # plus pin/disable/enable/add/remove/
#                                      # move/edit/write/reload/test
#
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
