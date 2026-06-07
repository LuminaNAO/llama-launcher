# llama-hddcase Stress Test Plan

## Goal

Validate the production llama-launcher + llama-hdd cache path under real OpenClaw workloads, with heartbeat injection disabled, using the author-pick Qwen3.6 27B MTP setup. The test should prove whether recent launcher/proxy/cache changes still maximize reusable context while avoiding branch corruption, unexpected overwrites, cold prompt processing, and runaway HDD slot growth.

## Current Test Target

- OpenClaw command: `/home/claude/.local/bin/openclaw`
- Launcher proxy: `http://127.0.0.1:40801`
- Internal llama-server: `http://127.0.0.1:40802`
- Model: `Qwen3.6-27B-UD-Q4_K_XL.gguf`
- Tune: author pick `Qwen3.6-27B-MTP.64gb-q4-140k-coding-v1.conf`
- Effective context: launcher/server started with 131k-class context (`-c 143360`)
- Repo logs:
  - `/home/claude/code/llama-launcher/llama.log`
  - `/home/claude/code/llama-launcher/llama-deep.log`
- Production slot cache:
  - `/mnt/storage/llama-slots/Qwen3.6-27B-UD-Q4_K_XL`

## Known Risk Areas To Validate

1. Same-base branch pruning may be too aggressive.

   Commit `989b805` added `pruneSameBaseSlots(baseId, keepSlotId)`, which deletes old same-base branch files after a successful save. That can conflict with the intended copy-on-write hierarchy: a forked request should be able to reuse an older parent without overwriting or deleting a sibling branch.

2. Response-complete saves can transiently fail.

   Recent logs show `HDD CACHE save status=0 n_saved=0 n_written=0` after response completion, followed by a later switch-time save that often succeeds. This creates a window where a session branch is represented only by volatile metadata and has no durable `.bin`.

3. OpenClaw compaction may change the request anchor.

   If the proxy base ID is derived from fields that change during auto-compaction, heartbeat removal, or system-message changes, a logically continuous session can become a new base. That causes `restore MISS` even when useful parent cache exists.

4. llama.cpp live LCP can hide proxy misses.

   A proxy `restore MISS` can still look acceptable if the single live slot has a similar prefix. The test must distinguish disk-cache reuse from live-slot fallback, because live fallback will not survive session switching or process restart.

5. Existing regression tests may mask the issue.

   `utils/test-proxy-cow-cache.mjs` currently allows very low branch retention and no longer requires a recorded disk-parent restore. If real workloads confirm branch loss, this test should be tightened again.

## Incident Classification

Warm:

- Proxy logs `restore exact`, `restore parent`, or `restore SKIPPED` from a live same-base slot.
- llama.cpp restores a checkpoint close to the prompt target.
- Prompt eval is only the new delta, typically under 2k-5k tokens for incremental turns.

Semi-cold:

- Proxy logs a miss or weak parent, or llama.cpp restores only an early checkpoint.
- Prompt eval is materially larger than the new turn, typically over 5k tokens or over 20% of the request context.
- llama.cpp may log `erased invalidated context checkpoint`, which means it reused an early prefix but discarded later checkpoints.

Cold:

- Proxy logs `restore MISS`.
- llama.cpp has no useful checkpoint or restores only a tiny prefix.
- Prompt eval approaches the full request context.

Save failure:

- Proxy logs `HDD CACHE save status=0`, non-200 save status, `nSaved=0`, or `nWritten=0`.
- Matching `.meta.json` has `volatile=true`, `completed=false`, or no durable `.bin`.

Excessive HDD usage:

- Slot directory approaches configured cap unexpectedly.
- Many siblings for the same base accumulate without LRU pruning, or pruning removes useful branches and causes later cold PP.

## Measurements

For every OpenClaw turn, record:

- Timestamp and OpenClaw session key/session ID.
- Prompt body size from `REQUEST POST`.
- Proxy session ID (`baseId-branchId`) from llama logs.
- Restore kind: exact, parent, live-parent, skipped, miss.
- Restore source file and `n_restored`/`n_read`.
- llama.cpp LCP similarity and selected checkpoint position.
- Prompt eval token count and prompt eval time.
- Generation token rate from `n_decoded` / `eval time`.
- Save status, `n_saved`, `n_written`, and whether later switch-time save recovered it.
- Cache directory size and file count before and after the phase.

