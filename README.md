# llama-launcher

Helper scripts for building llama.cpp and running `llama-server` with per-model configs, launch history, benchmarking, and SSH tunneling.

## Layout

Place next to the `llama.cpp` repo:

```
code/
├── llama.cpp/
└── llama-launcher/
    ├── builds/<backend>/{bin,lib}/   # built artifacts
    ├── model-configs/                # per-model tunes (*.conf)
    ├── benchmark-results/            # JSONL/TXT results
    ├── build.sh
    ├── llama-server-launcher.sh
    └── ...
```

Scripts resolve their own location via `readlink -f`, so the launcher can be symlinked into `PATH`.

## Install the launcher into `PATH`

```bash
./install.sh
```

Symlinks `llama-launcher` into `/usr/local/bin` (if root) or `~/.local/bin` (otherwise), creating the directory if needed and warning if it isn't on `PATH`. Then call `llama-launcher …` from anywhere.

## Scripts

### `build.sh <rocm|vulkan|cuda> [gpu-arch]`

Builds llama.cpp into `builds/<backend>/`. GPU arch (gfx target or CUDA compute cap) is auto-detected via `rocminfo` / `nvidia-smi` and can be overridden.

### `llama-server-launcher.sh`

Interactive launcher with per-model configs and launch history.

**Flags:**

| Flag | Description |
|------|-------------|
| `--build <type>` | rocm / vulkan / cuda (skips build menu) |
| `--model <path>` | Path to `.gguf` (skips model menu) |
| `--tune <name>`  | Named tune from model's `.conf` |
| `--seed <N>`     | Override seed |
| `--context <N>`  | Override context size |
| `--parallel <N>` | Override parallel slots |
| `--proxy`        | Enable deep-logging proxy (off by default) |
| `--log`          | Tee server output to `~/llama.log` (off by default) |
| `--save`         | Persist effective settings into the model's `.conf` |

**Subcommand:**

```bash
llama-launcher stop      # SIGINT llama-server and deep proxy; SIGTERM after 10s
```

**Launch history:** the last 5 unique `build+model+tune` combinations are shown at startup. Selecting one re-applies the flags (`--log` / `--proxy`) used in that launch. Stored at `.launch-history`.

**Per-model configs:** `model-configs/<model>.conf`. CLI flags override saved values; use `--save` to persist.

**Models directory:** scanned from `LLAMACPP_MODELS_DIR` or `/usr/local/share/llama.cpp/models`. Path is saved to `.llama-launcher-config` on first run.

### `llama-deep-proxy.mjs <listen-port> <backend-port> [log-file]`

Transparent HTTP proxy that tees request/response bodies to a log (default `~/llama-deep.log`). Started automatically by the launcher when `--proxy` is passed.

### `download-model.sh <hf-url-or-repo>`

Interactive GGUF downloader from HuggingFace with quant selection. Reads `HF_TOKEN` or `~/.cache/huggingface/token`.

### `install-service.sh [--seed N] [--uninstall]`

Installs `llama-server` as a systemd unit. Reads `LLAMACPP_BUILD_TYPE` (default `rocm`) to select the backend binary.

### `ssh-tunnel.sh [remote] [--port N] [--api-key K] [--status|--stop]`

Manage an SSH tunnel to a remote `llama-server`. History in `.tunnel-history`.

### `mlock-fixer.sh`

Raises `memlock` in `/etc/security/limits.conf` so `llama-server --mlock` doesn't swap. Requires re-login.

## Benchmarking / stress

| Script | Purpose |
|--------|---------|
| `benchmark.sh <label>` | Inference benchmarks across context sizes against `localhost:40801`. Writes `benchmark-results/bench-<label>-<ts>.jsonl`. |
| `bench-batch-sizes.sh` | Sweep `-b` values, restart server between runs, log GTT. |
| `benchmark-backends.sh [model]` | Compare vulkan / rocm / rocm-gfx1100 via `llama-bench`. |
| `load-test.sh` | Fire concurrent diverse requests, monitor slot usage. |
| `soak-test-v3b.sh` | 1-hour soak test under concurrent high-context load. |
| `vram-stress-test.sh` | Peak VRAM/GTT measurement across all slots. |
| `tune-gemma4-v3.sh` | Sweep v3a/v3b/v3c tunes, report best under VRAM limit. |

See `BENCHMARK-RESULTS.md` for recorded results.

## Requirements

`cmake`, `git`, `bash`, `curl`, `jq`, `bc`, `node` (for the deep proxy), `ssh` (for tunnels).

## License

MIT (same as llama.cpp).
