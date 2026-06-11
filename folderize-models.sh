#!/bin/bash
# Migrate flat .gguf model directory to folder-based layout.
#
# Scans a directory for .gguf files sitting directly in it (not already
# in subfolders) and groups them into per-model-family folders.
#
# Usage:
#   ./folderize-models.sh [models_dir]
#
# If models_dir is omitted, reads LLAMACPP_MODELS_DIR from config or
# falls back to /usr/local/share/llama.cpp/models.
#
# Always does a dry run first and asks for confirmation before moving.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.llama-launcher-config"
DEFAULT_MODELS_DIR="/usr/local/share/llama.cpp/models"

# ── Resolve models directory ─────────────────────────────────────────────────
if [ -n "${1:-}" ]; then
    MODELS_DIR="$1"
elif [ -f "$CONFIG_FILE" ]; then
    eval "$(cat "$CONFIG_FILE")"
    MODELS_DIR="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"
else
    MODELS_DIR="$DEFAULT_MODELS_DIR"
fi

if [ ! -d "$MODELS_DIR" ]; then
    echo "ERROR: Directory not found: $MODELS_DIR"
    exit 1
fi

echo "Scanning: $MODELS_DIR"
echo ""

# ── Find loose .gguf files (not in subfolders, not split continuations) ──────
declare -A folder_map  # file -> target folder
loose_files=()

while IFS= read -r -d '' filepath; do
    name="$(basename "$filepath")"
    loose_files+=("$name")
done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)

if [ ${#loose_files[@]} -eq 0 ]; then
    echo "No loose .gguf files found — nothing to migrate."
    exit 0
fi

echo "Found ${#loose_files[@]} loose .gguf file(s)."
echo ""

# ── Derive folder name for each file ────────────────────────────────────────
# Strategy: strip uploader prefix, quant suffix, split suffix, mmproj suffix
# to get the base model family name.
derive_folder() {
    local name="$1"

    # Strip .gguf extension
    local base="${name%.gguf}"

    # Strip split suffix: -00001-of-00002
    base="$(echo "$base" | sed -E 's/-[0-9]+-of-[0-9]+$//')"

    # Strip uploader prefix: anything_before_first_known-model-name
    # Common patterns: unsloth_, DavidAU_..._GGUF_, mistralai_, nvidia_, lovedheart_..._GGUF_
    # Heuristic: strip everything up to and including _GGUF_ if present
    if [[ "$base" == *_GGUF_* ]]; then
        base="${base##*_GGUF_}"
    # Strip simple single-word uploader prefix (word_RestOfName where Rest starts uppercase)
    elif [[ "$base" =~ ^[a-zA-Z0-9]+-?[a-zA-Z0-9]*_ ]]; then
        local after="${base#*_}"
        # Only strip if what follows looks like a model name (starts with uppercase or number)
        if [[ "$after" =~ ^[A-Z0-9] ]]; then
            base="$after"
        fi
    fi

    # Strip mmproj marker
    base="$(echo "$base" | sed -E 's/-mmproj-[A-Za-z0-9_]+$//')"

    # Strip quant suffix: common patterns like -Q8_0, -Q4_K_M, -BF16, -UD-Q6_K_XL, -IQ4_XS, etc.
    # Also strip -H-v2 style variant markers before the quant
    base="$(echo "$base" | sed -E 's/-(H-v[0-9]+-)?((UD|imat|Imatrix)-)?[A-Z]*(Q[0-9]|BF16|FP16|F32|IQ)[A-Za-z0-9_]*$//')"
    # Catch remaining -BF16, -FP16 without Q prefix
    base="$(echo "$base" | sed -E 's/-(BF16|FP16|F32)$//')"

    # Strip trailing variant suffixes that come after the base model
    # e.g., -Uncen-Hrt-NEO-CODE-MAX-imat-D_AU
    # This is too model-specific to handle generically, so we leave it.

    echo "$base"
}

# Build the mapping
declare -A groups  # folder -> list of files (newline-separated)

for name in "${loose_files[@]}"; do
    folder="$(derive_folder "$name")"
    folder_map["$name"]="$folder"
    if [ -n "${groups[$folder]+x}" ]; then
        groups["$folder"]="${groups[$folder]}"$'\n'"$name"
    else
        groups["$folder"]="$name"
    fi
done

# ── Show proposed groupings ──────────────────────────────────────────────────
echo "Proposed folder groupings:"
echo ""

# Sort folder names for display
mapfile -t sorted_folders < <(printf '%s\n' "${!groups[@]}" | sort)

for folder in "${sorted_folders[@]}"; do
    # Check if folder already exists
    exists=""
    if [ -d "$MODELS_DIR/$folder" ]; then
        exists=" (exists)"
    fi
    echo "  $folder/$exists"
    while IFS= read -r file; do
        echo "    <- $file"
    done <<< "${groups[$folder]}"
done

echo ""

# ── Let user edit groupings ──────────────────────────────────────────────────
echo "Options:"
echo "  y) Proceed with this grouping"
echo "  e) Edit — manually assign folders (one by one)"
echo "  n) Abort"
echo ""
read -rp "Choice [y/e/n]: " choice

case "$choice" in
    e|E)
        echo ""
        echo "For each file, enter the target folder name (or press Enter to accept default):"
        echo ""
        # Reset groups
        declare -A groups=()
        for name in "${loose_files[@]}"; do
            default="${folder_map[$name]}"
            read -rp "  $name -> [$default]: " custom
            folder="${custom:-$default}"
            folder_map["$name"]="$folder"
            if [ -n "${groups[$folder]+x}" ]; then
                groups["$folder"]="${groups[$folder]}"$'\n'"$name"
            else
                groups["$folder"]="$name"
            fi
        done
        echo ""
        echo "Final groupings:"
        echo ""
        mapfile -t sorted_folders < <(printf '%s\n' "${!groups[@]}" | sort)
        for folder in "${sorted_folders[@]}"; do
            echo "  $folder/"
            while IFS= read -r file; do
                echo "    <- $file"
            done <<< "${groups[$folder]}"
        done
        echo ""
        read -rp "Proceed? [y/n]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
        ;;
    y|Y)
        ;;
    *)
        echo "Aborted."
        exit 0
        ;;
esac

# ── Move files ───────────────────────────────────────────────────────────────
echo ""
echo "Moving files..."
moved=0
for name in "${loose_files[@]}"; do
    folder="${folder_map[$name]}"
    target_dir="$MODELS_DIR/$folder"
    mkdir -p "$target_dir"
    mv -v "$MODELS_DIR/$name" "$target_dir/$name"
    moved=$((moved + 1))
done

echo ""
echo "Done. Moved $moved file(s) into ${#groups[@]} folder(s)."
