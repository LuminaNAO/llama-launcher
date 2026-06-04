#!/bin/bash
# Build llama.cpp in the builds/ directory
# Usage: build.sh <build-type> [gpu-arch]
#
# <build-type> is <backend>[-<tag>], where <backend> ∈ {rocm,vulkan,cuda}.
# The optional -tag suffix selects a parallel output directory under builds/
# so multiple variants of the same backend can coexist (e.g. a fork build).
#   ./build.sh rocm           # → builds/rocm (default mainline source)
#   ./build.sh rocm-mtp       # → builds/rocm-mtp (use LLAMACPP_SRC to point at fork)
#
# To build from a non-default llama.cpp source tree (e.g. an upstream fork),
# set LLAMACPP_SRC:
#   LLAMACPP_SRC=~/code/llama-mtp/llama.cpp ./build.sh rocm-mtp
#
# GPU arch is auto-detected for ROCm builds but can be overridden:
#   ./build.sh rocm gfx1100    # Force RX 7900 series target
#   ./build.sh rocm gfx1151    # Force Strix Halo target
#
# For CUDA builds, compute capability is auto-detected but can be overridden:
#   ./build.sh cuda             # Auto-detect NVIDIA GPU
#   ./build.sh cuda 89          # Force Ada Lovelace (RTX 4090)
#
# Supported AMD GPU targets:
#   gfx1100  — RDNA 3   (RX 7900 XTX/XT/GRE)
#   gfx1101  — RDNA 3   (RX 7800 XT / 7700 XT)
#   gfx1102  — RDNA 3   (RX 7600)
#   gfx1150  — RDNA 3.5 (Strix Point)
#   gfx1151  — RDNA 3.5 (Strix Halo)
#   gfx942   — CDNA 3   (MI300)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LLAMACPP_DIR="$(dirname "$SCRIPT_DIR")/llama.cpp"

# ── Build type argument (required) ──────────────────────────────────────────
BUILD_TYPE="${1:-}"
GPU_ARCH_OVERRIDE="${2:-}"
if [ -z "$BUILD_TYPE" ]; then
    echo "❌ Build type required."
    echo ""
    echo "Usage: build.sh <rocm|vulkan|cuda>[-tag] [gpu-arch]"
    echo ""
    echo "Examples:"
    echo "  ./build.sh vulkan          # Vulkan backend (any GPU)"
    echo "  ./build.sh rocm            # ROCm/HIP backend (auto-detect GPU)"
    echo "  ./build.sh rocm gfx1100    # ROCm for RX 7900 series"
    echo "  ./build.sh rocm gfx1151    # ROCm for Strix Halo"
    echo "  ./build.sh cuda            # CUDA backend (auto-detect NVIDIA GPU)"
    echo "  ./build.sh cuda 89         # CUDA for Ada Lovelace (RTX 4090)"
    echo "  ./build.sh rocm-mtp        # Tagged build (prompts for source dir)"
    exit 1
fi

BUILD_DIR="$SCRIPT_DIR/builds/$BUILD_TYPE"
# Backend = prefix before the first dash, so e.g. "rocm-mtp" uses the rocm
# toolchain/cmake flags but lands in a separate output dir.
BACKEND="${BUILD_TYPE%%-*}"
# Tag = the rest after the first dash, empty if none. Used to bias the
# source-tree picker (a tag of "mtp" suggests the path containing "mtp").
BUILD_TAG=""
[ "$BUILD_TYPE" != "$BACKEND" ] && BUILD_TAG="${BUILD_TYPE#*-}"

# ── Resolve llama.cpp source directory ──────────────────────────────────────
# Priority:
#   1. LLAMACPP_SRC env var (explicit override — non-interactive)
#   2. Plain BUILD_TYPE (no tag) with default source present → silent default
#   3. Otherwise interactive picker (smart default based on tag, custom-path option)
if [ -n "${LLAMACPP_SRC:-}" ]; then
    LLAMACPP_DIR="$LLAMACPP_SRC"
elif [ -z "$BUILD_TAG" ] && [ -f "$DEFAULT_LLAMACPP_DIR/CMakeLists.txt" ]; then
    LLAMACPP_DIR="$DEFAULT_LLAMACPP_DIR"
