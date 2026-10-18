# llama-waterfall — priority failover proxy for llama.cpp endpoints

Waterfall is a small, stateless proxy that routes inference traffic to
ordered lists of llama.cpp endpoints ("tiers"), fastest first. If the
preferred tier is down, requests cascade down the list until they hit a
live server. When a faster tier recovers, traffic is promoted back.

It serves **N independent named routing tables ("portals")** from one
process — each portal is a name, a listen port, and an ordered endpoint
list. Two portals exist by default:

| Portal      | Port  | Purpose                                   |
|-------------|-------|-------------------------------------------|
| `[agent]`    | 40800 | main agent endpoint (freeclaw points here) |
| `[subagent]` | 40810 | sub-agent endpoint                         |

and `waterfall.conf` sections define any further portals (names are
`[a-z0-9-]+`, each with its own `port = N`).

The point: freeclaw (or any client) points at `localhost:40800` (main) and
`localhost:40810` (sub-agents) once, permanently, and never needs to know
which machine is actually serving either role.

## Running it

```
llama-waterfall               # THE default: starts the server if it isn't
                              # running, then opens the TUI. q closes the
                              # server too IF this invocation started it
                              # (otherwise q just detaches). Q always stops
                              # everything. The TUI is the app, same mental
                              # model as llama-launcher.
llama-waterfall stop          # stop the server and every attached TUI
                              # (unsaved routing changes are saved first)
llama-waterfall serve [port]  # just the proxy (this is what llama-launcher
                              # --waterfall and the no-arg autostart run)
llama-waterfall tui           # attach-only dashboard (q always detaches)
```

The auto-started server logs to `waterfall.log` in the launcher root.
The TUI header shows which exit behavior applies: `owned — q stops server`
vs `attached — q detaches`.

## Architecture

```
freeclaw agent    → waterfall :40800 [agent]    → tier 1  127.0.0.1:40801   (local deep-proxy → :40802 llama-server)
                                                → tier 2  127.0.0.1:40811   (ssh tunnel → remote deep-proxy → …)
                                                → tier 3  10.0.0.x:40801 (WireGuard peer's deep-proxy)
freeclaw subagent → waterfall :40810 [subagent] → its own tier list (e.g. cloudclaw :40820, or the same nodes)
other client      → waterfall :NNNNN [any-name] → any further portal defined in waterfall.conf
```

### Layering invariant

**deep-proxy belongs to a node the way a GPU does; waterfall routes
_between_ nodes and stays stateless.**

- `llama-deep-proxy.mjs` is a **per-node** component. On every machine the
  launcher runs, deep-proxy listens on the node's public port (40801) and
  manages that machine's KV slot cache on that machine's disk, with
  llama-server hiding behind it on the internal port (40802).
- Waterfall stacks **in front of nodes**. Each tier endpoint *is* that
  node's deep-proxy, because that is already every node's public face.
  Waterfall never touches deep-proxy internals, slot state, or sessions.

Why not deep-proxy in front of waterfall (i.e. waterfall on 40802)?

1. **Slot save/restore would break.** Deep-proxy issues
   `/slots/0?action=save|restore` against *its backend* and tracks which
   session's KV is loaded there, assuming one stable backend. Behind a
   failover router, those slot commands would land on whichever tier is
   active, referencing slot files that exist only on another machine's
   disk — and llama-server returns HTTP 200 even on a failed restore, so
   it would corrupt session state silently.
2. **Restart immunity would be lost.** The launcher's stop routine pkills
   `llama-deep-proxy.mjs`. With deep-proxy in front, a local model swap
   takes down the path to healthy remote tiers too. With waterfall in
   front (separate process name, survives launcher restarts), the local
   tier bounces, traffic fails over, and the client never notices.
3. **Remote nodes already run their own deep-proxy** — the front-of-chain
   ordering avoids double session/slot logic in the path.

### Emergent KV warmth

Session identity is derived per-node from the same request headers/body,
so each node keeps its own slot cache. If tier 1 dies and tier 2 has
served this session before, tier 2 does a warm slot restore from its own
disk instead of a full re-prefill. The "failover = cold prefill" penalty
applies only the *first* time a session lands on a given node. Neither
program needs to know about the other for this to work.

