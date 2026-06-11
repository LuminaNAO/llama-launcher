# llama.cpp Backend Benchmark Results

**Date**: 2026-04-04
**Hardware**: AMD Ryzen AI Max+ 395 (Strix Halo), 128 GB unified memory, gfx1151
**Model**: Qwen3.5-35B-A3B-H-v2-Q8_0.gguf (34.4 GiB, MoE 256 experts, 8 active)
**llama.cpp**: build 8653 (f57c401e7)
**Launch params**: `-ngl 99 -fa on --no-mmap -c 488576 --parallel 2 -ctk q8_0 -ctv q8_0`

## Vulkan vs ROCm Comparison

### Generation Speed (tok/s) — higher is better

| Context Size | Vulkan TG | ROCm TG | Vulkan Advantage |
|-------------|-----------|---------|-----------------|
| Short (~25 tok) | **52.0-52.9** | 42.6-43.3 | +22% |
| Medium (~3k tok) | **51.3** | 41.3-41.6 | +24% |
| Large (~10k tok) | **49.4-49.5** | 37.3-37.5 | +33% |
| XL (~39k tok) | **44.2** | 26.9-27.0 | +64% |
| XXL (~52k tok) | **38.8** | FAILED | - |

### Prompt Processing Speed (tok/s) — higher is better

| Context Size | Vulkan PP | ROCm PP | Vulkan Advantage |
|-------------|-----------|---------|-----------------|
| Short (~25 tok) | **199** | 99-175 | +14-100% |
| Medium (~3k tok) | **931** | 324 | +187% |
| Large (~10k tok) | **863** | 223 | +287% |
| XL (~39k tok) | **563** | 93 | +505% |
| XXL (~52k tok) | **339** | FAILED | - |

## Key Findings

### 1. Vulkan is dramatically faster than ROCm on Strix Halo for Qwen 3.5

- Generation is 22-64% faster on Vulkan, with the gap widening at longer contexts
- Prompt processing is 2-6x faster on Vulkan, with the gap increasing at scale
- ROCm fails at 128k+ context; Vulkan handles it fine

### 2. Known ROCm Bug: HIP Dispatch Overhead (ggml-org/llama.cpp#20218)

The ROCm performance issue is a **confirmed bug** where HIP kernel dispatch overhead
consumes 99% of wall time while the GPU sits idle. Profiling shows:
- 14,977 kernel dispatches for pp128
- GPU compute: 0.039 seconds
- Wall time: ~4.1 seconds
- **99% of time is dispatch overhead**

The fused GDN path (PR #20340) partially fixes this (our build has it — graph nodes
reduced from 4209 to 3849), but significant overhead remains.

### 3. Vulkan on Strix Halo Uses RADV (Mesa)

The Vulkan backend uses the `RADV STRIX_HALO` driver (open-source Mesa), which
has excellent compute dispatch efficiency on RDNA 3.5. It doesn't suffer from
the HIP runtime overhead.

### 4. Context Scaling

Both backends degrade at long context, but Vulkan degrades much more gracefully:
- Vulkan: 52 tok/s (short) -> 39 tok/s (52k) = **25% degradation**
- ROCm: 43 tok/s (short) -> 27 tok/s (39k) = **37% degradation** (and fails at 128k)

## Recommendations

### Immediate: Switch to Vulkan Backend

Vulkan is the clear winner for Qwen 3.5 on Strix Halo. The default build type
in the launcher should be changed to `vulkan`.

### Build Flags

**Vulkan (recommended)**:
```
cmake -S . -B builds/vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
```

**ROCm (for reference/comparison)**:
```
cmake -S . -B builds/rocm -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 \
  -DGGML_HIP_ROCWMMA_FATTN=ON -DCMAKE_BUILD_TYPE=Release
```

### Launch Parameters (current, validated)

These are already well-tuned:
- `-fa on` — flash attention, essential for performance
- `-ctk q8_0 -ctv q8_0` — good KV compression with negligible quality loss
- `--no-mmap` — required for unified memory (mmap doesn't work well with GPU)
- `-ngl 99` — offload all layers to GPU
- `--parallel 2` — allows concurrent requests without significant overhead

### Environment Variables

For ROCm (when used):
- `ROCBLAS_USE_HIPBLASLT=1` — use hipBLASLt for matrix operations
- `HSA_XNACK=1` — enable XNACK for unified memory

For Vulkan: no special env vars needed.

## Optimization Testing (2026-04-04)

### Settings tested: --threads 8, -ub 256, -dio

Tested reducing threads from 32→8, micro-batch from 512→256, and enabling direct I/O.

| Setting | Impact on TG | Impact on PP | Verdict |
|---------|-------------|-------------|---------|
| `--threads 8` | +1-3% short ctx, ~0% long | **-18% across the board** | REVERT — PP regression too large |
| `-ub 256` | ~0% | **-18% across the board** | REVERT — no TG benefit, PP hurt |
| `-dio` | ~0% | ~0% | KEEP — no perf impact, faster model loading |

Combined (threads=8 + ub=256 + dio): TG +1-3% short, PP -18%. Not worth it.
Final decision: **keep only `-dio`**, revert threads and ubatch to defaults.

### Extended Context Benchmark (Vulkan + DIO, defaults otherwise)

| Context | PP tok/s | TG tok/s |
|---------|----------|----------|
| Short (~25 tok) | 200 | **53.1** |
| 3k | 969 | **51.6** |
| 10k | 861 | **49.8** |
| 39k | 560 | **44.3** |
| 52k | 336 | **38.7** |
| ~128k | 231 | **34.4** |
| ~256k | 175 | **19.9** |

Context scaling: 53→20 tok/s from short to 256k = **62% degradation** at max context.
Usable up to ~128k (34 tok/s). 256k works but is noticeably slow at 20 tok/s.

### Batch Size (`-b`) Benchmark

Tested `-b` values: 512, 1024, 2048 (default), 4096, 8192. Server restarted
between each test. Memory (GTT) logged before and after.

**Generation (TG tok/s):**

| Context | b=512 | b=1024 | b=2048 | b=4096 | b=8192 |
|---------|-------|--------|--------|--------|--------|
| Short | 52.8 | 53.1 | 53.1 | 52.9 | 53.0 |
| 3k | 51.4 | 51.7 | 51.6 | 51.4 | 51.5 |
| 10k | 49.6 | 49.8 | 49.7 | 49.7 | 49.8 |
| 39k | 44.2 | 44.2 | 44.4 | 44.3 | 44.3 |
| 52k | 38.7 | 38.8 | 38.8 | 38.8 | 38.8 |
| ~128k | 34.5 | 34.5 | 34.6 | 34.6 | 34.5 |
| ~256k | 30.0 | 30.9 | 30.9 | 31.1 | 29.8 |

**Prompt Processing (PP tok/s):**

| Context | b=512 | b=1024 | b=2048 | b=4096 | b=8192 |
|---------|-------|--------|--------|--------|--------|
| 3k | 975 | 976 | 971 | 972 | 972 |
| 10k | 866 | 866 | 864 | 861 | 863 |
| 39k | 561 | 561 | 560 | 558 | 559 |
| 52k | 337 | 337 | 337 | 337 | 337 |

**Memory:** Idle GTT = 43,930 MB across all batch sizes. Post-benchmark delta = 0 MB.

**Conclusion:** Batch size has **zero measurable impact** on this hardware/model.
The Vulkan backend handles batching internally, making `-b` irrelevant.
Leave at default (2048).

## Raw Data

Benchmark results are in `utils/benchmark-results/` as JSONL files.