Use the repo logs as source of truth. Use slot `.meta.json` files to confirm durability and parent/branch relationships.

## Workload Phases

### Phase 0: Baseline Snapshot

1. Confirm launcher proxy and llama-server are running through `llama-launcher`.
2. Capture active OpenClaw sessions with `openclaw sessions --json --active 120`.
3. Capture cache footprint with `du -sh /mnt/storage/llama-slots/Qwen3.6-27B-UD-Q4_K_XL` and file counts.
4. Parse recent `llama.log` for:
   - `REQUEST POST`
   - `restore MISS`
   - `restore PARENT`
   - `restore SKIPPED`
   - `HDD CACHE save status=`
   - `pruneSameBaseSlots`
   - `prompt eval time`
   - `restored context checkpoint`
   - `erased invalidated context checkpoint`

### Phase 1: Real OpenClaw Fan-Out

Start 4-6 direct OpenClaw sessions with explicit session IDs:

```sh
openclaw agent --session-id hddcase-audit-a --message "..." --thinking high --timeout 900 --json
```

Use real coding workloads, not synthetic curl requests. Good workloads:

- Audit a subsystem and propose concrete fixes.
- Inspect a complex module and summarize risks.
- Trace a bug through logs and code references.
- Produce a migration plan from existing code.
- Compare two implementations and identify regressions.
- Review tests and propose missing coverage.

Run the first turns in parallel where safe, then alternate session turns to force slot switching.

### Phase 2: Incremental Growth

Build each session in steps:

- 10k-20k context: initial audit and code reading.
- 30k-60k context: ask follow-up questions that require using the previous analysis.
- 60k-90k context: add a second related task that should preserve the same base.
- 90k-110k context: continue until OpenClaw auto-compaction is likely to trigger.

After every turn, classify the cache behavior as warm, semi-cold, cold, or save-failure.

### Phase 3: Fork And Resume

For at least two sessions:

1. Build an original session to a durable saved slot.
2. Start a near-identical fork with the same initial prompt shape but different follow-up instructions.
3. Continue the fork until it saves its own branch.
4. Resume the original session.
5. Confirm the original branch was not deleted or overwritten by the fork.

Expected healthy behavior: a fork can reuse a parent, then diverge into its own durable slot file, while the original remains resumable without cold PP.

### Phase 4: Auto-Compaction

Push several sessions past the OpenClaw auto-compaction threshold around 100k context.

For each compaction event:

- Compare pre-compaction and post-compaction proxy base IDs.
- Check whether the proxy can still find a disk parent.
- Confirm heartbeat-disabled sessions do not inject unrelated text into the cache anchor.
- Record whether compaction creates a new base, a same-base branch, or a complete miss.

### Phase 5: Disk Pressure And Retention

While the workload runs:

- Track total cache size and file count.
- Track same-base branch counts.
- Record every `pruneSlotCache` and `pruneSameBaseSlots` event.
- If a cold/semi-cold event follows a same-base prune, inspect whether the deleted file was the needed parent/sibling.

## Analysis Procedure On Cold Or Semi-Cold PP

1. Locate the `REQUEST POST` in `llama.log` and copy its proxy session ID.
2. Search `llama-deep.log` for the same session ID.
3. Identify the restore decision and reason.
4. Check matching `.meta.json` for `baseId`, `slotId`, `restoreKind`, `restoredFrom`, `completed`, `volatile`, `nSaved`, and `nWritten`.
5. List other slot files with the same `baseId`.
6. Search earlier logs for `pruneSameBaseSlots` for that `baseId`.
7. Compare llama.cpp checkpoint position with request size:
   - high checkpoint near target: warm
   - early checkpoint with large prompt eval: semi-cold
   - no checkpoint or full prompt eval: cold
8. Decide likely cause:
   - branch pruned
   - save failed and never recovered
   - base changed because OpenClaw anchor changed
   - live-slot LCP only, no durable disk parent
   - expected first turn/new unrelated session

## Expected Outputs

- A JSONL observation log under `utils/benchmark-results/`, one row per OpenClaw turn.
- A short incident table listing cold/semi-cold/save-failure cases and likely cause.
- A cache usage summary showing peak GB, final GB, file count, and prune events.
- A fix recommendation.

## Likely Fixes If Current Suspicion Is Confirmed

