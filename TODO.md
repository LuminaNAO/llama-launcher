# TODO

## Enable --mlock to prevent swap thrashing

llama-server should use `--mlock` to pin memory pages and prevent the kernel
from swapping them out. Without this, the 67 GB model + KV cache can get
partially swapped, causing catastrophic performance drops (0.02 tok/s observed
when 22.5 GB was in swap).

### Steps

1. Raise memlock ulimit — add to `/etc/security/limits.conf`:
   ```
   claude  hard  memlock  unlimited
   claude  soft  memlock  unlimited
   ```
2. Re-login (or reboot) for limits to take effect
3. Add `--mlock` to the llama-server launch args in `llama-server-launcher.sh`
4. Verify with `grep VmLck /proc/$(pgrep -f llama-server)/status`

### Context

- Observed 2026-04-02: 40 GB cache + 67 GB model exceeded 125 GB RAM, kernel
  swapped 22.5 GB of llama-server pages, dual-slot generation dropped to
  0.02-0.43 tok/s. Reduced cache to 30 GB as immediate fix.
- Must be done on all machines running llama-server (buildhost, framed).
