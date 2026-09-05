# Production config snapshot — 2026-09-05 — Qwen3.8-27B-GSQ-RCO IQ3_S-mtp, tune gsq3s-262k-v1 (consolidated)

The single production tune after the 2026-09-04/05 screen, sweep and KV A/B;
the interim v2/v3 tunes were folded back into v1 (history in git). Ground
truth for the running config: diff `2026-09-05-gsq3s-cmdline.txt` against
`/proc/<pid>/cmdline` (paths under the home directory are written as `$HOME`).
Replaces `2026-08-21-nvfp4hi-*` (HIGHEST) as the production reference.

Final settings and the measurement behind each — see the tune's notes:
- KV q4_0/q4_0: Hadamard-rotated in this build; wikitext-2 PPL within +0.04%
  (32k) / +0.16% (64k) of f16; needle retrieval 6/6 at deep context, same as q8_0.
- Checkpoints 16384 x 16 = exact 262144 coverage, all 16 persisted (~11 GiB host RAM at full
  depth; 150 MiB + 4.02 KiB/token measured); worst rollback 16k tokens (~3-4 s).
- MTP depth 3 (sweep optimum), -b 2048 -ub 512, mmproj on GPU, froggeric
  fixed template (bare name, launcher-resolved), reasoning_effort xhigh.

Box notes: RC watchdog notify timeout 60 s (initramfs); 5090 on PCIe x8 (BIOS
bifurcation); production traffic routed to another server as of 2026-09-05,
so this instance's uptime is not critical until told otherwise.
