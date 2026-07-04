# Matrix as Human Interface, Nervi as Agent Substrate

**Date:** 2026-07-04
**Status:** Design — not implemented, not yet reviewed against system-defence
**Proposed repo:** `Corrièr` (Occitan: courier/postman) — new repo, not a Caissa or
Charradissa subdirectory. Houses the read/write gateway pair as a protocol-agnostic
core plus one adapter per messaging backend (Matrix first; Slack, WhatsApp, MS
Teams, IRC intended to follow — see Protocol adapters, below).
**Supersedes (in scope):** `Caissa/caissa-cli/src/commands/listen.rs`'s `/matrix/reply`,
`/turn`, `room_sessions`, `run_matrix_client_loop`, `SidecarProcess`, `RoomSession`,
and the `agent-sidecar.js` per-room hosting model.
**Does not touch:** `/trigger/chronicle`, `/trigger/dream`, `/trigger/sre-alert`,
`/trigger/backlog-review`, `/trigger/dispatch`, `/trigger/mission-pulse`,
`/trigger/intake`, `/trigger/scan` — these are one-shot `claude --print` subprocess
runs with no session state and no Matrix ownership. They are not proxying anything
and are out of scope for this spec.

---

## Problem statement

The codename table (`Cor/cor-codename.md`) charters two different components for
two different jobs:

| Codename | Chartered role |
|---|---|
| Charradissa | *"Matrix-chat runtime. Projects live as rooms, agents as members. Constructs specialists at runtime, manages approval queues."* |
| Caissa | *"Docker-based container toolbox. Contains sandboxed Claude Code runtime, PII anonymization proxy, and sidecar reporter."* |

What actually got built inverts this. `Caissa/caissa-cli/src/commands/listen.rs` logs
in as a Matrix bot user, long-polls `/sync`, owns an in-process `HashMap` of live
room sessions, and spawns/pipes to a persistent `agent-sidecar.js` child process per
room — the Matrix-chat-runtime job, charted to Charradissa. Charradissa, in the
running system, is reduced to a set of MCP tools (`matrix_send`, `matrix_invite`,
...) that Guilhem calls. The "sandboxed runtime" component absorbed the "Matrix
runtime" component's charter, and became a single daemon proxying every room's
traffic through itself — transport, session lifecycle, and agent invocation, all in
one service, with continuity resting entirely on the SDK's `resume` mechanism and a
map that lives in exactly one pod's memory.

This spec's premise: **that inversion is the actual problem**, not "a queue in the
middle vs. a direct connection." The fix is to put each job back with the component
chartered for it, and to make the boundary between them structural rather than
aspirational.

A second inversion follows from the first: Charradissa's charter was specifically
*Matrix*-chat runtime, but the actual need is protocol-agnostic — Matrix today,
Slack/WhatsApp/MS Teams/IRC intended later. Naming a single-protocol charter as the
home for a multi-protocol job would just relocate the drift this spec is trying to
fix. This spec proposes retiring Charradissa's chat-runtime charter in favor of a new
component, `Corrièr`, chartered explicitly as protocol-agnostic — Matrix becomes one
adapter inside it, not the thing it's named after. See Protocol adapters, below.

## Core principle

> Matrix is an exchange interface with humans. It is not a registry, not a session
> store, not a source of truth for routing, and not something an agent ever talks to
> directly.

This generalizes a rule that already exists one level up: Guilhem's own Fondament
definition states that component agents communicate with each other *only* through
Nervi, never Matrix — *"A matrix_send call targeting a component's room will 403 or
land somewhere no one is watching."* This spec extends that same rule to the human-
facing side. An agent's only communication substrate is Nervi, full stop. The only
component with Matrix credentials or Matrix-specific logic is the bridge.

Concretely:

- No agent process holds a Matrix access token, a Matrix user identity, or any
  Matrix client code.
- No agent process's continuity depends on a Matrix-side mechanism (room state,
  `resume` sessions tied to a Matrix room ID, room topic/custom state events).
- The bridge holds no conversation state and makes no model calls. It translates
  Matrix room events into Nervi messages and back. Nothing else.

## Component roles, redefined

### Corrièr — split into two gateways, not one bridge, and protocol-agnostic at the core

A single bidirectional "bridge" is still one component doing two jobs with two
different load shapes (inbound rate is driven by human typing speed and Synapse's
serialized AS delivery; outbound rate is driven by however many agent replies land
on Nervi, which can burst independently). Splitting them lets each scale on its own
signal and keeps either half's failure from taking down the other direction.

