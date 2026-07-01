# Per-Agent Matrix Independence — Design

## Problem

The 8 Occitan component agents (gardian, fondament, farga, amassada, cor, caissa, charradissa, nervi) and Guilhem are each supposed to be a real, continuously-running presence in their own Matrix room. Live investigation on 2026-07-01 (against the running cluster, Charradissa image `sha-e17288b`, top of `main`) found this isn't happening:

- Every one of the 8 component rooms has exactly two members: `@pierre-luc` and `@charradissa`. No `@gardian`, `@fondament`, `@farga`, etc. has ever joined a room, including its own.
- Root cause: `Charradissa/charradissa-matrix/src/client.rs` `create_room_with_owner` (line 80) sets `power_level_content_override.users` entries for the owning component and every `AGENT_LOCAL_PARTS` entry — but power-level overrides only apply to existing members. Nothing in `create_room_with_owner` or `create_or_join_aliased_room` ever actually invites or joins those virtual users. Confirmed live: Charradissa's own logs show `agent send failed: backend error: send_message failed: 403 Forbidden` whenever it tries to post as a component's ghost identity.
- Guilhem's own replies (verified working end-to-end earlier today) are posted by `@charradissa` too — Guilhem does not hold its own Matrix identity in practice, despite commit `b8e7f90` ("Guilhem gets own Matrix identity, charradissa is the substrate bot") suggesting otherwise.
- All of this currently flows through Charradissa's Application Service: it fetches room history, calls each agent's `POST /matrix/reply` over HTTP, and posts the response back under the appropriate ghost identity (when that identity happens to be joined, which today it never is except `@charradissa` itself).

Separately: Guilhem's reply-generation path (`Caissa/caissa-cli/src/commands/listen.rs`, `run_matrix_reply`) already does the hard part correctly and generically — it resolves each pod's own Fondament definition via `state.generation` (e.g. `"gardian-agent"`) and keeps a persistent per-room `agent-sidecar.js` (Claude Agent SDK, `resume`-based) session alive, reaped after 30 minutes idle and respawned on next message. This is identical for every component agent pod already; it is only ever *triggered* by Charradissa's webhook push today.

## Goals

- Each of the 9 agents (guilhem + 8 components) has its own real Matrix user, holds its own login session, and posts as itself in its own room — no message for these 9 rooms passes through Charradissa.
- `@charradissa` (the Matrix username) becomes the identity of the **charradissa component agent** (it chronicles the Charradissa GitHub repo), not the relay software's own bot identity. Whatever of Charradissa's other responsibilities remain (DM fabric with humans, `#occitan` project room, concierge archival) use a renamed identity, `@charradissa-relay`.
- `@charradissa-relay` (or any prior relay/guilhem ghost identity) is removed from all 8 component rooms as a cleanup step — final membership is exactly `@pierre-luc` + the room's own agent in each.
- Each agent's session is wired to the `SessionGraph` context-collapse mechanism (`charradissa-core::graph_context`, commit `e17288b`) so recall holds up across session respawns, the same mechanism already proven for Guilhem.
- Reuse the existing persistent-session machinery in `run_matrix_reply` unchanged — this feature is about message transport (how messages get in, how replies get out), not session/reply generation, which already works.

## Non-goals

- Rebuilding or changing the Claude Agent SDK session/sidecar mechanism itself.
- Farga's `ContextNode`/`Reference`/`Discipline` context-graph feature (commits `6ef71a5`, `8c1c992`) — explicitly out of scope; this design only wires up `SessionGraph`.
- Charradissa's DM fabric, `#occitan` project-room handling, concierge archival, or federation with future generations — untouched, out of scope.
- Any change to Fondament system-prompt resolution, Farga's memory substrate itself, or Gardian's credential model beyond storing new Matrix passwords in OpenBao.

## Architecture

