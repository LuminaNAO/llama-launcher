#!/bin/bash
# Build llama.cpp in the builds/ directory
# Usage: build-llamacpp.sh <build-type> [gpu-arch]
#
# <build-type> is <backend>[-<tag>], where <backend> ∈ {cpu,rocm,vulkan,cuda,metal}.
# The optional -tag suffix selects a parallel output directory under builds/
# so experimental variants of the same backend can coexist.
#   ./build-llamacpp.sh rocm           # -> builds/rocm (default mainline source)
#   ./build-llamacpp.sh rocm-test      # -> builds/rocm-test
#   ./build-llamacpp.sh cpu            # -> builds/cpu
#
# Run interactively, the script asks which server variant to build
# (llama-hdd.cpp, llama-rocmfpx-hdd, or vanilla llama.cpp) and offers to
# clone / paru -S whatever is missing, and to install missing build deps.
# rocmfpx-hdd builds are staged as builds/<backend>-rocmfpx-hdd so they
# never clobber stock backend builds. Non-interactive runs keep the silent
# llama-hdd-first defaults.
#
# To build from a non-default llama.cpp source tree,
# set LLAMACPP_SRC:
#   LLAMACPP_SRC=/path/to/llama.cpp ./build-llamacpp.sh rocm-test
#
# GPU arch is auto-detected for ROCm builds but can be overridden:
#   ./build-llamacpp.sh rocm gfx1100    # Force RX 7900 series target
#   ./build-llamacpp.sh rocm gfx1151    # Force Strix Halo target
#
# For CUDA builds, compute capability is auto-detected but can be overridden:
#   ./build-llamacpp.sh cuda            # Auto-detect NVIDIA GPU
#   ./build-llamacpp.sh cuda 89         # Force Ada Lovelace (RTX 4090)
#
# Supported AMD GPU targets:
#   gfx1100  — RDNA 3   (RX 7900 XTX/XT/GRE)
#   gfx1101  — RDNA 3   (RX 7800 XT / 7700 XT)
#   gfx1102  — RDNA 3   (RX 7600)
#   gfx1150  — RDNA 3.5 (Strix Point)
#   gfx1151  — RDNA 3.5 (Strix Halo)
#   gfx942   — CDNA 3   (MI300)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
case "$SCRIPT_DIR" in
    /usr/bin|/usr/local/bin|/bin)
        ROOT_DIR="${LLAMA_LAUNCHER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/llama-launcher}"
        PACKAGED_INSTALL=1
        ;;
    *)
        ROOT_DIR="$SCRIPT_DIR"
        PACKAGED_INSTALL=0
        ;;
esac
DEFAULT_LLAMACPP_DIR="$(dirname "$ROOT_DIR")/llama.cpp"
DEFAULT_LLAMAHDD_DIR="$(dirname "$ROOT_DIR")/llama-hdd.cpp"

# The llama-rocmfpx-hdd fork (ROCmFP4/MTP fork + the hdd-cache sidecar) is
# the only tree that can load ROCmFP4-quantized models. Its ggml/rocmfpx/
# directory is unique to it; name/remote checks cover trees without it built.
is_rocmfpx_hdd_src() {
    [ -d "$1/ggml/rocmfpx" ] && return 0
    case "$(basename "$(realpath "$1" 2>/dev/null || echo "$1")")" in
        *rocmfpx*) return 0 ;;
    esac
    git -C "$1" remote get-url origin 2>/dev/null | grep -q "rocmfpx"
}

# The llama-hdd fork carries the flags the launcher tunes expect (-dio,
# --slot-save-max-checkpoints, --checkpoint-min-step); a vanilla checkout
# builds fine but produces a server that rejects them. Match by checkout
# name/remote first, then by an hdd-only source marker for renamed trees.
# llama-rocmfpx-hdd trees carry those flags too, so that check must win.
is_llama_hdd_src() {
    is_rocmfpx_hdd_src "$1" && return 1
    case "$(basename "$(realpath "$1" 2>/dev/null || echo "$1")")" in
        *llama-hdd*) return 0 ;;
    esac
    git -C "$1" remote get-url origin 2>/dev/null | grep -q "llama-hdd" && return 0
    grep -qs -- "slot-save-max-checkpoints" "$1/common/arg.cpp"
}

ldconfig_has() {
    # Avoid grep -q in a pipe under pipefail: grep can exit early after a
    # match, SIGPIPE ldconfig, and make a present library look missing.
    local needle="$1"
    ldconfig -p 2>/dev/null | awk -v needle="$needle" 'index($0, needle) { found=1 } END { exit found ? 0 : 1 }'
}