Everything below describes the **Matrix adapter's** implementation of this pair — the
first one to build, and the one this spec details fully. Other adapters (Protocol
adapters, below) implement the same two roles against a different wire protocol.

**Read gateway (ingress), Matrix adapter.** Responsibilities, and only these:

1. **Registers as a Matrix Application Service**, not a bot user. Synapse pushes
   room events to the AS as HTTP transactions — this replaces `run_matrix_client_loop`'s
   `/sync` long-poll entirely. An AS is the primitive Matrix provides specifically for
   bridge software; a bot user polling `/sync` is the wrong tool for this job and is
   what today's Caissa does.
2. On each inbound room event: resolve `room_id → nervi_subject` (see Routing, below)
   and `nervi_publish` the event verbatim (sender, content, room_id, event_id). No
   interpretation, no LLM call, no session lookup, and no direct call to any agent —
   `nervi_publish` is the *only* output this service produces. See Statelessness,
   below, for why that last constraint is load-bearing.

**Write gateway (egress), Matrix adapter.** Responsibilities, and only these:

1. Subscribes to Nervi outbound chat subjects as a durable queue-group consumer.
2. On each reply message (tagged with `room_id`): post it to that room via the
   normal Matrix client-server API (mermaid-image substitution, markdown rendering —
   the existing `post_reply`/`substitute_mermaid_with_images` logic in `listen.rs` is
   reusable here verbatim; it's presentation, not proxying, and has no reason to move).
3. Its only input is Nervi. It never receives a direct call from an agent pod, a
   Farga hook, or anything else — if a reply didn't arrive over Nervi, this service
   has no way to know it exists, by construction.

Matrix room membership lifecycle (`caissa bootstrap-matrix-agents`) is a third,
separate concern — it's provisioning, not message traffic, and can sit with either
gateway or stand alone; this spec doesn't need to decide that placement.

Neither gateway holds a per-room map, a child process, or a model credential. Either
one can be killed, restarted, or scaled to zero and back with no conversation loss,
because neither one ever held the conversation.

### Protocol adapters — the reason this is a new repo, not a Charradissa subfolder

Corrièr's core is a canonical message schema and the Nervi-facing half of both
gateways (publish inbound, consume outbound, resolve routing against Farga). None of
that is Matrix-specific. Each supported backend implements the same small contract
against that core:

- **Inbound:** *protocol event → canonical message* (`sender`, `content`, a
  protocol-agnostic `conversation_id`, an adapter tag) → handed to the shared
  `nervi_publish` path.
- **Outbound:** canonical reply (tagged with `conversation_id`) → *rendered for this
  protocol* → delivered.

Everything else in this spec — statelessness, horizontal scaling, no direct
agent calls, routing lives in Farga not in the protocol — applies per adapter, not
just to Matrix. An agent pod never knows or cares which adapter a `conversation_id`
came from; that's the entire point of putting a canonical schema between the agent
and the wire protocol.

Planned adapters, in the order named: Matrix (this spec, first), Slack, WhatsApp,
MS Teams, IRC.

**Slack, WhatsApp, MS Teams** all have a webhook-style push primitive analogous to
Matrix's Application Service — Slack's Events API, WhatsApp's Business API webhook,
the Bot Framework connector for Teams. Each read gateway variant is expected to look
structurally like the Matrix one: stateless, push-driven, no polling loop.

**IRC is the exception, flagged now rather than discovered later.** IRC has no
server-side push primitive at all — no webhook, no equivalent of an Application
Service. The only way to observe a channel is a client holding a live, persistent
connection to the server and reading the stream as it arrives. That reintroduces one
small piece of session-shaped state (a held connection, and whichever channels it's
currently sitting in) that every other adapter in this spec is designed to avoid.
It should still hold the rest of the statelessness contract — no per-room map beyond
channel membership, no agent logic, no model calls, `nervi_publish` as its only
output — but "holds a live connection" is a real, protocol-forced exception to
"stateless," not an oversight. Worth deciding explicitly whether that's acceptable
before building it, rather than trying to force IRC into the same shape as the
webhook-based adapters and discovering it doesn't fit.

### Nervi — the substrate

Already the right shape for this; nothing new needs building at the transport layer.
What changes is what flows over it:

- **Inbound subject** per component (or per component+room — see Routing):
  `occitan.chat.inbound.<component>`
- **Outbound/reply subject**: `occitan.chat.outbound.<component>`, payload tagged
  with `conversation_id` (Matrix room ID today; the adapter-agnostic handle once
  other backends exist) so the write gateway knows where to deliver it.
- **Delivery to agent pods must be push, not poll.** The existing
  `run_nervi_loop_if_component` pattern (`tokio::time::sleep(60s)` between polls) is
  the wrong consumption model for anything interactive — it would add up to 60s of
  latency to a chat reply. This needs a durable JetStream **push** consumer, or a
  tight blocking pull loop with no sleep, keyed by room for ordering (the existing
  `consumer_name = subject.replace('.', "-")` derivation in `poll_nervi_subject`
  already shows the right instinct — extend it to be per-room, not just per-subject,
  so message order within a room is preserved while different rooms process in
  parallel).

### Agent pods — the compute

Each component's own pod (and Guilhem's) subscribes directly to its inbound chat
subject. This is genuinely new capability, not a relabeling of the sidecar:

