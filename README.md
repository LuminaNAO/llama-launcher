# llama-launcher

Helper scripts for managing llama.cpp models and server.

## Placement

This repo is designed to be placed **next to** the main `llama.cpp` repo:

```
/path/to/code/
├── llama.cpp/           # Main llama.cpp repo
├── llama-launcher/     # This repo (contains these scripts)
│   ├── build.sh
│   ├── llama-server-launcher.sh
│   └── benchmark.sh
└── ...
```

The scripts automatically discover the `llama.cpp` repo by looking one level up from their location.

## Build Structure

Builds are now stored in a dedicated `builds/` directory:

```
llama-launcher/
├── builds/
│   ├── rocm/            # ROCm/HIP build
│   │   ├── bin/         # llama-server, etc.
│   │   └── lib/         # .so files
│   └── vulkan/          # Vulkan build (future)
├── build.sh
├── llama-server-launcher.sh
└── benchmark.sh
```

This keeps the source tree clean and makes it easy to maintain multiple configurations.

## Scripts

### `build.sh`

Builds llama.cpp for a specific backend.

**Usage:**
```bash
cd /path/to/code/llama-launcher
./build.sh rocm
```

**Supported backends:**
- `rocm` - AMD ROCm/HIP (default)
- `vulkan` - Vulkan backend

**What it does:**
- Creates build directory in `builds/<backend>/`
- Runs CMake with backend-specific configuration
- Builds the project

**Error message if llama.cpp not found:**
```
❌ llama.cpp not found at /path/to/code/llama.cpp
```

### `llama-server-launcher.sh`

Lists available `.gguf` models and launches llama-server with your selection.

**Usage:**
```bash
cd /path/to/code/llama-launcher
./llama-server-launcher.sh
```

**Environment Variables:**
- `LLAMACPP_MODELS_DIR` - Path to models directory (default: `/usr/local/share/llama.cpp/models`)
- `LLAMACPP_BUILD_TYPE` - Backend to use (rocm, vulkan, etc.)

**Error messages:**

If `llama-server` binary not found:
```
❌ llama-server not found at /path/to/builds/rocm/bin/llama-server

Available builds:
  ✅ rocm
  ⚠️  vulkan (not built)

To build a backend, run:
  cd /path/to/code/llama-launcher
  ./build.sh [rocm|vulkan]
```

If no `.gguf` models found:
```
❌ No .gguf models found in /path/to/models
```

If invalid model selection:
```
❌ Invalid selection
```

### `benchmark.sh`

Runs performance benchmarks on llama.cpp servers with interactive model selection.

**Usage:**
```bash
cd /path/to/code/llama-launcher
./benchmark.sh
```

**What it does:**
- Reads model path from config (same as launcher)
- Lists available `.gguf` models interactively
- Lets you select a model
- Starts llama-server in background
- Runs multiple benchmark tests
- Measures tokens/sec, duration, and generates CSV results
- Stops the server when done

**Benchmark tests:**
- Short response (100 tokens)
- Medium response (500 tokens)
- Long response (2000 tokens)

**Output:**
- Real-time progress
- Results saved to `$HOME/benchmark-results.csv`
- Summary table at the end

**Environment Variables:**
- `LLAMACPP_BUILD_TYPE` - Backend to use (rocm, vulkan, etc.)
- `LLAMACPP_MODELS_DIR` - Path to models directory (default: `/usr/local/share/llama.cpp/models`)

## Configuration

### Default Paths

The scripts expect:
- `llama.cpp` repo at: `$(dirname "$0")/../../llama.cpp`
- Builds directory at: `$(dirname "$0")/builds/`
- Models directory at: `/usr/local/share/llama.cpp/models`

### Customization

Override defaults via environment variables before running scripts:

```bash
export LLAMACPP_MODELS_DIR=/custom/path/to/models
./llama-server-launcher.sh
```

## Requirements

- `cmake` - For building llama.cpp
- `git` - For cloning llama.cpp (if needed)
- `bash` - Script interpreter
- `curl` - For benchmarking
- `jq` - For parsing JSON responses
- `bc` - For floating-point calculations

## ROCm Build Configuration

The default ROCm build uses:
- `GGML_HIP=ON`
- `AMDGPU_TARGETS=gfx1151` (RDNA 3 - Strix Halo)
- `GGML_HIP_ROCWMMA_FATTN=ON` (FlashAttention)
- `CMAKE_BUILD_TYPE=Release`

## Vulkan Build Configuration

To build for Vulkan, you'll need:
- Vulkan SDK installed
- GLSLC compiler

```bash
export LLAMACPP_BUILD_TYPE=vulkan
./build.sh vulkan
```

## License

MIT (same as llama.cpp)