spirv_headers_config_found() {
    local dir prefix
    local dirs=(
        /usr/share/cmake/SPIRV-Headers
        /usr/lib/cmake/SPIRV-Headers
        /usr/lib/x86_64-linux-gnu/cmake/SPIRV-Headers
        /usr/local/share/cmake/SPIRV-Headers
        /usr/local/lib/cmake/SPIRV-Headers
    )

    if [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
        IFS=':' read -r -a prefixes <<< "$CMAKE_PREFIX_PATH"
        for prefix in "${prefixes[@]}"; do
            [ -n "$prefix" ] || continue
            dirs+=(
                "$prefix/share/cmake/SPIRV-Headers"
                "$prefix/lib/cmake/SPIRV-Headers"
                "$prefix/lib/x86_64-linux-gnu/cmake/SPIRV-Headers"
            )
        done
    fi

    for dir in "${dirs[@]}"; do
        [ -f "$dir/SPIRV-HeadersConfig.cmake" ] && return 0
        [ -f "$dir/spirv-headers-config.cmake" ] && return 0
    done

    return 1
}

nvcc_supported_cuda_archs() {
    command -v nvcc >/dev/null 2>&1 || return 0
    nvcc --list-gpu-arch 2>/dev/null \
        | sed -n 's/^compute_\([0-9][0-9a-z]*\)$/\1/p' \
        | sort -uV
}

nvcc_supports_cuda_arch() {
    local arch="$1"
    [ "$arch" = "native" ] && return 0
    nvcc_supported_cuda_archs | awk -v arch="$arch" '$0 == arch { found=1 } END { exit found ? 0 : 1 }'
}

nvcc_best_cuda_arch_for() {
    local requested="$1"
    local best=""
    local arch
    [ "$requested" = "native" ] && { printf '%s\n' "$requested"; return 0; }
    while IFS= read -r arch; do
        [ -n "$arch" ] || continue
        [ "$arch" = "$requested" ] && { printf '%s\n' "$arch"; return 0; }
        if [[ "$requested" =~ ^[0-9]+$ && "$arch" =~ ^[0-9]+$ ]] && [ "$arch" -lt "$requested" ]; then
            best="$arch"
        fi
    done < <(nvcc_supported_cuda_archs)
    [ -n "$best" ] && printf '%s\n' "$best"
}

# Find an installed CUDA toolkit whose nvcc supports the requested arch when
# the one on PATH doesn't (e.g. distro nvcc 12.x vs /usr/local/cuda 13.x).
nvcc_alternate_supporting() {
    local cap="$1" nv real seen="" path_nvcc
    path_nvcc="$(realpath "$(command -v nvcc 2>/dev/null || echo /nonexistent)" 2>/dev/null || true)"
    for nv in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc /opt/cuda/bin/nvcc; do
        [ -x "$nv" ] || continue
        real="$(realpath "$nv" 2>/dev/null || echo "$nv")"
        case " $seen " in *" $real "*) continue ;; esac
        seen="$seen $real"
        [ "$real" = "$path_nvcc" ] && continue
        if "$nv" --list-gpu-arch 2>/dev/null | awk -v want="compute_$cap" '$0 == want { found=1 } END { exit found ? 0 : 1 }'; then
            printf '%s\n' "$nv"
            return 0
        fi
    done
    return 1
}

# ── Build type argument (required) ──────────────────────────────────────────
BUILD_TYPE="${1:-}"
GPU_ARCH_OVERRIDE="${2:-}"
if [ -z "$BUILD_TYPE" ] && [ -t 0 ]; then
    # No build type on an interactive run: suggest one from detected hardware.
    if command -v nvidia-smi >/dev/null 2>&1; then
        suggested_type="cuda"
    elif command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary 2>/dev/null | grep -q "deviceName"; then
        suggested_type="vulkan"
    elif command -v rocminfo >/dev/null 2>&1; then
        suggested_type="rocm"
    elif [ "$(uname)" = "Darwin" ]; then
        suggested_type="metal"
    else
        suggested_type="cpu"
    fi
    echo "Build types: cpu, vulkan, rocm, cuda, metal — optionally with a -tag suffix (e.g. rocm-test)"
    read -rp "Build type [default=$suggested_type]: " BUILD_TYPE
    BUILD_TYPE="${BUILD_TYPE:-$suggested_type}"
    echo ""
fi
if [ -z "$BUILD_TYPE" ]; then
    echo "❌ Build type required."
    echo ""
    echo "Usage: build-llamacpp.sh <cpu|rocm|vulkan|cuda|metal>[-tag] [gpu-arch]"
    echo ""
    echo "Examples:"
    echo "  ./build-llamacpp.sh cpu             # CPU-only backend"
    echo "  ./build-llamacpp.sh vulkan          # Vulkan backend (any GPU)"
    echo "  ./build-llamacpp.sh rocm            # ROCm/HIP backend (auto-detect GPU)"
    echo "  ./build-llamacpp.sh rocm gfx1100    # ROCm for RX 7900 series"
    echo "  ./build-llamacpp.sh rocm gfx1151    # ROCm for Strix Halo"
    echo "  ./build-llamacpp.sh cuda            # CUDA backend (auto-detect NVIDIA GPU)"
    echo "  ./build-llamacpp.sh cuda 89         # CUDA for Ada Lovelace (RTX 4090)"
    echo "  ./build-llamacpp.sh metal           # Metal backend (macOS / Apple Silicon)"
    echo "  ./build-llamacpp.sh rocm-test       # Tagged ROCm build"
    exit 1
fi

BUILD_DIR="${LLAMA_LAUNCHER_BUILDS_DIR:-$ROOT_DIR/builds}/$BUILD_TYPE"
# Backend = prefix before the first dash, so e.g. "rocm-test" uses the rocm
# toolchain/cmake flags but lands in a separate output dir.
BACKEND="${BUILD_TYPE%%-*}"
# Tag = the rest after the first dash, empty if none. Tags select separate
# output directories, not alternate source trees.
BUILD_TAG=""
[ "$BUILD_TYPE" != "$BACKEND" ] && BUILD_TAG="${BUILD_TYPE#*-}"

# ── Resolve llama.cpp source directory ──────────────────────────────────────
# Priority:
#   1. LLAMACPP_SRC env var (explicit override — non-interactive)
#   2. Interactive: ask which server variant is wanted, then find a matching
#      checkout — offering to clone (or paru -S) whatever is missing
#   3. Non-interactive: plain BUILD_TYPE with default source present → silent
#      default (llama-hdd sibling wins over vanilla llama.cpp when both
#      exist), otherwise the candidate-preference order below
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"

variant_label() {
    case "$1" in
        vanilla)     echo "llama.cpp" ;;
        llama-hdd)   echo "llama-hdd.cpp" ;;
        rocmfpx-hdd) echo "llama-rocmfpx-hdd" ;;
    esac
}

