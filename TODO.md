TODO:
- Add `--help` / `-h` output for `llama-server-launcher.sh`.

Waterfall (docs/WATERFALL.md — deferred from v1):
- Heterogeneous endpoints: model-name mapping / virtual model advertisement,
  per-tier context-size awareness (v1 assumes Qwen 3.6 everywhere).
- Unified request log: optional tee at waterfall; today deep logs are
  complete in aggregate but distributed per node.
- Integrated ssh-tunnel management: TUI add-endpoint flow offering to spawn
  utils/ssh-tunnel.sh, tunnel-liveness vs server-liveness, reconnects.
