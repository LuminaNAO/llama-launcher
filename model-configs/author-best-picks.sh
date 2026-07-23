# Author-maintained first-install recommendation.
#
# To replace the initial recommendation later, update these values and add the
# matching model-configs/<model>.<tune>.yaml file.
AUTHOR_BEST_PICK_NAME="Ornith-1.0-35B MXFP4 MTP 5090 coding"
AUTHOR_BEST_PICK_REPO="s-batman/Ornith-1.0-35B-NVFP4-MTP-GGUF"
AUTHOR_BEST_PICK_GGUF="ornith-1.0-35b-MXFP4_MOE-MTP.gguf"
AUTHOR_BEST_PICK_TUNE="Ornith-1.0-35B-NVFP4-MTP-GGUF.32gb-mxfp4-mtp-draft-coding-v1.yaml"

# Hardware-aware override: AMD Strix Halo (gfx1151 / Ryzen AI MAX APUs).
# Validated on a Ryzen AI MAX+ 395 / Radeon 8060S: Qwen3.6-27B-MTP
# UD-Q4_K_XL with the Vulkan coding tune (MTP draft depth 5) is the best
# speed/quality pick on this hardware. The tune declares
# RECOMMENDED_BACKEND=vulkan; the launcher warns if the selected build
# lacks the Vulkan backend.
_author_pick_is_strix_halo() {
    if command -v rocminfo >/dev/null 2>&1 && rocminfo 2>/dev/null | grep -q "gfx1151"; then
        return 0
    fi
    if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi "strix halo"; then
        return 0
    fi
    grep -qi "Ryzen AI MAX" /proc/cpuinfo 2>/dev/null
}
if _author_pick_is_strix_halo; then
    AUTHOR_BEST_PICK_NAME="Qwen3.6-27B-MTP Strix Halo Vulkan coding"
    AUTHOR_BEST_PICK_REPO="unsloth/Qwen3.6-27B-MTP-GGUF"
    AUTHOR_BEST_PICK_GGUF="Qwen3.6-27B-UD-Q4_K_XL.gguf"
    AUTHOR_BEST_PICK_TUNE="Qwen3.6-27B-MTP.64gb-q4-140k-coding-v2-vulkan.yaml"
fi
unset -f _author_pick_is_strix_halo
