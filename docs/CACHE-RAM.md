# `--cache-ram` / `CACHE_RAM` — what it actually is

This doc exists because the flag name is misleading and has led to repeated
mistakes when tuning. Read this before adjusting `CACHE_RAM` in a tune file.

## The short version

`--cache-ram N` enables llama-server's **host-memory prompt cache**
(PR [#16391](https://github.com/ggml-org/llama.cpp/pull/16391)). It stores
processed-prompt KV state in RAM so that repeat/warm prompts skip
prompt-processing and return ~8-9× faster.

- **Allocation:** `std::vector<uint8_t>` on the C++ heap. Pure RAM.
- **Storage:** **not** written to disk by llama-server. No `mmap`, `fopen`,
  `ofstream` anywhere in the cache code path.
- **Limit:** `N` is a MiB ceiling. Actual usage is whatever the cache
  can allocate up to `N`.
- **Overflow behavior:** on `std::bad_alloc`, cache self-shrinks to 40% of
  its current size (`limit_size = 0.4 * size()`). It will never crash
  the server — just evict older entries.

## The nuance: spill to swap

Cache-ram pages are **not mlocked**. Under system memory pressure, the
Linux kernel will page them out to swap like any anonymous heap allocation.
This is effectively a disk-backed cache, courtesy of the VM subsystem.

**Latency tiers for a ~38K token prompt on MiniMax M2 (q4_0 KV):**

| Scenario | Latency | Why |
|---|---|---|
| Cache in RAM | µs-ms | heap read |
| Cache in swap (NVMe) | ~2-3 s | ~2.4 GB KV state / ~1 GB/s random read |
| No cache (cold PP) | ~9 min | 38K tokens @ ~69 tok/s PP |

**Warm-from-swap is ~200× faster than cold PP.** On memory-constrained
boxes (e.g. 128 GB unified running a 102 GB model), swap-spill is a
feature, not a bug — it extends usable cache well beyond resident RAM
with a tolerable latency hit on overflow.

## Sizing guidance

- **Set `CACHE_RAM` aspirationally high** (e.g. `102400` = 100 GiB on a
  128 GiB box). The value is a ceiling; it will never allocate that much
  because RAM and self-shrink will gate it first.
- **Don't reason about it as "RAM required"** — it isn't reserved up front,
  and swap absorbs the overflow.
- **Do pair it with:**
  - `--mlock` on the model weights (so they can't be swapped out and
    ruined by cache pressure)
  - a disk swapfile sized to tolerate spill (e.g. 128 GiB on an inference
    box; btrfs `mkswapfile` is fine)
  - `vm.swappiness=10` — kernel stays reluctant, swaps anonymous pages
    only when necessary
  - optional: `zswap` — compresses swapped pages in-RAM, often lets us
    avoid actually touching the SSD at all

## Don't confuse with `--prompt-cache FNAME`

Two completely different features with unfortunately similar names:

| Flag | Mechanism | Used by |
|---|---|---|
| **`--cache-ram N`** | host-memory heap (can spill to swap) | llama-server, automatic |
| **`--prompt-cache FNAME`** | file-backed KV dump at explicit path | llama-cli, manual |

Only `--cache-ram` is relevant for the server workflow. `--prompt-cache` is
a legacy CLI feature.

## Source references

- `tools/server/server-task.h:622` — `struct server_prompt_cache`
- `tools/server/server-task.cpp:1991` — `server_prompt_cache::alloc()`
- `tools/server/server-context.cpp:933-941` — enablement + log line
- `common/common.h:574` — `int32_t cache_ram_mib`
- `common/arg.cpp:1305-1307` — CLI binding
- PR #16391, commit `d00cbea63c67` (Oct 2025) — title literally
  "host-memory prompt caching"
