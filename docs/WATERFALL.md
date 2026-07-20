# llama-waterfall — priority failover proxy for llama.cpp endpoints

Waterfall is a small, stateless proxy that routes inference traffic to an
ordered list of llama.cpp endpoints ("tiers"), fastest first. If the
preferred tier is down, requests cascade down the list until they hit a
live server. When a faster tier recovers, traffic is promoted back.

The point: freeclaw (or any client) points at `localhost:40800` once,
permanently, and never needs to know which machine is actually serving.

## Architecture

```
freeclaw → waterfall :40800 → tier 1  127.0.0.1:40801   (local deep-proxy → :40802 llama-server)
                            → tier 2  127.0.0.1:40811   (ssh tunnel → remote deep-proxy → …)
                            → tier 3  192.0.2.20:40801 (WireGuard peer's deep-proxy)
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

| Port  | Role                                              |
|-------|---------------------------------------------------|
| 40800 | waterfall (client-facing; freeclaw points here)   |
| 40801 | the node's deep-proxy — public face of every node |
| 40802 | llama-server (internal, behind deep-proxy)        |

The convention "40801 = the node's deep-proxy" holds on **every** machine,
local and remote, which keeps debugging sane.

## Failure semantics

- **Dispatch** is optimistic: try the highest-priority enabled tier
  believed healthy; on connect-refused / connect-timeout, cascade to the
  next tier. Request bodies are buffered so they can be replayed against
  the next tier.
- **Failure detection looks above TCP.** A healthy deep-proxy can front a
  dead llama-server, so upstream 502/503 *before response headers are
  forwarded* also marks the tier down and cascades.
- **Mid-stream death cannot fail over.** Once response headers/bytes have
  been forwarded to the client, a dying upstream fails that request (tier
  marked down); the client's own retry lands on the next tier.
- **Health polling** hits each tier's `/health` every `--poll-interval`
  seconds (through deep-proxy, which forwards it to llama-server). A downed
  tier is promoted back only after `--promote-after` consecutive healthy
  polls (hysteresis, so a flaky endpoint doesn't flap).
- WireGuard peers that drop manifest as connect *timeouts*, not fast
  refusals — `--connect-timeout` (default 2000 ms) is the knob that
  matters there.

## v1 assumptions

- **Homogeneous models** (Qwen 3.6 on all nodes). Model names pass through
  untouched. The TUI shows each tier's model from `/props` and flags
  mismatches, but waterfall does not translate between models.
- Endpoints are plain `ip:port` (WireGuard/LAN/localhost). SSH tunnels
  work passively — a tunnel just makes `localhost:<port>` behave like a
  remote node — but waterfall does not manage tunnel lifecycles.

## Components

- `llama-waterfall.mjs` — zero-dependency Node, three subcommands:
  - `serve <port>` — the proxy + health poller + unix control socket
    (`waterfall.sock` in the launcher root; local-only by nature, no auth
    story, no second TCP port).
  - `tui` — vim-keyed live dashboard attached to the running proxy over
    the control socket (JSON-lines protocol; push events, no polling).
  - `status [--json]` — scriptable one-shot state dump (waybar, cron).
- `waterfall.conf` — one `host:port  # label` per line, priority = line
  order, `#` comments. Lives in the launcher root next to
  `.tunnel-history`.
- Launcher `--waterfall` mode — starts the proxy with **no local
  inference** (routing-only node).

## TUI

Config-as-buffer semantics (vim mental model): rank/add/remove/edit
changes apply to the running proxy immediately, but `waterfall.conf` is
only persisted on `w`. A `[+]` dirty indicator shows unsaved state; `u`
reverts the runtime list to what's on disk.

```
 j/k   move cursor          g/G  top/bottom
 J/K   rank down/up         a    add endpoint      dd  remove
 e     edit endpoint        x    disable (drain)   X   hard disable
 p     pin traffic to tier  t    test (health + 1-token completion)
 w     write config         u    undo → reload from disk
 r     reload config        ?    help              q   quit
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
