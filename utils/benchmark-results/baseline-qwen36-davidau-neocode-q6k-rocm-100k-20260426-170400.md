# Baseline: Qwen3.6-27B-NEO-CODE-Di-IMatrix-MAX (DavidAU Q6_K)

**Captured:** 2026-04-26 ~17:00–17:04 (live openclaw session)
**Build:** ROCm
**Model:** `/mnt/storage/models/Qwen3.6-27B-NEO-CODE-Di-IMatrix-MAX/Qwen3.6-27B-NEO-CODE-2T-OT-Q6_K.gguf` (20.86 GiB)
**Tune:** `64gb-100k-v1` (q8_0 KV, FA on, `-ub 512 -b 2048`, 102_400 ctx)
**Workload:** Real openclaw agentic session (3 turns observed, deep proxy NOT enabled)
**Source log:** `~/llama.log` (lines 18,734+)

## Per-turn performance

| Turn | Task ID | PP tokens | PP tok/s | TG tokens | TG tok/s | Wall (s) | Notes |
|------|---------|-----------|----------|-----------|----------|----------|-------|
| 1 (cold) | 0     | 79,227 | **180.14** | 1,360 | **6.15** | 660.9 | full 80k context PP |
| 2 (warm-incremental) | 1401  |  1,468 | 122.13     |   105 |   6.21 |  28.9 | cache hit on 79k tokens |
| 3 (partial cache)    | 1509  | 50,146 | 151.10     |   474 |   6.09 | 409.7 | cache hit on 32k of 82k |

## Headline numbers

- **TG (decode) ceiling: ~6.1 tok/s** — rock-steady across cold and warm runs. Memory-bandwidth bound; this is the fundamental floor for 27B dense Q6_K on Strix Halo (256 GB/s memory) and won't change with tuning.
- **PP (prefill) effective: 122–180 tok/s** depending on cache hit ratio.
- **Cold-start cost on 80k openclaw context: ~11 minutes** (mostly PP)
- **Warm tool-call turn: ~30 s** when cache hits the prior conversation
- **Partial cache turn (~half new): ~6.8 min** — typical openclaw turn after a long tool result lands

## Resource state during session

| Metric | Value |
|--------|-------|
| llama-server VmRSS | 15.8 GB (grew from 1.7 GB at start) |
| llama-server VmLck | 994 MiB (CPU-resident embed/output, mlocked) |
| llama-server VmSize | 50.8 GB (model + KV + checkpoints + heap) |
| Context checkpoints | **22 of 32** used at 80k ctx, each 149.6 MiB ≈ 3.3 GiB total. Will hit cap at 32 (~4.8 GiB) |
| Prompt cache | 20 GiB ceiling, active, hit reuse confirmed (turns 2–3) |
| GPU model buffer | 20,354 MiB ROCm0 |
| KV buffer | 3,400 MiB ROCm0 (q8_0 K+V, 100k ctx) |
| Recurrent state buffer | 150 MiB |
| Compute buffer | 495 MiB ROCm + 220 MiB host |

## Behavioral observations

- **No template exceptions** — the embedded GGUF template (pre-Unsloth-fixes, lacks `developer` role) handled openclaw's role schema cleanly. The `developer`-role concern flagged in the chat-template diff has not fired in this session.
- **No tool-call grammar errors** in any of the 3 turns.
- **Reasoning budget:** activated at 15,360 tokens on each turn; model exited thinking phase **naturally (under budget)** every time. No truncations, no overflows.
- **Fused Gated Delta Net kernels active** (both autoregressive and chunked paths) — confirmed at startup; means hybrid arch is using optimized ROCm code paths, not a fallback.
- **Chat format reported as `peg-native`** by `params_from_` — llama.cpp picked the right parser for this template flavor.
- One server-side warning logged at startup: `common_context_can_seq_rm: the target context does not support partial sequence removal` — expected for hybrid recurrent archs; means cache eviction is whole-state rather than tail-rebuild. Not impacting throughput so far.

## Comparison context

- **MiniMax M2.7 IQ4_XS @ 100k** (10B-active MoE on same host): TG ~25–30 tok/s. **Qwen 27B dense is ~4–5× slower on decode** — exactly as forecast from active-param ratio. Confirms the latency tradeoff is real and roughly 4×.

## Bottleneck attribution

- **Decode is memory-bandwidth bound.** ~6.1 tok/s × ~21.4 GiB working set ≈ 130 GiB/s effective bandwidth — about half of Strix Halo's theoretical 256 GB/s peak. There's some headroom (kernels could improve) but the gap to the MiniMax MoE will not close at this model size.
- **Prefill is compute-bound at -ub 512.** 180 tok/s peak on cold PP is similar in shape to MiniMax-class numbers we've seen on this hardware.
- **Cache reuse is working as designed** — turn 2's near-instant response confirms the host-memory prompt cache returned tokens without re-prefilling.

## Limitations of this baseline

- **No request/response bodies captured.** Server was launched without `--proxy`; deep-log tool-call analysis (argument shapes, response correctness, retry counts) is not available from this run.
- **N=3 turns** — small sample; cold/warm/mixed-cache hit cases are each represented once.
- The reported numbers are **steady-state generation**; first-token latency is not separately measured (would need TTFT timing only the proxy provides).

## A/B comparison plan vs Unsloth UD-Q5_K_XL

To make the comparison apples-to-apples once Unsloth UD-Q5_K_XL is downloaded:

1. Same tune skeleton (`64gb-100k-v1` derivative, only model path changes)
2. Same openclaw session pattern (cold start with similar-size context, then 2–3 warm turns)
3. Capture both runs with `--proxy --log` to compare tool-call body counts/shapes
4. Metrics to compare:
   - TG tok/s (expect ~5–10% gain from smaller working set on UD-Q5_K_XL @ 18.66 GiB)
   - PP tok/s (similar; both arch-bound)
   - Tool-call success (count + retry rate from proxy log)
   - Reasoning trace length (does code-imatrix model think more or less?)
   - Subjective: code edit quality on a representative openclaw task