- The agent owns its own turn loop and its own context assembly — from Farga,
  not from an SDK `resume()` black box. This is the natural home for
  trajectory-conditioned context collapse (`2026-07-01-trajectory-conditioned-
  collapse.md`): since the agent now controls its own per-turn context construction
  instead of delegating continuity to an opaque resumed session, it can rebuild scope
  from the graph each turn rather than accumulating raw history indefinitely. This
  spec doesn't require that collapse be implemented — it just removes the structural
  reason it currently isn't (a resumed sidecar session has no seam to rebuild context at).
- The agent never imports a Matrix client, never sees a Matrix access token, and can
  be tested/run/replayed with zero Matrix dependency — its input is "a message
  arrived on my inbound subject," full stop.
- The agent publishes its reply to its own outbound subject, tagged with the
  originating `room_id`. It does not know or care how that reply reaches a human.

### Farga — the routing authority

The one thing this design needs that doesn't exist yet: a durable answer to *"which
Nervi subject does this room's traffic go to."* This must not live in Matrix (room
topic, custom state event, or anything else queryable from the room itself) — that
would just be a smaller, disguised version of the registry problem this spec exists
to avoid.

Store it as a Farga context node, consistent with the existing convention:

```
path: "[<room_id>][routing]"
content: { "component": "<component>", "inbound_subject": "occitan.chat.inbound.<component>" }
```

The bridge reads this once per inbound event (cacheable, invalidated on room-
membership-change events, which *are* legitimate for the bridge to observe — knowing
who's present in a room is what an exchange interface is for; it is not the same
thing as using the room as a database).

### Caissa — reverts to its original charter

Caissa stops being a Matrix-facing daemon at all. It becomes what the codename table
already said it was: a sandboxed Claude Code execution environment, PII proxy, and
sidecar reporter. Concretely, under this spec:

- Caissa is the **runtime image/spec that agent pods run inside**, not a central
  process that owns their sessions. "These pods that hold agent sessions run in a
  Caissa env" — many instances, each scoped to one agent pod, none of them proxying
  anyone else's traffic.
- The existing trigger endpoints (`chronicle`, `dream`, `sre-alert`, `backlog-review`,
  `dispatch`, `mission-pulse`, `intake`, `scan`) are unaffected — they're one-shot
  subprocess runs with no session state, which is exactly what "sandboxed runtime"
  means. They stay exactly as they are.
- Everything that made Caissa a proxy — `room_sessions`, `SidecarProcess`,
  `run_matrix_client_loop`, `/matrix/reply`, `/turn` — is removed from Caissa
  entirely, not refactored in place. It doesn't relocate into Charradissa either;
  the session/turn-loop logic moves into each agent pod, which is a genuinely
  different owner than either of the two components that fought over it before.

## Statelessness and horizontal scaling

Both gateways must be stateless in the strict sense — no in-memory state that a
second replica wouldn't also have — for two reasons that are separate but reinforce
each other: horizontal scaling under load, and keeping the context graph honest.

**Why the "only Nervi in or out" rule matters beyond decoupling.** If a gateway ever
called an agent directly (HTTP, gRPC, an in-process function call) instead of
publishing to Nervi, that call would be invisible to everything that already
consumes Nervi subjects to build a picture of what's happening in the stack —
Guilhem's dream/chronicle/librarian passes, Farga's signal history, any future
context-graph tooling. Human-chat traffic would become a second, undocumented
channel alongside the one the rest of the org already instruments. Routing every
message through a real Nervi publish/subscribe, with no side channel, is what lets
chat traffic show up in the same graph as `occitan.dispatch.*` and
`occitan.contribution.*` without a special case.

