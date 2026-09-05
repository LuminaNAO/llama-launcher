# Running-config snapshot — Qwen3.8-27B-NVFP4-MTP-HIGHEST

Captured 2026-08-21 13:21 AWST, read-only, server not disrupted.
Reason for capture: this configuration reaches ~9,164 t/s prefill and is the
fastest prefill measured on this box. Preserve it before any tune edits.

## Process identity

| | |
|---|---|
| PID | 455601 |
| Started | Wed 2026-08-19 06:52:27 AWST |
| Uptime at capture | 2 d 06:28:48 |
| RSS | 6,732,800 KiB (~6.4 GiB host) |
| Server instance # in current llama.log | 65 (of 65 starts) |
| Binary | `~/code/llama-launcher/builds/cuda/bin/llama-server` |

## Ground truth: verbatim command line

Read from `/proc/455601/cmdline`. This — not the tune YAML — is what is
actually running. Full copy in `2026-08-21-nvfp4hi-cmdline.txt`.

```
llama-server
  -m /usr/local/share/llama.cpp/models/Qwen3.8-27B-NVFP4-MTP-HIGHEST/Qwen3.8-27B-NVFP4-MTP-HIGHEST.gguf
  -ngl 999
  -c 262144
  -fa on
  --temp 1.0  --top-p 0.95  --top-k 20  --min-p 0
  --threads 16
  -dio
  --timeout 3600
  --host 127.0.0.1  --port 40802
  --api-key ollama-local
  --jinja
  --parallel 1
  --kv-unified
  --cache-ram 0
  -ctk q4_0  -ctv q4_0
  --checkpoint-min-step 4096
  --ctx-checkpoints 20
  --slot-save-max-checkpoints 10
  --seed 1320
  --mlock
  --mmproj /usr/local/share/llama.cpp/models/Qwen3.8-27B-NVFP4-MTP-HIGHEST/mmproj-BF16.gguf
  --slot-save-path /usr/local/share/llama.cpp/llama-slots/Qwen3.8-27B-NVFP4-MTP-HIGHEST
  --log-colors on
  --spec-type draft-mtp
  --spec-draft-n-max 3
  -b 2048  -ub 512
  --image-min-tokens 1024
  --no-mmproj-offload
  --chat-template-file /usr/local/share/llama.cpp/models/Qwen3.8-27B-UD-Q6_K_XL/chat_template_fixed.jinja
  --reasoning-format deepseek
  --chat-template-kwargs {"reasoning_effort":"xhigh"}
```

Confirmed from the live process: flash attention is **on** (`-fa on`),
KV is **q4_0** both halves, context is the full **262144**, MTP speculative
decoding is active at **draft depth 3**, and batching is **-b 2048 / -ub 512**.

## Build provenance

| | |
|---|---|
| Source repo | `~/code/llama-hdd.cpp` |
| HEAD | `37043bc09ca34724cbc6d4d245f14e097861bd53` |
| Describe | `b10488-31-g37043bc09` |
| Commit date | 2026-08-18 22:16:00 +0800 |
| Commit subject | shrink: adopt upstream packed slot format, drop media sidecar machinery |
| Worktree | clean at capture |
| Binaries built | 2026-08-18 22:50–22:54 (`libggml-*.so.0.20.2`) |

## Weights and assets

| File | Size | mtime |
|---|---|---|
| `Qwen3.8-27B-NVFP4-MTP-HIGHEST.gguf` | 23,185,001,824 B | 2026-08-18 23:42 |
| `mmproj-BF16.gguf` | 931,146,432 B | 2026-08-18 22:51 |
| `chat_template_fixed.jinja` (froggeric, borrowed from the UD-Q6_K_XL dir) | 22,156 B | 2026-08-18 21:56 |

Both GGUFs were sha256-verified against HuggingFace LFS metadata at download time.
Note the chat template lives under the **UD-Q6_K_XL** model directory — deleting
that directory would break this configuration.

