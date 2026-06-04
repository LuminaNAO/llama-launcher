# TODO

## Per-model namespacing for SLOT_SAVE_PATH

Slot save files are model-specific KV cache bytes. A file saved while running
Gemma cannot be restored when MiniMax (or any other model) is loaded —
llama-server returns `400 invalid slot save file`. Currently all tunes that
opt in to slot save share one flat directory `/mnt/storage/llama-slots/`,
so every model switch leaves stale files that the next session can't use,
and produces noisy 400s on every restore attempt.

### Fix

Auto-suffix `SLOT_SAVE_PATH` with the model folder name in
`llama-server-launcher.sh`. Conceptually:

```bash
EFFECTIVE_SLOT_SAVE_PATH="$SLOT_SAVE_PATH/$(basename "$MODEL_FOLDER")"
mkdir -p "$EFFECTIVE_SLOT_SAVE_PATH"
# pass to both --slot-save-path (server) and --slot-cache-dir (proxy)
```

Tunes still set `SLOT_SAVE_PATH=/mnt/storage/llama-slots` as the *root*;
the launcher namespaces it. Different models get isolated cache pools,
swapping models doesn't pollute caches, and no one ever sees a 400 from a
stale-from-other-model file.

### Steps

1. [ ] Add `EFFECTIVE_SLOT_SAVE_PATH` derivation in launcher (~line 845).
2. [ ] Update `slot-tools.sh` to walk per-model subdirs in `list`.
3. [ ] Migration: move existing flat files into a default `unknown/` dir
   on first launch after the change, so nothing surprises the user.
4. [ ] Document the namespace scheme in the SLOT_SAVE_PATH comment in
   the MiniMax tune file.

### Context

Discovered 2026-04-26 mid-test when switching from Gemma test tune back to
MiniMax: every restore attempt returned 400 because the slot files on disk
were Gemma's KV bytes. The 400 is the *safe* failure — server refuses to
reinterpret incompatible bytes — but it makes the slot dir useless for
multi-model workflows.

## Enable --mlock to prevent swap thrashing

llama-server should use `--mlock` to pin memory pages and prevent the kernel
from swapping them out. Without this, the 67 GB model + KV cache can get
partially swapped, causing catastrophic performance drops (0.02 tok/s observed
when 22.5 GB was in swap).

### Steps

1. [x] Raise memlock ulimit. Done on buildhost (2026-04-22) via
   `~/code/framework-server-setup/scripts/elevate-memlock.sh --all`.
   PENDING on `framed`.
2. [x] Re-login. buildhost verified: `ulimit -l` prints `unlimited`.
3. [x] Add `--mlock` to the llama-server launch args in `llama-server-launcher.sh`.
   Already present: the launcher auto-enables `--mlock` when `ulimit -l`
   is unlimited (see `MLOCK_FLAG` logic ~line 634).
4. [ ] Verify at next launch: look for "🔒 mlock: enabled" in startup output,
   then `grep VmLck /proc/$(pgrep -f llama-server)/status` should show
   ~model size pinned.

### Context

- Observed 2026-04-02: 40 GB cache + 67 GB model exceeded 125 GB RAM, kernel
  swapped 22.5 GB of llama-server pages, dual-slot generation dropped to
  0.02-0.43 tok/s. Reduced cache to 30 GB as immediate fix.
- Must be done on all machines running llama-server (buildhost, framed).
- Production path: use `~/code/framework-server-setup/scripts/llama-server-unit.sh`
  to install a systemd unit with `LimitMEMLOCK=infinity` + `MemorySwapMax=0`,
  which bypasses the ulimit dance entirely.

## Benchmark -ub 256 vs -ub 512 on MiniMax-M2.7 IQ4_XS

After a ROCm OOM on an 18k-token prompt at default `-b 2048 -ub 512`, the
`128gb-iq4xs-64k-v1` tune was changed to `-b 1024 -ub 256` to shrink the FA
tile scratch alloc. Claim (unverified): prompt-processing throughput roughly
halves on long prompts.

### Memory accounting (MiniMax M2: 48 heads × 128 head_dim, 64k ctx)

- GPU VRAM cap: ~118 GB (123044 MiB free at launch, default TTM)
- Model (UD-IQ4_XS, all 63 layers on GPU): 102.7 GB
- KV cache @ 64k ctx q8_0: ~8.4 GB
- Remaining for FA tile + compute scratch: ~6-7 GB

FA tile scratch scales ~linearly with -ub:
  - -ub 128: ~0.9 GB
  - -ub 256: ~1.8 GB (current — safe at 64k ctx)
  - -ub 512: ~3.6 GB (OOM'd at 64k ctx on 18k prompt)
  - -ub 1024: ~7.2 GB
  - -ub 2048: ~14.4 GB

### Goal: 100k ctx at -ub 512 or better

At 100k ctx, KV (q8_0) would be ~13 GB — far over budget with the model alone.
Pathways to get there:
  a. KV q4_0: halves KV to ~6.5 GB. Quality cost unknown on MiniMax.
  b. Bump TTM back to 116 GiB (limine kernel cmdline). Adds ~2 GB GPU budget.
  c. Both (a) and (b) combined is probably what gets us to 100k + -ub 512.

### Steps

1. Run `benchmark.sh` against current tune (`-ub 256 -b 1024`, 64k ctx) — baseline.
2. Variant B: `-ub 512 -b 2048` at 48k ctx (known-safe memory envelope).
3. Variant C: `-ub 512 -b 2048` at 100k ctx with KV q4_0 (reboot with TTM bump first).
4. Measure PP tok/s at 2k, 8k, 16k, 32k, 64k prompt lengths.
5. Decision rules:
   - If B beats A by <20% on PP, keep A (-ub 256) — not worth ctx sacrifice.
   - If B wins ≥30%, do variant C (q4_0 KV + TTM bump) for the 100k target.
   - If q4_0 KV shows visible quality regression on MiniMax, fall back to q8_0 + 72k ctx.

### Context

- Added 2026-04-22 after OOM during live use on 18,602-token prompt.
- Crash site: `launch_fattn<128,32,2>` → `ggml_cuda_device_malloc` in
  `ggml-cuda.cu:430`.
- Note: mlock / swap-disk fixes (2026-04-22) freed *system RAM*, not GPU VRAM
  — they don't directly help `-ub 512` fit. TTM bump and/or KV quant shrink
  are the actual levers.
- Target: 100k usable ctx, preferably at `-ub 512 -b 2048` for acceptable PP.
