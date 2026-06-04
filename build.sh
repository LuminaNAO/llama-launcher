cd /srv/shared/git/llama.cpp
mkdir -p build

cmake -S . -B build \
  -DGGML_HIP=ON \
  -DAMDGPU_TARGETS=gfx1151 \
  -DGGML_HIP_ROCWMMA_FATTN=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build -j$(nproc)