**Read gateway scaling.** The routing decision (`room_id → subject`, via the Farga
lookup) is a pure function of inputs already in the request — no replica needs to
have seen this room before to handle it correctly, so any replica can handle any
transaction. Synapse itself serializes AS transaction delivery (it sends one, waits
for the ack, sends the next), so a plain load-balanced pool of stateless replicas
behind one registered AS URL introduces no ordering risk on the way in — scale by
replica count against inbound rate, nothing more is needed.

**Write gateway scaling.** NATS JetStream's queue-group consumer semantics are the
right primitive here: multiple stateless replicas durably subscribed under the same
consumer name split the outbound workload with each message delivered to exactly
one replica, no coordination between replicas required. The one thing this doesn't
solve for free: if a single room could receive multiple agent replies that must
land in a specific order, plain queue-group delivery doesn't guarantee that ordering
across replicas. That's an open decision (see below), not assumed away — options are
a consistent hash of `room_id` to a fixed partition, or accepting best-effort
ordering because in practice one agent produces one reply per turn.

**What "stateless" rules out concretely:** no `room_sessions`-style map, no
per-room child process, no sticky routing requirement, no assumption that "the next
message for this room will hit the same replica as the last one." If a design for
either gateway needs any of those, it has quietly reintroduced the thing this spec
removes Caissa for doing.

## Message flow

```
Element ──1. writes message──▶ Synapse
Synapse ──2. pushes txn (AS API)──▶ Read gateway (stateless, N replicas)
Read gateway ──3. publishes msg──▶ Nervi (inbound subject)
Nervi ──4. push delivers──▶ Agent pod
Agent pod ──5. publishes reply──▶ Nervi (outbound subject)
Nervi ──6. queue-group delivers──▶ Write gateway (stateless, N replicas)
Write gateway ──7. posts reply──▶ Synapse
Synapse ──8. delivers via sync──▶ Element
```

Symmetric by design: the agent's reply goes back through Nervi, not straight to
Synapse. This is the load-bearing choice in this spec, not an incidental one — if the
agent posted directly to Matrix, every agent pod would need Matrix credentials and
Matrix logic, which is exactly the coupling this spec exists to remove. The one-hop
latency cost of routing the reply back through a gateway buys total Matrix isolation
for every agent pod. Steps 2→3 and 6→7 are handled by two different services that
never call each other directly — the only thing connecting an inbound message to
its eventual reply is that both pass through Nervi with the same `room_id`.

## What this explicitly rejects

- Caissa (or anything) logging in as a Matrix bot user and long-polling `/sync` to
  discover new messages. Use the Application Service push model instead.
- Any component hosting a per-room, in-process session map as the *sole* record of
  conversation state. If that process dies, the conversation dies with it.
- Using Matrix room state, topic fields, or custom state events as a routing
  registry, a session store, or anything else load-bearing beyond "who is in this
  room and what did they say."
- A single daemon that is simultaneously the Matrix transport, the session owner,
  and the agent invoker. That conflation is the actual defect in the current design,
  independent of whether the middle hop is a direct pipe or a queue.
- Either gateway calling an agent pod directly (HTTP, gRPC, in-process) instead of
  publishing to Nervi. Even one such shortcut makes chat traffic invisible to
  everything else that instruments the stack by consuming Nervi subjects.
- Any state in a gateway that a second replica of that same gateway wouldn't also
  have. If scaling a gateway to N replicas requires sticky routing or a shared
  in-memory map, the statelessness requirement has already been violated.

## Decisions (resolved 2026-07-04, prior to implementation planning)

1. **Multi-agent / approval-room fan-out — resolved.** The Farga routing node
   (see Routing, above) holds a *list* of `{component, inbound_subject}` entries per
   room, not a single value, from the first implementation — not a later schema
   migration. The read gateway fans out an inbound event to every subject in the
   list. Covers the single-agent-per-room common case today (a one-element list)
   without a breaking change when approval/debate rooms with multiple agent members
   are built.