- Replace `pruneSameBaseSlots(... keep only newest ...)` with retention that preserves the copy-on-write graph:
  - keep exact active branches,
  - keep recent parents,
  - prune by global disk budget/LRU,
  - optionally cap same-base branches above a reasonable count, not one branch.
- Restore test coverage that proves a fork can reuse a disk parent and then resume the original branch.
- Add save retry/backoff or delayed finalization for `save status=0`.
- Mark metadata durable only after successful `.bin` and `.ckpt` writes.
- Improve base-anchor derivation for OpenClaw compacted sessions so logical continuity survives compaction.

## Initial Live Run Notes - 2026-06-06

Started three direct OpenClaw agent sessions with explicit `hddcase-*` session IDs against the running author-pick Qwen3.6 launcher server.

Initial cache footprint:

- `172G`
- `141` files

After the first batch of real OpenClaw traffic:

- `178G`
- `156` files

Observed hddcase proxy sessions:

| Proxy session | Restore | llama.cpp fallback | Prompt eval | Classification |
| --- | --- | --- | --- | --- |
| `aae4b471c435-4e078d3c50c2` | `restore MISS` | live LCP `0.736`, checkpoint `10239` | `5978` tokens, `20.8s` | semi-cold live fallback |
| `ec2521df1174-14bdd7c79d0c` | `restore MISS` | live LCP `0.996`, checkpoint `14335` | `1894` tokens, `7.0s` | warm-ish live fallback, not HDD |
| `65300801a114-d6bb1c55158e` | `restore MISS` | live LCP `0.996`, checkpoint `14335` | `1877` tokens, `7.0s` | warm-ish live fallback, not HDD |
| `395c1fe0c058-0c49d5e0100e` | `restore MISS` | live LCP `0.899`, checkpoint `14335` | `3642` tokens, `13.2s` | semi-cold live fallback |
| `5ec9a79d6feb-e4da2527a36f` | `restore MISS` | live LCP `0.541`, checkpoint `14335`, erased checkpoint `17461` | `15557+` prompt tokens in progress | semi-cold/cold candidate |

Important finding: response-complete saves are repeatedly failing with:

```text
HDD CACHE save status=0 n_saved=0 n_written=0
```

The next request often performs a switch-time save that succeeds and writes `.bin` + `.bin.ckpt`, for example:

```text
HDD CACHE save status=200 n_saved=16362 n_written=458871840 checkpoint_sidecar=aae4b471c435-4e078d3c50c2.bin.ckpt
```

However, the successful switch-time save path in `ensureSlotLoaded()` does not update `.meta.json` to durable state. The metadata remains:

```json
{"completed":false,"volatile":true,"saveReason":"response-complete","nSaved":0,"nWritten":0}
```

This matters because `findBestSameBaseParent()` only trusts rich parent matching when metadata has `completed && !volatile && promptPrefix`. Durable `.bin` files with stale volatile metadata are downgraded to legacy fallback behavior.

Immediate code audit target:

- In `ensureSlotLoaded()`, after a successful save of `currentSession`, call `writeSlotMeta(currentRequestInfo, { completed: true, volatile: false, createdFrom: currentLoadedFrom, saveReason: "switch", nSaved, nWritten })`, matching the successful branch in `saveCurrentSlot()`.
- After that fix, rerun the same hddcase workload and verify whether same-base follow-ups can use `restore parent` with nonzero LCP/similarity instead of only legacy/live fallback.

Patch status:

- Applied the switch-time metadata finalization fix in `llama-deep-proxy.mjs`.
- `node --check llama-deep-proxy.mjs` passed.
- `node utils/test-proxy-cow-cache.mjs` passed.
- The currently running launcher/proxy process has not been restarted yet, so live traffic after this note is still using the old proxy code until restart.

## Controlled Baseline Comparison - 2026-06-06

Compared the patched current tree against the tree at `a8ac4693d9e62520cd02497a509a3c714d18d614`.

Important caveat: `a8ac4693d9e62520cd02497a509a3c714d18d614` is not an ancestor of current `HEAD` in the local repository, so this comparison uses it as a baseline tree snapshot rather than a linear commit range.

Both runs used:

- Same llama-server binary through the launcher.
- Same Qwen3.6 author-pick model.
- Same effective v5/v1 tune: 143360 ctx, q4_0 KV, `--checkpoint-min-step 2048`, `--ctx-checkpoints 64`, `CACHE_RAM=0`, HDD slot cache.
- Same synthetic fork/resume sequence:
  - A1 cold
  - B1 cold after switching away from A
  - A2 return to A from disk
  - A3 same-base live continuation
  - B2 return to B from disk

