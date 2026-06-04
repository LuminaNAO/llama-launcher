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
    ├── utils/                        # maintenance, benchmarking, service tools
    │   ├── benchmark-results/        # JSONL/TXT results
    │   └── stress-tests/             # specialized load/stress scripts
    ├── llama-server-launcher.sh
    └── ...
```

Scripts resolve their own location via `readlink -f`, so the launcher can be symlinked into `PATH`.

## Install the launcher into `PATH`

```bash
./install.sh
```

The installer is interactive. It checks `LLAMACPP_MODELS_DIR` and `LLAMACPP_SLOT_SAVE_PATH`, scans common GGUF locations including the Hugging Face cache, suggests defaults, creates missing directories when approved, and saves the result to `.llama-launcher-config`.

It symlinks `llama-launcher` into `/usr/local/bin` (if root) or `~/.local/bin` (otherwise), then installs a managed shell startup block for bash, zsh, or fish so `PATH` and the launcher environment are available in new shells.

## Scripts

### `build-llamacpp.sh <rocm|vulkan|cuda> [gpu-arch]`

Builds llama.cpp into `builds/<backend>/`. GPU arch (gfx target or CUDA compute cap) is auto-detected via `rocminfo` / `nvidia-smi` and can be overridden.

### `llama-server-launcher.sh`

Interactive launcher with per-model configs and launch history.

Run without flags for the interactive launcher. Enter `s` from the recent-launch or build menus to open Settings. Settings edits the repo-local `.llama-launcher-config` for global defaults such as model directory, HDD slot-cache directory, HDD slot-cache disk limits, ports, bind host, API key, log colors, and default build type.

**Flags:**

| Flag | Description |
|------|-------------|
| `--build <type>` | rocm / vulkan / cuda (skips build menu) |
| `--model <path>` | Path to `.gguf` (skips model menu) |
| `--tune <name>`  | Named tune from model's `.conf` |
| `--seed <N>`     | Override seed |
| `--context <N>`  | Override context size |
| `--parallel <N>` | Override parallel slots |
| `--hdd-cache`    | Enable disk-backed slot cache and force `CACHE_RAM=0`. For full benefit (prompt-checkpoint resumption — avoids cold prefill on prompt switch for hybrid/MTP models), install [`llama-hdd`](https://codeberg.org/LuminaNAO/git/llama-hdd.cpp) instead of vanilla `llama.cpp`. With vanilla llama.cpp the slot KV still restores, but the `common_prompt_checkpoint` list is lost and the model cold-prefills. |
| `--no-hdd-cache` | Disable disk-backed slot cache for this launch; flag-driven launches default off when neither HDD flag is passed |
| `--proxy`        | Enable deep-logging proxy (off by default) |
| `--log`          | Tee server output to `~/llama.log` (off by default) |
| `--save`         | Persist effective settings into the model's `.conf` |

**Subcommand:**

```bash
llama-launcher stop      # SIGINT llama-server and deep proxy; SIGTERM after 10s
```

**Launch history:** the last 5 unique `build+model+tune` combinations are shown at startup. Selecting one re-applies the flags (`--log` / `--proxy`) used in that launch. Stored at `.launch-history`.

**Per-model configs:** `model-configs/<model>.conf`. CLI flags override saved values; use `--save` to persist.

**Models directory:** scanned from `LLAMACPP_MODELS_DIR` or `/usr/local/share/llama.cpp/models`. Global settings are saved to `.llama-launcher-config`.

### `llama-deep-proxy.mjs <listen-port> <backend-port> [log-file]`

Transparent HTTP proxy that tees request/response bodies to a log (default `~/llama-deep.log`). Started automatically by the launcher when `--proxy` is passed.

### `download-model.sh <hf-url-or-repo>`

Interactive GGUF downloader from HuggingFace with quant selection. Reads `HF_TOKEN` or `~/.cache/huggingface/token`.

### `utils/install-service.sh [--seed N] [--uninstall] [--system]`

Installs `llama-server` as a systemd unit. Defaults to a per-user service; pass `--system` with sudo for a system service. The installer follows the launcher flow for build, model, tune, vision, proxy, and HDD cache choices.

### `utils/ssh-tunnel.sh [remote] [--port N] [--api-key K] [--status|--stop]`

Manage an SSH tunnel to a remote `llama-server`. History in `.tunnel-history`.

### `utils/mlock-fixer.sh`

Raises `memlock` in `/etc/security/limits.conf` so `llama-server --mlock` doesn't swap. Requires re-login.

## Tuning notes

- [`docs/CACHE-RAM.md`](docs/CACHE-RAM.md) — what `--cache-ram` / `CACHE_RAM` actually is (hint: it's not what the name suggests). **Read this before adjusting the value in a tune.**

## Benchmarking / stress

| Script | Purpose |
|--------|---------|
| `utils/benchmark.sh <label>` | Inference benchmarks across context sizes against `localhost:40801`. Writes `utils/benchmark-results/bench-<label>-<ts>.jsonl`. |
| `utils/bench-batch-sizes.sh` | Sweep `-b` values, restart server between runs, log GTT. |
| `utils/benchmark-backends.sh [model]` | Compare vulkan / rocm / rocm-gfx1100 via `llama-bench`. |
| `utils/load-test.sh` | Fire concurrent diverse requests, monitor slot usage. |
| `utils/soak-test-v3b.sh` | 1-hour soak test under concurrent high-context load. |
| `utils/vram-stress-test.sh` | Peak VRAM/GTT measurement across all slots. |

See `utils/BENCHMARK-RESULTS.md` for recorded results.

## Requirements

`cmake`, `git`, `bash`, `curl`, `jq`, `bc`, `node` (for the deep proxy), `ssh` (for tunnels).

## License

MIT (same as llama.cpp).
