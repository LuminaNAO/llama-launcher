#!/bin/bash
# Inspect / manage llama-server slot save files. Reads SLOT_SAVE_PATH from
# the same model-config that the launcher uses, or falls back to
# /mnt/storage/llama-slots.
#
# Usage:
#   slot-tools.sh list                 # list saved sessions with size + age
#   slot-tools.sh erase <id|all>       # delete one session or every file
#   slot-tools.sh inspect <id>         # show file metadata (size only; binary format)
#   slot-tools.sh hash                 # show how a session ID is computed (sha256[:16] of system + msg[0])

set -euo pipefail

DEFAULT_DIR="/mnt/storage/llama-slots"
SLOT_DIR="${LLAMA_SLOT_DIR:-$DEFAULT_DIR}"

cmd="${1:-list}"

case "$cmd" in
    list)
        if [ ! -d "$SLOT_DIR" ]; then
            echo "no slot dir at $SLOT_DIR"
            exit 0
        fi
        echo "Slot directory: $SLOT_DIR"
        printf '%-20s %-12s %s\n' "session_id" "size" "modified"
        printf '%-20s %-12s %s\n' "----------" "----" "--------"
        # shellcheck disable=SC2012
        ls -lt "$SLOT_DIR"/*.bin 2>/dev/null | awk '{
            name=$NF; sub(".*/","",name); sub("\\.bin$","",name);
            size=$5;
            unit="B"; if (size>1024) {size/=1024; unit="K"}
            if (size>1024) {size/=1024; unit="M"}
            if (size>1024) {size/=1024; unit="G"}
            printf "%-20s %8.1f%s   %s %s %s\n", name, size, unit, $6, $7, $8
        }' || true
        echo ""
        echo "Total size:"
        du -sh "$SLOT_DIR" 2>/dev/null || echo "(empty)"
        ;;
    erase)
        target="${2:-}"
        if [ -z "$target" ]; then
            echo "Usage: slot-tools.sh erase <id|all>" >&2
            exit 1
        fi
        if [ "$target" = "all" ]; then
            read -rp "Erase ALL slot files in $SLOT_DIR? [y/N] " ans
            [[ "$ans" == "y" ]] || { echo "aborted"; exit 0; }
            rm -f "$SLOT_DIR"/*.bin
            echo "erased"
        else
            file="$SLOT_DIR/${target}.bin"
            if [ ! -f "$file" ]; then echo "no such session: $target" >&2; exit 1; fi
            rm -f "$file"
            echo "erased $target"
        fi
        ;;
    inspect)
        target="${2:-}"
        file="$SLOT_DIR/${target}.bin"
        if [ ! -f "$file" ]; then echo "no such session: $target" >&2; exit 1; fi
        ls -la "$file"
        echo "(file format is opaque binary; size scales ~8 KB per cached token)"
        ;;
    hash)
        echo "Session ID = sha256(system + '\\n' + messages[0].content)[0:16]"
        echo "Computed by llama-deep-proxy on each /v1/messages request."
        echo "To compute manually for a request body:"
        echo "  jq -r '.system + \"\\n\" + (.messages[0].content // \"\")' < req.json | sha256sum | head -c 16"
        ;;
    *)
        echo "Usage: slot-tools.sh {list|erase <id|all>|inspect <id>|hash}" >&2
        exit 1
        ;;
esac
