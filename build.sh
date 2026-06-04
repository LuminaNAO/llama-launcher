# Build llama.cpp for ROCm in the builds/ directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMACPP_DIR="$(dirname "$SCRIPT_DIR")/llama.cpp"
BUILD_DIR="$SCRIPT_DIR/builds/rocm"

echo "🔍 llama.cpp source: $LLAMACPP_DIR"
echo "🏗️  Build directory: $BUILD_DIR"
echo ""

cd "$LLAMACPP_DIR" || { echo "❌ llama.cpp not found at $LLAMACPP_DIR"; exit 1; }

mkdir -p "$BUILD_DIR"

cmake -S . -B "$BUILD_DIR" \
  -DGGML_HIP=ON \
  -DAMDGPU_TARGETS=gfx1151 \
  -DGGML_HIP_ROCWMMA_FATTN=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" -j$(nproc)

echo ""
echo "✅ Build complete!"
echo "   Server: $BUILD_DIR/bin/llama-server"
echo "   Libs: $BUILD_DIR/lib/"

