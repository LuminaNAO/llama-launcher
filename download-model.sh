#!/bin/bash
# Download GGUF models from HuggingFace with interactive quant selection.
#
# Usage:
#   ./download-model.sh <huggingface-url-or-repo>
#
# Examples:
#   ./download-model.sh https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF
#   ./download-model.sh unsloth/gemma-4-26B-A4B-it-GGUF
#
# Features:
#   - Lists available quants with sizes
#   - Auto-downloads mmproj/audio projection files
#   - Handles split models (multi-part .gguf)
#   - Creates proper folder structure for llama-server-launcher
#   - Resume support and per-file progress bars

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.llama-launcher-config"
DEFAULT_MODELS_DIR="/usr/local/share/llama.cpp/models"
TMPDIR="${TMPDIR:-/tmp}"
PARSE_FILE="$(mktemp "$TMPDIR/download-model.XXXXXX.json")"
trap 'rm -f "$PARSE_FILE"' EXIT

# ── Parse input ──────────────────────────────────────────────────────────────
REPO_INPUT="${1:-}"
if [ -z "$REPO_INPUT" ]; then
    echo "Usage: download-model.sh <huggingface-url-or-repo>"
    echo ""
    echo "Examples:"
    echo "  ./download-model.sh https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF"
    echo "  ./download-model.sh unsloth/gemma-4-26B-A4B-it-GGUF"
    exit 1
fi

# Normalize: strip URL prefix to get owner/repo
REPO="$REPO_INPUT"
REPO="${REPO#https://huggingface.co/}"
REPO="${REPO#http://huggingface.co/}"
REPO="${REPO%/}"
REPO="$(echo "$REPO" | sed -E 's|/tree/.*||')"

