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
        echo "Slot directory: $SLOT_DIR (per-quant subdirs)"
        # Walk per-quant subdirectories. Each subdir corresponds to one .gguf
        # file's slot pool; sessions inside are KV-compatible only with that quant.
        for sub in "$SLOT_DIR"/*/; do
            [ -d "$sub" ] || continue
            quant_name=$(basename "$sub")
            n=$(find "$sub" -maxdepth 1 -name "*.bin" -type f 2>/dev/null | wc -l)
            [ "$n" -eq 0 ] && continue
            echo ""
            echo "── $quant_name ──"
            printf '  %-20s %-12s %s\n' "session_id" "size" "modified"
            # shellcheck disable=SC2012
            ls -lt "$sub"/*.bin 2>/dev/null | awk '{
                name=$NF; sub(".*/","",name); sub("\\.bin$","",name);
                size=$5; unit="B";
                if (size>1024) {size/=1024; unit="K"}
                if (size>1024) {size/=1024; unit="M"}
                if (size>1024) {size/=1024; unit="G"}
                printf "  %-20s %8.1f%s   %s %s %s\n", name, size, unit, $6, $7, $8
            }'
        done
        # Surface any flat-layout legacy files at the root
        flat=$(find "$SLOT_DIR" -maxdepth 1 -name "*.bin" -type f 2>/dev/null | wc -l)
        if [ "$flat" -gt 0 ]; then
            echo ""
            echo "── (legacy flat layout — $flat files at root) ──"
            find "$SLOT_DIR" -maxdepth 1 -name "*.bin" -type f -exec ls -lh {} +
        fi
        echo ""
        echo "Total size:"
        du -sh "$SLOT_DIR" 2>/dev/null || echo "(empty)"
        ;;
    erase)
        target="${2:-}"
        if [ -z "$target" ]; then
            echo "Usage: slot-tools.sh erase <id|all|<quant>/all>" >&2
            exit 1
        fi
        if [ "$target" = "all" ]; then
            read -rp "Erase ALL slot files under $SLOT_DIR (every quant)? [y/N] " ans
            [[ "$ans" == "y" ]] || { echo "aborted"; exit 0; }
            find "$SLOT_DIR" -name "*.bin" -delete
            echo "erased"
        elif [[ "$target" == */all ]]; then
            quant="${target%/all}"
            sub="$SLOT_DIR/$quant"
            if [ ! -d "$sub" ]; then echo "no such quant dir: $quant" >&2; exit 1; fi
            read -rp "Erase ALL slot files in $sub? [y/N] " ans
            [[ "$ans" == "y" ]] || { echo "aborted"; exit 0; }
            rm -f "$sub"/*.bin
            echo "erased $quant"
        else
            # Find this session id across all quant subdirs
            matches=( "$SLOT_DIR"/*/"${target}.bin" )
            found=0
            for m in "${matches[@]}"; do
                [ -f "$m" ] || continue
                rm -f "$m"; echo "erased $m"; found=1
            done
            if [ "$found" -eq 0 ]; then
                echo "no such session: $target (search rooted at $SLOT_DIR/*/)" >&2
                exit 1
            fi
        fi
        ;;
    inspect)
        target="${2:-}"
        # Find session in any quant subdir
        matches=( "$SLOT_DIR"/*/"${target}.bin" )
        found=0
        for m in "${matches[@]}"; do
            [ -f "$m" ] || continue
            ls -la "$m"; found=1
        done
        if [ "$found" -eq 0 ]; then
            echo "no such session: $target" >&2
            exit 1
        fi
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