### Patched current tree

| Case | Wall time | Prompt eval |
| --- | ---: | --- |
| A1 cold | `65.088s` | `18846 tokens / 60.074s` |
| B1 cold | `65.514s` | `18846 tokens / 59.995s` |
| A2 disk parent | `8.067s` | `542 tokens / 2.470s` |
| A3 live same-base | `8.359s` | `566 tokens / 2.504s` |
| B2 disk parent | `8.480s` | `542 tokens / 2.459s` |

Current patched parent selection:

```text
restore PARENT ... (lcp=88287 similarity=1.000)
```

Metadata after the run was finalized correctly:

```json
{"completed":true,"volatile":false,"restoreKind":"parent","restoreLcp":88287,"restoreSimilarity":0.9999773471213854}
```

Remaining current-tree problem observed during the same run:

```text
pruneSameBaseSlots: removed 1 old branch slot(s)
```

That branch deletion is still a likely fork/resume regression.

### `a8ac4693...` baseline tree

| Case | Wall time | Prompt eval |
| --- | ---: | --- |
| A1 cold | `65.062s` | `18847 tokens / 60.072s` |
| B1 cold | `65.372s` | `18847 tokens / 60.039s` |
| A2 disk fallback | `8.314s` | `542 tokens / 2.468s` |
| A3 live same-base | `8.435s` | `566 tokens / 2.512s` |
| B2 disk fallback | `8.064s` | `542 tokens / 2.458s` |

Baseline parent selection:

```text
restore FALLBACK ... -> latest same-base slot
```

Baseline does not score parent candidates by stored prompt-prefix LCP. It simply falls back to the latest same-base slot, which works for the controlled linear branch test but is less precise for real forked sessions.

### Interpretation

The controlled benchmark does not show a raw performance regression between `a8ac4693...` and patched current for a simple two-base fork/resume sequence. Both get roughly:

- `~65s` cold
- `~8s` warm/disk-parent
- `~542-566` prompt eval tokens after restore instead of `~18846`

The regressions are in correctness and robustness:

- Current pre-patch switch-time saves produced durable `.bin/.ckpt` files but stale volatile metadata; patched current fixes this.
- Current still deletes same-base siblings through `pruneSameBaseSlots`, which can break real fork/resume even though the simple linear benchmark passes.
- The current test harness should be strengthened to fail when branch preservation or disk-parent restore is lost.

The ROCm warning:

```text
llama_sampler_backend_support: device 'ROCm0' does not have support for op TOP_K needed for sampler 'top-k'
```

appeared in both current and `a8ac4693...` runs. It is not introduced by the later launcher/cache changes and is not tied to HDD cache restore behavior.

## Direct OpenClaw Partial Run

After the synthetic benchmark, a direct OpenClaw probe was run through the
normal launcher/proxy path:

```sh
openclaw agent --session-id hddcase-direct-a -m '...'
```

This confirmed real OpenClaw requests were reaching the launcher proxy:

```text
REQUEST POST /v1/messages body_bytes=59917 ... session=b52feb58d124-9bb52b5a42b1
```

A larger direct OpenClaw A-session run was then started. It was stopped before
the requested two-session incremental test completed, so this is not yet a full
validation of the target scenario. It did, however, expose a real semi-cold
case that the synthetic test missed.

Within one OpenClaw turn, OpenClaw issued several same-base child requests. The
early same-base children used live copy-on-write and only processed small
prompt deltas:

```text
restore SKIPPED: 2b0548f1de6f-04831a955096.bin (copy-on-write from live same-base slot ...)
selected slot by LCP similarity, sim_best = 0.992, f_keep = 0.991
prompt eval time = 7528.97 ms / 2040 tokens
```

The same turn later issued a much larger request:

```text
REQUEST POST /v1/messages body_bytes=257048 ... session=2b0548f1de6f-639d9e29cbc5
restore SKIPPED: 2b0548f1de6f-639d9e29cbc5.bin (copy-on-write from live same-base slot ...)
selected slot by LCP similarity, sim_best = 0.224, f_keep = 0.694
restored context checkpoint ... n_tokens = 14336
erased invalidated context checkpoint ... n_tokens = 16424
erased invalidated context checkpoint ... n_tokens = 18884
erased invalidated context checkpoint ... n_tokens = 20991
```