```
                         ┌─────────────────────────────────────────┐
                         │  agent pod (e.g. gardian-agent)          │
                         │  container: guilhem (caissa listen)      │
                         │                                           │
  Synapse  ◄──/sync──────┤  NEW: matrix_client background task       │
  (Matrix) ──/login──────┤    - login (own user + password)          │
           ──send────────┤    - confirm room membership              │
                         │    - long-poll /sync, filter own echoes   │
                         │    - on new message:                      │
                         │        run_matrix_reply(&state, &req)     │  ◄── existing, unchanged
                         │        (in-process call, not HTTP)        │
                         │    - post reply with own token            │
                         │                                           │
                         │  existing: cron handlers (dream/chronicle/│
                         │  dispatch/...), HTTP :8080 (still used by │
                         │  sre-watchdog /health, dispatcher)        │
                         └─────────────────────────────────────────┘

  Bootstrap (idempotent, runs every Helm sync):
    Synapse ◄── register 9 users (shared-secret registration)
            ◄── invite/force-join each into its designated room (temp admin token)
            ◄── kick @charradissa-relay from all 8 component rooms

  Charradissa (companion change, same rollout):
    - stops calling provision_project_rooms / relaying for these 9 rooms
    - renames its own bot identity to @charradissa-relay
```

### Components

1. **Matrix sync-loop task** (new module, `Caissa/caissa-cli/src/commands/matrix_client.rs`)
   - Spawned from `caissa listen`'s startup alongside the existing HTTP server.
   - Login: `POST /_matrix/client/v3/login`, `m.login.password`, credentials from `/creds/matrix.env` (written by an init container, same pattern as the existing GitHub/GitLab token fetch).
   - Startup: confirm membership in `MATRIX_ROOM_ID` (bootstrap already invited/joined it — this is a sanity check, not the join mechanism); do an initial `/sync` to capture a `since` token without processing historical backlog.
   - Loop: `/sync?since=...&timeout=30000`, long-poll. For each new `m.room.message` in the pod's room where `sender != own user id` (echo guard), build a request and call `run_matrix_reply` directly as a Rust function call — no HTTP round-trip to itself.
   - Post the reply via `PUT /_matrix/client/v3/rooms/{room}/send/m.room.message/{txn}` using the pod's own access token.