2. **Subject naming — resolved, symmetric on both directions.** Per-room subjects,
   not per-component-with-a-consumer-key:
   - Inbound: `occitan.chat.inbound.<component>.<room_short_id>`
   - Outbound: `occitan.chat.outbound.<component>.<room_short_id>`

   Each component subscribes via a wildcard (`occitan.chat.inbound.<component>.>`)
   for the "one subscription sees all my rooms" property, while NATS subject
   semantics give correct per-room ordering natively — no invented consumer-key
   convention needed on either side. Symmetry matters here specifically because the
   agent pod's own context-graph construction (Farga-backed, per-room) is keyed the
   same way the transport is: the room is the unit of ordering, the unit of
   subject-space, and the unit of context-graph identity, on both the read and the
   write side. Delivery of an inbound message to a room's subject is what triggers
   that room's context-graph read/update as part of turn processing (see Agent
   pods, above) — the transport-level and context-level granularity deliberately
   match instead of being two different keying schemes bolted together.

3. **Write-gateway reply ordering across replicas — resolved: no ordering guarantee
   needed at the transport level, at all.** Stronger than "accept best-effort
   because one reply per turn": the Farga context graph is the actual source of
   truth an agent reads before producing a reply, and it carries real timestamps —
   information an LLM can and does interpret directly when reasoning about what
   happened when. Correctness depends on the graph capturing events accurately, not
   on NATS delivery order matching wall-clock order. No partition key, no
   consistent-hash-to-replica scheme. This should be treated as a real design
   principle for this stack going forward, not a one-off exception for the write
   gateway specifically: **wire-order is not a substitute for a graph with
   timestamps, and shouldn't be engineered for where a graph already exists.**

4. **Identity/registration — resolved as a real adapter-contract concern, not a
   Matrix-specific detail.** Matrix's Application Service virtual-user mechanism is
   *one adapter's implementation* of a general capability every protocol adapter
   must provide: a way to represent and provision N agent-facing identities in that
   protocol, without any agent process ever holding that protocol's credentials
   itself. The Corrièr core defines this as an explicit per-adapter contract (not
   optional, not Matrix-only prose) — Matrix implements it via AS virtual users;
   a future Slack adapter would implement the same contract via a workspace bot
   identity + per-agent display-name/icon conventions; IRC via provisioned
   nicks. The core never hardcodes "AS" as a concept — it only requires "the
   adapter can represent this set of agent identities," however that protocol
   expresses it. Nothing about this ships except the Matrix implementation today,
   but the *interface* is real, checked-in code from the first implementation task,
   not a placeholder.

5. **Migration path — resolved: accept the one-time continuity loss.** No bridge,
   no final-chronicle seeding step. Rebuilding a room's working context from Farga
   on the agent pod's first real turn *is* the new steady state this spec
   establishes (every subsequent turn does exactly this) — cutover is just that
   steady state's first occurrence for each room, not a special case needing its
   own migration engineering.

6. **Push consumer implementation — resolved: JetStream push consumers.** Lower
   latency than a tight pull loop, and it's the primitive NATS already provides for
   exactly this delivery shape — a pull loop would be reimplementing push badly.

7. **IRC's forced exception to statelessness — not resolved today by design; explicit
   interim position recorded.** IRC is last in the adapter build order and is not
   part of this spec's implementation plan. Interim position: the connection-
   holding carve-out is provisionally acceptable, strictly scoped to "one live
   socket + the channel list it's currently in," with reconnect/backoff logic
   allowed but no growth into a session or routing cache — the same constraint the
   stateless gateways get, plus the one exception IRC's protocol forces. Real
   decision deferred to when IRC adapter work actually starts. This is the sharpest
   instance of decision 4, above: whatever "identity provisioning" means for IRC
   (registering N nicks under one held connection) has to satisfy the same
   adapter contract Matrix's AS mechanism does, even though the underlying
   connection model looks nothing like a webhook/AS push.

**Scope note carried into planning:** decisions 1, 2, and 4 exist specifically so
the *first* implementation (Matrix-only) is built against a real multi-adapter,
multi-agent-per-room contract from day one — Pierre-Luc's explicit instruction is
not to build a Matrix-only design that happens to have adapter-shaped comments, but
to build the actual core/adapter boundary now, with Matrix as its first and only
adapter for this plan. No second protocol ships in this round; the seam it would
plug into does.

## Relationship to other specs in this repo

- Directly enables `2026-07-01-trajectory-conditioned-collapse.md`'s per-turn context
  rebuild, by removing the SDK `resume()` session as the thing standing in the way of
  it. This spec does not implement collapse; it removes the reason collapse couldn't
  previously be tried on the live chat path.
- Consistent with, and a direct extension of, the Nervi-not-Matrix rule already
  written into Guilhem's Fondament definition for inter-agent communication.
