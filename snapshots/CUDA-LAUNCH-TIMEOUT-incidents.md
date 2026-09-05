# Incident log — `CUDA error: the launch timed out and was terminated`

Model: Qwen3.8-27B-NVFP4-MTP-HIGHEST, tune `32gb-cuda-5090-nvfp4hi-262k-v1`.
Config unchanged throughout — every restore used the byte-identical cmdline in
`2026-08-21-nvfp4hi-cmdline.txt`. Nothing about the model, tune, launcher or
build has been altered across any of these events.

## Failure shape

`ggml_abort` → process dies → proxy takes SIGTERM → **service is fully down**
until relaunched. Not a degradation; a hard stop. Recovery is a plain relaunch,
~30 s to healthy. The watchdog task (`buju8ygex`) detects and notifies.

## Production incidents (current server generation)

| # | Date/time (AWST) | Uptime before | Stack position | Work at death |
|---|---|---|---|---|
| 1 | 2026-08-21 18:04 | 2 d 11 h | `common_speculative_impl_draft_mtp::draft` | 4,848 tok generated |
| 2 | 2026-08-22 01:15 | 7.2 h | `ggml_cuda_mul_mat_q` (no MTP frame) | just after 232,498-tok prefill (58.3 s) |
| 3 | 2026-08-22 07:55 | 6.6 h | `ggml_backend_cuda_synchronize` (no MTP frame) | 2,956 tok generated |
| 4 | 2026-08-22 21:45 | 13.8 h | `draft_mtp::draft` → `common_sampler_sample` | 641 tok generated |
| 5 | 2026-08-23 01:07 | 3.4 h | `ggml_backend_cuda_synchronize` | 3,194 tok generated |
| 6 | 2026-08-23 01:50 | 43 min | (Xid 8, pid 384359) | — |
| 7 | 2026-08-23 03:49 | 2.0 h | (Xid 8, pid 418390) | — |
| 8 | 2026-08-26 (mid-session) | long-run | `ggml_backend_cuda_synchronize` (no MTP, plain decode) | ~75k-deep session |

**Incident 8 correlation**: crashed while the live session was ~75,000 tokens
deep — the same deep context that slowed decode to ~77 t/s. Deep context =
longest attention kernels = highest 7s-watchdog exposure. Reinforces that
kernel DURATION (driven by context depth / micro-batch), not subsystem, is the
trigger. Watchdog was disarmed at the time, so the outage went uncaught until
noticed manually.

Gaps are shortening overall (2 d 11 h → 7.2 → 6.6 → 13.8 → 3.4 → 0.7 → 2.0)
but hardware telemetry stayed clean throughout, so this reflects workload
mix — more deep-context work crossing the 7 s kernel ceiling — not decay.