2. **Ported `SessionGraph` collapse** (`Caissa/caissa-core/src/graph_context.rs`, mirrors `Charradissa/charradissa-core/src/graph_context.rs`)
   - Depends directly on `amassada_core` (already a usable cross-repo dependency; Charradissa already depends on it, so this isn't a new kind of dependency for the stack).
   - Called only when `run_matrix_reply` is about to spawn a **new** sidecar session (first message after idle-reap or pod restart) — a live `resume`d session already carries its own turn history in-context; the graph's job is bridging across session boundaries.
   - Called with `history = []` — each pod now processes messages incrementally as they arrive; the persistent graph loaded from Farga already carries prior turns, so there's no rolling window to replay.
   - Non-fatal by convention (matches the existing `amassada_core::farga` and `build_graph_context` behavior): any failure logs a warning and falls back to the existing bare-prompt path.

3. **Bootstrap job** (idempotent Kubernetes Job, part of the Helm release, re-run-safe on every sync)
   - Registers the 9 Matrix users via the existing shared-secret registration mechanism (`POST /_synapse/admin/v1/register` with HMAC nonce, same approach used ad hoc during today's investigation) — treats "user already exists" as success.
   - Mints a short-lived admin token (same shared-secret mechanism), uses it to force-join/invite each of the 9 users into its designated room, then discards the token.
   - Kicks `@charradissa-relay` from all 8 component rooms if present (checks current membership first — no-op if already clean).
   - Stores each agent's Matrix **password** (not access token) in OpenBao at `secret/occitan/matrix/<agent>-password` — generated once, reused across restarts. Passwords, not tokens, because we watched a stored `SYNAPSE_ADMIN_TOKEN` go stale after a Matrix reset earlier today; logging in fresh at every pod startup is resilient to that failure mode in a way a cached token isn't.

4. **Chart wiring**
   - `Caissa/deploy/charts/component-agents/templates/agents.yaml`: add `MATRIX_USER` (= `.name`) and `MATRIX_ROOM_ID` (= `.roomId`, finally consuming the field that's been declared but unused) env vars, plus an init-container step fetching the OpenBao-stored password into `/creds/matrix.env`.
   - `Caissa/deploy/charts/guilhem/templates/guilhem.yaml`: add the same — `MATRIX_USER=guilhem`, `MATRIX_ROOM_ID` (Guilhem's room, currently only known to Charradissa; needs to be added here for the first time).
   - `Caissa/deploy/charts/component-agents/values.yaml`: the existing `roomId` values are stale (verified live — the old IDs 404 against the current Synapse) and must be updated to the room IDs actually resolved via Synapse's admin room-list API during this investigation.

5. **Charradissa companion change** (same rollout, not a separate phase — see Error Handling)
   - Stop calling `provision_project_rooms` / relaying for these 9 rooms.
   - Rename its own AS bot identity from `@charradissa` to `@charradissa-relay` (resolves the naming collision with the charradissa *component agent*, which now owns `@charradissa`).
   - DM fabric, `#occitan` project room, concierge archival continue under `@charradissa-relay` — unchanged in behavior, just a renamed identity.

## Data Flow

1. Pod starts → init container writes `/creds/matrix.env` (agent's own Matrix username + password, fetched from OpenBao).
2. `caissa listen` starts → spawns the Matrix client task → logs in → gets access token + `since` token from an initial no-op sync.
3. Sync loop: on each new inbound message (not self-authored), calls `run_matrix_reply(&state, &req)` in-process.
4. Inside `run_matrix_reply`: existing session-cache lookup; if spawning a fresh sidecar, `build_graph_context` (ported) supplies collapsed prior context from Farga; the sidecar (existing, unchanged) produces the reply.
5. Reply posted back to Matrix using the pod's own token.

## Error Handling

- Login/sync failures: non-fatal, backoff-retry. `/health` continues to reflect only HTTP-server liveness, not Matrix connectivity — matches the existing convention that Matrix issues degrade gracefully rather than crash the pod.
- **`M_UNKNOWN_TOKEN` at any point → automatic re-login.** We hit this exact failure mode live today (a stored admin token went stale after a Matrix reset) — the client must detect it and re-login rather than crash-loop or require manual intervention.
- Sync loop resumes from the last known `since` token on transient errors (network blips, 5xx) — never reprocesses already-handled events.
- Bootstrap job steps are individually idempotent: registration treats "already exists" as success; invite/kick check current membership before acting. Safe to run on every Helm sync, including after a future Matrix reset.
- **Deployment-order requirement**: the Charradissa change (stop relaying these 9 rooms, rename its own identity) must roll out atomically with — not after — enabling Caissa's direct sync loop for these 9 agents. Landing them separately creates a window where both paths reply to the same message, producing duplicates.

## Testing

- Unit tests for the new sync-loop module against a mocked Synapse (`wiremock`, matching Charradissa's existing test style): login, `/sync` event parsing and echo-filtering, re-login on `M_UNKNOWN_TOKEN`.
- Port Charradissa's existing `unreachable_farga_returns_none_not_panic`-style test for Caissa's copy of `build_graph_context`.
- Bootstrap idempotency: run the job twice against a real or test Synapse; second run must be a clean no-op (no errors, membership unchanged).
- **Real end-to-end verification** (not a substitute for the above, in addition to it): repeat the send-a-message-and-poll-for-a-reply check already validated for Guilhem this session, against 2-3 component agents post-deployment — confirm the reply's `sender` is the agent's own `@name`, and confirm exactly one reply appears (proving the old Charradissa relay path is actually off, not just redundant).

## Open Questions

- None outstanding — all major forks (relay-vs-independent, Guilhem's inclusion, the `@charradissa` naming collision, SessionGraph-vs-ContextNode, in-process-vs-sidecar-container) were resolved during design. Implementation-level details (exact bootstrap Job manifest shape, exact OpenBao path naming) are left to the implementation plan.
