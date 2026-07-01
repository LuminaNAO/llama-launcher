# llama-launcher

> **⚠️ This GitHub repository is a read-only mirror.** The primary repository is on [Codeberg](https://codeberg.org/LuminaNAO/llama-launcher). Please raise issues and submit pull requests there — submissions to this GitHub mirror will be ignored.

Helper scripts for building llama.cpp and running `llama-server` with per-model configs, launch history, benchmarking, and SSH tunneling.

## Layout

Place next to the `llama.cpp` repo:

```
code/
├── llama.cpp/
└── llama-launcher/
    ├── builds/<backend>/{bin,lib}/   # built artifacts
    ├── model-configs/                # per-model tunes (*.yaml)
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

On first install it also offers the author best pick from `model-configs/author-best-picks.sh`. The current pick is `Ornith-1.0-35B-NVFP4-MTP-GGUF.32gb-mxfp4-mtp-draft-coding-v1.yaml` with `ornith-1.0-35b-MXFP4_MOE-MTP.gguf`, downloaded through `download-model.sh` when approved.

It symlinks `llama-launcher`, `llama-build`, and `llama-download-model` into `/usr/local/bin` (if root) or `~/.local/bin` (otherwise), then installs a managed shell startup block for bash, zsh, or fish so `PATH` and the launcher environment are available in new shells.

## Scripts

### `build-llamacpp.sh <cpu|rocm|vulkan|cuda> [gpu-arch]`

Builds llama.cpp into `builds/<backend>/`. For GPU backends, the GPU arch (gfx target or CUDA compute cap) is auto-detected via `rocminfo` / `nvidia-smi` and can be overridden.
When installed, this script is available as `llama-build`.
For packaged installs, source discovery also checks AUR helper build caches such as `~/.cache/paru/clone/llama-hdd/src/llama-hdd` and `~/.cache/yay/llama-hdd/src/llama-hdd`.

### `llama-server-launcher.sh`

Interactive launcher with per-model configs and launch history.

Run without flags for the interactive launcher. Enter `s` from the recent-launch or build menus to open Settings. Settings edits the repo-local `.llama-launcher-config` for global defaults such as model directory, HDD slot-cache directory, HDD slot-cache disk limits, ports, bind host, API key, log colors, and default build type.

**Flags:**

| Flag | Description |
|------|-------------|
| `--build <type>` | cpu / rocm / vulkan / cuda (skips build menu) |
| `--model <path>` | Path to `.gguf` (skips model menu) |
| `--tune <name>`  | Named tune from model's `.yaml` |
| `--seed <N>`     | Override seed |
| `--context <N>`  | Override context size |
| `--parallel <N>` | Override parallel slots |
| `--hdd-cache`    | Enable disk-backed slot cache and force `CACHE_RAM=0`. For full benefit (prompt-checkpoint resumption — avoids cold prefill on prompt switch for hybrid/MTP models), install [`llama-hdd`](https://codeberg.org/LuminaNAO/git/llama-hdd.cpp) instead of vanilla `llama.cpp`. With vanilla llama.cpp the slot KV still restores, but the `common_prompt_checkpoint` list is lost and the model cold-prefills. |
| `--no-hdd-cache` | Disable disk-backed slot cache for this launch; flag-driven launches default off when neither HDD flag is passed |
| `--proxy`        | Enable deep-logging proxy (off by default) |
| `--log`          | Tee server output to `llama.log` (in the llama-launcher dir; off by default) |
| `--save`         | Persist effective settings into the model's `.yaml` |

**Subcommand:**

```bash
llama-launcher stop      # SIGINT llama-server and deep proxy; SIGTERM after 10s
```

A dedicated `llama-launcher-log` command is also installed alongside `llama-launcher`
(by the same `install.sh` / AUR package). It is equivalent to `tail -f` on the
repo-local log file:

```bash
llama-launcher-log          # follow $LLAMA_LAUNCHER_DIR/llama.log
llama-launcher log          # same (subcommand form also works)
llama-launcher-log -n 200   # start from last 200 lines, then follow
```

(When no log exists yet it prints a helpful message instead of failing silently.)

**Launch history:** the last 5 unique `build+model+tune` combinations are shown at startup. Selecting one re-applies the flags (`--log` / `--proxy`) used in that launch. Stored at `.launch-history`.

**Per-model tunes:** `model-configs/<model>.yaml` or `model-configs/<model>.<tune>.yaml`. CLI flags override saved values; use `--save` to persist. Tune files are YAML data, not sourced shell. The launcher loads only an allowlist of keys under `settings`, which is intentional groundwork for future user-shared tunes.

The interactive tune menu also supports `n` for a new tune and `e` to edit an existing tune. New tunes can start fresh from the current system profile or copy an existing tune first.

**Models directory:** scanned from `LLAMACPP_MODELS_DIR` or `/usr/local/share/llama.cpp/models`. Global settings are saved to `.llama-launcher-config`.

### `llama-deep-proxy.mjs <listen-port> <backend-port> [log-file]`

Transparent HTTP proxy that tees request/response bodies to a log (default `llama-deep.log` in the llama-launcher dir). Started automatically by the launcher when `--proxy` is passed.

With `--slot-cache-dir` it also manages the disk-backed slot cache. Slot routing prefers explicit client identity headers over prompt-content hashing:

| Header | Meaning |
|--------|---------|
| `x-openclaw-session-id` | Stable conversation id; maps 1:1 to a sanitized, exact-match-only slot file. Works for any channel shape (`signal:group:…`, `tui-…`, web GUI ids). |
| `x-openclaw-agent-kind` | `main` or `subagent`. Subagent traffic never touches persisted slots. |
| `x-openclaw-cache-policy` | `hdd` or `no-hdd`. `no-hdd` on a main session restores its warm cache read-only; the response is never persisted. |

Requests without headers fall back to body identity keys (`session_id`, `conversation_id`, …) and finally a system+first-message anchor hash with copy-on-write branch slots. OpenClaw subagent and internal-runtime traffic is also recognized by body markers when headers are absent.

Slots are persisted **only on session switch and graceful shutdown** — never per response. An unclean death loses the turns since the last switch; the transcript lives with the client and the cache re-fills on the next prefill.

### `download-model.sh <hf-url-or-repo>`

Interactive GGUF downloader from HuggingFace with quant selection. Reads `HF_TOKEN` or `~/.cache/huggingface/token`. Use `--filename <gguf-name>` to preselect a specific GGUF while still showing the download summary and confirmation.

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
| `utils/diagnose-cache-divergence.mjs [log] --latest` | Compare deep-log request bodies from the log tail and explain prompt/cache divergence. |
| `utils/load-test.sh` | Fire concurrent diverse requests, monitor slot usage. |
| `utils/soak-test-v3b.sh` | 1-hour soak test under concurrent high-context load. |
| `utils/vram-stress-test.sh` | Peak VRAM/GTT measurement across all slots. |

See `utils/BENCHMARK-RESULTS.md` for recorded results.

## Requirements

`cmake`, `git`, `bash`, `curl`, `jq`, `yq` 3.x (Python jq-wrapper, common distro package), `bc`, `node` (for the deep proxy), `ssh` (for tunnels).

## License

MIT (same as llama.cpp).

## GPG Signature

Public key available in [KEYS](KEYS) and on keys.openpgp.org (`5EBC6FD72F5664B9AC6B359CF09191C191DED4BA`).

## Install

**AUR (Arch Linux):**

```bash
yay -S llama-launcher
# or
paru -S llama-launcher
```

**Manual:**

```bash
git clone https://codeberg.org/LuminaNAO/llama-launcher.git
cd llama-launcher
./install.sh
```

## Contributing

Issues and pull requests should be submitted on [Codeberg](https://codeberg.org/LuminaNAO/llama-launcher). The GitHub mirror is read-only.
