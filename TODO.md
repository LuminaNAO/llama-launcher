# TODO

## Verify slot save actually wrote the file (don't trust 200 alone) — done

llama-server's `/slots/0?action=save` endpoint returns HTTP 200 even when
the underlying `llama_state_seq_save_file` call fails (e.g., parent dir
missing, disk full, permission denied). The file-open error is logged to
the server's stderr but never propagated to the HTTP response body. The
proxy currently logs `SLOT save status=200` and treats this as success,
silently leaving the slot file unwritten. Next restore for that hash
returns a misleading 400 "no save file or invalid".

Discovered 2026-04-26 when an inline `find ... -type d -empty -delete`
during a "clean all" operation removed the per-quant subdir while the
server was running. Saves silently failed for the rest of the session,
producing recurring 400s on restore. The proxy's `ensureSlotCacheDir()`
mkdir-before-save now defends against that specific case, but the broader
"trust 200 even when file write failed" gap remains for other failure
modes (full disk, ENOSPC, EACCES, etc.).

### Fix

Implemented in `llama-deep-proxy.mjs::ensureSlotLoaded` and
`saveCurrentSlot`: parse the JSON response body and require both
`n_saved > 0` and `n_written > 0` before logging a save as successful.
Detected failures now log clearly (red), including the parsed counters.

```js
const r = await callSlotAction("save", `${currentSession}.bin`);
const save = slotSaveSucceeded(r);
slotLog(
  `--- SLOT save status=${r.status} n_saved=${save.nSaved} n_written=${save.nWritten}\n`,
  save.ok ? C_CYAN : C_RED,
);
```

### Upstream

llama.cpp side could be reported separately — the slot save endpoint
returning 200 on failed write is a contract violation that affects any
client trusting the status code. Worth a one-line PR if motivated:
propagate the file-open error to `result_->error()` instead of bubbling
out via `LLAMA_LOG_ERROR`.

## HDD slot restore does not preserve prompt checkpoints

Observed 2026-05-05 with `Qwen3.6-27B.62gb-q8-131k-v2`: the proxy proved
that HDD slot save/restore moved real bytes:

```text
SLOT save status=200 n_saved=43 n_written=158392888
SLOT restore status=200 n_restored=43 n_read=158392888
```

But the next request still fell back to cold prompt processing:

```text
common_context_can_seq_rm: the target context does not support partial sequence removal
slot update_slots: n_past = 28, slot.prompt.tokens.size() = 43, seq_id = 0, pos_min = 42, n_swa = 0
slot update_slots: forcing full prompt re-processing due to lack of cache data
```

Root cause: `llama_state_seq_save_file()` / `llama_state_seq_load_file()`
persist the raw sequence state and tokens, but not
`server_prompt.checkpoints`. `CACHE_RAM` works because
`server_prompt_cache::alloc()` copies the whole `server_prompt`, including
its checkpoint list:

```cpp
cur = {
    /*.tokens      =*/ prompt.tokens.clone(),
    /*.data        =*/ std::move(state_data),
    /*.checkpoints =*/ prompt.checkpoints,
};
```

For Qwen3.6 / hybrid / recurrent contexts where llama.cpp reports
`COMMON_CONTEXT_SEQ_RM_TYPE_FULL`, restored state cannot be partially
trimmed. If the saved slot contains `prompt + generated output` and the next
request only matches the prompt prefix, llama.cpp needs an earlier checkpoint
to roll back. The HDD slot file does not have that checkpoint, so the restore
is valid but not useful for prompt reuse.

### Implications

- Disabling context checkpoints when `CACHE_RAM=0` is counterproductive for
  these models. The launcher should leave checkpoint settings alone.
- HDD slot persistence can still be useful for append-only continuations where
  the next request includes the entire saved transcript plus new tokens.
- It will not replace `CACHE_RAM` for replay/branching workloads until
  llama.cpp can persist and restore `server_prompt.checkpoints`, or exposes a
  prompt-cache save/load endpoint that includes checkpoint data.

### Fix direction

Local proof-of-fix implemented in sibling `~/code/llama.cpp`:
`tools/server/server-context.cpp` now writes a sidecar file next to each slot
save, named `<slot>.bin.ckpt`, and reloads it during slot restore. The sidecar
serializes the missing checkpoint state:

1. `server_prompt.checkpoints` metadata
2. checkpoint byte buffers

The existing `.bin` file still carries `server_prompt.tokens` and the
`llama_state_seq_*` state bytes.

Validation on Qwen3.6-27B with `CACHE_RAM=0`, `SLOT_SAVE_PATH`, and 32k ctx:

```text
saved 2 context checkpoint(s), sidecar size = 299.252 MiB
restored 2 context checkpoint(s), sidecar size = 299.252 MiB
restored context checkpoint (pos_min = 3416, pos_max = 3416, n_tokens = 3417, n_past = 3417, size = 149.626 MiB)
prompt eval time = 410.50 ms / 24 tokens
usage: cache_read_input_tokens=3417, input_tokens=24
```

Before the sidecar patch, the same append test cold-prefilled:

```text
forcing full prompt re-processing due to lack of cache data
usage: cache_read_input_tokens=0, input_tokens=3439
```

Helper-side workaround: use non-zero `CACHE_RAM` for Qwen3.6/full-seq-rm
models when prompt replay/branching matters, and let the kernel page the
prompt cache to swap/NVMe if RAM is tight.

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