if ! [[ "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
    echo "ERROR: Invalid repo format: $REPO"
    echo "Expected: owner/repo (e.g., unsloth/gemma-4-26B-A4B-it-GGUF)"
    exit 1
fi

REPO_NAME="${REPO#*/}"

echo "Repository: $REPO"
echo ""

# ── Resolve models directory ────────────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
    eval "$(cat "$CONFIG_FILE")"
fi
MODELS_DIR="${LLAMACPP_MODELS_DIR:-$DEFAULT_MODELS_DIR}"

if [ ! -d "$MODELS_DIR" ]; then
    echo "ERROR: Models directory not found: $MODELS_DIR"
    echo "Set LLAMACPP_MODELS_DIR in $CONFIG_FILE"
    exit 1
fi

# ── HuggingFace auth (optional, for gated models) ───────────────────────────
HF_TOKEN="${HF_TOKEN:-}"
if [ -z "$HF_TOKEN" ] && [ -f "$HOME/.cache/huggingface/token" ]; then
    HF_TOKEN="$(cat "$HOME/.cache/huggingface/token")"
fi

hf_curl() {
    if [ -n "$HF_TOKEN" ]; then
        curl -sf -H "Authorization: Bearer $HF_TOKEN" "$@"
    else
        curl -sf "$@"
    fi
}

# ── Fetch file listing ──────────────────────────────────────────────────────
echo "Fetching file list..."

API_URL="https://huggingface.co/api/models/${REPO}/tree/main"
ROOT_FILES="$(hf_curl "$API_URL")" || {
    echo "ERROR: Could not fetch repo. Check the URL and try again."
    echo "  API: $API_URL"
    exit 1
}

# Check for subdirectories (some repos put BF16/FP16 splits in subdirs)
SUBDIRS=()
while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    SUBDIRS+=("$dir")
done < <(echo "$ROOT_FILES" | python3 -c "
import json, sys
for f in json.load(sys.stdin):
    if f['type'] == 'directory':
        print(f['path'])
" 2>/dev/null)

# Fetch subdir contents and merge
ALL_FILES="$ROOT_FILES"
for subdir in "${SUBDIRS[@]}"; do
    SUBDIR_FILES="$(hf_curl "${API_URL}/${subdir}" 2>/dev/null)" || continue
    ALL_FILES="$(python3 -c "
import json, sys
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
print(json.dumps(a + b))
" "$ALL_FILES" "$SUBDIR_FILES")"
done

# ── Parse into categories and write to temp file ────────────────────────────
echo "$ALL_FILES" | python3 -c "
import json, sys, re

files = json.load(sys.stdin)

quants = []
splits = {}
projections = []

for f in files:
    if f['type'] != 'file':
        continue
    path = f['path']
    name = path.split('/')[-1]
    size = f.get('size', 0)

    if not name.endswith('.gguf'):
        continue

    # Projection files (mmproj, audio)
    if 'mmproj' in name.lower() or 'audio' in name.lower() or 'projector' in name.lower():
        projections.append({'path': path, 'name': name, 'size': size})
        continue

    # Split files: name-NNNNN-of-NNNNN.gguf
    split_match = re.match(r'^(.*)-(\d+)-of-(\d+)\.gguf$', name)
    if split_match:
        base = split_match.group(1)
        part = int(split_match.group(2))
        total = int(split_match.group(3))
        dir_prefix = '/'.join(path.split('/')[:-1])
        key = f'{dir_prefix}/{base}' if dir_prefix else base
        if key not in splits:
            splits[key] = {'base': base, 'total': total, 'parts': [], 'total_size': 0}
        splits[key]['parts'].append({'path': path, 'name': name, 'size': size, 'part': part})
        splits[key]['total_size'] += size
        continue

    quants.append({'path': path, 'name': name, 'size': size})

# Build selectable items list
items = []
for q in quants:
    items.append({
        'type': 'single',
        'label': q['name'],
        'size': q['size'],
        'files': [{'path': q['path'], 'size': q['size']}]
    })
for key, s in sorted(splits.items()):
    parts_sorted = sorted(s['parts'], key=lambda p: p['part'])
    label = f\"{s['base']} [{s['total']} parts]\"
    items.append({
        'type': 'split',
        'label': label,
        'size': s['total_size'],
        'files': [{'path': p['path'], 'size': p['size']} for p in parts_sorted]
    })

items.sort(key=lambda x: x['size'])

json.dump({'items': items, 'projections': projections}, open(sys.argv[1], 'w'))
" "$PARSE_FILE"

# ── Read counts ──────────────────────────────────────────────────────────────
read -r ITEM_COUNT PROJ_COUNT < <(python3 -c "
import json
d = json.load(open('$PARSE_FILE'))
print(len(d['items']), len(d['projections']))
")

if [ "$ITEM_COUNT" -eq 0 ]; then
    echo "ERROR: No .gguf model files found in this repo."
    exit 1
fi

# ── Display available quants ─────────────────────────────────────────────────
echo ""
echo "Available quants:"
echo ""

python3 -c "
import json
d = json.load(open('$PARSE_FILE'))
for i, item in enumerate(d['items']):
    size_gb = item['size'] / (1024**3)
    parts = ''
    if item['type'] == 'split':
        n = len(item['files'])
        parts = f'  [{n} parts]'
    print(f'  {i+1:2d}) {item[\"label\"]:60s} {size_gb:8.2f} GB{parts}')
"

if [ "$PROJ_COUNT" -gt 0 ]; then
    echo ""
    echo "Projection files (auto-downloaded with model):"
    python3 -c "
import json
d = json.load(open('$PARSE_FILE'))
for p in d['projections']:
    size_gb = p['size'] / (1024**3)
    print(f'   + {p[\"name\"]:60s} {size_gb:8.2f} GB')
"
fi

echo ""

# ── Select quant(s) ─────────────────────────────────────────────────────────
read -rp "Select quant(s) [1-${ITEM_COUNT}, or comma-separated]: " selection

selected_indices=()
IFS=',' read -ra sel_parts <<< "$selection"
for part in "${sel_parts[@]}"; do
    part="$(echo "$part" | tr -d ' ')"
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
            selected_indices+=("$((i-1))")
        done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
        selected_indices+=("$((part-1))")
    else
        echo "ERROR: Invalid selection: $part"
        exit 1
    fi
done

# ── Derive folder name ──────────────────────────────────────────────────────
FOLDER_NAME="$REPO_NAME"
FOLDER_NAME="${FOLDER_NAME%-GGUF}"
FOLDER_NAME="${FOLDER_NAME%-gguf}"

TARGET_DIR="$MODELS_DIR/$FOLDER_NAME"

echo ""
echo "Target folder: $TARGET_DIR"

if [ -d "$TARGET_DIR" ]; then
    echo "  (folder exists — files will be added to it)"
fi

read -rp "Proceed? [y/n]: " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

mkdir -p "$TARGET_DIR"

# ── Download function ────────────────────────────────────────────────────────
download_file() {
    local remote_path="$1"
    local local_path="$2"
    local remote_size="$3"
    local filename="$(basename "$local_path")"

    if [ -f "$local_path" ]; then
        local local_size
        local_size="$(stat -c%s "$local_path" 2>/dev/null || echo 0)"
        if [ "$local_size" -eq "$remote_size" ]; then
            echo "  ✓ $filename (already downloaded)"
            return 0
        else
            echo "  ↻ $filename (resuming...)"
        fi
    else
        echo "  ↓ $filename"
    fi

    local url="https://huggingface.co/${REPO}/resolve/main/${remote_path}"

    if [ -n "$HF_TOKEN" ]; then
        curl -L -C - --progress-bar \
            -H "Authorization: Bearer $HF_TOKEN" \
            -o "$local_path" \
            "$url"
    else
        curl -L -C - --progress-bar \
            -o "$local_path" \
            "$url"
    fi
}

# ── Download selected quants ─────────────────────────────────────────────────
echo ""
echo "Downloading..."
echo ""

for idx in "${selected_indices[@]}"; do
    # Extract item details from parse file
    item_data="$(python3 -c "
import json, sys
d = json.load(open('$PARSE_FILE'))
idx = $idx
if idx < 0 or idx >= len(d['items']):
    print('ERROR')
    sys.exit(1)
item = d['items'][idx]
print(item['label'])
for f in item['files']:
    print(f['path'] + '\t' + str(f['size']))
")" || { echo "ERROR: Invalid selection index: $((idx+1))"; continue; }

    item_label="$(head -1 <<< "$item_data")"
    echo "── $item_label ──"

    # Download each file
    tail -n +2 <<< "$item_data" | while IFS=$'\t' read -r file_path file_size; do
        file_name="$(basename "$file_path")"
        download_file "$file_path" "$TARGET_DIR/$file_name" "$file_size"
    done
    echo ""
done

# ── Download projection files ────────────────────────────────────────────────
if [ "$PROJ_COUNT" -gt 0 ]; then
    echo "── Projection files ──"

    if [ "$PROJ_COUNT" -gt 1 ]; then
        echo ""
        echo "Multiple projection files available:"
        python3 -c "
import json
d = json.load(open('$PARSE_FILE'))
for i, p in enumerate(d['projections']):
    size_gb = p['size'] / (1024**3)
    print(f'  {i+1}) {p[\"name\"]:50s} {size_gb:.2f} GB')
"
        echo "  a) All"
        echo ""
        read -rp "Select [1-${PROJ_COUNT}, comma-separated, or a for all]: " proj_sel

        if [[ "$proj_sel" == "a" || "$proj_sel" == "A" ]]; then
            proj_indices=()
            for ((i=0; i<PROJ_COUNT; i++)); do proj_indices+=("$i"); done
        else
            proj_indices=()
            IFS=',' read -ra pparts <<< "$proj_sel"
            for pp in "${pparts[@]}"; do
                pp="$(echo "$pp" | tr -d ' ')"
                proj_indices+=("$((pp-1))")
            done
        fi
    else
        proj_indices=(0)
    fi

    for pi in "${proj_indices[@]}"; do
        proj_data="$(python3 -c "
import json
d = json.load(open('$PARSE_FILE'))
p = d['projections'][$pi]
print(p['path'] + '\t' + str(p['size']))
")"
        proj_path="${proj_data%%$'\t'*}"
        proj_size="${proj_data##*$'\t'}"
        proj_name="$(basename "$proj_path")"

        download_file "$proj_path" "$TARGET_DIR/$proj_name" "$proj_size"
    done
    echo ""
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo "Done!"
echo ""
echo "  Folder: $TARGET_DIR"
echo "  Files:"
ls -lh "$TARGET_DIR"/*.gguf 2>/dev/null | awk '{print "    " $NF " (" $5 ")"}'
echo ""
echo "  Launch with: ./llama-server-launcher.sh"
