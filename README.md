# llama-launcher

Helper scripts for managing llama.cpp models and server.

## Placement

This repo is designed to be placed **next to** the main `llama.cpp` repo:

```
/path/to/code/
├── llama.cpp/           # Main llama.cpp repo
├── llama-launcher/     # This repo (contains these scripts)
│   ├── build.sh
│   └── llama-server-launcher.sh
└── ...
```

The scripts automatically discover the `llama.cpp` repo by looking one level up from their location.

## Scripts

### `build.sh`

Builds llama.cpp from source. Runs from within the `llama.cpp` directory.

**Usage:**
```bash
cd /path/to/code/llama-launcher
./build.sh
```

**What it does:**
- Navigates into the `llama.cpp` repo
- Creates build directory
- Runs CMake with default configuration
- Builds the project

**Error message if llama.cpp not found:**
```
main llamacpp rep not found exiting
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
- `LLAMACPP_SERVER_PATH` - Override server path (auto-discovered by default)

**Error messages:**

If `llama-server` binary not found:
```
❌ llama-server not found at /path/to/llama.cpp/build/bin/llama-server
   Expected llama.cpp repo at: /path/to/llama.cpp
```

If no `.gguf` models found:
```
❌ No .gguf models found in /path/to/models
```

If invalid model selection:
```
❌ Invalid selection
```

## Configuration

### Default Paths

The scripts expect:
- `llama.cpp` repo at: `$(dirname "$0")/../../llama.cpp`
- `llama-server` binary at: `$(dirname "$0")/../../llama.cpp/build/bin/llama-server`
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

## License

MIT (same as llama.cpp)
