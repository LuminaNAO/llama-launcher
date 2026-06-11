# TODO

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
3. [ ] Add `--mlock` to the llama-server launch args in `llama-server-launcher.sh`.
4. [ ] Verify with `grep VmLck /proc/$(pgrep -f llama-server)/status`.

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

### Steps

1. Run `benchmark.sh` against the 64k tune with the current `-ub 256 -b 1024`.
2. Temporarily flip EXTRA_ARGS back to `-ub 512 -b 2048` (only safe if KV/ctx
   is reduced enough that OOM won't recur — maybe drop ctx to 48k for the test).
3. Compare pp tok/s at representative prompt lengths (2k, 8k, 16k).
4. If pp cost is small, keep `-ub 256` permanently. If it's ≥30%, look at
   alternatives (smaller ctx + bigger ubatch, or q4_0 KV + default ubatch).

### Context

- Added 2026-04-22 after OOM during live use on 18,602-token prompt.
- Crash site: `launch_fattn<128,32,2>` → `ggml_cuda_device_malloc` in
  `ggml-cuda.cu:430`.
