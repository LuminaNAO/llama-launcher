#!/bin/bash
# Build llama.cpp in the builds/ directory
# Usage: build.sh <rocm|vulkan>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMACPP_DIR="$(dirname "$SCRIPT_DIR")/llama.cpp"

# ── Build type argument (required) ──────────────────────────────────────────
BUILD_TYPE="${1:-}"
if [ -z "$BUILD_TYPE" ]; then
    echo "❌ Build type required."
    echo ""
    echo "Usage: build.sh <rocm|vulkan>"
    echo ""
    echo "Examples:"
    echo "  ./build.sh vulkan    # Recommended for Strix Halo / RDNA 3.5"
    echo "  ./build.sh rocm      # ROCm/HIP backend"
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
        # Check ROCm / HIP
        if [ ! -d /opt/rocm ] && ! command -v hipcc >/dev/null 2>&1; then
            MISSING+=("ROCm/HIP|rocm-hip-sdk (Arch) / rocm (AMD repo) — AMD GPU compute stack")
        fi
        if ! command -v hipcc >/dev/null 2>&1; then
            MISSING+=("hipcc|hip-runtime-amd — HIP compiler (part of ROCm)")
        fi
        # Check rocblas
        if [ ! -f /opt/rocm/lib/librocblas.so ] && ! ldconfig -p 2>/dev/null | grep -q librocblas; then
            MISSING+=("rocblas|rocblas — ROCm BLAS library")
        fi
        # Check hipblas
        if [ ! -f /opt/rocm/lib/libhipblas.so ] && ! ldconfig -p 2>/dev/null | grep -q libhipblas; then
            MISSING+=("hipblas|hipblas — HIP BLAS library")
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
            echo "  sudo pacman -S rocm-hip-sdk rocblas hipblas"
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

# ── Configure and build ────────────────────────────────────────────────────
case "$BUILD_TYPE" in
    rocm)
        cmake -S . -B "$BUILD_DIR" \
          -DGGML_HIP=ON \
          -DAMDGPU_TARGETS=gfx1151 \
          -DGGML_HIP_ROCWMMA_FATTN=ON \
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
