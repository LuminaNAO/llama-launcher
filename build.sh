#!/bin/bash
# Build llama.cpp in the builds/ directory
# Usage: build.sh <rocm|vulkan> [gpu-arch]
#
# GPU arch is auto-detected for ROCm builds but can be overridden:
#   ./build.sh rocm gfx1100    # Force RX 7900 series target
#   ./build.sh rocm gfx1151    # Force Strix Halo target
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
LLAMACPP_DIR="$(dirname "$SCRIPT_DIR")/llama.cpp"

# ── Build type argument (required) ──────────────────────────────────────────
BUILD_TYPE="${1:-}"
GPU_ARCH_OVERRIDE="${2:-}"
if [ -z "$BUILD_TYPE" ]; then
    echo "❌ Build type required."
    echo ""
    echo "Usage: build.sh <rocm|vulkan> [gpu-arch]"
    echo ""
    echo "Examples:"
    echo "  ./build.sh vulkan          # Vulkan backend (any GPU)"
    echo "  ./build.sh rocm            # ROCm/HIP backend (auto-detect GPU)"
    echo "  ./build.sh rocm gfx1100    # ROCm for RX 7900 series"
    echo "  ./build.sh rocm gfx1151    # ROCm for Strix Halo"
    exit 1
fi

BUILD_DIR="$SCRIPT_DIR/builds/$BUILD_TYPE"

echo "🔍 llama.cpp source: $LLAMACPP_DIR"
echo "🏗️  Build type: $BUILD_TYPE"
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

case "$BUILD_TYPE" in
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
        echo "❌ Unknown build type: $BUILD_TYPE"
        echo ""
        echo "Usage: build.sh <rocm|vulkan>"
        echo ""
        echo "Examples:"
        echo "  ./build.sh vulkan    # Recommended for Strix Halo / RDNA 3.5"
        echo "  ./build.sh rocm      # ROCm/HIP backend"
        exit 1
        ;;
esac

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "❌ Missing dependencies for $BUILD_TYPE build:"
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
        if [ "$BUILD_TYPE" = "vulkan" ]; then
            echo "  sudo pacman -S vulkan-headers vulkan-icd-loader shaderc vulkan-tools"
        else
            echo "  sudo pacman -S rocm-hip-sdk rocblas hipblas rocminfo"
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        echo "Debian/Ubuntu quick install:"
        if [ "$BUILD_TYPE" = "vulkan" ]; then
            echo "  sudo apt-get install libvulkan-dev vulkan-tools glslc"
        else
            echo "  See https://rocm.docs.amd.com for ROCm installation"
        fi
    fi
    echo ""
    exit 1
fi

echo "✅ All dependencies found for $BUILD_TYPE build"
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
if [ "$BUILD_TYPE" = "rocm" ]; then
    if [ -n "$GPU_ARCH_OVERRIDE" ]; then
        GPU_ARCH="$GPU_ARCH_OVERRIDE"
        echo "🎯 GPU arch (override): $GPU_ARCH"
    elif command -v rocminfo >/dev/null 2>&1; then
        # Extract unique gfx targets from rocminfo
        DETECTED_ARCHS=$(rocminfo 2>/dev/null | grep -oP 'gfx[0-9a-f]+' | sort -u || true)
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

# ── Configure and build ────────────────────────────────────────────────────
case "$BUILD_TYPE" in
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