## Port map

| Port  | Role                                                |
|-------|-----------------------------------------------------|
| 40800 | waterfall `[agent]` (freeclaw's main provider)      |
| 40810 | waterfall `[subagent]` (freeclaw's subagent provider) |
| 40801 | the node's deep-proxy — public face of every node   |
| 40802 | llama-server (internal, behind deep-proxy)          |
| 40820 | cloudclaw (cloud inference module — addable as a tier) |

The convention "40801 = the node's deep-proxy" holds on **every** machine,
local and remote, which keeps debugging sane.

## Failure semantics

- **Dispatch** is optimistic: try the highest-priority enabled tier
  believed healthy; on connect-refused / connect-timeout, cascade to the
  next tier. Request bodies are buffered so they can be replayed against
  the next tier.
- **Failure detection looks above TCP.** A healthy deep-proxy can front a
  dead llama-server, so upstream 502/503 also marks the tier down and
  cascades (llama-server answers 503 while loading a model).
- **The commit point is the first response body byte, not the headers.**
  llama-server sends SSE headers immediately, long before the first token,
  so headers prove nothing. Streaming responses commit when the first SSE
  chunk arrives — a tier dying during prefill/queueing (the longest
  window) fails over invisibly. Non-streaming responses are buffered in
  full (up to `--max-body-mb`) and replay on the next tier if the
  upstream dies anywhere mid-body; the client sees one clean response.
- **Stall timeout (pre-commit only).** A black-holed tier — power loss,
  dropped WireGuard peer — never sends a TCP reset; the request would
  just hang until the client's own timeout. If no response activity
  arrives before the first body byte for `--stall-timeout` seconds
  (default 600, 0 = off), the tier is marked down and the request
  cascades. The timer disarms at the first forwarded byte, so long
  generations are never cut. This is the *last-resort* detector only —
  anything that produces a real signal (connect-refused, connect-timeout,
  502/503, TCP reset, premature close) cascades immediately without
  waiting for it.
- **Mid-generation death cannot fail over.** Once body bytes have been
  forwarded, replaying elsewhere would restart generation and duplicate
  already-streamed tokens. The request fails (tier marked down); the
  client's own retry lands on the next tier.
- **Health polling** hits each tier's `/health` every `--poll-interval`
  seconds (through deep-proxy, which forwards it to llama-server). A downed
  tier is promoted back only after `--promote-after` consecutive healthy
  polls (hysteresis, so a flaky endpoint doesn't flap).
- WireGuard peers that drop before a request starts manifest as connect
  *timeouts* — `--connect-timeout` (default 2000 ms) is the knob there;
  drops mid-request are the stall timeout's job.

## Persistence

`waterfall.conf` holds every portal and its full routing state — one
`[name]` section per portal (`[a-z0-9-]+`), an optional `port = N` line,
then endpoints:

```
[agent]
port = 40800
127.0.0.1:40801  # local
10.0.0.x:40801  # example peer

[subagent]
port = 40810
*127.0.0.1:40801  # local        ← * = pinned
!127.0.0.1:40820  # cloudclaw    ← ! = disabled

[cloud]
port = 40830
127.0.0.1:40820  # cloudburst
```

- Priority = line order. The conf defines the portal set: sections are
  portal names, any number of them. `port =` is optional for the two
  canonical portals (`[agent]` defaults to :40800, `[subagent]` to
  :40810) and required for everything else; auto-save always writes it
  explicitly. Legacy files without section headers read as `[agent]` —
  old single-table confs keep working.
- Saved on `w` in the TUI (or the `write` CLI command) **and
  automatically whenever the server exits** (stop command, signals,
  owned-TUI quit) — portals, ports, order, pins, and disabled state all
  come back after a restart.
- Between saves the `[+]` dirty indicator shows unsaved state; `u`
  reverts the runtime portals to what's on disk. Hand edits are fine —
  `r` in the TUI or SIGHUP to the proxy reloads, including live re-binds
  when a portal's `port =` changed and listeners opening/closing when
  sections were added or removed.

## v1 assumptions

- **Homogeneous models per portal** (Qwen 3.6 on all nodes). Model names
  pass through untouched. The TUI shows each tier's model from `/props`
  and flags mismatches, but waterfall does not translate between models.
- Endpoints are plain `ip:port` (WireGuard/LAN/localhost). SSH tunnels
  work passively — a tunnel just makes `localhost:<port>` behave like a
  remote node — but waterfall does not manage tunnel lifecycles.

## Components

- `llama-waterfall.mjs` — zero-dependency Node:
  - no args — autostart + TUI (see Running it above).
  - `serve [agent-port] [--subagent-port <n>] [--portal <name:port> …]` —
    the proxy + health poller + unix control socket (`waterfall.sock` in
    the launcher root; local-only by nature, no auth story, no second TCP
    port). `--portal name:port` (repeatable) overrides any portal's
    listen port and beats conf `port =` lines; the legacy positional
    agent-port and `--subagent-port` keep working the same way.
  - `tui` — vim-keyed live dashboard attached to the running proxy over
    the control socket (JSON-lines protocol; push events, no polling).
  - `stop` — stop the server and attached TUIs, saving unsaved changes.
  - **Portal CRUD** — `portal list [--json]`, `portal add <name>
    [--port <n>]` (listener opens immediately; persist with `write`/`w`),
    `portal rm <name>`.
  - **CLI control** — the full TUI surface is also exposed as subcommands
    so agents and scripts can drive it (ranks are 1-based, as displayed;
    every command accepts `--json`; per-tier commands act on the first
    portal (`[agent]`) unless `--portal <name>` is given — `--table` is a
    deprecated alias, and `sub` still means `subagent`):
    `status`, `pin <rank>|off`, `disable <rank> [--hard]`, `enable <rank>`,
    `add <host:port> [label…] [--rank <n>]`, `remove <rank>`,
    `move <rank> <new-rank>`, `edit <rank> <host:port> [label…]`,
    `write`, `reload`, `test <rank>`.
    `status --json` exposes the portals under `.portals` (`.tables` is
    kept as a deprecated alias).
- `waterfall.conf` — see Persistence above. Lives in the launcher root
  next to `.tunnel-history`.
- Launcher `--waterfall` mode — starts the proxy with **no local
  inference** (routing-only node).

## TUI

One stacked pane per portal, in conf order, with the event log
underneath. **Tab / l** (next) and **Shift-Tab / h** (previous) move
focus between panes; every key acts on the focused pane. If the terminal
is too short to show every pane expanded, unfocused panes collapse to a
one-line summary (name, port, tier/healthy counts, active endpoint) so
the focused pane always stays whole. Config-as-buffer semantics (vim
mental model): rank/add/remove/edit/pin/disable/portal changes apply to
the running proxy immediately, but `waterfall.conf` is only persisted on
`w` — or automatically when the server exits. A `[+]` dirty indicator
shows unsaved state; `u` reverts the runtime portals to what's on disk.

```
 h/l   switch pane (Tab/Shift-Tab too)
 j/k   move cursor          C-d/C-u  jump 5 down/up
 g/G   top/bottom (gg works) J/K  rank down/up
 a     add endpoint         dd   remove
 e     edit endpoint        x    disable (drain)   X   hard disable
 p     pin traffic to tier  t    test (health + 1-token completion)
 A     add portal (name:port)  D  remove focused portal (asks y/N)
 w     write config         u    undo → reload from disk
 r     reload config        ?    help
 q     quit (stops the server only if this invocation started it)
 Q     quit AND stop the server + all TUIs, whoever started it
```

- `x` drains: new requests stop, in-flight ones finish (`draining…`).
- `t` proves the model is actually generating, not just that `/health`
  returns 200.
- Per-tier row: state, poll latency, request/failure counters, last error
  with timestamp, model + ctx from `/props` (mismatch flagged in red).
- Event log pane records failovers/promotions with timestamps.

## Future work (deliberately out of v1)

- **Heterogeneous endpoints** — model-name mapping / virtual model
  advertisement, per-tier context-size awareness.
- **Unified request log** — optional tee at waterfall; today deep logs
  are complete in aggregate but distributed per node.
- **Integrated ssh-tunnel management** — TUI add-endpoint flow offering
  to spawn `utils/ssh-tunnel.sh`, tunnel-liveness vs server-liveness
  distinction, reconnects.
- **Mid-generation continuation** — resuming a died-mid-stream request on
  another tier would need model-level prompt surgery (append generated
  tokens, continue); out of scope.

## Usage telemetry for tokentail (operator, Manu 2026-10-18)

Goal: every request through waterfall shows up in tokentail with tokens, model, agent and session, so local
inference has the same per-session/per-agent view as cloudburst. Waterfall stays a stateless router; telemetry
never adds latency or failure to serving.

1. **Emitter.** Waterfall records one usage event per client request through tokentail's producer SDK
   (`lib/emit.mjs`: `createEmitter({source: "waterfall"})`, `.record()` is fire-and-forget, non-blocking,
   fail-silent, JSONL spool under `$XDG_DATA_HOME/tokentail/spool/`). The SDK is vendored as a single file
   `utils/tokentail-emit.mjs` (copied verbatim, with its source commit noted in a header comment), so
   llama-launcher has no new dependency. If tokentail is not installed nothing breaks: the spool is just a file.
2. **Where.** Exactly once per client request, at every exit of `dispatch`: the normal finish, a failure after
   the commit point, client-gone-first, the all-tiers-failed 503 and the no-endpoint 503. Never at a pre-commit
   tier retry (that request is not finished). The outcome is explicit: upstream end → `complete`, failure after
   commit → `error`, both 503s → `error`, client gone first → `aborted`.
3. **Fields** (tokentail schema v2): `requestId` (`x-request-id` header or a fresh UUID), `endpoint` = portal name
   (`agent`, `subagent`, or any configured portal), `port` = listen port, `provider` = the tier's configured label, else `tier-<n>` (never
   host or address: topology must not reach the spool), `model` from the response, `agentId` from
   `X-OpenClaw-Agent-Id`, `sessionId` from `X-OpenClaw-Session-Key` (falling back to `X-OpenClaw-Session-Id`),
   `instance` from `X-OpenClaw-Instance`, `status`, `durationMs`, `outcome`, `usage`.
4. **Usage.** llama.cpp responses:
   - non-streaming: the body is already buffered for failover; parse it once and read `usage.prompt_tokens` →
     `input`, `usage.completion_tokens` → `output`, `cacheRead`/`cacheWrite` = 0 (or llama.cpp's
     `timings.cache_n` → `cacheRead` with `input = prompt_tokens - cache_n` when present). Parse failure →
     `usage: null`, never throw.
   - streaming: scan the forwarded chunks with a small rolling tail window for the final `usage` object (and
     `timings`) that llama-server sends before `[DONE]`; same mapping. If the client did not ask for usage and
     none arrives, `usage: null` (the request still counts).
5. **Opt-out.** `--no-telemetry` flag and `WATERFALL_TELEMETRY=0` turn the emitter off. Default on.
6. **Tests** (node:test, no network, fake upstream): one record per request on each of the five exits and none on
   a retried tier; outcome per exit; usage from non-streaming body, from a streamed final chunk, and null when
   absent; headers mapped to agentId/sessionId/instance; provider uses label or `tier-<n>` and never contains a
   host or port; emitter throwing or a read-only spool dir never affects the response; `--no-telemetry` writes
   nothing.
7. **Dashboard.** The record is read by tokentail's stand-alone waterfall dashboard (tokentail ARCH §4.3a,
   `tokentail serve --waterfall` on the same box). README gains one line pointing to it. Nothing cloudburst or
   enterprise is involved.
8. **Inference only.** Only model calls are recorded (POST to the completion/chat/embedding paths). Waterfall's own
   health probes and GET requests such as `/v1/models` are never recorded.