This is the strongest current reproduction of the semi-cold behavior:

- The proxy treated same-base live copy-on-write as sufficient and skipped disk
  restore.
- llama.cpp found only a weak usable prefix (`sim_best = 0.224`) and fell back
  to the 14k checkpoint.
- Higher checkpoints were invalidated.
- The request then had to process tens of thousands of prompt tokens.

The same run also confirmed that `pruneSameBaseSlots` actively deletes older
same-base siblings during real OpenClaw behavior:

```text
pruneSameBaseSlots: removed 1 old branch slot(s) for base 2b0548f1de6f
```

The direct OpenClaw test still needs to be rerun with a smaller, controlled
OpenClaw task shape so two sessions can be built incrementally without one
turn expanding into a long multi-request audit.

## Direct OpenClaw Two-Session Run - 2026-06-06

Launcher was restarted through `llama-server-launcher.sh` with the author-pick
Qwen3.6 model and tune:

```sh
./llama-server-launcher.sh --build rocm \
  --model /usr/local/share/llama.cpp/models/Qwen3.6-27B-MTP/Qwen3.6-27B-UD-Q4_K_XL.gguf \
  --tune 64gb-q4-140k-coding-v1 \
  --hdd-cache --proxy --log --deep-log \
  --port 40801 --internal-port 40802 --parallel 1
```

The live proxy included the current hardening patches:

- Preserve same-base siblings instead of pruning them immediately.
- Retry response-complete slot saves.
- Finalize metadata after successful switch-time saves.
- Refuse to switch slots after a failed dirty save, returning 503 instead of
  forwarding a request that could overwrite the only live branch.
- Prefer a better disk same-base parent over a weak live same-base parent.

Two direct OpenClaw sessions were built incrementally:

- `hddcase-100k-a`
- `hddcase-100k-b`

### A/B Branch Growth

| Turn | Proxy session | Restore behavior | Result |
| --- | --- | --- | --- |
| A large turn | `af9a6659a512-2753bffbec17` | live same-base from earlier small A child | saved `52292` tokens |
| B large turn | `a5e71f62f9b9-d9a82ad617e8` | miss, then live shared startup checkpoint | saved `52118` tokens |
| A return | `af9a6659a512-dfa4e8fd1523` | disk parent `af9a6659a512-2753bffbec17` | restored `52292`, saved `88078` |
| B return | `a5e71f62f9b9-e6d54795e79a` | disk parent `a5e71f62f9b9-d9a82ad617e8` | restored `52118`, saved `87916` |
| A >100k | `af9a6659a512-dd5f723ac609` | disk parent `af9a6659a512-dfa4e8fd1523` | restored `88078`, saved `137460` |
| B >100k | `a5e71f62f9b9-958adaf684d9` | disk parent `a5e71f62f9b9-e6d54795e79a` | restored `87916`, saved `101509` |

Healthy same-base evidence:

```text
HDD CACHE restore PARENT: af9a6659a512-dfa4e8fd1523.bin <- af9a6659a512-2753bffbec17.bin (lcp=89548 similarity=0.600)
HDD CACHE restore status=200 n_restored=52292 n_read=1121995920
```

```text
HDD CACHE restore PARENT: a5e71f62f9b9-958adaf684d9.bin <- a5e71f62f9b9-e6d54795e79a.bin (lcp=177538 similarity=0.749)
HDD CACHE restore status=200 n_restored=87916 n_read=1779472464
```

Interpretation:

- The original branch-overwrite concern was not reproduced after the hardening
  patches.
- A and B successfully evicted each other from the live slot and later restored
  their own disk parents.
- The user-visible prompt processing during A2/B2/A3/B3 was mostly expected new
  OpenClaw suffix work, not branch loss. The key indicators are
  `n_restored` near the prior branch size and `f_keep=1.000`.

### Auto-Compaction Behavior

A crossed the auto-compaction threshold at `137460` tokens. OpenClaw then sent
a separate tiny summarization request:

```text
REQUEST POST /v1/messages body_bytes=3376 ... session=1ec38c9a08c4-e9a550c31ae5
HDD CACHE restore MISS: 1ec38c9a08c4-e9a550c31ae5.bin
forcing full prompt re-processing due to lack of cache data
HDD CACHE save status=200 n_saved=2923 n_written=210841656
```

