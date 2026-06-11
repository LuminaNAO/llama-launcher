#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TARGET="$SCRIPT_DIR/llama-server-launcher.sh"

if [[ ! -x "$TARGET" ]]; then
    echo "❌ Launcher not found or not executable: $TARGET"
    exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
    LINK_DIR="/usr/local/bin"
else
    LINK_DIR="$HOME/.local/bin"
    mkdir -p "$LINK_DIR"
fi
LINK="$LINK_DIR/llama-launcher"

if [[ -e "$LINK" || -L "$LINK" ]]; then
    if [[ -L "$LINK" && "$(readlink -f "$LINK")" == "$TARGET" ]]; then
        echo "✅ Already installed: $LINK -> $TARGET"
    else
        echo "⚠️  $LINK exists and points elsewhere (or is a regular file)."
        read -rp "Overwrite? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
        ln -sfn "$TARGET" "$LINK"
        echo "✅ Updated: $LINK -> $TARGET"
    fi
else
    ln -s "$TARGET" "$LINK"
    echo "✅ Installed: $LINK -> $TARGET"
fi

case ":$PATH:" in
    *":$LINK_DIR:"*) ;;
    *)
        echo ""
        echo "⚠️  $LINK_DIR is not on your PATH."
        echo "    Add this to your shell rc:"
        echo "      export PATH=\"$LINK_DIR:\$PATH\""
        ;;
esac

echo ""
echo "Run:  llama-launcher        # interactive"
echo "      llama-launcher stop   # graceful shutdown"