else
    # Discover candidate llama.cpp source trees near the helper.
    # Patterns covered:
    #   ~/code/llama.cpp            (default sibling)
    #   ~/code/llama.cpp-*          (suffix style, e.g. llama.cpp-v4flash)
    #   ~/code/llama*/llama.cpp     (nested style, e.g. llama-mtp/llama.cpp)
    parent_dir="$(dirname "$SCRIPT_DIR")"
    candidates=()
    for c in "$parent_dir"/llama.cpp "$parent_dir"/llama.cpp-* "$parent_dir"/llama*/llama.cpp; do
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

    if [ ${#candidates[@]} -eq 0 ]; then
        echo "❌ No llama.cpp source trees found near $parent_dir"
        echo "   Either clone one (e.g. git clone https://github.com/ggml-org/llama.cpp.git $DEFAULT_LLAMACPP_DIR)"
        echo "   or set LLAMACPP_SRC=/path/to/llama.cpp"
        exit 1
    fi

    # Smart default: prefer a candidate whose path contains the BUILD_TAG
    default_sel=1
    if [ -n "$BUILD_TAG" ]; then
        for i in "${!candidates[@]}"; do
            [[ "${candidates[$i]}" == *"$BUILD_TAG"* ]] && { default_sel=$((i+1)); break; }
        done
    fi

    echo "🔍 Available llama.cpp source trees:"
    for i in "${!candidates[@]}"; do
        label=""
        [ "${candidates[$i]}" = "$DEFAULT_LLAMACPP_DIR" ] && label="$label (default)"
        if [ -d "${candidates[$i]}/.git" ]; then
            branch=$(git -C "${candidates[$i]}" branch --show-current 2>/dev/null || true)
            [ -n "$branch" ] && label="$label [$branch]"
        fi
        printf "  %d) %s%s\n" $((i+1)) "${candidates[$i]}" "$label"
    done
    echo "  c) Custom path"
    echo ""

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
    LLAMACPP_DIR="$(realpath "$LLAMACPP_DIR")"
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
    vulkan)
        # Check Vulkan headers (needed at compile time — vulkan-headers package)
        if [ ! -f /usr/include/vulkan/vulkan.h ] && [ ! -f /usr/local/include/vulkan/vulkan.h ]; then
            MISSING+=("vulkan headers|vulkan-headers (Arch) / libvulkan-dev (Debian/Ubuntu)")
        fi
        # Check Vulkan ICD loader (runtime library)
        if ! ldconfig -p 2>/dev/null | grep -q libvulkan.so && [ ! -f /usr/lib/libvulkan.so ] && [ ! -f /usr/lib64/libvulkan.so ]; then
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
        ;;
    cuda)
        # Check CUDA toolkit (nvcc compiler)
        if ! command -v nvcc >/dev/null 2>&1; then
            MISSING+=("nvcc|cuda (Arch) / nvidia-cuda-toolkit (Debian/Ubuntu) — CUDA compiler")
        fi
        # Check NVIDIA driver / nvidia-smi
        if ! command -v nvidia-smi >/dev/null 2>&1; then
            MISSING+=("nvidia-smi|nvidia (Arch) / nvidia-driver (Debian/Ubuntu) — NVIDIA GPU driver")
        fi
        # Check cublas
        if ! ldconfig -p 2>/dev/null | grep -q libcublas && [ ! -f /usr/local/cuda/lib64/libcublas.so ]; then
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
        if [ ! -f /opt/rocm/lib/librocblas.so ] && ! ldconfig -p 2>/dev/null | grep -q librocblas; then
            MISSING+=("rocblas|rocblas (Arch) / rocm-libs (Debian) — ROCm BLAS library")
        fi
        # Check hipblas
        if [ ! -f /opt/rocm/lib/libhipblas.so ] && ! ldconfig -p 2>/dev/null | grep -q libhipblas; then
            MISSING+=("hipblas|hipblas (Arch) / rocm-libs (Debian) — HIP BLAS library")
        fi
        ;;
    *)
        echo "❌ Unknown backend: $BACKEND (derived from build type '$BUILD_TYPE')"
        echo ""
        echo "Usage: build.sh <rocm|vulkan|cuda>[-tag]"
        echo ""
        echo "Examples:"
        echo "  ./build.sh vulkan    # Recommended for Strix Halo / RDNA 3.5"
        echo "  ./build.sh rocm      # ROCm/HIP backend"
        echo "  ./build.sh cuda      # NVIDIA CUDA backend"
        echo "  LLAMACPP_SRC=~/code/llama-mtp/llama.cpp ./build.sh rocm-mtp  # fork build"
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

    # Detect package manager and give a one-liner
    if command -v pacman >/dev/null 2>&1; then
        echo "Arch/CachyOS quick install:"
        case "$BACKEND" in
            vulkan) echo "  sudo pacman -S vulkan-headers vulkan-icd-loader shaderc vulkan-tools" ;;
            rocm)   echo "  sudo pacman -S rocm-hip-sdk rocblas hipblas rocminfo" ;;
            cuda)   echo "  sudo pacman -S cuda" ;;
        esac
    elif command -v apt-get >/dev/null 2>&1; then
        echo "Debian/Ubuntu quick install:"
        case "$BACKEND" in
            vulkan) echo "  sudo apt-get install libvulkan-dev vulkan-tools glslc" ;;
            rocm)   echo "  See https://rocm.docs.amd.com for ROCm installation" ;;
            cuda)   echo "  sudo apt-get install nvidia-cuda-toolkit libcublas-dev" ;;
        esac
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
            echo "🎯 CUDA compute capability (auto-detected): $CUDA_ARCH"
        fi
    else
        echo "⚠️  nvidia-smi not found — using native detection."
        CUDA_ARCH="native"
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
esac

cmake --build "$BUILD_DIR" -j$(nproc)

echo ""
echo "✅ Build complete! ($BUILD_TYPE)"
echo "   Server: $BUILD_DIR/bin/llama-server"
echo "   Libs: $BUILD_DIR/lib/"