This is expected: the compaction summary is a new prompt, not a continuation of
the full A branch. The important safety check passed: the proxy saved
`af9a6659a512-dd5f723ac609` before the compaction request overwrote the live
slot.

After compaction, a follow-up to `hddcase-100k-a` produced a new proxy base:

```text
REQUEST POST /v1/messages body_bytes=185611 ... session=9780cbee0088-260c528c9db6
HDD CACHE restore MISS: 9780cbee0088-260c528c9db6.bin
selected slot by LCP similarity, sim_best = 0.242, f_keep = 0.159
restored context checkpoint ... n_tokens = 14336
```

This is a real semi-cold event, but the cause is not lost cache. OpenClaw
rewrote the prompt after compaction and changed the proxy base ID. The new
request is not a byte-prefix continuation of either the old full A branch or
the small compaction-summary request. Measured raw prefix overlap with the
saved full A branch and the summary branch was only about 100 bytes, so forcing
a restore from the old full A cache would be unsafe and could create a
mismatched KV state.

The turn completed with:

```text
prompt eval time = 259088.29 ms / 52306 tokens
stop processing: n_tokens = 66685, truncated = 0
HDD CACHE save status=200 n_saved=66685 n_written=1387633128
```

Classification:

- Same-base A/B branch resumes: healthy.
- OpenClaw auto-compaction summary request: expected cold/new prompt.
- Post-compaction A resume: valid semi-cold due prompt rewrite/new base, not
  cache corruption.

### Disk Usage

Observed production slot directory:

- Initial direct-run area: about `172G`.
- After A/B large branches and compaction: about `181G`.
- After B saved `101509` tokens: about `187G`.

The configured launcher cap in this run was `--max-total-slots-gb 180`.
Pruning ran before large saves, but a current large save can push the directory
above the cap until the next prune. This is not runaway growth, but the cap is
currently soft around active writes.

### Updated Fix Guidance

Do not restore arbitrary cross-base parents unless the proxy can prove prompt
prefix compatibility. The post-compaction A case shows why: the old branch is
durable and logically related, but the compacted prompt is structurally
different. Reusing the old full-context KV would trade a semi-cold prompt for a
possible wrong-cache/corruption bug.

Useful next hardening:

- Add explicit log wording for “base changed after compaction / no safe
  prefix-compatible parent” when cross-base candidates have weak prefix match.
  Implemented in the working tree as a conservative cross-base selector:
  exact restore -> same-base parent -> cross-base parent only if stored prompt
  prefixes prove compatibility with `lcp >= 64 KiB` and `similarity >= 0.5`.
  Weak cross-base candidates are logged as rejected misses and are never
  restored.
- Consider a first-class OpenClaw session identifier in the proxy input if
  OpenClaw can provide one. That would let the proxy distinguish logical
  session continuity from prompt-prefix compatibility, but it still must only
  restore when the prompt prefix is compatible.
- Treat the slot-size cap as soft around the active save, or add a post-save
  prune pass that protects the just-saved branch and its current parent.
- Keep the fail-closed dirty-save behavior; it is the main guard against the
  disastrous case where a new request overwrites an unsaved similar branch.

Validation after the cross-base selector patch:

```text
node --check llama-deep-proxy.mjs
node utils/test-proxy-cow-cache.mjs
```

Both passed.

The launcher was then restarted through `llama-server-launcher.sh` with the
same author-pick model/tune, and a small direct OpenClaw follow-up was sent to
`hddcase-100k-a`.

Post-restart result:

```text
REQUEST POST /v1/messages body_bytes=185880 ... session=9780cbee0088-648ace71f247
HDD CACHE restore PARENT: 9780cbee0088-648ace71f247.bin <- 9780cbee0088-260c528c9db6.bin (lcp=125845 similarity=0.679)
HDD CACHE restore status=200 n_restored=66685 n_read=1387633128
selected slot by LCP similarity, sim_best = 0.999, f_keep = 0.999
prompt eval time = 5344.67 ms / 591 tokens
stop processing: n_tokens = 66755, truncated = 0
HDD CACHE save status=200 n_saved=66755 n_written=1388925048
```

This validates the important post-compaction distinction:

- The first post-compaction request is semi-cold because OpenClaw rewrites the
  prompt and changes base.
- Once that new compacted branch is saved, normal follow-up turns are warm
  again and restore from disk correctly across a launcher/proxy restart.