Four further instances of the same error appear earlier in `llama.log` (after
server starts #4/#10/#22/#23/#36) during the multi-model gauntlet rotation;
which model was loaded at each is not established. Total in current log: 9.

## What the data supports

- Every event is `cudaErrorLaunchTimeout`, i.e. an externally-imposed **time
  limit on GPU work**, not a computation fault.
- It lands at whatever synchronise/launch point is executing. Five events,
  four distinct stack positions, MTP present in some and absent in others.
  **It is not a bug in one kernel or one subsystem.**
- Uptime gaps show no trend: 2 d 11 h, 7.2 h, 6.6 h, 13.8 h, 3.4 h.

## What the data does NOT support

- "Long sustained work is the trigger" — proposed after events 1–3, then
  falsified by event 4 (641 tokens, an ordinary short generation).
- "It's the MTP draft path" — proposed after events 1 and the gauntlet
  crashes, then falsified by events 2 and 3 (no MTP frame). Dropping
  `--spec-type draft-mtp` would cost ~40% decode and would **not** be
  expected to fix this.

## CONFIRMED CAUSE (2026-08-23, from the kernel log)

The NVIDIA **RC (Robust Channel) watchdog** is killing the server's channel.
Every one of the six incidents has an exactly-matching kernel message pair,
carrying the crashed server's own PID:

```
NVRM: krcWatchdog_IMPL: RC watchdog: GPU is probably locked!  Notify Timeout Seconds: 7
NVRM: Xid (PCI:0000:01:00): 8, pid=<llama-server pid>, channel 0x00000005
```

- **Xid 8** = graphics/compute engine stopped processing on that channel.
- **The timeout is 7 seconds.** A single CUDA kernel that runs longer than
  ~7 s gets its channel reset, which surfaces to userspace as
  `cudaErrorLaunchTimeout`.

This explains everything the earlier theories could not: why it lands at
arbitrary stack positions (whichever kernel crosses 7 s), why MTP presence is
irrelevant, and why it is load-dependent rather than deterministic.

**The hardware is healthy** — no ECC errors, no throttling
(`clocks_event_reasons.active = 0x0`), 47 °C, P1. This is not a failing card.

PID-to-incident mapping confirmed for all six: 455601, 3159944, 3488209,
3793371, 229319, 384359.

## Contributing factor worth testing

`kwin_wayland` (PID 1737) holds a **C+G (compute+graphics)** context on the
5090 even though every card0 connector reads `disconnected` and the monitor
is on the Intel UHD 770 (`card1-DP-1`) — KDE renders on the 5090 and scans
out via the iGPU. Sharing the GPU with a compositor is the most likely reason
a 7 s channel watchdog is armed at all on a card doing pure compute.

Note the tension with the fast config: larger micro-batches make individual
kernels longer, so `-ub 512` (the +12% prefill win) plausibly increases
watchdog exposure at deep context. Lowering `-ub` would shorten kernels at
some prefill cost — an explicit speed-vs-stability trade, and the operator's call.

## Untried, cheapest first

1. `sudo nvidia-smi -pm 1` — persistence mode is currently **Disabled**. No
   session disruption, reversible with `-pm 0`. If crashes continue unchanged
   this rules out driver residency.
2. Force KDE to render entirely on the Intel iGPU so the 5090 becomes
   compute-only. Removes the graphics context. **Logs you out** — do it
   deliberately, at the machine.
3. Automating watchdog restart (offered, declined-by-default): would cut
   outage to ~30 s, but a resurrector would fight an intentional model swap,
   so it needs an explicit decision and an abnormal-exit-only guard.

## Incident 9 (2026-09-04 10:35 AWST) and the corrected diagnosis

| # | Date/time (AWST) | Uptime before | Stack position | Work at death |
|---|---|---|---|---|
| 9 | 2026-09-04 10:35 | 19 h 47 m | `draft_mtp::process` → `cudaStreamSynchronize` | 1,426 tok generated at ~199.5k ctx (198k prompt) |

Same kernel pair, pid 3898. Longest uptime since #1 — the gaps are not shortening.

**The "deep context / kernel duration" trigger is falsified.** Context depth at
all 13 launch-timeout crashes in `llama.log`: 15.5k, 19k, 20k, 45k, 59k, 71k,
95k, 122k, 128k, 133k, 143k, 180k, 197k — three at ≤20k, across six different
models, with and without MTP, in prefill / decode / between tasks. And with
`kv_unified` the KV cache is preallocated in full at launch, so VRAM does not
vary with depth either. Crash depth simply mirrors workload exposure.

**What the watchdog actually measures (from `kernel_rc_watchdog*.c`, open
kernel modules):** it allocates its *own* graphics channel with a 2D object,
pushes a tiny notify job every tick, and fires when *that job's* notifier is
not written within `timeoutSecs` — then RCs whichever channel is running. It
has no display/headless/compute-only gate: it is armed on every GPU unless
MIG, Confidential Computing, emulation, or the registry disables it. Two
consequences: (1) the "kwin keeps the watchdog armed" theory above is wrong —
moving KDE off the 5090 would not disarm it; (2) llama-server's own
`--log-timestamps` show completed decode steps at 12.64 s and 15.67 s inside
the 7 s window that ended at 18.58 s: **the GPU was never locked.** The
watchdog's graphics-class job was starved for 7 s while a saturated compute
context kept completing work. A scheduling/preemption false positive. Why
preemption fails for 7 s when the kernels are 17 ms remains open (driver
610.57.04 runlist scheduler is the lead suspect; no newer driver in repos).

**Mitigation applied 2026-09-04:** `RmWatchDogTimeOut=60` via
`NVreg_RegistryDwords` (key confirmed in `nvidia.ko` and read host-side by
`_krcInitRegistryOverrides`, seconds, default 7). Baked into the initramfs by
`utils/set-rc-watchdog-timeout.sh` (limine-mkinitcpio path; verifies with
`lsinitcpio`). Live: `/proc/driver/nvidia/params` shows the key; a future Xid
would print `Notify Timeout Seconds: 60` — that would indicate a *real* 60 s
hang and point at the driver. Disabling the watchdog outright was rejected: a
true hang would then never recover.

Also found in passing: the 5090 runs PCIe **x8** — root port `00:01.0` has
`max_link_width=8`, the 16 PEG lanes are bifurcated x8/x8 with the KC3000
NVMe on `00:01.1`. Not the crash cause (0 replays), but a BIOS setting worth
checking; it halves host↔device bandwidth for slot restores and model loads.
