# Build llama.cpp in the builds/ directory
# Usage: build.sh [rocm|vulkan]  (default: rocm)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMACPP_DIR="$(dirname "$SCRIPT_DIR")/llama.cpp"

BUILD_TYPE="${1:-rocm}"
BUILD_DIR="$SCRIPT_DIR/builds/$BUILD_TYPE"

echo "🔍 llama.cpp source: $LLAMACPP_DIR"
echo "🏗️  Build type: $BUILD_TYPE"
echo "🏗️  Build directory: $BUILD_DIR"
echo ""

cd "$LLAMACPP_DIR" || { echo "❌ llama.cpp not found at $LLAMACPP_DIR"; exit 1; }

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
    *)
        echo "❌ Unknown build type: $BUILD_TYPE"
        echo "   Usage: build.sh [rocm|vulkan]"
        exit 1
        ;;
esac

cmake --build "$BUILD_DIR" -j$(nproc)

echo ""
echo "✅ Build complete! ($BUILD_TYPE)"
echo "   Server: $BUILD_DIR/bin/llama-server"
echo "   Libs: $BUILD_DIR/lib/"

