TODO:
- Add `--help` / `-h` output for `llama-server-launcher.sh`.

Waterfall (docs/WATERFALL.md — deferred from v1):
- Heterogeneous endpoints: model-name mapping / virtual model advertisement,
  per-tier context-size awareness (v1 assumes Qwen 3.6 everywhere).
- Unified request log: optional tee at waterfall; today deep logs are
  complete in aggregate but distributed per node.
- Integrated ssh-tunnel management: TUI add-endpoint flow offering to spawn
  utils/ssh-tunnel.sh, tunnel-liveness vs server-liveness, reconnects.

Models to try:
- [SCREENED 2026-09-04 -> PRODUCTION, tune gsq3s-262k-v1 (consolidated 09-05)]
  ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF (added 2026-09-04; repo uploaded
  2026-09-02, already ~100k downloads). GSQ = Gumbel-Softmax Quantization
  (jointly learned grid assignments + per-group scales), RCO = Riemannian
  Constrained Optimization (per-tensor quant-type allocation under a size
  budget). Low-bit only: IQ2_XS 2.50 bpw 8.4 GB → IQ3_S 3.50 bpw 11.8 GB.
  Card claims IQ3_S matches BF16 on AIME25 (100.00) and LiveCodeBench v6
  (85.71), within 0.51 on GPQA-Diamond. `-mtp` variants carry the MTP head
  (IQ3_S-mtp = 12.1 GB); mmproj-BF16 (0.9 GB) + imatrix in repo. Apache 2.0.
  Why: HIGHEST is ~29 GB NVFP4 — IQ3_S-mtp would free ~17 GB VRAM (q8_0 KV
  instead of q4_0, bigger -ub, or a DFlash2 drafter alongside) and, being
  bandwidth-bound at batch 1, may decode markedly faster. Unknowns to test:
  whether "task-lossless" on 3 benchmarks survives the Rust R1-R5 gauntlet
  (eval-harness-2026-08; HIGHEST = 26/26), and IQ3 dequant kernel cost vs
  NVFP4 native on sm_120. Checks: confirm blk.64/nextn MTP tensors present in
  the -mtp GGUF (the transformers round-trip gotcha), verify HF LFS sha256,
  download to disk not /tmp. Start with IQ3_S-mtp.
- [SCREENED 2026-09-04 -> NOT ADOPTED; revisit on DavidAU's V2]
  DavidAU/Qwen3.8-27B-TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored-NEO-CODER-MAX-MTP-GGUF
  (added 2026-09-04; repo uploaded 2026-09-04, public/not gated, ~40k
  downloads). Successor to the Cold-Fusion-GAIN-V1.1-NEO-MAX we gauntleted at
  28/31 (tune cfq6-262k-v1 — clone it) and the finished stage-2 of the gated
  732 stage-1 we dropped 08-25. Recipe: Fable-Fusion-711 method + Cold Fusion
  (GAIN per-sample adaptive + Unsloth) + Heretic stage-2 decensor (KL 0.0025,
  refusals 11/100 vs 86/100 stage 1) + NEO-CODER-MAX imatrix. "735/882" =
  claimed ARC-C/ARC-E (base 591/782 @ mxfp8). "TURBO" = thinking tokens cut
  1/2–1/10 — the interesting bit for agent latency if quality holds. MTP
  tensors Q8_0 in every -MTP quant, output tensor 16-bit; mmproj BF16/F16/F32
  in repo; 256k ctx; reasoning_effort xhigh/medium/low via template kwargs.
  Card samplers (thinking): temp 1.0, top_p 0.95, top_k 20, rep_pen 1.0 —
  MTP wants temp ≤1 / rep_pen 1.0, matches our setup. Sizes: MTP-Q6_K 24.0 GB
  (start here), LOW-MTP-Q6_K 22.4 GB, MTP-Q8_0 30.2 GB (too tight for 262k
  KV). Verify: all numbers are self-reported and ARC is a weak proxy for
  agentic coding → Rust R1-R5 gauntlet vs HIGHEST 26/26; measure MTP draft
  acceptance (Heretic can dent it); confirm TURBO's shorter thinking doesn't
  cost the 3-switch/security probes; verify HF LFS sha256, disk not /tmp.

Screen results 2026-09-04 (fresh FreeClaw per candidate, --thinking high;
full data + method in model-configs/<model>.*.yaml notes and eval-harness-2026-08/):
  Rust R1-R5      GSQ-RCO 4/5 (R1 stochastic; passes on retry; clears R3+R5)
                  DavidAU TURBO 3/5 (R3 Clone bound, R5 invents std::task::ArcWake)
                  HIGHEST 3/5 (08-19), 1/4 same-day rerun (killed early)
  decode t/s      shallow code GSQ 133 / TURBO 118 / HIGHEST 90; @201k 85 / 71 / 77
  prefill t/s     @62k GSQ 6275 / TURBO 5492 / HIGHEST 7866 (NVFP4 keeps prefill)
  VRAM served     GSQ 19.8 GiB (q4 KV) 24.1 (q8 KV) / TURBO 30.5 / HIGHEST 28.4
  TURBO claim     real: 10-30x less thinking, answers still correct; HF cutoff
                  bug did not reproduce on the froggeric template.
  Verdict         GSQ-RCO to production, single tune gsq3s-262k-v1 (consolidated
                  09-05): q4_0 KV (rotated; PPL-lossless at 32k/64k, needle 6/6),
                  full 262k checkpoint coverage 16384x16 (all persisted), mmproj on GPU, depth 3.
                  Follow-ups: v3 test of draft-mtp,ngram-mod at deep context
                  (+2% shallow); DavidAU V2 when released.

Explore — decode (t/g) speed on GSQ-RCO (2026-09-05; current: ~133 t/s code,
~110-123 prose/reasoning, ~87 @200k; sweep already found MTP depth 3 optimal,
p-split a no-op, -ub irrelevant to tg):
- [next] DFlash2 drafter in place of the embedded MTP head (branch feature/dflash2
  holds the parked draft tune): +51% code / +27%
  reasoning measured on HIGHEST 08-25 (longer accepted runs). GSQ-RCO is stock
  Qwen3.8 so the drafter's distribution matches. Blocker: cherry-pick llama.cpp
  PR #27342 onto llama-hdd and rebuild (vanilla cuda-dflash2 build lacks
  hdd-cache/checkpoints); validate hdd-cache + vision + gauntlet after.
- Unrotated KV: the Hadamard rotation costs ~10-12% tg upstream. f16 KV needs no
  rotation (fits: ~30.5 GiB at 262k, no headroom; 4x KV bytes so slower at
  depth) or q8_0 with LLAMA_ATTN_ROT_DISABLE=1 (upstream: good, not lossless).
  ~10 min each with eval-harness-2026-08/speed_probe.py.
- Cooler sampling for acceptance (0.36-0.54 today at temp 1.0/top-p 0.95/
  top-k 20): raises tg but changes outputs — quality decision, not a free win.
- Higher-precision MTP head: this gguf's blk.64 is Q6_K; grafting a BF16 head
  may nudge acceptance. Speculative, small.
Prerequisite before R&D resumes on this host: finish the signing-agent publish
cycle so the fallback 5090 runs this model/tune; then this box is free.

