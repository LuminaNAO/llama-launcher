# Stress Testing Tools

Tools for testing llama.cpp server stability, particularly tool calling reliability
at varying context window sizes.

## tool-call-stress.sh

Tests tool calling at increasing context levels by pregenerating padded conversation
payloads, then firing them back-to-back to minimize GPU idle time.

```bash
# Default levels (baseline through 120K)
./stress-tests/tool-call-stress.sh 40802 ollama-local

# Custom levels
./stress-tests/tool-call-stress.sh 40802 ollama-local 0 50000 100000 120000
```

**What it tests:**
- Sends 3 tool definitions (get_weather, search_database, send_email)
- Asks the model to call all 3 tools simultaneously
- Uses `parallel_tool_calls: true`
- Checks for: correct tool calls, raw template tag leakage, parse failures

**Output:**
- `PASS` = all 3 tools called correctly
- `PARTIAL` = some tools called, no errors
- `FAIL` = raw template tags leaked or no tool calls at all

**Requirements:** Python 3, curl, jq

## gpu-monitor.sh

Monitors GPU utilization during tests to identify idle periods.

```bash
# Start background monitor
./stress-tests/gpu-monitor.sh start /tmp/gpu-util.log 2

# Run your tests...

# Stop and analyze
./stress-tests/gpu-monitor.sh stop
./stress-tests/gpu-monitor.sh report /tmp/gpu-util.log

# Or foreground mode
./stress-tests/gpu-monitor.sh 1 /tmp/gpu.log
```

Supports both ROCm (rocm-smi) and NVIDIA (nvidia-smi) GPUs.

## Methodology

### Testing a new model/tune

1. **Research the model** — check HuggingFace model card and community discussions
   for recommended sampling params, known issues, and template requirements.

2. **Start with baseline** — test at low context first to confirm basic tool calling works.

3. **Test both parsers** — run with JINJA=0 (PEG) and JINJA=1 to determine which
   is more stable for the specific model/quant combination.

4. **Ramp up context** — test at 2K, 5K, 10K, 20K, 35K, 45K, 60K, 80K, 100K, 110K, 120K.

5. **Run multiple times at failure thresholds** — if a level fails, test it 3-5 times
   to distinguish flaky failures from consistent breakage.

6. **Document findings** — add stress test results to the tune config file header.

### Known patterns

- **Pre-b8783:** Q4_K_M appeared to degrade tool calling at high context (~37K PEG,
  ~45K JINJA). This was actually a parser bug, not quantization.
- **Post-b8783:** The Gemma 4 parsing edge case fix (e21cdc11a) resolved ALL high-context
  failures for both Q4_K_M and Q8_0. All quants now pass through 120K.
- **Q8_0 quantization** is rock-solid through 120K+ for Gemma 4 architecture.
- **`parallel_tool_calls: true`** is important — without it, models may only call
  one tool even when asked for multiple.
- **PEG vs JINJA** — with the Gemma 4 parsing edge case fix (b8783+), both parsers
  perform identically for Q8_0. For Q4_K_M, JINJA extends the usable range.
- **Rotor quants (PR #21038, b8898):** Hadamard-rotate activations before KV
  quantization. Auto-enables when head_dim % 64 == 0 AND KV type is quantized.
  Disable via `LLAMA_ATTN_ROT_DISABLE=1`. Rescues q4_0 KV quality to near-q8_0
  fidelity — enables using q4 KV (half the VRAM of q8) without visible degradation.

## Test Results Summary

| Model | Quant | Parser | Max Context (100% pass) | Notes |
|-------|-------|--------|------------------------|-------|
| gemma-4-26B-A4B-it | Q8_0 | PEG | 120K (62K pt) | b8783+ |
| gemma-4-26B-A4B-it | Q8_0 | JINJA | 120K (62K pt) | b8783+ |
| Gemopus-4-26B-A4B-it | Q8_0 | PEG | 120K (62K pt) | b8783+ |
| Gemopus-4-26B-A4B-it | Q8_0 | JINJA | 120K (62K pt) | b8783+ |
| supergemma4-26b-uncensored | Q4_K_M | JINJA | 120K (62K pt) | b8783+ (was ~45K pre-fix) |
| Claude-Opus-Distill (v1) | Q8_0 | PEG | 120K (62K pt) | b8783+, 65 ct consistently |
| supergemma4-26b-uncensored | Q4_K_M | PEG | 120K (62K pt) | b8783+ (was ~35K pre-fix) |
| Qwen3.5-27B-Claude-Opus-Distill | Q4_K_M | JINJA | 120K (65K pt) | b8791, 1/3 tools (sequential, normal Qwen) |
| MiniMax-M2.7-UD-IQ4_XS | q4_0 KV + rotor | JINJA | 100K (46K pt) | b8898, ROCm 7.2.2, 0 hangs, 1/3 tools (MiniMax sequential pattern). Hung at 55K on 64k-q8 tune 2026-04-22; q4+rotor fixed. |