matches_variant() {
    case "$2" in
        llama-hdd)   is_llama_hdd_src "$1" ;;
        rocmfpx-hdd) is_rocmfpx_hdd_src "$1" ;;
        vanilla)     ! is_rocmfpx_hdd_src "$1" && ! is_llama_hdd_src "$1" ;;
        *)           return 0 ;;
    esac
}

# No checkout of the selected variant exists: walk the user through getting
# one — paru -S for the packaged variant, otherwise a clone (preferring
# makepkg's local mirror, falling back to a custom URL on failure).
# On success sets RESOLVED_SRC to the new checkout path.
resolve_variant_source() {
    local variant="$1" canonical dest mirrors=() mirror src alt clone_ans hdd_ans
    RESOLVED_SRC=""
    case "$variant" in
        vanilla)
            canonical="https://github.com/ggml-org/llama.cpp.git"
            dest="$HOME/code/llama.cpp"
            ;;
        llama-hdd)
            canonical="https://codeberg.org/LuminaNAO/llama-hdd.cpp.git"
            dest="$HOME/code/llama-hdd.cpp"
            mirrors=("$cache_root/paru/clone/llama-hdd/llama-hdd" "$cache_root/yay/llama-hdd/llama-hdd")
            ;;
        rocmfpx-hdd)
            canonical="${LLAMA_ROCMFPX_GIT_URL:-https://codeberg.org/LuminaNAO/llama-rocmfpx-hdd.git}"
            dest="$HOME/code/llama-rocmfpx-hdd"
            mirrors=("$cache_root/paru/clone/llama-rocmfpx-hdd/llama-rocmfpx-hdd" "$cache_root/yay/llama-rocmfpx-hdd/llama-rocmfpx-hdd")
            ;;
    esac
    echo "ℹ️  No $(variant_label "$variant") checkout found."
    if [ "$variant" = "llama-hdd" ] && command -v paru >/dev/null 2>&1; then
        echo "  1) Clone the source to $dest and build here (default)"
        echo "  2) paru -S llama-hdd — prebuilt package; llama-launcher then uses it as the 'system' build"
        read -rp "Choice [1-2, default=1]: " hdd_ans
        if [ "${hdd_ans:-1}" = "2" ]; then
            if ! paru -S llama-hdd; then
                echo "❌ paru -S llama-hdd failed"
                return 1
            fi
            echo "✅ llama-hdd installed — no source build needed; pick the 'system' build in llama-launcher."
            exit 0
        fi
    fi
    src="$canonical"
    for mirror in ${mirrors[@]+"${mirrors[@]}"}; do
        if git -C "$mirror" rev-parse --git-dir >/dev/null 2>&1; then
            src="$mirror"
            break
        fi
    done
    read -rp "Clone $(variant_label "$variant") from $src to $dest? [Y/n]: " clone_ans
    [[ "$clone_ans" =~ ^[Nn] ]] && return 1
    mkdir -p "$(dirname "$dest")"
    if ! git clone "$src" "$dest"; then
        echo "⚠️  Clone from $src failed (not published there yet, or no network access)."
        read -rp "Alternate git URL (e.g. a private mirror; empty = give up): " alt
        [ -z "$alt" ] && return 1
        git clone "$alt" "$dest" || return 1
        src="$alt"
    fi
    # Future pulls should track upstream, not a package cache path.
    case "$src" in
        "$cache_root"/*) git -C "$dest" remote set-url origin "$canonical" ;;
    esac
    RESOLVED_SRC="$dest"
}

VARIANT=""
if [ -n "${LLAMACPP_SRC:-}" ]; then
    LLAMACPP_DIR="$LLAMACPP_SRC"
else
    if [ -t 0 ]; then
        echo "Which llama-server variant do you want to build?"
        echo "  1) llama-hdd.cpp       — llama.cpp + persistent HDD prompt-cache (launcher default)"
        echo "  2) llama-rocmfpx-hdd   — ROCmFP4/MTP fork + HDD cache (required for ROCmFP4 models)"
        echo "  3) llama.cpp           — vanilla upstream (its server rejects the launcher's hdd-cache flags)"
        read -rp "Select variant [1-3, default=1]: " variant_sel
        case "${variant_sel:-1}" in
            1) VARIANT="llama-hdd" ;;
            2) VARIANT="rocmfpx-hdd" ;;
            3) VARIANT="vanilla" ;;
            *) echo "❌ Invalid selection: $variant_sel"; exit 1 ;;
        esac
        echo ""
    fi

    if [ -z "$VARIANT" ] && [ -z "$BUILD_TAG" ] && [ -f "$DEFAULT_LLAMAHDD_DIR/CMakeLists.txt" ]; then
        LLAMACPP_DIR="$DEFAULT_LLAMAHDD_DIR"
    elif [ -z "$VARIANT" ] && [ -z "$BUILD_TAG" ] && [ -f "$DEFAULT_LLAMACPP_DIR/CMakeLists.txt" ]; then
        LLAMACPP_DIR="$DEFAULT_LLAMACPP_DIR"
    else
        # Discover candidate llama.cpp source trees near the helper or, for
        # packaged installs, near normal user checkout locations.
        # Patterns covered:
        #   ~/code/llama.cpp            (default sibling)
        #   ~/code/llama.cpp-*          (suffix style, e.g. llama.cpp-v4flash)
        #   ~/code/llama*/llama.cpp     (nested style, e.g. llama-mtp/llama.cpp)
        #   ~/code/llama*               (flat style, e.g. llama-mtp/ with CMakeLists at root)
        #   ~/.cache/{paru,yay} makepkg src dirs for llama-hdd / llama-rocmfpx-hdd
        search_roots=()
        if [ "$PACKAGED_INSTALL" -eq 1 ]; then
            search_roots+=(
                "$PWD"
                "$(dirname "$PWD")"
                "$HOME/code"
                "$HOME/src"
                "$HOME"
                "$cache_root/paru/clone/llama-hdd/src"
                "$cache_root/yay/llama-hdd/src"
                "$cache_root/paru/clone/llama-rocmfpx-hdd/src"
                "$cache_root/yay/llama-rocmfpx-hdd/src"
            )
        else
            search_roots+=("$(dirname "$ROOT_DIR")")
        fi
        parent_dir="${search_roots[0]}"
        candidates=()
        for root in "${search_roots[@]}"; do
            [ -d "$root" ] || continue
            for c in "$root" "$root"/llama.cpp "$root"/llama.cpp-* "$root"/llama-hdd.cpp "$root"/llama*/llama.cpp "$root"/llama*; do
                [ -f "$c/CMakeLists.txt" ] || continue
                # Deduplicate (a glob can hit the same path twice)
                c_real="$(realpath "$c" 2>/dev/null || echo "$c")"
                seen=0
                for s in "${candidates[@]}"; do
                    [ "$(realpath "$s" 2>/dev/null || echo "$s")" = "$c_real" ] && { seen=1; break; }
                done
                [ "$seen" -eq 1 ] && continue
                candidates+=("$c")
            done
        done

        # A chosen variant only accepts matching trees — a stock llama-hdd
        # checkout must never silently satisfy a rocmfpx-hdd build (it would
        # compile fine and then fail at model load on the FP4 tensor types).
        if [ -n "$VARIANT" ]; then
            filtered=()
            for c in "${candidates[@]}"; do
                matches_variant "$c" "$VARIANT" && filtered+=("$c")
            done
            candidates=(${filtered[@]+"${filtered[@]}"})
        fi

        if [ ${#candidates[@]} -eq 0 ] && [ -t 0 ]; then
            if resolve_variant_source "${VARIANT:-llama-hdd}"; then
                candidates+=("$RESOLVED_SRC")
            fi
        fi

        if [ ${#candidates[@]} -eq 0 ]; then
            echo "❌ No ${VARIANT:+$(variant_label "$VARIANT") }source trees found."
            if [ "$PACKAGED_INSTALL" -eq 1 ]; then
                echo "   Looked in: ${search_roots[*]}"
                echo "   Either clone one (e.g. git clone https://github.com/ggml-org/llama.cpp.git ~/code/llama.cpp)"
            else
                echo "   Looked near: $parent_dir"
                echo "   Either clone one (e.g. git clone https://github.com/ggml-org/llama.cpp.git $DEFAULT_LLAMACPP_DIR)"
            fi
            echo "   or set LLAMACPP_SRC=/path/to/llama.cpp"
            exit 1
        fi

        # Smart default: prefer an llama-hdd tree over vanilla llama.cpp — a
        # vanilla build yields a server that rejects the launcher's hdd flags
        # (-dio, slot-save checkpoints). Fall back to the mainline sibling
        # checkout, then the first candidate found. (With a chosen variant the
        # list is already filtered, so the first match is the default.)
        default_sel=0
        mainline_sel=0
        for i in "${!candidates[@]}"; do
            if [ "$default_sel" -eq 0 ] && is_llama_hdd_src "${candidates[$i]}"; then
                default_sel=$((i+1))
            fi
            [ "$mainline_sel" -eq 0 ] && [ "$(realpath "${candidates[$i]}" 2>/dev/null || echo "${candidates[$i]}")" = "$(realpath "$DEFAULT_LLAMACPP_DIR" 2>/dev/null || echo "$DEFAULT_LLAMACPP_DIR")" ] && mainline_sel=$((i+1))
        done
        [ "$default_sel" -eq 0 ] && default_sel=$mainline_sel
        [ "$default_sel" -eq 0 ] && default_sel=1

        if [ ${#candidates[@]} -eq 1 ]; then
            LLAMACPP_DIR="${candidates[0]}"
        else
            echo "🔍 Available llama.cpp source trees:"
            for i in "${!candidates[@]}"; do
                label=""
                if is_rocmfpx_hdd_src "${candidates[$i]}"; then
                    label="$label [llama-rocmfpx-hdd]"
                elif is_llama_hdd_src "${candidates[$i]}"; then
                    label="$label [llama-hdd]"
                fi
                [ $((i+1)) -eq "$default_sel" ] && label="$label (default)"
                if [ -d "${candidates[$i]}/.git" ]; then
                    branch=$(git -C "${candidates[$i]}" branch --show-current 2>/dev/null || true)
                    [ -n "$branch" ] && label="$label [$branch]"
                fi
                printf "  %d) %s%s\n" $((i+1)) "${candidates[$i]}" "$label"
            done
            echo "  c) Custom path"
            echo ""

            if [ ! -t 0 ]; then
                LLAMACPP_DIR="${candidates[$((default_sel-1))]}"
                echo "ℹ️  Non-interactive input; using default source: $LLAMACPP_DIR"
            else
                read -rp "Select source [1-${#candidates[@]}, c=custom, default=$default_sel]: " src_sel
                src_sel="${src_sel:-$default_sel}"
                if [[ "$src_sel" == "c" || "$src_sel" == "C" ]]; then
                    read -rp "Enter llama.cpp source path: " LLAMACPP_DIR
                elif [[ "$src_sel" =~ ^[0-9]+$ ]] && [ "$src_sel" -ge 1 ] && [ "$src_sel" -le ${#candidates[@]} ]; then
                    LLAMACPP_DIR="${candidates[$((src_sel-1))]}"
                else
                    echo "❌ Invalid selection: $src_sel"
                    exit 1
                fi
            fi
        fi
    fi
    LLAMACPP_DIR="$(realpath "$LLAMACPP_DIR")"
    if [ -n "$VARIANT" ] && ! matches_variant "$LLAMACPP_DIR" "$VARIANT"; then
        echo "⚠️  $LLAMACPP_DIR does not look like a $(variant_label "$VARIANT") tree — building it anyway."
    fi
fi

# The launcher keys runtime env (LD_LIBRARY_PATH) off the backend prefix and
# discovers builds by directory name — give rocmfpx-hdd builds their own
# suffixed output dir so they never clobber a stock backend build.
if is_rocmfpx_hdd_src "$LLAMACPP_DIR"; then
    case "$BUILD_TYPE" in
        *rocmfpx*) ;;
        *)
            BUILD_TYPE="${BUILD_TYPE}-rocmfpx-hdd"
            BUILD_TAG="${BUILD_TYPE#*-}"
            BUILD_DIR="${LLAMA_LAUNCHER_BUILDS_DIR:-$ROOT_DIR/builds}/$BUILD_TYPE"
            echo "ℹ️  rocmfpx-hdd source — output goes to builds/$BUILD_TYPE"
            ;;
    esac
fi

echo "🔍 llama.cpp source: $LLAMACPP_DIR"
echo "🏗️  Build type: $BUILD_TYPE  (backend: $BACKEND)"
echo "🏗️  Build directory: $BUILD_DIR"
echo ""

# ── Check llama.cpp source ──────────────────────────────────────────────────
if [ ! -d "$LLAMACPP_DIR" ]; then
    echo "❌ llama.cpp source not found at $LLAMACPP_DIR"
    echo "   Clone it:  git clone https://github.com/ggml-org/llama.cpp.git $LLAMACPP_DIR"
    exit 1
fi

if [ ! -f "$LLAMACPP_DIR/CMakeLists.txt" ]; then
    echo "❌ $LLAMACPP_DIR exists but has no CMakeLists.txt — is it a valid llama.cpp checkout?"
    exit 1
fi

# ── Dependency checks ──────────────────────────────────────────────────────
MISSING=()

# Common deps
command -v cmake >/dev/null 2>&1 || MISSING+=("cmake|cmake — build system generator")
command -v make >/dev/null 2>&1 || MISSING+=("make|make — build tool (or ninja)")
command -v gcc >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 || MISSING+=("gcc/g++|base-devel (Arch) / build-essential (Debian) — C/C++ compiler")
command -v git >/dev/null 2>&1 || MISSING+=("git|git — version control")
command -v pkg-config >/dev/null 2>&1 || MISSING+=("pkg-config|pkgconf (Arch) / pkg-config (Debian)")

case "$BACKEND" in
    cpu)
        if [ -n "$GPU_ARCH_OVERRIDE" ]; then
            echo "⚠️  GPU arch argument ignored for CPU builds: $GPU_ARCH_OVERRIDE"
        fi
        ;;
    vulkan)
        # Check Vulkan headers (needed at compile time — vulkan-headers package)
        if [ ! -f /usr/include/vulkan/vulkan.h ] && [ ! -f /usr/local/include/vulkan/vulkan.h ]; then
            MISSING+=("vulkan headers|vulkan-headers (Arch) / libvulkan-dev (Debian/Ubuntu)")
        fi
        # Check Vulkan ICD loader (runtime library)
        if ! ldconfig_has "libvulkan.so" && [ ! -f /usr/lib/libvulkan.so ] && [ ! -f /usr/lib64/libvulkan.so ]; then
            MISSING+=("vulkan loader|vulkan-icd-loader (Arch) / libvulkan1 (Debian/Ubuntu)")
        fi
        # Check for a Vulkan driver
        if command -v vulkaninfo >/dev/null 2>&1; then
            if ! vulkaninfo --summary 2>/dev/null | grep -q "deviceName"; then
                echo "⚠️  vulkaninfo found but no Vulkan device detected — check your GPU driver"
            fi
        else
            echo "⚠️  vulkaninfo not found — install vulkan-tools to verify your GPU driver"
        fi
        # Check glslc (shader compiler) — needed at build time
        command -v glslc >/dev/null 2>&1 || MISSING+=("glslc|shaderc (Arch) / glslc (Debian) — Vulkan shader compiler")
        # llama.cpp's Vulkan CMake also requires glslangValidator and SPIR-V package metadata.
        command -v glslangValidator >/dev/null 2>&1 || MISSING+=("glslangValidator|glslang (Arch) / glslang-tools (Debian/Ubuntu) — Vulkan GLSL validator")
        command -v spirv-as >/dev/null 2>&1 || MISSING+=("spirv-tools|spirv-tools (Arch/Debian/Ubuntu) — SPIR-V tools")
        spirv_headers_config_found || MISSING+=("SPIRV-Headers|spirv-headers (Arch/Debian/Ubuntu) — SPIR-V CMake package config")
        ;;
    cuda)
        # Check CUDA toolkit (nvcc compiler). Toolkits often install outside
        # PATH (Arch: /opt/cuda, profile.d only applies on next login;
        # NVIDIA runfile: /usr/local/cuda) — pick nvcc up from known prefixes.
        if ! command -v nvcc >/dev/null 2>&1; then
            for _nvcc in /opt/cuda/bin/nvcc /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do
                if [ -x "$_nvcc" ]; then
                    export PATH="$(dirname "$_nvcc"):$PATH"
                    export CUDACXX="$_nvcc"
                    echo "ℹ️  nvcc not on PATH; using $_nvcc"
                    break
                fi
            done
            unset _nvcc
        fi
        if ! command -v nvcc >/dev/null 2>&1; then
            MISSING+=("nvcc|cuda (Arch) / nvidia-cuda-toolkit (Debian/Ubuntu) — CUDA compiler")
        fi
        # Check NVIDIA driver / nvidia-smi
        if ! command -v nvidia-smi >/dev/null 2>&1; then
            MISSING+=("nvidia-smi|nvidia (Arch) / nvidia-driver (Debian/Ubuntu) — NVIDIA GPU driver")
        fi
        # Check cublas
        if ! ldconfig_has "libcublas" && [ ! -f /usr/local/cuda/lib64/libcublas.so ] && [ ! -f /opt/cuda/lib64/libcublas.so ]; then
            MISSING+=("cublas|cuda (Arch) / libcublas-dev (Debian/Ubuntu) — CUDA BLAS library")
        fi
        ;;
    rocm)
        # Check ROCm base installation
        if [ ! -d /opt/rocm ] && ! command -v hipcc >/dev/null 2>&1; then
            MISSING+=("ROCm/HIP|rocm-hip-sdk (Arch) / rocm (AMD repo) — AMD GPU compute stack")
        fi
        # Check HIP compiler
        if ! command -v hipcc >/dev/null 2>&1; then
            MISSING+=("hipcc|hip-runtime-amd (Arch) / rocm-hip-runtime (Debian) — HIP compiler")
        fi
        # Check HIP development headers
        if [ ! -d /opt/rocm/include/hip ] && [ ! -d /usr/include/hip ]; then
            MISSING+=("hip-dev|hip-dev (Arch) / rocm-hip-dev (Debian) — HIP development headers")
        fi
        # Check rocminfo (needed for GPU auto-detection)
        if ! command -v rocminfo >/dev/null 2>&1; then
            MISSING+=("rocminfo|rocminfo (Arch/Debian) — ROCm GPU info tool (needed for arch detection)")
        fi
        # Check rocblas
        if [ ! -f /opt/rocm/lib/librocblas.so ] && ! ldconfig_has "librocblas"; then
            MISSING+=("rocblas|rocblas (Arch) / rocm-libs (Debian) — ROCm BLAS library")
        fi
        # Check hipblas
        if [ ! -f /opt/rocm/lib/libhipblas.so ] && ! ldconfig_has "libhipblas"; then
            MISSING+=("hipblas|hipblas (Arch) / rocm-libs (Debian) — HIP BLAS library")
        fi
        ;;
    *)
        echo "❌ Unknown backend: $BACKEND (derived from build type '$BUILD_TYPE')"
        echo ""
        echo "Usage: build-llamacpp.sh <cpu|rocm|vulkan|cuda>[-tag]"
        echo ""
        echo "Examples:"
        echo "  ./build-llamacpp.sh cpu       # CPU-only backend"
        echo "  ./build-llamacpp.sh vulkan    # Recommended for Strix Halo / RDNA 3.5"
        echo "  ./build-llamacpp.sh rocm      # ROCm/HIP backend"
        echo "  ./build-llamacpp.sh cuda      # NVIDIA CUDA backend"
        echo "  LLAMACPP_SRC=/path/to/llama.cpp ./build-llamacpp.sh rocm-test      # alternate source"
        exit 1
        ;;
esac

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "❌ Missing dependencies for $BACKEND build:"
    echo ""
    for entry in "${MISSING[@]}"; do
        name="${entry%%|*}"
        pkg="${entry##*|}"
        printf "  %-20s → install: %s\n" "$name" "$pkg"
    done
    echo ""

    # Detect package manager, build the install command, and offer to run it
    dep_cmd=""
    dep_pkgs=""
    if command -v pacman >/dev/null 2>&1; then
        dep_cmd="sudo pacman -S --needed"
        case "$BACKEND" in
            vulkan) dep_pkgs="vulkan-headers vulkan-icd-loader shaderc glslang spirv-tools spirv-headers vulkan-tools" ;;
            rocm)   dep_pkgs="rocm-hip-sdk rocblas hipblas rocminfo" ;;
            cuda)   dep_pkgs="cuda" ;;
        esac
        # Pull in the common toolchain only when one of those was missing
        case " ${MISSING[*]} " in
            *"cmake|"*|*"make|"*|*"gcc/g++"*|*"git|"*|*"pkg-config"*)
                dep_pkgs="base-devel cmake pkgconf git${dep_pkgs:+ $dep_pkgs}" ;;
        esac
        [ -n "$dep_pkgs" ] && echo "Arch/CachyOS quick install:"
    elif command -v apt-get >/dev/null 2>&1; then
        dep_cmd="sudo apt-get install -y"
        case "$BACKEND" in
            vulkan) dep_pkgs="libvulkan-dev vulkan-tools glslc glslang-tools spirv-tools spirv-headers" ;;
            rocm)   echo "See https://rocm.docs.amd.com for ROCm installation" ;;
            cuda)   dep_pkgs="nvidia-cuda-toolkit libcublas-dev" ;;
        esac
        case " ${MISSING[*]} " in
            *"cmake|"*|*"make|"*|*"gcc/g++"*|*"git|"*|*"pkg-config"*)
                dep_pkgs="build-essential cmake pkg-config git${dep_pkgs:+ $dep_pkgs}" ;;
        esac
        [ -n "$dep_pkgs" ] && echo "Debian/Ubuntu quick install:"
    fi
    if [ -n "$dep_pkgs" ]; then
        echo "  $dep_cmd $dep_pkgs"
        echo ""
        if [ -t 0 ]; then
            read -rp "Run it now? [Y/n]: " dep_ans
            if [[ ! "$dep_ans" =~ ^[Nn] ]]; then
                # shellcheck disable=SC2086
                if $dep_cmd $dep_pkgs; then
                    echo "✅ Dependencies installed — re-checking..."
                    # Re-exec with the source pinned so nothing gets re-asked.
                    exec env LLAMACPP_SRC="$LLAMACPP_DIR" "$0" "$BUILD_TYPE" ${GPU_ARCH_OVERRIDE:+"$GPU_ARCH_OVERRIDE"}
                fi
                echo "❌ Package install failed — fix manually and re-run."
            fi
        fi
    fi
    echo ""
    exit 1
