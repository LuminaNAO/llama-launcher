# llama-waterfall — priority failover proxy for llama.cpp endpoints

Waterfall is a small, stateless proxy that routes inference traffic to
ordered lists of llama.cpp endpoints ("tiers"), fastest first. If the
preferred tier is down, requests cascade down the list until they hit a
live server. When a faster tier recovers, traffic is promoted back.

It serves **two independent routing tables** from one process:

| Table       | Port  | Purpose                                   |
|-------------|-------|-------------------------------------------|
| `[agent]`    | 40800 | main agent endpoint (freeclaw points here) |
| `[subagent]` | 40810 | sub-agent endpoint                         |

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
                                                → tier 3  192.0.2.20:40801 (WireGuard peer's deep-proxy)
freeclaw subagent → waterfall :40810 [subagent] → its own tier list (e.g. cloudclaw :40820, or the same nodes)
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

`waterfall.conf` holds both tables and their full routing state:

```
[agent]
127.0.0.1:40801  # local
192.0.2.20:40801  # peerhost

[subagent]
*127.0.0.1:40801  # local        ← * = pinned
!127.0.0.1:40820  # cloudclaw    ← ! = disabled
```

- Priority = line order. Legacy files without section headers read as
  `[agent]` — old single-table confs keep working.
- Saved on `w` in the TUI (or the `write` CLI command) **and
  automatically whenever the server exits** (stop command, signals,
  owned-TUI quit) — routing tables, order, pins, and disabled state all
  come back after a restart.
- Between saves the `[+]` dirty indicator shows unsaved state; `u`
  reverts the runtime tables to what's on disk. Hand edits are fine —
  `r` in the TUI or SIGHUP to the proxy reloads.

## v1 assumptions

- **Homogeneous models per table** (Qwen 3.6 on all nodes). Model names
  pass through untouched. The TUI shows each tier's model from `/props`
  and flags mismatches, but waterfall does not translate between models.
- Endpoints are plain `ip:port` (WireGuard/LAN/localhost). SSH tunnels
  work passively — a tunnel just makes `localhost:<port>` behave like a
  remote node — but waterfall does not manage tunnel lifecycles.

## Components

- `llama-waterfall.mjs` — zero-dependency Node:
  - no args — autostart + TUI (see Running it above).
  - `serve [agent-port] [--subagent-port <n>]` — the proxy + health
    poller + unix control socket (`waterfall.sock` in the launcher root;
    local-only by nature, no auth story, no second TCP port).
  - `tui` — vim-keyed live dashboard attached to the running proxy over
    the control socket (JSON-lines protocol; push events, no polling).
  - `stop` — stop the server and attached TUIs, saving unsaved changes.
  - **CLI control** — the full TUI surface is also exposed as subcommands
    so agents and scripts can drive it (ranks are 1-based, as displayed;
    every command accepts `--json`; per-tier commands act on `[agent]`
    unless `--table subagent` is given):
    `status`, `pin <rank>|off`, `disable <rank> [--hard]`, `enable <rank>`,
    `add <host:port> [label…] [--rank <n>]`, `remove <rank>`,
    `move <rank> <new-rank>`, `edit <rank> <host:port> [label…]`,
    `write`, `reload`, `test <rank>`.
- `waterfall.conf` — see Persistence above. Lives in the launcher root
  next to `.tunnel-history`.
- Launcher `--waterfall` mode — starts the proxy with **no local
  inference** (routing-only node).

## TUI

Two stacked panes — `[agent]` on top, `[subagent]` below — with the event
log underneath. **Tab** (or Shift-Tab) moves focus between panes; every
key acts on the focused pane. Config-as-buffer semantics (vim mental
model): rank/add/remove/edit/pin/disable changes apply to the running
proxy immediately, but `waterfall.conf` is only persisted on `w` — or
automatically when the server exits. A `[+]` dirty indicator shows
unsaved state; `u` reverts the runtime tables to what's on disk.

```
 Tab   switch pane          g/G  top/bottom
 j/k   move cursor          J/K  rank down/up
 a     add endpoint         dd   remove
 e     edit endpoint        x    disable (drain)   X   hard disable
 p     pin traffic to tier  t    test (health + 1-token completion)
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