## Host / GPU at capture

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 5090 (Blackwell sm_120) |
| Driver | 610.57.04 |
| VRAM | 28,442 / 32,607 MiB in use |
| Power draw | 597 W |
| SM clock | 2,880 MHz |

## Measured performance on this exact configuration

Prefill, from `llama.log` (rate varies with prefill size and context depth):

| Prefill size | Rate |
|---|---|
| 16,190 tok | **9,164 t/s** (best observed) |
| 16,014 tok | 9,003 t/s |
| 30,796 tok | 8,737 t/s |
| 42,104 tok | 8,413 t/s |
| ~200,000 tok | ~4,440 t/s |
| ~300,000 tok | ~3,339 t/s |

Peak sits near a 16k prefill and decays gently with size; deep context costs more
per token because attention runs against the accumulated KV.

Decode: ~101 t/s on short context, falling to ~62 t/s at ~143k depth.
MTP draft acceptance on this model: **0.32–0.68** (mean length ~2.5–3.0).

Tuning evidence behind two of the flags:
- `-ub 512` measured **+12% prefill** over `-ub 256` on this model (7,518 vs
  6,719 t/s @32k). Raising further is flat — `ub 1024` and `b 4096 / ub 2048`
  were swept and land within noise of `b 2048 / ub 512`.
- Draft depth swept at 2 / 3 / 4 on this model across prose, code and reasoning
  prompts: no depth dominates, spread smaller than temp-1.0 sampling noise.
  Depth 3 kept.

## Known caveats (documentation only — none affect runtime)

1. **The tune YAML's notes describe a different model.** The file
   `Qwen3.8-27B-NVFP4-MTP-HIGHEST.32gb-cuda-5090-nvfp4hi-262k-v1.yaml` carries
   `name: 32gb-cuda-5090-nvfp4nv-262k-v1` and a notes block measured on
   **Qwen3.6**-27B-NVIDIA-NVFP4-MTP-Q8attn on 2026-08-06. The throughput
   (155–181 t/s), acceptance (0.82–0.90) and perplexity figures in those notes
   are **not** this model's. The runtime settings themselves have since been
   validated on HIGHEST (see above); only the prose and the `name:` field are
   stale. A verbatim copy is preserved here as `2026-08-21-nvfp4hi-tune.yaml`.

2. **Checkpoint sizing is inherited.** `--checkpoint-min-step 4096` and
   `--ctx-checkpoints 20` were fitted from Qwen3.6 logs, not this model's.
   Unverified for HIGHEST, but running without complaint.

3. **Historical CUDA watchdog crashes, not on this instance.** The current
   llama.log holds four `CUDA error: the launch timed out and was terminated`
   aborts, all with an identical stack through
   `common_speculative_impl_draft_mtp::process` → `llama_get_embeddings_nextn`
   → `ggml_backend_cuda_synchronize`, i.e. the MTP draft path. They occurred
   after server starts #4, #10, #22, #23 and #36 — during the multi-model
   gauntlet, when several different models were being rotated. **The current
   instance is start #65 and has run 2 d 06 h with none.** Which model was
   loaded at each crash is not established, so these are not attributable to
   HIGHEST. A fifth, separate abort (`resource allocation failed`) also appears.

## Restoring this exactly

The launcher invocation that produced the above:

```
llama-launcher --build cuda \
  --model /usr/local/share/llama.cpp/models/Qwen3.8-27B-NVFP4-MTP-HIGHEST/Qwen3.8-27B-NVFP4-MTP-HIGHEST.gguf \
  --tune 32gb-cuda-5090-nvfp4hi-262k-v1 \
  --port 40801 --internal-port 40802 --log --proxy --hdd-cache --vision
```

If the tune file is ever edited and prefill regresses, diff the live
`/proc/<pid>/cmdline` against `2026-08-21-nvfp4hi-cmdline.txt` — that file is
the authoritative record of the fast configuration.

To rebuild the identical binary: `git -C ~/code/llama-hdd.cpp checkout 37043bc09`
then `llama-build cuda`.