fi

echo "✅ All dependencies found for $BACKEND build"
echo ""

# ── Prepare build directory ─────────────────────────────────────────────────
cd "$LLAMACPP_DIR"
mkdir -p "$BUILD_DIR"

# Wipe stale CMake cache if it was generated from a different source path
if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    CACHED_SRC=$(grep "CMAKE_HOME_DIRECTORY:INTERNAL=" "$BUILD_DIR/CMakeCache.txt" 2>/dev/null | cut -d= -f2)
    if [ -n "$CACHED_SRC" ] && [ "$CACHED_SRC" != "$LLAMACPP_DIR" ]; then
        echo "⚠️  Stale CMake cache (was: $CACHED_SRC, now: $LLAMACPP_DIR)"
        echo "   Wiping entire build directory..."
        rm -rf "$BUILD_DIR"/*
        mkdir -p "$BUILD_DIR"
    fi
fi

# ── GPU architecture detection (ROCm only) ────────────────────────────────
if [ "$BACKEND" = "rocm" ]; then
    if [ -n "$GPU_ARCH_OVERRIDE" ]; then
        GPU_ARCH="$GPU_ARCH_OVERRIDE"
        echo "🎯 GPU arch (override): $GPU_ARCH"
    elif command -v rocminfo >/dev/null 2>&1; then
        # Extract unique gfx targets from rocminfo
        # Match full gfx arch IDs (4+ hex chars) — excludes partial matches like gfx11-generic
        DETECTED_ARCHS=$(rocminfo 2>/dev/null | grep -oP 'gfx[0-9a-f]{4,}' | sort -u || true)
        if [ -z "$DETECTED_ARCHS" ]; then
            echo "⚠️  rocminfo found no AMD GPUs — falling back to manual selection."
            echo ""
            GPU_ARCH=""
        else
            # Use semicolon-separated list for multi-GPU builds
            GPU_ARCH=$(echo "$DETECTED_ARCHS" | tr '\n' ';' | sed 's/;$//')
            echo "🎯 GPU arch (auto-detected): $GPU_ARCH"
        fi
    else
        echo "⚠️  rocminfo not found — cannot auto-detect GPU."
        echo "   (Install rocminfo for auto-detection: sudo pacman -S rocminfo)"
        echo ""
        GPU_ARCH=""
    fi

    # Interactive picker if detection failed or wasn't available
    if [ -z "$GPU_ARCH" ]; then
        echo "Select your GPU architecture:"
        echo ""
        echo "  1) gfx1100  — RDNA 3   (RX 7900 XTX/XT/GRE)"
        echo "  2) gfx1101  — RDNA 3   (RX 7800 XT / 7700 XT)"
        echo "  3) gfx1102  — RDNA 3   (RX 7600)"
        echo "  4) gfx1150  — RDNA 3.5 (Strix Point)"
        echo "  5) gfx1151  — RDNA 3.5 (Strix Halo)"
        echo "  6) gfx942   — CDNA 3   (MI300)"
        echo ""
        printf "Choice [1-6]: "
        read -r choice
        case "$choice" in
            1) GPU_ARCH="gfx1100" ;;
            2) GPU_ARCH="gfx1101" ;;
            3) GPU_ARCH="gfx1102" ;;
            4) GPU_ARCH="gfx1150" ;;
            5) GPU_ARCH="gfx1151" ;;
            6) GPU_ARCH="gfx942"  ;;
            *)
                echo "❌ Invalid choice: $choice"
                exit 1
                ;;
        esac
        echo ""
        echo "🎯 GPU arch (selected): $GPU_ARCH"
    fi

    # Pretty-print detected targets
    for arch in $(echo "$GPU_ARCH" | tr ';' ' '); do
        case "$arch" in
            gfx1100) echo "   → $arch: RDNA 3 (RX 7900 XTX/XT/GRE)" ;;
            gfx1101) echo "   → $arch: RDNA 3 (RX 7800 XT / 7700 XT)" ;;
            gfx1102) echo "   → $arch: RDNA 3 (RX 7600)" ;;
            gfx1150) echo "   → $arch: RDNA 3.5 (Strix Point)" ;;
            gfx1151) echo "   → $arch: RDNA 3.5 (Strix Halo)" ;;
            gfx942)  echo "   → $arch: CDNA 3 (MI300)" ;;
            *)       echo "   → $arch: (unknown — build may still work)" ;;
        esac
    done
    echo ""

    # ROCWMMA flash attention: only beneficial on CDNA (gfx9xx) cards
    USE_ROCWMMA=OFF
    if echo "$GPU_ARCH" | grep -qP 'gfx9[0-9]+'; then
        # Check if rocwmma headers are available
        if [ -f /opt/rocm/include/rocwmma/rocwmma-version.hpp ] || \
           [ -f /usr/include/rocwmma/rocwmma-version.hpp ]; then
            USE_ROCWMMA=ON
            echo "✅ ROCWMMA flash attention enabled (CDNA target detected)"
        else
            echo "⚠️  CDNA target detected but rocwmma headers not found — flash attention disabled"
            echo "   Install for better performance: sudo pacman -S rocwmma  # Arch/CachyOS"
        fi
    else
        echo "ℹ️  ROCWMMA flash attention: disabled (RDNA targets don't support WMMA)"
    fi
fi

# ── GPU architecture detection (CUDA) ─────────────────────────────────────
if [ "$BACKEND" = "cuda" ]; then
    CUDA_ARCH_AUTO=0
    if [ -n "$GPU_ARCH_OVERRIDE" ]; then
        CUDA_ARCH="$GPU_ARCH_OVERRIDE"
        echo "🎯 CUDA compute capability (override): $CUDA_ARCH"
    elif command -v nvidia-smi >/dev/null 2>&1; then
        # Query compute capability from nvidia-smi
        DETECTED_CAPS=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sort -u | tr -d '.' || true)
        if [ -z "$DETECTED_CAPS" ]; then
            echo "⚠️  nvidia-smi found no NVIDIA GPUs — using native detection."
            CUDA_ARCH="native"
        else
            CUDA_ARCH=$(echo "$DETECTED_CAPS" | tr '\n' ';' | sed 's/;$//')
            CUDA_ARCH_AUTO=1
            echo "🎯 CUDA compute capability (auto-detected): $CUDA_ARCH"
        fi
    else
        echo "⚠️  nvidia-smi not found — using native detection."
        CUDA_ARCH="native"
    fi

    if [ "$CUDA_ARCH" != "native" ]; then
        resolved_archs=()
        for cap in $(echo "$CUDA_ARCH" | tr ';' ' '); do
            if nvcc_supports_cuda_arch "$cap"; then
                resolved_archs+=("$cap")
                continue
            fi

            alt_nvcc="$(nvcc_alternate_supporting "$cap" || true)"
            if [ -n "$alt_nvcc" ]; then
                echo "❌ nvcc on PATH does not support compute_$cap, but $alt_nvcc does."
                echo "   Refusing PTX fallback: kernels JIT-compiled from an older toolkit"
                echo "   can crash at model load on newer GPUs."
                echo "   Rebuild with the newer toolkit:"
                echo "   PATH=\"$(dirname "$alt_nvcc"):\$PATH\" CUDACXX=\"$alt_nvcc\" $0 $BUILD_TYPE${GPU_ARCH_OVERRIDE:+ $GPU_ARCH_OVERRIDE}"
                exit 1
            fi

            if [ "$CUDA_ARCH_AUTO" -eq 0 ]; then
                echo "❌ CUDA compute capability '$cap' is not supported by this nvcc."
                echo "   Supported: $(nvcc_supported_cuda_archs | paste -sd ' ' -)"
                exit 1
            fi

            fallback_cap="$(nvcc_best_cuda_arch_for "$cap")"
            if [ -z "$fallback_cap" ]; then
                echo "❌ CUDA compute capability '$cap' is not supported by this nvcc, and no fallback was found."
                echo "   Supported: $(nvcc_supported_cuda_archs | paste -sd ' ' -)"
                exit 1
            fi
            echo "⚠️  nvcc does not support compute_$cap; using compute_$fallback_cap PTX fallback."
            echo "   PTX JIT from an older toolkit may fail or crash on newer GPUs."
            echo "   If llama-server aborts at model load, install a newer CUDA toolkit and rebuild."
            resolved_archs+=("$fallback_cap")
        done
        CUDA_ARCH="$(printf '%s\n' "${resolved_archs[@]}" | sort -uV | tr '\n' ';' | sed 's/;$//')"
    fi

    # Pretty-print detected targets
    for cap in $(echo "$CUDA_ARCH" | tr ';' ' '); do
        case "$cap" in
            70) echo "   → sm_$cap: Volta (V100)" ;;
            75) echo "   → sm_$cap: Turing (RTX 2080, T4)" ;;
            80) echo "   → sm_$cap: Ampere (A100)" ;;
            86) echo "   → sm_$cap: Ampere (RTX 3090, A40)" ;;
            89) echo "   → sm_$cap: Ada Lovelace (RTX 4090, L40)" ;;
            90) echo "   → sm_$cap: Hopper (H100)" ;;
            native) echo "   → native: will detect at build time" ;;
            *)  echo "   → sm_$cap: (unknown — build may still work)" ;;
        esac
    done
    echo ""
fi

# ── Configure and build ────────────────────────────────────────────────────
case "$BACKEND" in
    cpu)
        cmake -S . -B "$BUILD_DIR" \
          -DGGML_NATIVE=ON \
          -DCMAKE_BUILD_TYPE=Release
        ;;
    cuda)
        CMAKE_CUDA_ARGS=(-DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release)
        if [ "$CUDA_ARCH" != "native" ]; then
            CMAKE_CUDA_ARGS+=(-DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH")
        fi
        cmake -S . -B "$BUILD_DIR" "${CMAKE_CUDA_ARGS[@]}"
        ;;
    rocm)
        cmake -S . -B "$BUILD_DIR" \
          -DGGML_HIP=ON \
          -DAMDGPU_TARGETS="$GPU_ARCH" \
          -DGGML_HIP_ROCWMMA_FATTN="$USE_ROCWMMA" \
          -DCMAKE_BUILD_TYPE=Release
        ;;
    vulkan)
        cmake -S . -B "$BUILD_DIR" \
          -DGGML_VULKAN=ON \
          -DCMAKE_BUILD_TYPE=Release
        ;;
    metal)
        cmake -S . -B "$BUILD_DIR" \
          -DGGML_METAL=ON \
          -DCMAKE_BUILD_TYPE=Release
        ;;
esac

if [ -n "$BUILD_TAG" ]; then
    # Tagged builds (e.g. forks) often have broken examples/ targets.
    # Match the upstream MTP model card recipe and build only essentials.
    echo "ℹ️  Tagged build ($BUILD_TAG) — building only llama-cli + llama-server"
    cmake --build "$BUILD_DIR" -j$(nproc) --target llama-cli llama-server
else
    cmake --build "$BUILD_DIR" -j$(nproc)
fi

echo ""
echo "✅ Build complete! ($BUILD_TYPE)"
echo "   Server: $BUILD_DIR/bin/llama-server"
echo "   Libs: $BUILD_DIR/lib/"
