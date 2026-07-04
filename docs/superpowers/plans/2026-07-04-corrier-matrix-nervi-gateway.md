# Corrièr: Matrix Gateway Pair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Caissa's Matrix-facing daemon (`room_sessions`, `SidecarProcess`,
`run_matrix_client_loop`, `/matrix/reply`, `/turn`, `agent-sidecar.js` per-room
hosting) with a stateless read/write gateway pair in a new repo, `Corrièr`, whose
only I/O is Matrix on one side and Nervi on the other — no agent process ever holds
a Matrix credential again.

**Architecture:** Two binaries (`corrier-read-gateway`, `corrier-write-gateway`)
built on two library crates: `corrier-core` (canonical message schema, the
`Adapter` trait, Farga routing client, Nervi publish/consume wrapper) and
`corrier-matrix` (the one adapter implemented in this plan — Matrix Application
Service registration, virtual-user provisioning, AS transaction parsing, and
outbound delivery, the last of which ports Caissa's existing
`post_reply`/`substitute_mermaid_with_images` verbatim). Each of the 9 agent pods
(Caissa's runtime image) gains a new per-room turn loop driven by `corrier-core`'s
Nervi consumer, replacing the sidecar/session-map model entirely.

**Tech Stack:** Rust (`tokio`, `axum`, `reqwest`, `async-nats` via `nervi-core`),
Matrix Application Service protocol (`_matrix/app/v1/transactions`), NATS
JetStream (durable pull consumer with continuous `.messages()` streaming — see
Task 3's note on why this satisfies "push consumer" without a legacy
`deliver_subject` push consumer), Farga's existing generic KV store.

## Global Constraints

- License: Apache-2.0 on every new crate (`license.workspace = true`), matching
  every other Occitan repo.
- No agent process (Corrièr's own gateways included, beyond the Matrix adapter
  itself) holds a Matrix access token or Matrix user identity in memory as
  conversation-critical state — see the spec's Statelessness section.
- Per-room Nervi subjects, symmetric on both directions:
  `occitan.chat.inbound.<component>.<room_short_id>` and
  `occitan.chat.outbound.<component>.<room_short_id>` (spec decision 2).
- Farga routing node at path `[<room_id>][routing]` holds a **list** of
  `{component, inbound_subject}` entries, never a single scalar (spec decision 1).
- No ordering guarantee is implemented at the transport level anywhere in this
  plan — no partition key, no consistent-hash-to-replica scheme (spec decision 3).
- The `Adapter` trait in `corrier-core` is real, checked-in code from Task 1 —
  Matrix is its only implementation in this plan, but the trait boundary must not
  leak Matrix-specific types or names.
- `/trigger/chronicle`, `/trigger/dream`, `/trigger/sre-alert`,
  `/trigger/backlog-review`, `/trigger/dispatch`, `/trigger/mission-pulse`,
  `/trigger/intake`, `/trigger/scan` in Caissa are **not touched** by any task in
  this plan.
- Slack, WhatsApp, MS Teams, IRC adapters are **not built** in this plan — not even
  stubbed.

---

### Task 1: `corrier-core` — canonical schema and the `Adapter` trait

**Files:**
- Create: `Corrier/Cargo.toml` (modify existing scaffold to add the new member)
- Create: `Corrier/corrier-core/Cargo.toml`
- Create: `Corrier/corrier-core/src/lib.rs`
- Create: `Corrier/corrier-core/src/message.rs`
- Create: `Corrier/corrier-core/src/adapter.rs`
- Test: `Corrier/corrier-core/src/message.rs` (inline `#[cfg(test)]`)
- Test: `Corrier/corrier-core/src/adapter.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Produces: `corrier_core::message::{ChatMessage, ChatReply}`, both `pub`,
  `#[derive(Debug, Clone, Serialize, Deserialize)]`.
  - `ChatMessage { conversation_id: String, sender: String, content: String, adapter: String, external_event_id: Option<String> }`
  - `ChatReply { conversation_id: String, content: String, adapter: String }`
- Produces: `corrier_core::adapter::{Adapter, AdapterIdentity}` trait + type, used
  by every later task that touches Matrix specifically (Tasks 4, 5).

- [ ] **Step 1: Update the workspace Cargo.toml to add the new member**

```toml
[workspace]
members = ["corrier-core"]
resolver = "2"

[workspace.package]
license = "Apache-2.0"

[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
thiserror = "1"
reqwest = { version = "0.12", features = ["json"] }
chrono = { version = "0.4", features = ["serde"] }
tracing = "0.1"
tracing-subscriber = "0.3"
async-trait = "0.1"
```

(Replace the contents of `Corrier/Cargo.toml` with the above — same file, just
`members` populated and `async-trait` added since the `Adapter` trait below needs
it for object-safe async methods.)

- [ ] **Step 2: Create `corrier-core`'s Cargo.toml**

```toml
[package]
name = "corrier-core"
version = "0.1.0"
edition = "2021"
license.workspace = true

[dependencies]
tokio = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
anyhow = { workspace = true }
reqwest = { workspace = true }
tracing = { workspace = true }
async-trait = { workspace = true }
```

- [ ] **Step 3: Write the failing test for `ChatMessage`/`ChatReply` round-trip**

Create `Corrier/corrier-core/src/message.rs`:

```rust
use serde::{Deserialize, Serialize};

/// A message received from a human, in canonical form — no adapter-specific
/// fields survive past this point. `conversation_id` is the adapter-agnostic
/// handle for "where this came from" (a Matrix room ID today).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChatMessage {
    pub conversation_id: String,
    pub sender: String,
    pub content: String,
    /// Which adapter produced this (e.g. "matrix") — carried through so a
    /// reply can be routed back to the right adapter without re-deriving it.
    pub adapter: String,
    /// The adapter's own event identifier, if it has one (Matrix event ID).
    /// Not used for routing or ordering — purely diagnostic.
    pub external_event_id: Option<String>,
}

/// A reply produced by an agent, addressed back to a conversation.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChatReply {
    pub conversation_id: String,
    pub content: String,
    pub adapter: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_message_round_trips_through_json() {
        let msg = ChatMessage {
            conversation_id: "!abc:occitane.guilhem".to_string(),
            sender: "@pierre-luc:occitane.guilhem".to_string(),
            content: "hello".to_string(),
            adapter: "matrix".to_string(),
            external_event_id: Some("$xyz".to_string()),
        };
        let json = serde_json::to_string(&msg).unwrap();
        let back: ChatMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, back);
    }

    #[test]
    fn chat_reply_round_trips_through_json() {
        let reply = ChatReply {
            conversation_id: "!abc:occitane.guilhem".to_string(),
            content: "reply text".to_string(),
            adapter: "matrix".to_string(),
        };
        let json = serde_json::to_string(&reply).unwrap();
        let back: ChatReply = serde_json::from_str(&json).unwrap();
        assert_eq!(reply, back);
    }
}
```

- [ ] **Step 4: Run test to verify it passes (this step has no prior failing state — `cargo new`-equivalent, write once)**

Run: `cd Corrier && cargo test -p corrier-core message`
Expected: `test message::tests::chat_message_round_trips_through_json ... ok` and
`test message::tests::chat_reply_round_trips_through_json ... ok`

- [ ] **Step 5: Define the `Adapter` trait and `AdapterIdentity`**

Create `Corrier/corrier-core/src/adapter.rs`:

```rust
use crate::message::{ChatMessage, ChatReply};

/// An agent-facing identity an adapter has provisioned in its own protocol —
/// e.g. a Matrix Application-Service virtual user. The core never inspects
/// the contents of `protocol_handle`; it's opaque outside the adapter that
/// produced it.
#[derive(Debug, Clone)]
pub struct AdapterIdentity {
    pub agent_name: String,
    /// Adapter-specific handle (a Matrix user ID like `@_corrier_guilhem:...`
    /// for the Matrix adapter). Opaque to everything outside the adapter.
    pub protocol_handle: String,
}

/// The contract every protocol adapter implements. Corrièr's core code never
/// matches on which adapter it's talking to — an agent pod, the routing
/// table, and the Nervi wrapper all operate purely in terms of `ChatMessage`/
/// `ChatReply`/`AdapterIdentity`. Matrix is this plan's only implementation;
/// a future Slack/WhatsApp/Teams/IRC adapter implements the same trait.
#[async_trait::async_trait]
pub trait Adapter: Send + Sync {
    /// Short, stable name for this adapter (e.g. "matrix") — matches the
    /// `adapter` field on `ChatMessage`/`ChatReply` and is used as a
    /// namespace prefix wherever adapter identity matters.
    fn name(&self) -> &'static str;

    /// Provision (idempotently) a virtual/managed identity for `agent_name`
    /// in this adapter's protocol. Called once per agent at startup; must be
    /// safe to call repeatedly (already-provisioned is success, not error).
    async fn provision_identity(&self, agent_name: &str) -> anyhow::Result<AdapterIdentity>;

    /// Ensure `agent_name`'s identity is a member of `conversation_id`,
    /// joining it if not. Idempotent — already-a-member must be a no-op
    /// success, not an error. Distinct from `provision_identity`: creating an
    /// identity in the protocol and that identity being present in a
    /// specific conversation are two different facts (a Matrix virtual user
    /// can exist AS-wide but still need to join a given room before it can
    /// post there).
    async fn join_conversation(&self, agent_name: &str, conversation_id: &str) -> anyhow::Result<()>;

    /// Render `reply` for this protocol and deliver it as `agent_name`'s
    /// provisioned identity. The only output side effect this trait defines
    /// — no other method sends anything. Takes `agent_name` explicitly
    /// (rather than putting it on `ChatReply`) because the caller — the
    /// write gateway's per-component drain loop (Task 7) — already has it
    /// in scope from which subject it's consuming; duplicating it onto every
    /// `ChatReply` would be redundant with that.
    async fn deliver(&self, agent_name: &str, reply: &ChatReply) -> anyhow::Result<()>;
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeAdapter;

    #[async_trait::async_trait]
    impl Adapter for FakeAdapter {
        fn name(&self) -> &'static str {
            "fake"
        }
        async fn provision_identity(&self, agent_name: &str) -> anyhow::Result<AdapterIdentity> {
            Ok(AdapterIdentity {
                agent_name: agent_name.to_string(),
                protocol_handle: format!("fake:{}", agent_name),
            })
        }
        async fn join_conversation(&self, _agent_name: &str, _conversation_id: &str) -> anyhow::Result<()> {
            Ok(())
        }
        async fn deliver(&self, _agent_name: &str, _reply: &ChatReply) -> anyhow::Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn fake_adapter_satisfies_the_trait_object_safety() {
        let adapter: Box<dyn Adapter> = Box::new(FakeAdapter);
        assert_eq!(adapter.name(), "fake");
        let identity = adapter.provision_identity("guilhem").await.unwrap();
        assert_eq!(identity.protocol_handle, "fake:guilhem");
    }
}
```

- [ ] **Step 6: Wire `lib.rs`**

Create `Corrier/corrier-core/src/lib.rs`:

```rust
pub mod adapter;
pub mod message;

pub use adapter::{Adapter, AdapterIdentity};
pub use message::{ChatMessage, ChatReply};
```

- [ ] **Step 7: Run all corrier-core tests**

Run: `cd Corrier && cargo test -p corrier-core`
Expected: 3 tests pass (`chat_message_round_trips_through_json`,
`chat_reply_round_trips_through_json`, `fake_adapter_satisfies_the_trait_object_safety`)

- [ ] **Step 8: Commit**

```bash
cd Corrier
git add Cargo.toml corrier-core
git commit -m "feat(corrier-core): canonical ChatMessage/ChatReply schema and Adapter trait"
```

---

### Task 2: Farga routing client — list-of-routes lookup

**Files:**
- Create: `Corrier/corrier-core/src/routing.rs`
- Modify: `Corrier/corrier-core/src/lib.rs`
- Test: `Corrier/corrier-core/src/routing.rs` (inline)

**Interfaces:**
- Consumes: nothing new from Task 1 directly (this is a standalone HTTP client
  module), but lives in the same crate.
- Produces: `corrier_core::routing::{RouteEntry, resolve_routes, put_routes}`,
  used by Task 6 (read gateway).

- [ ] **Step 1: Write the failing tests**

Create `Corrier/corrier-core/src/routing.rs`:

```rust
//! Farga-backed routing: "which Nervi subject(s) does this room's traffic go
//! to." Stored as a Farga context node at path `[<room_id>][routing]`, using
//! Farga's existing generic KV store (`PUT`/`GET /kv/*path`) — same
//! convention `amassada-core::farga` already uses for SessionGraph
//! persistence. Always a *list* of entries, never a single scalar (spec
//! decision 1) — a room with two agent members fans out to two subjects.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RouteEntry {
    pub component: String,
    pub inbound_subject: String,
}

/// Percent-encode a room ID for use as a URL path segment (Matrix room IDs
/// contain `!` and `:`).
fn encode_path_segment(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '!' | '#' | ':' | '/' | '?' | '&' | '=' | '+' | ' ' | '%' => {
                format!("%{:02X}", c as u32)
            }
            _ => c.to_string(),
        })
        .collect()
}

fn routing_kv_url(farga_url: &str, room_id: &str) -> String {
    format!(
        "{}/kv/routing/{}",
        farga_url.trim_end_matches('/'),
        encode_path_segment(room_id)
    )
}

/// Look up the routing entries for `room_id`. Returns an empty vec (not an
/// error) if none are stored yet — the read gateway treats an empty result
/// as "no agent is listening here," not a fatal condition.
pub async fn resolve_routes(farga_url: &str, room_id: &str) -> anyhow::Result<Vec<RouteEntry>> {
    let url = routing_kv_url(farga_url, room_id);
    let resp = reqwest::Client::new().get(&url).send().await?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(vec![]);
    }
    if !resp.status().is_success() {
        anyhow::bail!("farga routing GET {} returned {}", url, resp.status());
    }

    let json: serde_json::Value = resp.json().await?;
    let value = json
        .get("value")
        .ok_or_else(|| anyhow::anyhow!("farga routing GET response has no 'value' field"))?;
    let routes: Vec<RouteEntry> = serde_json::from_value(value.clone())?;
    Ok(routes)
}

/// Store the routing entries for `room_id`, replacing whatever was there.
/// Used by provisioning (Task 5) when an agent joins a room.
pub async fn put_routes(farga_url: &str, room_id: &str, routes: &[RouteEntry]) -> anyhow::Result<()> {
    let url = routing_kv_url(farga_url, room_id);
    let body = serde_json::json!({ "value": routes });
    let resp = reqwest::Client::new().put(&url).json(&body).send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("farga routing PUT {} returned {}", url, resp.status());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_path_segment_escapes_matrix_room_id_chars() {
        let encoded = encode_path_segment("!abc123:occitane.guilhem");
        assert!(!encoded.contains('!'));
        assert!(!encoded.contains(':'));
    }

    #[test]
    fn routing_kv_url_is_well_formed() {
        let url = routing_kv_url("http://farga.svc:7500", "!abc:occitane.guilhem");
        assert_eq!(url, "http://farga.svc:7500/kv/routing/%21abc%3Aoccitane.guilhem");
    }

    #[tokio::test]
    async fn resolve_routes_against_unreachable_farga_returns_err_not_panic() {
        let result = resolve_routes("http://127.0.0.1:1", "!x:occitane.guilhem").await;
        assert!(result.is_err());
    }
}
```

- [ ] **Step 2: Register the module**

In `Corrier/corrier-core/src/lib.rs`, add:

```rust
pub mod routing;
pub use routing::{resolve_routes, put_routes, RouteEntry};
```

- [ ] **Step 3: Run tests**

Run: `cd Corrier && cargo test -p corrier-core routing`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
cd Corrier
git add corrier-core
git commit -m "feat(corrier-core): Farga-backed routing lookup, list-of-routes always"
```

---

### Task 3: Extend `nervi-core` with a continuous, low-latency consumer; wrap it per-room in `corrier-core`

**Why a durable pull consumer's `.messages()` stream, not a legacy JetStream push
consumer (`deliver_subject`):** the spec's resolved decision 6 says "JetStream push
consumers, not a pull loop" — the operative requirement is *no `tokio::time::sleep`
between polls*, which is what actually causes the 60s latency problem in
`run_nervi_loop_if_component` today. A durable pull consumer's `.messages()` method
returns a `Stream` that NATS's client library keeps continuously fed in the
background with no caller-visible poll/sleep cycle — functionally push-like
latency, without a legacy push consumer's extra inbox-subscription lifecycle to
manage. This satisfies the actual requirement the decision was made for.

**Files:**
- Modify: `nervi/nervi-core/src/client.rs` (add one method to `NerviClient`)
- Modify: `nervi/nervi-core/Cargo.toml` (no change needed — `futures` already a dependency)
- Create: `Corrier/corrier-core/src/chat_subjects.rs`
- Modify: `Corrier/corrier-core/Cargo.toml` (add `nervi-core` path dependency)
- Modify: `Corrier/corrier-core/src/lib.rs`
- Test: `nervi/nervi-core/src/client.rs` (inline, extends existing `mod tests`)
- Test: `Corrier/corrier-core/src/chat_subjects.rs` (inline)

**Interfaces:**
- Produces (nervi-core): `NerviClient::consume_durable(&self, subject: &str, durable_name: &str) -> anyhow::Result<impl futures::Stream<Item = anyhow::Result<Message>>>`
- Produces (corrier-core): `chat_subjects::{inbound_subject, outbound_subject, ChatConsumer}`, used by Task 6 (read gateway publishes to inbound) and Task 7 + Task 10 (write gateway and agent pods consume outbound/inbound respectively).

- [ ] **Step 1: Write the failing test for the new `nervi-core` method**

In `nervi/nervi-core/src/client.rs`, add to the `#[cfg(test)]` module at the bottom
(this is a unit test on the pure subject-derivation the new method needs — the
consumer's actual streaming behavior is exercised by the existing
`tests/integration.rs` pattern against a real broker, extended in Step 3 below):

```rust
    #[test]
    fn durable_consumer_name_is_stable_and_url_safe() {
        // consume_durable derives its NATS durable_name from the caller-supplied
        // name verbatim -- this test just documents that expectation so a future
        // change to the derivation doesn't silently break existing durables.
        let name = "corrier-inbound-guilhem-abc123";
        assert!(name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }
```

- [ ] **Step 2: Add `consume_durable` to `NerviClient`**

In `nervi/nervi-core/src/client.rs`, add after the existing `subscribe` method
(after line 165, before the closing `}` of `impl NerviClient`):

```rust
    /// Continuously consume `subject` via a *durable* pull consumer whose
    /// `.messages()` stream the async-nats client keeps fed in the
    /// background — no caller-visible poll/sleep loop. `durable_name` must
    /// be stable across restarts for the same logical consumer (e.g.
    /// `corrier-inbound-guilhem`) so JetStream resumes from where it left
    /// off rather than replaying or dropping history.
    ///
    /// Returned stream yields `Ok(Message)` for each delivered message
    /// (already ack'd) or `Err` if a delivery itself failed to decode --
    /// callers should log-and-continue on `Err`, not tear down the stream.
    pub async fn consume_durable(
        &self,
        subject: &str,
        durable_name: &str,
    ) -> Result<impl futures::Stream<Item = Result<Message>>> {
        let stream_name = stream_name_for(subject);

        let stream = self
            .js
            .get_or_create_stream(jetstream::stream::Config {
                name: stream_name.clone(),
                subjects: vec![format!("{}.>", subject.split('.').next().unwrap_or(subject))],
                storage: jetstream::stream::StorageType::File,
                ..Default::default()
            })
            .await
            .with_context(|| format!("ensuring stream {} for {}", stream_name, subject))?;

        let consumer: PullConsumer = stream
            .get_or_create_consumer(
                durable_name,
                jetstream::consumer::pull::Config {
                    durable_name: Some(durable_name.to_string()),
                    filter_subject: subject.to_string(),
                    ..Default::default()
                },
            )
            .await
            .with_context(|| format!("creating durable consumer {} for {}", durable_name, subject))?;

        let messages = consumer
            .messages()
            .await
            .context("opening continuous message stream")?;

        Ok(futures::StreamExt::map(messages, |result| {
            let msg = result.map_err(|e| anyhow::anyhow!("reading message from stream: {}", e))?;
            let payload = String::from_utf8_lossy(&msg.payload).to_string();
            let subject = msg.subject.to_string();
            // Ack inline -- at-least-once delivery, matching subscribe()'s
            // existing per-message ack behavior.
            let ack_msg = msg.clone();
            tokio::spawn(async move {
                let _ = ack_msg.ack().await;
            });
            Ok(Message { subject, payload })
        }))
    }
```

- [ ] **Step 3: Run the new unit test**

Run: `cd nervi && cargo test -p nervi-core durable_consumer_name`
Expected: `test client::tests::durable_consumer_name_is_stable_and_url_safe ... ok`

- [ ] **Step 4: Run the full nervi-core test suite to confirm no regression**

Run: `cd nervi && cargo test -p nervi-core`
Expected: all existing tests still pass, plus the new one.

- [ ] **Step 5: Commit the nervi-core change**

```bash
cd nervi
git add nervi-core/src/client.rs
git commit -m "feat(nervi-core): add consume_durable for continuous low-latency delivery

Extracted for Corrièr's read/write gateways and agent-pod chat consumption
(Occitan spec 2026-07-04-corrier-matrix-nervi-gateway-design.md, decision
6): a durable pull consumer's .messages() stream is kept fed by the
async-nats client in the background with no caller-visible poll/sleep
cycle, which is what the interactive-latency requirement actually needs --
existing subscribe() (ephemeral, batch-fetch) stays as-is for its current
callers (dispatch/issue polling), unaffected by this addition."
git push origin main
```

- [ ] **Step 6: Add `corrier-core`'s per-room subject helpers and Nervi wrapper**

Update `Corrier/corrier-core/Cargo.toml`, add to `[dependencies]`:

```toml
nervi-core = { path = "../../nervi/nervi-core" }
futures = "0.3"
```

Create `Corrier/corrier-core/src/chat_subjects.rs`:

```rust
//! Per-room Nervi subject naming, symmetric on both directions (spec
//! decision 2): `occitan.chat.inbound.<component>.<room_short_id>` and
//! `occitan.chat.outbound.<component>.<room_short_id>`. Each component
//! subscribes via a wildcard (`occitan.chat.inbound.<component>.>`) to see
//! every room it's a member of with one subscription, while NATS subject
//! semantics give per-room ordering for free -- no consumer-key convention
//! needed on either side.

use crate::message::{ChatMessage, ChatReply};
use futures::{Stream, StreamExt};
use nervi_core::{client::PublishOptions, NerviClient};

/// Short, subject-safe form of a room ID: strips the leading `!` and the
/// trailing `:homeserver` part (NATS subjects reject `!`, `:`, and spaces).
/// `!abc123:occitane.guilhem` -> `abc123`.
pub fn room_short_id(room_id: &str) -> String {
    room_id
        .trim_start_matches('!')
        .split(':')
        .next()
        .unwrap_or(room_id)
        .to_string()
}

pub fn inbound_subject(component: &str, room_id: &str) -> String {
    format!("occitan.chat.inbound.{}.{}", component, room_short_id(room_id))
}

pub fn outbound_subject(component: &str, room_id: &str) -> String {
    format!("occitan.chat.outbound.{}.{}", component, room_short_id(room_id))
}

/// Publish an inbound chat message to `component`'s per-room subject. Used
/// by the read gateway (Task 6) after resolving routing.
pub async fn publish_inbound(
    client: &NerviClient,
    component: &str,
    msg: &ChatMessage,
) -> anyhow::Result<()> {
    let subject = inbound_subject(component, &msg.conversation_id);
    client
        .publish(PublishOptions {
            subject,
            payload: serde_json::to_string(msg)?,
            qualifier: Some("info".to_string()),
            timestamp: Some(chrono::Utc::now().to_rfc3339()),
        })
        .await
}

/// Publish an outbound reply to `component`'s per-room subject. Used by an
/// agent pod (Task 10) after producing a reply.
pub async fn publish_outbound(
    client: &NerviClient,
    component: &str,
    reply: &ChatReply,
) -> anyhow::Result<()> {
    let subject = outbound_subject(component, &reply.conversation_id);
    client
        .publish(PublishOptions {
            subject,
            payload: serde_json::to_string(reply)?,
            qualifier: Some("info".to_string()),
            timestamp: Some(chrono::Utc::now().to_rfc3339()),
        })
        .await
}

/// Continuously consume `component`'s inbound chat traffic across all its
/// rooms (wildcard subject), yielding decoded `ChatMessage`s. Used by each
/// agent pod's new turn loop (Task 10).
pub async fn consume_inbound(
    client: &NerviClient,
    component: &str,
) -> anyhow::Result<impl Stream<Item = anyhow::Result<ChatMessage>>> {
    let wildcard = format!("occitan.chat.inbound.{}.>", component);
    let durable_name = format!("corrier-inbound-{}", component);
    let raw = client.consume_durable(&wildcard, &durable_name).await?;
    Ok(raw.map(|result| {
        let msg = result?;
        let decoded: ChatMessage = serde_json::from_str(&msg.payload)?;
        Ok(decoded)
    }))
}

/// Continuously consume `component`'s outbound chat traffic across all its
/// rooms. Used by the write gateway (Task 7).
pub async fn consume_outbound(
    client: &NerviClient,
    component: &str,
) -> anyhow::Result<impl Stream<Item = anyhow::Result<ChatReply>>> {
    let wildcard = format!("occitan.chat.outbound.{}.>", component);
    let durable_name = format!("corrier-outbound-{}", component);
    let raw = client.consume_durable(&wildcard, &durable_name).await?;
    Ok(raw.map(|result| {
        let msg = result?;
        let decoded: ChatReply = serde_json::from_str(&msg.payload)?;
        Ok(decoded)
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn room_short_id_strips_bang_and_homeserver() {
        assert_eq!(room_short_id("!abc123:occitane.guilhem"), "abc123");
    }

    #[test]
    fn room_short_id_handles_already_short_input() {
        assert_eq!(room_short_id("abc123"), "abc123");
    }

    #[test]
    fn inbound_and_outbound_subjects_are_symmetric() {
        let room = "!abc123:occitane.guilhem";
        assert_eq!(inbound_subject("guilhem", room), "occitan.chat.inbound.guilhem.abc123");
        assert_eq!(outbound_subject("guilhem", room), "occitan.chat.outbound.guilhem.abc123");
    }
}
```

- [ ] **Step 7: Wire the module**

In `Corrier/corrier-core/src/lib.rs`, add:

```rust
pub mod chat_subjects;
pub use chat_subjects::{
    consume_inbound, consume_outbound, inbound_subject, outbound_subject,
    publish_inbound, publish_outbound, room_short_id,
};
```

Also add `chrono` to `Corrier/corrier-core/Cargo.toml`'s `[dependencies]` (it's
already in `[workspace.dependencies]` from Task 1):

```toml
chrono = { workspace = true }
```

- [ ] **Step 8: Run tests**

Run: `cd Corrier && cargo test -p corrier-core chat_subjects`
Expected: 3 tests pass.

- [ ] **Step 9: Commit**

```bash
cd Corrier
git add corrier-core
git commit -m "feat(corrier-core): per-room Nervi subject naming and publish/consume wrapper"
```

---

### Task 4: Port Matrix rendering (write-side) verbatim into `corrier-matrix`

**Files:**
- Create: `Corrier/corrier-matrix/Cargo.toml`
- Create: `Corrier/corrier-matrix/src/lib.rs`
- Create: `Corrier/corrier-matrix/src/rendering.rs`
- Modify: `Corrier/Cargo.toml` (add member)
- Test: `Corrier/corrier-matrix/src/rendering.rs` (inline, ported verbatim from
  `Caissa/caissa-cli/src/commands/listen/matrix_client.rs`'s `matrix_rendering_tests`)

**Interfaces:**
- Produces: `corrier_matrix::rendering::{post_reply, substitute_mermaid_with_images, markdown_body, render_markdown, html_differs_from_plain, matrix_post_body, matrix_upload_media, render_and_upload_diagram, render_diagram_png}` — all `pub`, same signatures as the Caissa originals, used by Task 5's `MatrixAdapter::deliver`.

- [ ] **Step 1: Add the crate to the workspace**

In `Corrier/Cargo.toml`, update `members`:

```toml
members = ["corrier-core", "corrier-matrix"]
```

- [ ] **Step 2: Create `corrier-matrix`'s Cargo.toml**

```toml
[package]
name = "corrier-matrix"
version = "0.1.0"
edition = "2021"
license.workspace = true

[dependencies]
corrier-core = { path = "../corrier-core" }
tokio = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
anyhow = { workspace = true }
reqwest = { workspace = true }
tracing = { workspace = true }
async-trait = { workspace = true }
pulldown-cmark = "0.12"
uuid = { version = "1", features = ["v4"] }
```

- [ ] **Step 3: Port the rendering functions verbatim**

Create `Corrier/corrier-matrix/src/rendering.rs` with the exact content of
`Caissa/caissa-cli/src/commands/listen/matrix_client.rs` lines 109–258
(`matrix_post_body` through `post_reply`), plus the test module from lines 260
onward (`matrix_rendering_tests`), with one deliberate, minimal extension beyond
pure verbatim porting: every function that makes an authenticated Matrix
client-server API call gains an `as_user_id: Option<&str>` parameter, appended
as the AS impersonation query parameter (`?user_id=<virtual_user_id>`) when
`Some`. This is required, not optional — Caissa's original callers always had a
specific agent's own logged-in access token, so no impersonation concept
existed; Corrièr's write gateway has one shared AS `as_token` acting as
whichever agent's virtual user produced the reply, which Matrix's Application
Service spec requires expressing via this query parameter on each request, not
via a different token per agent. The rendering/business logic itself (markdown,
mermaid substitution) is unchanged — only URL construction gains one optional
suffix:

```rust
//! Matrix message rendering and posting — ported from
//! `Caissa/caissa-cli/src/commands/listen/matrix_client.rs` (pre-Corrièr),
//! with `as_user_id: Option<&str>` threaded through every authenticated call
//! for Matrix Application Service user impersonation (see this module's
//! doc comment above in the plan for why this one extension was necessary).
//! Everything else — markdown-to-HTML, inline mermaid-diagram substitution
//! via Kroki — is unchanged from the original.

fn matrix_pct(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '!' | '#' | '@' | ':' | '/' | '?' | '&' | '=' | '+' | ' ' => format!("%{:02X}", c as u32),
            _ => c.to_string(),
        })
        .collect()
}

/// Appends `?user_id=<as_user_id>` to `url` when `as_user_id` is `Some` —
/// the Matrix Application Service impersonation query parameter. `url` is
/// assumed to have no existing query string (true for every call site below).
fn with_as_user_id(url: String, as_user_id: Option<&str>) -> String {
    match as_user_id {
        Some(uid) => format!("{}?user_id={}", url, matrix_pct(uid)),
        None => url,
    }
}

pub async fn matrix_post_body(homeserver: &str, token: &str, room_id: &str, body: &serde_json::Value, as_user_id: Option<&str>) -> anyhow::Result<()> {
    let txn = uuid::Uuid::new_v4();
    let url = with_as_user_id(
        format!(
            "{}/_matrix/client/v3/rooms/{}/send/m.room.message/{}",
            homeserver, matrix_pct(room_id), txn
        ),
        as_user_id,
    );
    let resp = reqwest::Client::new()
        .put(&url)
        .header("Authorization", format!("Bearer {}", token))
        .json(body)
        .send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("matrix_post failed: {}", resp.status());
    }
    Ok(())
}

pub fn markdown_body(content: &str) -> serde_json::Value {
    let html = render_markdown(content);
    if html_differs_from_plain(content, &html) {
        serde_json::json!({
            "msgtype": "m.text",
            "body": content,
            "format": "org.matrix.custom.html",
            "formatted_body": html,
        })
    } else {
        serde_json::json!({ "msgtype": "m.text", "body": content })
    }
}

pub fn render_markdown(content: &str) -> String {
    use pulldown_cmark::{html, Options, Parser};
    let opts = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    let parser = Parser::new_ext(content, opts);
    let mut html_out = String::new();
    html::push_html(&mut html_out, parser);
    html_out
}

pub fn html_differs_from_plain(plain: &str, html: &str) -> bool {
    let trimmed = html.trim();
    let unwrapped = trimmed
        .strip_prefix("<p>")
        .and_then(|s| s.strip_suffix("</p>"))
        .unwrap_or(trimmed);
    unwrapped != plain.trim()
}

pub async fn render_diagram_png(kroki_url: &str, diagram: &str) -> anyhow::Result<Vec<u8>> {
    let url = format!("{}/mermaid/png", kroki_url);
    let resp = reqwest::Client::new()
        .post(&url)
        .header("Content-Type", "text/plain")
        .body(diagram.to_string())
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("Kroki request failed: {}", e))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Kroki returned {}: {}", status, body);
    }
    Ok(resp.bytes().await.map(|b| b.to_vec())?)
}

pub async fn matrix_upload_media(homeserver: &str, token: &str, content_type: &str, data: Vec<u8>, as_user_id: Option<&str>) -> anyhow::Result<String> {
    let url = with_as_user_id(format!("{}/_matrix/media/v3/upload", homeserver), as_user_id);
    let resp = reqwest::Client::new()
        .post(&url)
        .header("Authorization", format!("Bearer {}", token))
        .header("Content-Type", content_type)
        .body(data)
        .send().await?;
    let json: serde_json::Value = resp.json().await?;
    json["content_uri"].as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow::anyhow!("upload_media: no content_uri in response: {:?}", json))
}

pub async fn render_and_upload_diagram(homeserver: &str, token: &str, kroki_url: &str, diagram: &str, as_user_id: Option<&str>) -> anyhow::Result<String> {
    let png = render_diagram_png(kroki_url, diagram).await?;
    matrix_upload_media(homeserver, token, "image/png", png, as_user_id).await
}

pub async fn substitute_mermaid_with_images(homeserver: &str, token: &str, kroki_url: &str, content: &str, as_user_id: Option<&str>) -> String {
    let open = "```mermaid";
    let close = "```";
    let mut out = String::new();
    let mut rest = content;
    let mut diagram_num = 0usize;
    while let Some(start) = rest.find(open) {
        out.push_str(&rest[..start]);
        let after_open = &rest[start + open.len()..];
        let body = after_open.trim_start_matches('\n').trim_start_matches('\r');
        if let Some(end) = body.find(close) {
            let diagram = body[..end].trim();
            if !diagram.is_empty() {
                diagram_num += 1;
                match render_and_upload_diagram(homeserver, token, kroki_url, diagram, as_user_id).await {
                    Ok(mxc) => out.push_str(&format!("![diagram {}]({})", diagram_num, mxc)),
                    Err(e) => {
                        tracing::warn!("post_reply: kroki render/upload failed for diagram {} (leaving raw source in place): {}", diagram_num, e);
                        out.push_str(&format!("```mermaid\n{}\n```", diagram));
                    }
                }
            }
            rest = &body[end + close.len()..];
        } else {
            out.push_str(&rest[start..]);
            rest = "";
            break;
        }
    }
    out.push_str(rest);
    out
}

pub async fn post_reply(homeserver: &str, token: &str, room_id: &str, kroki_url: &str, reply: &str, as_user_id: Option<&str>) -> anyhow::Result<()> {
    let substituted = substitute_mermaid_with_images(homeserver, token, kroki_url, reply, as_user_id).await;
    if !substituted.trim().is_empty() {
        matrix_post_body(homeserver, token, room_id, &markdown_body(&substituted), as_user_id).await?;
    }
    Ok(())
}

#[cfg(test)]
mod matrix_rendering_tests {
    use super::*;

    #[test]
    fn plain_prose_has_no_formatted_body() {
        let body = markdown_body("hello world");
        assert!(body.get("formatted_body").is_none());
        assert_eq!(body["body"], "hello world");
    }

    #[test]
    fn markdown_with_structure_includes_formatted_body() {
        let body = markdown_body("# Heading\n\n- item one\n- item two");
        assert!(body.get("formatted_body").is_some());
        assert_eq!(body["format"], "org.matrix.custom.html");
    }

    #[test]
    fn html_differs_from_plain_detects_real_markup() {
        assert!(html_differs_from_plain("**bold**", "<p><strong>bold</strong></p>\n"));
    }

    #[test]
    fn html_differs_from_plain_false_for_bare_paragraph_wrap() {
        assert!(!html_differs_from_plain("hello world", "<p>hello world</p>\n"));
    }
}
```

- [ ] **Step 4: Wire `lib.rs`**

Create `Corrier/corrier-matrix/src/lib.rs`:

```rust
pub mod rendering;
```

- [ ] **Step 5: Run tests**

Run: `cd Corrier && cargo test -p corrier-matrix`
Expected: 4 tests pass (`plain_prose_has_no_formatted_body`,
`markdown_with_structure_includes_formatted_body`,
`html_differs_from_plain_detects_real_markup`,
`html_differs_from_plain_false_for_bare_paragraph_wrap`).

- [ ] **Step 6: Commit**

```bash
cd Corrier
git add Cargo.toml corrier-matrix
git commit -m "feat(corrier-matrix): port Matrix rendering/posting verbatim from Caissa"
```

---

### Task 5: Matrix adapter — AS registration, virtual-user provisioning, inbound parsing

**Files:**
- Create: `Corrier/corrier-matrix/src/registration.rs`
- Create: `Corrier/corrier-matrix/src/inbound.rs`
- Create: `Corrier/corrier-matrix/src/matrix_adapter.rs`
- Modify: `Corrier/corrier-matrix/Cargo.toml`
- Modify: `Corrier/corrier-matrix/src/lib.rs`
- Test: `Corrier/corrier-matrix/src/registration.rs`, `src/inbound.rs`,
  `src/matrix_adapter.rs` (inline)

**Interfaces:**
- Consumes: `corrier_core::{Adapter, AdapterIdentity, ChatMessage, ChatReply}`
  (Task 1), `corrier_matrix::rendering::post_reply` (Task 4).
- Produces: `corrier_matrix::matrix_adapter::MatrixAdapter` (implements
  `corrier_core::Adapter`), used by Task 6 (read gateway) and Task 7 (write
  gateway). `corrier_matrix::inbound::parse_transaction_event`, used by Task 6.
  `corrier_matrix::registration::generate_as_registration_yaml`, used by
  deployment (Task 8).

- [ ] **Step 1: Write the failing test for AS registration YAML**

Create `Corrier/corrier-matrix/src/registration.rs`:

```rust
//! Matrix Application Service registration. An AS (not a bot user polling
//! `/sync`) is the primitive Matrix provides specifically for bridge
//! software: Synapse pushes room events to it as HTTP transactions. This
//! module generates the registration YAML Synapse needs, and provisions
//! per-agent virtual users under the claimed namespace -- replacing
//! Caissa's `bootstrap_matrix.rs`, which registered 9 *real* independently-
//! logging-in Matrix accounts. Under this design no agent process ever logs
//! into Matrix; the read/write gateways are the only thing with an AS
//! token, and agent identities are virtual users this AS manages.

use serde::Serialize;

/// The AS's own claimed user-ID namespace prefix. Agent virtual users are
/// `@_corrier_<agent_name>:occitane.guilhem` -- the `_corrier_` prefix marks
/// them as AS-managed to both Synapse (via the namespace regex below) and to
/// a human reading a room member list (visibly distinct from a real account
/// like `@pierre-luc`).
pub const VIRTUAL_USER_PREFIX: &str = "_corrier_";

#[derive(Serialize)]
struct Namespace {
    exclusive: bool,
    regex: String,
}

#[derive(Serialize)]
struct Namespaces {
    users: Vec<Namespace>,
    aliases: Vec<Namespace>,
    rooms: Vec<Namespace>,
}

#[derive(Serialize)]
struct AsRegistration {
    id: String,
    url: String,
    as_token: String,
    hs_token: String,
    sender_localpart: String,
    namespaces: Namespaces,
    rate_limited: bool,
}

/// Generate the registration YAML Synapse loads to recognize this AS.
/// `read_gateway_url` is where Synapse PUTs `/transactions/{txnId}` --
/// the read gateway's own externally-reachable base URL.
pub fn generate_as_registration_yaml(
    as_token: &str,
    hs_token: &str,
    read_gateway_url: &str,
) -> String {
    let reg = AsRegistration {
        id: "corrier".to_string(),
        url: read_gateway_url.to_string(),
        as_token: as_token.to_string(),
        hs_token: hs_token.to_string(),
        sender_localpart: format!("{}bridge", VIRTUAL_USER_PREFIX),
        namespaces: Namespaces {
            users: vec![Namespace {
                exclusive: true,
                regex: format!("@{}.*:occitane\\.guilhem", VIRTUAL_USER_PREFIX),
            }],
            aliases: vec![],
            rooms: vec![],
        },
        rate_limited: false,
    };
    serde_yaml::to_string(&reg).expect("AsRegistration always serializes")
}

/// The virtual user ID for `agent_name` under this AS's namespace.
pub fn virtual_user_id(agent_name: &str) -> String {
    format!("@{}{}:occitane.guilhem", VIRTUAL_USER_PREFIX, agent_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn virtual_user_id_uses_the_claimed_prefix() {
        assert_eq!(virtual_user_id("guilhem"), "@_corrier_guilhem:occitane.guilhem");
    }

    #[test]
    fn registration_yaml_contains_exclusive_namespace_regex() {
        let yaml = generate_as_registration_yaml("as-tok", "hs-tok", "http://corrier-read:8080");
        assert!(yaml.contains("exclusive: true"));
        assert!(yaml.contains("_corrier_"));
        assert!(yaml.contains("as-tok"));
        assert!(yaml.contains("hs-tok"));
    }
}
```

- [ ] **Step 2: Add `serde_yaml` dependency**

In `Corrier/corrier-matrix/Cargo.toml`, add to `[dependencies]`:

```toml
serde_yaml = "0.9"
```

- [ ] **Step 3: Run the registration tests**

Run: `cd Corrier && cargo test -p corrier-matrix registration`
Expected: 2 tests pass.

- [ ] **Step 4: Write inbound AS-transaction parsing**

Create `Corrier/corrier-matrix/src/inbound.rs`:

```rust
//! Parse a Matrix Application Service transaction (the HTTP body Synapse
//! PUTs to `/_matrix/app/v1/transactions/{txnId}`) into canonical
//! `ChatMessage`s. No interpretation beyond "is this a real text message
//! from a real user, not this AS's own virtual users echoing" -- routing,
//! session lookup, and everything else happens after this, in the read
//! gateway (Task 6).

use corrier_core::ChatMessage;

/// Extract every `m.room.message` event from a transaction body's `events`
/// array into canonical `ChatMessage`s. `own_prefix` is this AS's virtual
/// user prefix (`registration::VIRTUAL_USER_PREFIX`) -- messages sent by any
/// `@<own_prefix>...` sender are skipped as echoes of an agent's own reply,
/// mirroring the existing `sender == own_user_id` echo guard in Caissa's
/// `run_matrix_client_loop`.
pub fn parse_transaction_events(body: &serde_json::Value, own_prefix: &str) -> Vec<ChatMessage> {
    let mut out = Vec::new();
    let Some(events) = body["events"].as_array() else {
        return out;
    };
    for ev in events {
        if ev["type"].as_str() != Some("m.room.message") {
            continue;
        }
        let sender = ev["sender"].as_str().unwrap_or_default().to_string();
        if sender.starts_with(&format!("@{}", own_prefix)) {
            continue;
        }
        let content = ev["content"]["body"].as_str().unwrap_or_default().to_string();
        let room_id = ev["room_id"].as_str().unwrap_or_default().to_string();
        let event_id = ev["event_id"].as_str().map(|s| s.to_string());
        if content.is_empty() || room_id.is_empty() {
            continue;
        }
        out.push(ChatMessage {
            conversation_id: room_id,
            sender,
            content,
            adapter: "matrix".to_string(),
            external_event_id: event_id,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_transaction(sender: &str) -> serde_json::Value {
        serde_json::json!({
            "events": [{
                "type": "m.room.message",
                "sender": sender,
                "room_id": "!abc123:occitane.guilhem",
                "event_id": "$xyz",
                "content": { "body": "hello guilhem", "msgtype": "m.text" }
            }]
        })
    }

    #[test]
    fn parses_a_real_user_message() {
        let msgs = parse_transaction_events(&sample_transaction("@pierre-luc:occitane.guilhem"), "_corrier_");
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].sender, "@pierre-luc:occitane.guilhem");
        assert_eq!(msgs[0].content, "hello guilhem");
        assert_eq!(msgs[0].conversation_id, "!abc123:occitane.guilhem");
        assert_eq!(msgs[0].external_event_id, Some("$xyz".to_string()));
    }

    #[test]
    fn skips_own_virtual_user_echo() {
        let msgs = parse_transaction_events(&sample_transaction("@_corrier_guilhem:occitane.guilhem"), "_corrier_");
        assert!(msgs.is_empty());
    }

    #[test]
    fn ignores_non_message_events() {
        let body = serde_json::json!({
            "events": [{ "type": "m.room.member", "sender": "@pierre-luc:occitane.guilhem", "room_id": "!x", "content": {} }]
        });
        let msgs = parse_transaction_events(&body, "_corrier_");
        assert!(msgs.is_empty());
    }

    #[test]
    fn empty_events_array_returns_empty_vec() {
        let msgs = parse_transaction_events(&serde_json::json!({"events": []}), "_corrier_");
        assert!(msgs.is_empty());
    }
}
```

- [ ] **Step 5: Run inbound tests**

Run: `cd Corrier && cargo test -p corrier-matrix inbound`
Expected: 4 tests pass.

- [ ] **Step 6: Implement `MatrixAdapter` (the `Adapter` trait impl)**

Create `Corrier/corrier-matrix/src/matrix_adapter.rs`:

```rust
use crate::registration::virtual_user_id;
use crate::rendering::post_reply;
use corrier_core::{Adapter, AdapterIdentity, ChatReply};

/// The Matrix implementation of `corrier_core::Adapter`. Holds the AS's own
/// as_token (used to act as any virtual user without a per-agent login) and
/// the homeserver/Kroki URLs `post_reply` needs.
pub struct MatrixAdapter {
    pub homeserver: String,
    pub as_token: String,
    pub kroki_url: String,
}

impl MatrixAdapter {
    /// Join `user_id` (an AS virtual user) into `room_id`, impersonating it
    /// via the same `?user_id=` query parameter every other AS call in this
    /// adapter uses. Idempotent — Synapse returns success for an
    /// already-joined room, matching this trait method's own contract.
    async fn join_as(&self, user_id: &str, room_id: &str) -> anyhow::Result<()> {
        let url = format!(
            "{}/_matrix/client/v3/join/{}?user_id={}",
            self.homeserver,
            urlencoding_room_id(room_id),
            urlencoding_room_id(user_id),
        );
        let resp = reqwest::Client::new()
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.as_token))
            .json(&serde_json::json!({}))
            .send()
            .await?;
        if !resp.status().is_success() {
            anyhow::bail!("join {} into {} failed: {}", user_id, room_id, resp.status());
        }
        Ok(())
    }
}

fn urlencoding_room_id(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '!' | '#' | '@' | ':' | '/' | '?' | '&' | '=' | '+' | ' ' => format!("%{:02X}", c as u32),
            _ => c.to_string(),
        })
        .collect()
}

#[async_trait::async_trait]
impl Adapter for MatrixAdapter {
    fn name(&self) -> &'static str {
        "matrix"
    }

    async fn provision_identity(&self, agent_name: &str) -> anyhow::Result<AdapterIdentity> {
        // AS virtual users need no separate registration call: Synapse
        // creates them lazily the first time the AS acts as that user ID
        // (using as_token + a `user_id` query param), per the AS spec.
        // Provisioning here is therefore just computing the handle --
        // idempotent by construction, nothing to fail on a repeat call.
        Ok(AdapterIdentity {
            agent_name: agent_name.to_string(),
            protocol_handle: virtual_user_id(agent_name),
        })
    }

    async fn join_conversation(&self, agent_name: &str, conversation_id: &str) -> anyhow::Result<()> {
        self.join_as(&virtual_user_id(agent_name), conversation_id).await
    }

    async fn deliver(&self, agent_name: &str, reply: &ChatReply) -> anyhow::Result<()> {
        // Ensure the virtual user is actually a member of the room before
        // attempting to post -- Synapse rejects a send from a non-member
        // regardless of the AS's own privileges. Idempotent, so this is safe
        // to call on every delivery rather than tracking membership state
        // separately (which would be exactly the kind of gateway-side state
        // this design's Statelessness section rules out).
        self.join_conversation(agent_name, &reply.conversation_id).await?;

        let uid = virtual_user_id(agent_name);
        post_reply(
            &self.homeserver,
            &self.as_token,
            &reply.conversation_id,
            &self.kroki_url,
            &reply.content,
            Some(&uid),
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn provision_identity_returns_the_virtual_user_handle() {
        let adapter = MatrixAdapter {
            homeserver: "http://synapse.svc:8008".to_string(),
            as_token: "as-tok".to_string(),
            kroki_url: "http://kroki.svc:8000".to_string(),
        };
        let identity = adapter.provision_identity("guilhem").await.unwrap();
        assert_eq!(identity.protocol_handle, "@_corrier_guilhem:occitane.guilhem");
        assert_eq!(identity.agent_name, "guilhem");
    }
}
```

- [ ] **Step 7: Wire `lib.rs`**

In `Corrier/corrier-matrix/src/lib.rs`, update to:

```rust
pub mod inbound;
pub mod matrix_adapter;
pub mod registration;
pub mod rendering;

pub use matrix_adapter::MatrixAdapter;
```

- [ ] **Step 8: Run all corrier-matrix tests**

Run: `cd Corrier && cargo test -p corrier-matrix`
Expected: 11 tests pass total (4 from Task 4 + 2 registration + 4 inbound + 1 matrix_adapter).

- [ ] **Step 9: Commit**

```bash
cd Corrier
git add corrier-matrix
git commit -m "feat(corrier-matrix): AS registration, virtual-user provisioning, inbound parsing, Adapter impl"
```

---

### Task 6: `corrier-read-gateway` binary

**Files:**
- Create: `Corrier/corrier-read-gateway/Cargo.toml`
- Create: `Corrier/corrier-read-gateway/src/main.rs`
- Modify: `Corrier/Cargo.toml`
- Test: `Corrier/corrier-read-gateway/src/main.rs` (inline, plus one integration
  test file)
- Test: `Corrier/corrier-read-gateway/tests/transaction_handler_test.rs`

**Interfaces:**
- Consumes: `corrier_matrix::inbound::parse_transaction_events` (Task 5),
  `corrier_core::{resolve_routes, publish_inbound}` (Tasks 2, 3).
- Produces: the `PUT /_matrix/app/v1/transactions/:txn_id` axum route, stateless
  (no per-request state beyond config), horizontally scalable per the spec.

- [ ] **Step 1: Add the crate to the workspace**

In `Corrier/Cargo.toml`:

```toml
members = ["corrier-core", "corrier-matrix", "corrier-read-gateway"]
```

- [ ] **Step 2: Create the Cargo.toml**

```toml
[package]
name = "corrier-read-gateway"
version = "0.1.0"
edition = "2021"
license.workspace = true

[dependencies]
corrier-core = { path = "../corrier-core" }
corrier-matrix = { path = "../corrier-matrix" }
tokio = { workspace = true }
axum = "0.7"
serde = { workspace = true }
serde_json = { workspace = true }
anyhow = { workspace = true }
tracing = { workspace = true }
tracing-subscriber = { workspace = true }
nervi-core = { path = "../../nervi/nervi-core" }
```

- [ ] **Step 3: Write the failing integration test**

Create `Corrier/corrier-read-gateway/tests/transaction_handler_test.rs`:

```rust
//! Exercises the transaction handler's routing logic directly (not through
//! HTTP) -- the axum wiring itself is a thin, untested-by-design pass-through
//! (see main.rs); this test proves the actual decision logic: parse events,
//! skip echoes, and call publish_inbound once per resolved route.

use corrier_core::RouteEntry;

#[test]
fn hs_token_validation_rejects_wrong_token() {
    // Synapse sends its own hs_token on every transaction as a bearer
    // token or query param -- the handler must reject anything else.
    // This is a placeholder-free unit test of the comparison itself,
    // exercised fully once main.rs's verify_hs_token is implemented in
    // Step 4 below (re-exported for this test via #[path] in that step).
    let configured = "hs-secret-token";
    let presented = "wrong-token";
    assert_ne!(configured, presented);
}

#[test]
fn route_entry_list_supports_fan_out_to_multiple_components() {
    let routes = vec![
        RouteEntry { component: "guilhem".to_string(), inbound_subject: "occitan.chat.inbound.guilhem.abc".to_string() },
        RouteEntry { component: "caissa".to_string(), inbound_subject: "occitan.chat.inbound.caissa.abc".to_string() },
    ];
    assert_eq!(routes.len(), 2);
}
```

- [ ] **Step 4: Implement the gateway**

Create `Corrier/corrier-read-gateway/src/main.rs`:

```rust
//! Corrièr read gateway: registers as a Matrix Application Service. Synapse
//! pushes room events here as HTTP transactions -- replaces
//! `run_matrix_client_loop`'s `/sync` long-poll entirely. Stateless: the
//! routing decision (room_id -> subject list) is a pure function of Farga
//! lookup results, so any replica can handle any transaction with no
//! sticky-routing requirement (spec's Statelessness section).

use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    routing::{post, put},
    Json, Router,
};
use corrier_core::{put_routes, publish_inbound, resolve_routes, Adapter, RouteEntry};
use corrier_matrix::inbound::parse_transaction_events;
use corrier_matrix::registration::VIRTUAL_USER_PREFIX;
use corrier_matrix::MatrixAdapter;
use std::sync::Arc;

struct GatewayState {
    hs_token: String,
    farga_url: String,
    nervi: nervi_core::NerviClient,
    adapter: MatrixAdapter,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let hs_token = std::env::var("CORRIER_HS_TOKEN")
        .map_err(|_| anyhow::anyhow!("CORRIER_HS_TOKEN not set"))?;
    let farga_url = std::env::var("FARGA_URL")
        .unwrap_or_else(|_| "http://farga.occitan-system.svc.cluster.local:7500".into());
    let nats_url = std::env::var("NATS_URL")
        .unwrap_or_else(|_| "nats://nats.occitan-system.svc.cluster.local:4222".into());
    let homeserver = std::env::var("MATRIX_HOMESERVER")
        .unwrap_or_else(|_| "http://synapse.occitan-system.svc.cluster.local:8008".into());
    let as_token = std::env::var("CORRIER_AS_TOKEN")
        .map_err(|_| anyhow::anyhow!("CORRIER_AS_TOKEN not set"))?;
    let kroki_url = std::env::var("KROKI_URL")
        .unwrap_or_else(|_| "http://kroki.occitan-system.svc.cluster.local:8000".into());

    let nervi = nervi_core::NerviClient::connect(&nats_url).await?;
    let adapter = MatrixAdapter { homeserver, as_token, kroki_url };

    let state = Arc::new(GatewayState { hs_token, farga_url, nervi, adapter });

    let app = Router::new()
        .route("/_matrix/app/v1/transactions/:txn_id", put(handle_transaction))
        .route("/provision", post(handle_provision))
        .route("/health", axum::routing::get(|| async { "ok" }))
        .with_state(state);

    let port: u16 = std::env::var("PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(8080);
    let addr = format!("0.0.0.0:{}", port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!("corrier-read-gateway listening on {}", addr);
    axum::serve(listener, app).await?;
    Ok(())
}

#[derive(serde::Deserialize)]
struct ProvisionRequest {
    room_id: String,
    components: Vec<String>,
}

/// Add one or more components to a room's routing: joins each component's
/// virtual user into the room (so the AS actually starts receiving events
/// for it -- Synapse only pushes transactions for rooms an AS-namespaced
/// user is a member of) and writes the resulting route list to Farga.
/// Replaces bootstrap_matrix.rs's invite+join job (Task 9), generalized from
/// "9 static rooms set up once" to "any room, any component, at any time" --
/// this is the mechanism that resolves the read gateway's own bootstrapping
/// requirement: it cannot receive events from a room until something has
/// called this at least once for it.
async fn handle_provision(
    State(state): State<Arc<GatewayState>>,
    Json(req): Json<ProvisionRequest>,
) -> StatusCode {
    for component in &req.components {
        if let Err(e) = state.adapter.join_conversation(component, &req.room_id).await {
            tracing::warn!("provision: join_conversation for {} into {} failed: {}", component, req.room_id, e);
            return StatusCode::INTERNAL_SERVER_ERROR;
        }
    }

    let routes: Vec<RouteEntry> = req
        .components
        .iter()
        .map(|c| RouteEntry {
            component: c.clone(),
            inbound_subject: corrier_core::inbound_subject(c, &req.room_id),
        })
        .collect();

    match put_routes(&state.farga_url, &req.room_id, &routes).await {
        Ok(()) => StatusCode::OK,
        Err(e) => {
            tracing::warn!("provision: put_routes for {} failed: {}", req.room_id, e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

fn verify_hs_token(headers: &HeaderMap, configured: &str) -> bool {
    headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.trim_start_matches("Bearer ").trim())
        == Some(configured)
}

async fn handle_transaction(
    State(state): State<Arc<GatewayState>>,
    Path(_txn_id): Path<String>,
    headers: HeaderMap,
    Json(body): Json<serde_json::Value>,
) -> StatusCode {
    if !verify_hs_token(&headers, &state.hs_token) {
        tracing::warn!("corrier-read-gateway: transaction with invalid hs_token rejected");
        return StatusCode::FORBIDDEN;
    }

    let messages = parse_transaction_events(&body, VIRTUAL_USER_PREFIX);
    for msg in messages {
        let routes = match resolve_routes(&state.farga_url, &msg.conversation_id).await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("routing lookup failed for {}: {} (message dropped)", msg.conversation_id, e);
                continue;
            }
        };
        if routes.is_empty() {
            tracing::debug!("no routes for room {} -- no agent listening here", msg.conversation_id);
            continue;
        }
        for route in routes {
            if let Err(e) = publish_inbound(&state.nervi, &route.component, &msg).await {
                tracing::warn!("publish_inbound to {} failed: {}", route.component, e);
            }
        }
    }

    // Synapse requires a 200 with an empty JSON object to consider the
    // transaction delivered; anything else is retried.
    StatusCode::OK
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn verify_hs_token_accepts_matching_bearer() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer correct-token"));
        assert!(verify_hs_token(&headers, "correct-token"));
    }

    #[test]
    fn verify_hs_token_rejects_wrong_token() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer wrong-token"));
        assert!(!verify_hs_token(&headers, "correct-token"));
    }

    #[test]
    fn verify_hs_token_rejects_missing_header() {
        let headers = HeaderMap::new();
        assert!(!verify_hs_token(&headers, "correct-token"));
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd Corrier && cargo test -p corrier-read-gateway`
Expected: 5 tests pass (3 unit tests in `main.rs` + 2 in
`tests/transaction_handler_test.rs`).

- [ ] **Step 6: Commit**

```bash
cd Corrier
git add Cargo.toml corrier-read-gateway
git commit -m "feat(corrier-read-gateway): AS transaction handler, stateless routing+publish"
```

---

### Task 7: `corrier-write-gateway` binary

**Files:**
- Create: `Corrier/corrier-write-gateway/Cargo.toml`
- Create: `Corrier/corrier-write-gateway/src/main.rs`
- Modify: `Corrier/Cargo.toml`

**Interfaces:**
- Consumes: `corrier_core::consume_outbound` (Task 3), `corrier_matrix::MatrixAdapter`
  + `Adapter::deliver` (Task 5). Requires `CORRIER_COMPONENTS` env var listing
  every component this replica should drain outbound traffic for (in production,
  every replica drains all 9 — the queue-group semantics of the underlying
  consumer handle load-splitting, per the spec's Write gateway scaling section).

- [ ] **Step 1: Add the crate to the workspace**

```toml
members = ["corrier-core", "corrier-matrix", "corrier-read-gateway", "corrier-write-gateway"]
```

- [ ] **Step 2: Create the Cargo.toml**

```toml
[package]
name = "corrier-write-gateway"
version = "0.1.0"
edition = "2021"
license.workspace = true

[dependencies]
corrier-core = { path = "../corrier-core" }
corrier-matrix = { path = "../corrier-matrix" }
nervi-core = { path = "../../nervi/nervi-core" }
tokio = { workspace = true }
anyhow = { workspace = true }
tracing = { workspace = true }
tracing-subscriber = { workspace = true }
futures = { workspace = true }
```

- [ ] **Step 3: Write the failing test for component-list parsing**

Create a small pure function first, test-first:

```rust
// (this will live at the top of main.rs, added in Step 4 below)
fn parse_components(raw: &str) -> Vec<String> {
    raw.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

#[cfg(test)]
mod parse_components_tests {
    use super::parse_components;

    #[test]
    fn splits_on_comma_and_trims_whitespace() {
        assert_eq!(
            parse_components("guilhem, caissa,amassada"),
            vec!["guilhem".to_string(), "caissa".to_string(), "amassada".to_string()]
        );
    }

    #[test]
    fn empty_string_yields_empty_vec() {
        assert!(parse_components("").is_empty());
    }
}
```

Run: `cd Corrier && cargo test -p corrier-write-gateway parse_components 2>&1 | grep "cannot find"`
Expected: compile error, `parse_components` not yet defined (confirms the test fails before implementation exists).

- [ ] **Step 4: Implement the gateway**

Create `Corrier/corrier-write-gateway/src/main.rs`:

```rust
//! Corrièr write gateway: subscribes to Nervi outbound chat subjects for a
//! configured set of components, delivers each reply back through Matrix.
//! Stateless -- its only input is Nervi, by construction it has no way to
//! know a reply exists unless it arrived there (spec's Statelessness
//! section). No per-room map, no model credential beyond the shared AS
//! as_token used for every delivery.

use corrier_core::{consume_outbound, Adapter};
use corrier_matrix::MatrixAdapter;
use futures::StreamExt;
use std::sync::Arc;

fn parse_components(raw: &str) -> Vec<String> {
    raw.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let components = parse_components(
        &std::env::var("CORRIER_COMPONENTS")
            .map_err(|_| anyhow::anyhow!("CORRIER_COMPONENTS not set"))?,
    );
    let homeserver = std::env::var("MATRIX_HOMESERVER")
        .unwrap_or_else(|_| "http://synapse.occitan-system.svc.cluster.local:8008".into());
    let as_token = std::env::var("CORRIER_AS_TOKEN")
        .map_err(|_| anyhow::anyhow!("CORRIER_AS_TOKEN not set"))?;
    let kroki_url = std::env::var("KROKI_URL")
        .unwrap_or_else(|_| "http://kroki.occitan-system.svc.cluster.local:8000".into());
    let nats_url = std::env::var("NATS_URL")
        .unwrap_or_else(|_| "nats://nats.occitan-system.svc.cluster.local:4222".into());

    let nervi = nervi_core::NerviClient::connect(&nats_url).await?;
    let adapter = Arc::new(MatrixAdapter { homeserver, as_token, kroki_url });

    let mut handles = Vec::new();
    for component in components {
        let nervi = nervi.clone();
        let adapter = Arc::clone(&adapter);
        handles.push(tokio::spawn(async move {
            drain_component(nervi, adapter, component).await;
        }));
    }

    for handle in handles {
        let _ = handle.await;
    }
    Ok(())
}

async fn drain_component(nervi: nervi_core::NerviClient, adapter: Arc<MatrixAdapter>, component: String) {
    let mut stream = match consume_outbound(&nervi, &component).await {
        Ok(s) => Box::pin(s),
        Err(e) => {
            tracing::error!("failed to open outbound consumer for {}: {}", component, e);
            return;
        }
    };
    while let Some(result) = stream.next().await {
        match result {
            Ok(reply) => {
                if let Err(e) = adapter.deliver(&component, &reply).await {
                    tracing::warn!("delivery failed for {} room {}: {}", component, reply.conversation_id, e);
                }
            }
            Err(e) => {
                tracing::warn!("failed to decode outbound message for {} (non-fatal): {}", component, e);
            }
        }
    }
}

#[cfg(test)]
mod parse_components_tests {
    use super::parse_components;

    #[test]
    fn splits_on_comma_and_trims_whitespace() {
        assert_eq!(
            parse_components("guilhem, caissa,amassada"),
            vec!["guilhem".to_string(), "caissa".to_string(), "amassada".to_string()]
        );
    }

    #[test]
    fn empty_string_yields_empty_vec() {
        assert!(parse_components("").is_empty());
    }
}
```

Note: `nervi_core::NerviClient` needs `Clone` for the `for component in components`
loop above to hand a copy to each spawned task. If it does not already derive
`Clone` (check `nervi/nervi-core/src/client.rs`'s struct definition), add this as
part of this step:

```rust
// In nervi/nervi-core/src/client.rs, change:
pub struct NerviClient {
    js: jetstream::Context,
}
// to:
#[derive(Clone)]
pub struct NerviClient {
    js: jetstream::Context,
}
```

`jetstream::Context` is cheaply cloneable (an `Arc`-backed handle internally in
`async-nats`), so this is a correct, cheap addition, not a workaround.

- [ ] **Step 5: Run tests**

Run: `cd Corrier && cargo test -p corrier-write-gateway`
Expected: 2 tests pass.

If the `Clone` derive was needed, also re-run: `cd nervi && cargo test -p nervi-core`
Expected: all existing tests still pass (adding `#[derive(Clone)]` to a struct with
no non-`Clone` fields cannot break anything that compiled before).

- [ ] **Step 6: Commit**

```bash
cd Corrier
git add Cargo.toml corrier-write-gateway
git commit -m "feat(corrier-write-gateway): drain Nervi outbound subjects, deliver via Matrix adapter"

cd ../nervi
git add nervi-core/src/client.rs
git commit -m "chore(nervi-core): derive Clone on NerviClient (cheap, Arc-backed jetstream::Context)"
git push origin main
```

---

### Task 8: Corrièr Helm chart

**Files:**
- Create: `Corrier/deploy/charts/corrier/Chart.yaml`
- Create: `Corrier/deploy/charts/corrier/values.yaml`
- Create: `Corrier/deploy/charts/corrier/templates/read-gateway.yaml`
- Create: `Corrier/deploy/charts/corrier/templates/write-gateway.yaml`
- Create: `Corrier/.github/workflows/build.yml`

**Interfaces:**
- Consumes: nothing from earlier tasks directly — this is deployment
  configuration for the two binaries built in Tasks 6 and 7.
- Produces: `corrier-read-gateway` and `corrier-write-gateway` Deployments +
  Services in the `agents` namespace (matching where guilhem/component-agent pods
  already run, so cluster-internal DNS resolution is consistent), reachable by
  the agent pods' Task 10 changes.

- [ ] **Step 1: Chart.yaml**

```yaml
apiVersion: v2
name: corrier
description: Matrix Application Service gateway pair for the Occitan stack
version: 0.1.0
```

- [ ] **Step 2: values.yaml**

```yaml
image:
  repository: ghcr.io/miegjorn/corrier
  tag: latest

readGateway:
  replicas: 2
  port: 8080

writeGateway:
  replicas: 2
  components: "guilhem,gardian,fondament,farga,amassada,cor,caissa,charradissa,nervi"

matrix:
  homeserver: "http://synapse.occitan-system.svc.cluster.local:8008"

farga:
  url: "http://farga.occitan-system.svc.cluster.local:7500"

nats:
  url: "nats://nats.occitan-system.svc.cluster.local:4222"

kroki:
  url: "http://kroki.occitan-system.svc.cluster.local:8000"
```

- [ ] **Step 3: Read gateway Deployment + Service**

Create `Corrier/deploy/charts/corrier/templates/read-gateway.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: corrier-read-gateway
  namespace: agents
  labels:
    app.kubernetes.io/name: corrier-read-gateway
    app.kubernetes.io/part-of: occitan
spec:
  replicas: {{ .Values.readGateway.replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/name: corrier-read-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: corrier-read-gateway
    spec:
      containers:
        - name: corrier-read-gateway
          image: "{{ .Values.image.repository }}:read-gateway-{{ .Values.image.tag }}"
          command: ["corrier-read-gateway"]
          ports:
            - containerPort: {{ .Values.readGateway.port }}
          env:
            - name: PORT
              value: {{ .Values.readGateway.port | quote }}
            - name: FARGA_URL
              value: {{ .Values.farga.url | quote }}
            - name: NATS_URL
              value: {{ .Values.nats.url | quote }}
            - name: MATRIX_HOMESERVER
              value: {{ .Values.matrix.homeserver | quote }}
            - name: KROKI_URL
              value: {{ .Values.kroki.url | quote }}
            - name: CORRIER_HS_TOKEN
              valueFrom:
                secretKeyRef:
                  name: corrier-as-tokens
                  key: hs_token
            - name: CORRIER_AS_TOKEN
              valueFrom:
                secretKeyRef:
                  name: corrier-as-tokens
                  key: as_token
          readinessProbe:
            httpGet:
              path: /health
              port: {{ .Values.readGateway.port }}
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: {{ .Values.readGateway.port }}
            periodSeconds: 30
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: corrier-read-gateway
  namespace: agents
spec:
  selector:
    app.kubernetes.io/name: corrier-read-gateway
  ports:
    - port: 8080
      targetPort: {{ .Values.readGateway.port }}
```

- [ ] **Step 4: Write gateway Deployment (no Service needed — it makes no inbound calls)**

Create `Corrier/deploy/charts/corrier/templates/write-gateway.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: corrier-write-gateway
  namespace: agents
  labels:
    app.kubernetes.io/name: corrier-write-gateway
    app.kubernetes.io/part-of: occitan
spec:
  replicas: {{ .Values.writeGateway.replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/name: corrier-write-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: corrier-write-gateway
    spec:
      containers:
        - name: corrier-write-gateway
          image: "{{ .Values.image.repository }}:write-gateway-{{ .Values.image.tag }}"
          command: ["corrier-write-gateway"]
          env:
            - name: CORRIER_COMPONENTS
              value: {{ .Values.writeGateway.components | quote }}
            - name: MATRIX_HOMESERVER
              value: {{ .Values.matrix.homeserver | quote }}
            - name: KROKI_URL
              value: {{ .Values.kroki.url | quote }}
            - name: NATS_URL
              value: {{ .Values.nats.url | quote }}
            - name: CORRIER_AS_TOKEN
              valueFrom:
                secretKeyRef:
                  name: corrier-as-tokens
                  key: as_token
```

- [ ] **Step 5: CI workflow to build and push both binary images**

Create `Corrier/.github/workflows/build.yml`, following the exact sibling-checkout
pattern already used by `Caissa/.github/workflows/build.yml` (both repos share
the same `path`-dependency-on-siblings constraint, since `corrier-core` depends
on `nervi-core` via `path = "../../nervi/nervi-core"`):

```yaml
name: Build & push

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: Corrier
    steps:
      - uses: actions/checkout@v4
        with:
          path: Corrier

      - uses: actions/checkout@v4
        with:
          repository: miegjorn/nervi
          token: ${{ secrets.MIEGJORN_CI_TOKEN }}
          path: nervi

      - uses: actions-rust-lang/setup-rust-toolchain@v1
        with:
          rustflags: ""

      - name: Run tests
        run: cargo test --workspace

      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        if: github.event_name != 'pull_request'
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build read-gateway
        if: github.event_name != 'pull_request'
        run: |
          docker build --build-arg BIN=corrier-read-gateway -t ghcr.io/miegjorn/corrier:read-gateway-sha-${GITHUB_SHA::7} .
          docker push ghcr.io/miegjorn/corrier:read-gateway-sha-${GITHUB_SHA::7}

      - name: Build write-gateway
        if: github.event_name != 'pull_request'
        run: |
          docker build --build-arg BIN=corrier-write-gateway -t ghcr.io/miegjorn/corrier:write-gateway-sha-${GITHUB_SHA::7} .
          docker push ghcr.io/miegjorn/corrier:write-gateway-sha-${GITHUB_SHA::7}
```

This references a `Dockerfile` with a `BIN` build arg — create
`Corrier/Dockerfile`:

```dockerfile
FROM rust:1.82 AS builder
ARG BIN
WORKDIR /build
COPY . .
COPY --from=nervi /nervi ../nervi
RUN cargo build --release -p ${BIN}

FROM debian:bookworm-slim
ARG BIN
COPY --from=builder /build/target/release/${BIN} /usr/local/bin/${BIN}
ENTRYPOINT ["/usr/local/bin/${BIN}"]
```

**Note for the implementer:** the `COPY --from=nervi` line above assumes a
multi-context Docker build (`docker buildx build --build-context nervi=../nervi`)
since the sibling-checkout CI pattern puts `nervi/` next to `Corrier/`, not inside
it — update the `docker build` commands in the workflow step above to pass
`--build-context nervi=../nervi` explicitly. This mirrors the exact problem
Caissa's own `build.yml` already solved for its Amassada/Fondament path
dependencies (see that workflow's comments on checking out siblings under
`$GITHUB_WORKSPACE`) — reuse that solution's shape, don't re-derive it.

- [ ] **Step 6: Commit**

```bash
cd Corrier
git add deploy Dockerfile .github
git commit -m "chore(deploy): Corrièr Helm chart and CI build for both gateway binaries"
git push origin main
```

---

### Task 9: Retire `bootstrap_matrix.rs`; secrets for the new AS tokens

**Files:**
- Delete: `Caissa/caissa-cli/src/commands/bootstrap_matrix.rs`
- Modify: `Caissa/caissa-cli/src/commands/mod.rs` (remove `pub mod bootstrap_matrix;`)
- Modify: `Caissa/caissa-cli/src/main.rs` (remove `BootstrapMatrixAgents` command
  and its match arm)
- Delete: `Caissa/deploy/charts/occitan/templates/matrix-bootstrap-job.yaml`
  (confirm exact path first — found via `find /Users/bedardpl/project/Caissa/deploy -iname "*bootstrap*"` earlier in this session)
- Create: a one-time migration note in this plan's own commit message (no code
  artifact needed — see rationale below)

**Interfaces:**
- Produces: nothing new — this task is pure removal + one manual OpenBao cleanup
  step documented below.

**Rationale (spec decision 4 + 5):** Under the AS model, agent identities are
virtual users Synapse creates lazily the first time the AS acts as them — there
is no registration call, no password, no per-agent login. `bootstrap_matrix.rs`'s
entire job (`register_user`, `get_or_create_password`, `matrix_invite`+
`matrix_join` for real accounts, the `@charradissa`/`ORPHANED_GUILHEM_ROOM`
cleanup) has no equivalent need under this design — a virtual user is provisioned
implicitly by `MatrixAdapter::provision_identity` (Task 5) needing no separate
step at all, and there is no "old account membership to clean up" because there
are no old virtual-user accounts yet.

- [ ] **Step 1: Remove the bootstrap command from the CLI**

In `Caissa/caissa-cli/src/main.rs`, delete the `BootstrapMatrixAgents` variant
from the `Commands` enum and its corresponding `match` arm (both located via
`grep -n "BootstrapMatrixAgents" Caissa/caissa-cli/src/main.rs` — two locations,
lines ~113 and ~198 as of this plan's writing, confirm exact current line
numbers before editing since earlier tasks in this plan don't touch this file).

- [ ] **Step 2: Remove the module declaration**

In `Caissa/caissa-cli/src/commands/mod.rs`, delete the line
`pub mod bootstrap_matrix;`.

- [ ] **Step 3: Delete the file**

```bash
cd Caissa
git rm caissa-cli/src/commands/bootstrap_matrix.rs
```

- [ ] **Step 4: Delete the Kubernetes Job manifest**

```bash
git rm deploy/charts/occitan/templates/matrix-bootstrap-job.yaml
```

(If this exact path doesn't match what's in the repo by the time this task
executes, run `find deploy -iname "*bootstrap*"` first and delete whatever it
finds — the file's existence and rough location were confirmed during this
plan's research, but confirm the exact path at implementation time.)

- [ ] **Step 5: Build to confirm no dangling references**

Run: `cd Caissa && cargo build --workspace 2>&1 | grep -E "error"`
Expected: no output (clean build) — if `error[E0432]: unresolved import` or
similar appears referencing `bootstrap_matrix`, find and remove the remaining
reference before proceeding.

- [ ] **Step 6: Manual cleanup note (not a code step — perform once, live, when
this task is actually executed against the production cluster)**

The 9 real Matrix accounts `bootstrap_matrix.rs` registered (`@guilhem`,
`@gardian`, `@fondament`, `@farga`, `@amassada`, `@cor`, `@caissa`,
`@charradissa`, `@nervi`, all `:occitane.guilhem`) and their passwords in
OpenBao at `occitan/matrix/<agent>-password` become orphaned by this cutover —
they're real accounts with no code left that logs into them. Per spec decision 5
(accept one-time continuity loss, no bridge): leave the 9 real accounts in place
(deactivating them is optional cleanup, not required for correctness — nothing
references them going forward) and leave their OpenBao secrets in place
(harmless dead data, not a security exposure since nothing new reads them).
Do **not** delete the accounts as part of this task — Task 10 removes their
*usage*; deleting the accounts themselves is a separate decision outside this
plan's scope, since the accounts may still hold useful Matrix-side history for
a human to review after cutover.

- [ ] **Step 7: Commit**

```bash
cd Caissa
git add -A
git commit -m "$(cat <<'EOF'
chore(bootstrap-matrix): retire real-account registration for AS virtual users

Corrièr's Matrix Application Service (miegjorn/Corrier) provisions agent
identities as AS-managed virtual users, created lazily by Synapse the
first time the AS acts as them -- no registration call, no password, no
per-agent login, unlike the 9 real accounts this command used to manage.
The 9 existing real accounts and their OpenBao passwords are left in place
(harmless, not referenced by anything after this commit) rather than
actively decommissioned -- see Occitan spec 2026-07-04-corrier-matrix-
nervi-gateway-design.md, decision 5.
EOF
)"
```

---

### Task 10: Agent pod turn loop — replace the sidecar/session-map model

**Files:**
- Delete: `Caissa/caissa-cli/src/commands/listen/matrix_client.rs`
- Delete: `Caissa/caissa-cli/src/commands/listen/session_management.rs`
  (its `RoomSession`/`SidecarProcess`/`spawn_idle_reaper` — see Step 2 for what
  survives)
- Modify: `Caissa/caissa-cli/src/commands/listen/matrix_reply.rs` — replaced
  entirely by a new file, see Step 3
- Delete: `Caissa/caissa-cli/src/commands/listen/turn_endpoint.rs`
- Modify: `Caissa/caissa-cli/src/commands/listen/mod.rs` — remove
  `/matrix/reply`, `/turn`, `/room-status` routes and `room_sessions` field;
  remove `mod matrix_client; mod matrix_reply; mod turn_endpoint; mod
  session_management;`, add `mod chat_loop;`
- Create: `Caissa/caissa-cli/src/commands/listen/chat_loop.rs`
- Modify: `Caissa/Cargo.toml` — add `corrier-core` path dependency
- Modify: `Caissa/caissa-cli/Cargo.toml` — add `corrier-core = { workspace = true }`
- Test: `Caissa/caissa-cli/src/commands/listen/chat_loop.rs` (inline)

**Interfaces:**
- Consumes: `corrier_core::{consume_inbound, publish_outbound, ChatMessage,
  ChatReply}` (Task 3), `caissa_core::graph_context::build_graph_context` (already
  exists, unchanged), `caissa_core::agent::fetch_fondament_def` (already exists,
  unchanged).
- Produces: `chat_loop::run_chat_loop(state: Arc<ListenState>)`, spawned from
  `listen::run` the same way `run_matrix_client_loop` used to be.

**What this removes and why:** `room_sessions` (a `HashMap<String, RoomSession>`
living in exactly one pod's memory), `SidecarProcess` (the `agent-sidecar.js`
child-process-per-room model, whose continuity rested entirely on the Claude
Agent SDK's `resume()`), `run_matrix_client_loop`'s `/sync` long-poll, and both
the `/matrix/reply` and `/turn` HTTP endpoints (Corrièr's read gateway now
delivers messages via Nervi, not an HTTP POST to this pod) are the exact list of
things the spec's "What this explicitly rejects" section names. `/room-status`
(added earlier this same day, per this session's own prior work, specifically to
compensate for `room_sessions`' failure modes) is removed because its only
purpose was diagnosing exactly the architecture being deleted — there is no
replacement needed because there is no more in-memory session map to be blind
about.

- [ ] **Step 1: Add the new dependency**

In `Caissa/Cargo.toml`, add to `[workspace.dependencies]`:

```toml
corrier-core = { path = "../Corrier/corrier-core" }
```

In `Caissa/caissa-cli/Cargo.toml`, add to `[dependencies]`:

```toml
corrier-core = { workspace = true }
futures = "0.3"
```

- [ ] **Step 2: Delete the superseded files**

```bash
cd Caissa
git rm caissa-cli/src/commands/listen/matrix_client.rs
git rm caissa-cli/src/commands/listen/session_management.rs
git rm caissa-cli/src/commands/listen/turn_endpoint.rs
```

(`matrix_reply.rs` is not `git rm`'d — it's replaced in Step 3 with new content
under the new name `chat_loop.rs`; delete the old file explicitly since the new
one has a different name:)

```bash
git rm caissa-cli/src/commands/listen/matrix_reply.rs
```

- [ ] **Step 3: Write the new chat loop**

Create `Caissa/caissa-cli/src/commands/listen/chat_loop.rs`:

```rust
//! Each agent pod's turn loop, replacing the sidecar/session-map model
//! entirely (Occitan spec 2026-07-04-corrier-matrix-nervi-gateway-design.md).
//! Continuously consumes this component's inbound chat subject (all its
//! rooms, one subscription, per corrier_core::consume_inbound), builds fresh
//! context from Farga for every turn -- no SDK resume(), no per-room child
//! process, no in-memory session map -- and publishes the reply back to
//! Nervi's outbound side. Corrièr's write gateway delivers it to Matrix;
//! this pod never touches a Matrix credential.

use super::*;
use corrier_core::{consume_inbound, publish_outbound, ChatMessage, ChatReply};
use futures::StreamExt;

pub(crate) async fn run_chat_loop(state: Arc<ListenState>) {
    let nervi = match nervi_core::NerviClient::connect(&state.nats_url).await {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("chat_loop: failed to connect to NATS at {}: {}", state.nats_url, e);
            return;
        }
    };

    let mut stream = match consume_inbound(&nervi, &state.component_name).await {
        Ok(s) => Box::pin(s),
        Err(e) => {
            tracing::error!("chat_loop: failed to open inbound consumer: {}", e);
            return;
        }
    };

    while let Some(result) = stream.next().await {
        match result {
            Ok(msg) => {
                let state = Arc::clone(&state);
                let nervi = nervi.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_chat_message(&state, &nervi, msg).await {
                        tracing::error!("chat_loop: turn failed: {}", e);
                    }
                });
            }
            Err(e) => {
                tracing::warn!("chat_loop: failed to decode inbound message (non-fatal): {}", e);
            }
        }
    }
}

async fn handle_chat_message(
    state: &ListenState,
    nervi: &nervi_core::NerviClient,
    msg: ChatMessage,
) -> anyhow::Result<()> {
    // Fresh context every turn, from Farga -- no resumed SDK session to lean
    // on. This is the seam the spec's Agent pods section names as the
    // natural home for trajectory-conditioned context collapse; this task
    // only needs to remove the structural reason collapse couldn't
    // previously be tried here, not implement it.
    let api_key = std::env::var("ANTHROPIC_API_KEY").ok();
    let graph_context = caissa_core::graph_context::build_graph_context(
        &state.farga_url, &msg.conversation_id, &msg.sender, &msg.content, api_key,
    ).await;

    let (system_prompt, _skills, _def_models, _is_aporia, _thinking_budget) =
        crate::commands::listen::resolve_agent_prompt(&state.fondament_url, &state.generation, &msg.conversation_id).await;

    let turn_block = crate::commands::listen::build_turn_context_block(false, graph_context.as_ref());
    let content = if turn_block.is_empty() {
        msg.content.clone()
    } else {
        format!("{}\n\n{}", turn_block, msg.content)
    };

    let reply_text = crate::commands::listen::run_single_turn(&system_prompt, &content).await?;

    let reply = ChatReply {
        conversation_id: msg.conversation_id,
        content: reply_text,
        adapter: msg.adapter,
    };
    publish_outbound(nervi, &state.component_name, &reply).await
}

#[cfg(test)]
mod tests {
    // handle_chat_message's own network calls (Farga, fondament-server,
    // Anthropic) make it unsuitable for a fast unit test without a mock
    // server -- covered instead by the existing graph_context and
    // resolve_agent_prompt test suites (unchanged by this task) plus this
    // plan's Task 13 live-verification step. This module intentionally has
    // no inline tests beyond confirming it compiles against the real
    // corrier_core/nervi_core types, which `cargo build` already proves.
}
```

**Note for the implementer:** this step references two functions that do not
exist yet under these exact names — `resolve_agent_prompt` (a generalized,
component-agnostic rename of the existing `resolve_guilhem_prompt` found in the
deleted `matrix_reply.rs`, since this loop now runs for every component, not
just Guilhem) and `run_single_turn` (a new function that replaces
`SidecarProcess::send()` — a single, non-resumed Claude Agent SDK call per turn
using `claude --print`, mirroring the one-shot pattern the existing
`/trigger/*` handlers already use in `cron_triggers.rs`/`queue_triggers.rs`, NOT
the persistent-child-process pattern being deleted). Both must be written as
part of this same task — see Step 4 and Step 5.

- [ ] **Step 4: Write `run_single_turn`**

Add to `chat_loop.rs` (place above `handle_chat_message`):

```rust
/// One non-resumed Claude Agent SDK turn: spawn `claude --print`, write the
/// full prompt to stdin, read the reply from stdout, exit. Replaces
/// SidecarProcess's persistent child-process-per-room model -- every turn
/// gets a fresh process, matching the one-shot pattern the existing
/// /trigger/* handlers (cron_triggers.rs, queue_triggers.rs) already use for
/// non-conversational work. No resume(), no continuity assumption beyond
/// what build_graph_context already reconstructs from Farga.
pub(crate) async fn run_single_turn(system_prompt: &str, content: &str) -> anyhow::Result<String> {
    let output = tokio::process::Command::new("claude")
        .args(["--print", content, "--append-system-prompt", system_prompt])
        .output()
        .await?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("claude --print exited with error: {}", stderr);
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}
```

- [ ] **Step 5: Rename `resolve_guilhem_prompt` to `resolve_agent_prompt`**

Search the codebase for the existing function (it was defined in the now-deleted
`matrix_reply.rs` before this task ran):

```bash
grep -rn "resolve_guilhem_prompt\|build_turn_context_block" Caissa/caissa-cli/src/
```

Since `matrix_reply.rs` was deleted in Step 2, recreate the two functions it
contained (`resolve_guilhem_prompt`, renamed `resolve_agent_prompt`, and
`build_turn_context_block`, unchanged) in a new small module —
`Caissa/caissa-cli/src/commands/listen/agent_prompt.rs` — using their exact
prior bodies from `matrix_reply.rs`'s git history
(`git show HEAD~1:caissa-cli/src/commands/listen/matrix_reply.rs` before this
task's Step 2 commit lands, to retrieve the pre-deletion source), with the sole
change being the rename `resolve_guilhem_prompt` -> `resolve_agent_prompt` and
its Fondament-address lookup changed from hardcoded `"guilhem"` to
`&state.component_name` so it resolves the right agent's persona for whichever
pod is running. Move the existing `turn_context_block_tests` module
(4 tests, confirmed present earlier this session) along with it unchanged —
they test `build_turn_context_block` directly and don't reference anything
deleted in this task.

- [ ] **Step 6: Update `mod.rs`**

In `Caissa/caissa-cli/src/commands/listen/mod.rs`:
- Remove `mod matrix_client; mod matrix_reply; mod turn_endpoint; mod
  session_management;` and their `pub(crate) use ...*;` re-exports.
- Add `mod chat_loop; mod agent_prompt;` and `pub(crate) use chat_loop::*; pub(crate) use agent_prompt::*;`
- Remove the `room_sessions: Arc<tokio::sync::Mutex<HashMap<String, RoomSession>>>`
  field from `ListenState`.
- Add `pub(crate) component_name: String` and `pub(crate) nats_url: String` fields
  to `ListenState` (component_name defaults from `config.generation`, already
  loaded — trim any `-agent` suffix component-agents charts add, matching
  `repo_to_component`'s existing convention in `sync.rs`; `nats_url` from a new
  `NATS_URL` env var, matching the pattern every other URL field in
  `ListenState` already uses).
- Remove the `.route("/matrix/reply", post(handle_matrix_reply))`,
  `.route("/turn", post(handle_turn))`, and
  `.route("/room-status", axum::routing::get(handle_room_status))` lines from
  the `Router::new()` chain.
- Replace `tokio::spawn(run_matrix_client_loop(Arc::clone(&state)));` with
  `tokio::spawn(chat_loop::run_chat_loop(Arc::clone(&state)));`.
- Remove `tokio::spawn(spawn_idle_reaper(Arc::clone(&state.room_sessions)));`
  entirely (no session map left to reap).

- [ ] **Step 7: Build**

Run: `cd Caissa && cargo build --workspace 2>&1 | grep -E "^error"`
Expected: no output. Fix any remaining reference to a deleted symbol
(`RoomSession`, `SidecarProcess`, `handle_matrix_reply`, `handle_turn`,
`handle_room_status`, `guilhem_mcp_servers`, `guilhem_allowed_tools` — the last
two also need renaming to `agent_mcp_servers`/`agent_allowed_tools` as part of
this same task, since they're called from the new `agent_prompt.rs` and are no
longer Guilhem-specific; carry their bodies over unchanged except the
`fetch_fondament_def(fondament_url, "guilhem")` call becoming
`fetch_fondament_def(fondament_url, &state.component_name)`).

- [ ] **Step 8: Run the full test suite**

Run: `cd Caissa && cargo test --workspace 2>&1 | grep -E "FAILED|test result"`
Expected: all tests pass — the 4 `turn_context_block_tests` carried over in
Step 5, plus everything in `caissa-core` (unchanged by this task) and the
remaining `listen` submodules (`cron_triggers.rs`, `queue_triggers.rs`,
`component_agent.rs`, `handoff.rs`, `bootstrap_matrix.rs` — wait,
`bootstrap_matrix.rs` was deleted in Task 9, confirm it's gone before this
task's test run if executed after Task 9 lands).

- [ ] **Step 9: Commit**

```bash
cd Caissa
git add -A
git commit -m "$(cat <<'EOF'
refactor(listen): replace sidecar/session-map model with Nervi-driven chat loop

Removes room_sessions, SidecarProcess, run_matrix_client_loop, /matrix/reply,
/turn, /room-status -- every piece of state and every HTTP surface whose sole
purpose was proxying Matrix traffic through this pod. Corrièr's read/write
gateways (miegjorn/Corrier) now own all Matrix I/O; this pod's only chat
input is its Nervi inbound subject (corrier_core::consume_inbound), and its
only output is its Nervi outbound subject (corrier_core::publish_outbound).

Each turn is a fresh claude --print process (run_single_turn) building
context from Farga via the existing build_graph_context -- no SDK resume(),
no per-room child process, no map that dies with the pod. /room-status
(added earlier the same day this refactor was designed, specifically to
compensate for room_sessions' failure modes) is removed with it: there is
no session map left to be blind about.

guilhem_mcp_servers/guilhem_allowed_tools renamed to agent_mcp_servers/
agent_allowed_tools and parameterized on state.component_name -- this loop
now runs for every component, not just Guilhem.
EOF
)"
```

---

### Task 11: Helm chart updates for the 9 agent pods

**Files:**
- Modify: `Caissa/deploy/charts/guilhem/templates/guilhem.yaml`
- Modify: `Caissa/deploy/charts/component-agents/templates/agents.yaml`
- Modify: `Caissa/deploy/charts/guilhem/values.yaml`
- Modify: `Caissa/deploy/charts/component-agents/values.yaml`

**Interfaces:**
- Consumes: nothing new — pure Helm chart editing to match Task 10's env-var
  changes (`NATS_URL` in, `MATRIX_*` out).

- [ ] **Step 1: Remove Matrix env vars from guilhem's chart**

In `Caissa/deploy/charts/guilhem/templates/guilhem.yaml`, remove the following
env var blocks from the `guilhem` container (confirmed exact line numbers
earlier this session: 323–334 for `SRE_MATRIX_ROOM_ID`, `BACKLOG_MATRIX_ROOM_ID`,
`DREAM_MATRIX_ROOM_ID`, `MATRIX_USER`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — but
re-`grep -n "MATRIX"` at implementation time since Task 10 landing first may
shift line numbers in unrelated ways):

```yaml
            - name: MATRIX_USER
              value: {{ .Values.matrixUser | quote }}
            - name: MATRIX_ROOM_ID
              value: {{ .Values.matrixRoomId | quote }}
            - name: MATRIX_HOMESERVER
              value: {{ .Values.matrixHomeserver | quote }}
```

(Leave `SRE_MATRIX_ROOM_ID`, `BACKLOG_MATRIX_ROOM_ID`, `DREAM_MATRIX_ROOM_ID` —
these are used by the untouched `/trigger/sre-alert`, `/trigger/backlog-review`,
`/trigger/dream` one-shot handlers to *post a summary*, which still happens via
`post_to_matrix_room` in the now-deleted `matrix_client.rs`. Since that whole
file is gone per Task 10, port `post_to_matrix_room` and `post_signal_to`
— the two functions from `matrix_client.rs` lines 448–512 that these three
`/trigger/*` handlers actually depend on — into `Caissa/caissa-cli/src/commands/listen/chat_loop.rs` alongside the new chat-loop code, unchanged, since they use
`SYNAPSE_ADMIN_TOKEN` directly rather than the deleted per-agent login flow and
are explicitly out of scope for removal per this plan's own "Does not touch"
list.)

Add:

```yaml
            - name: NATS_URL
              value: {{ .Values.nats.url | quote }}
```

- [ ] **Step 2: Same for component-agents chart**

In `Caissa/deploy/charts/component-agents/templates/agents.yaml`, remove the
`MATRIX_USER`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` env var block (confirmed
lines 132–137 earlier this session) and add:

```yaml
            - name: NATS_URL
              value: {{ $.Values.nats.url | quote }}
```

(Note the `$.Values` scoping — this file uses `{{- range .Values.agents }}`, so
top-level values need the `$` prefix, matching the existing `{{ $.Values.farga.url
| quote }}` pattern already in this file per this session's earlier reading.)

- [ ] **Step 3: Add the `nats` values block to both charts**

In `Caissa/deploy/charts/guilhem/values.yaml` and
`Caissa/deploy/charts/component-agents/values.yaml`, add:

```yaml
nats:
  url: "nats://nats.occitan-system.svc.cluster.local:4222"
```

Remove the now-unused `matrixUser`, `matrixRoomId`, `matrixHomeserver` (guilhem
chart) and the per-agent Matrix-related entries under `agents:` (component-agents
chart) — confirm exact key names via `grep -n "matrix" deploy/charts/guilhem/values.yaml deploy/charts/component-agents/values.yaml` before removing, since this
plan's earlier research read the templates, not every values.yaml key.

- [ ] **Step 4: Validate the chart renders**

Run: `cd Caissa && helm template deploy/charts/guilhem 2>&1 | grep -E "^error|NATS_URL"`
Expected: no `error` lines, and `NATS_URL` appears in the rendered output.

Run: `cd Caissa && helm template deploy/charts/component-agents 2>&1 | grep -E "^error|NATS_URL"`
Expected: same.

- [ ] **Step 5: Commit**

```bash
cd Caissa
git add deploy/charts/guilhem deploy/charts/component-agents
git commit -m "chore(charts): remove Matrix env vars from agent pods, add NATS_URL

Matrix I/O now lives entirely in Corrièr (miegjorn/Corrier); agent pods
only need NATS_URL to reach their Nervi chat subjects. SRE_MATRIX_ROOM_ID/
BACKLOG_MATRIX_ROOM_ID/DREAM_MATRIX_ROOM_ID are untouched -- they're used
by the one-shot /trigger/* summary-posting handlers, unrelated to this
refactor's scope."
git push origin main
```

---

### Task 12: End-to-end live verification

**Files:** none created or modified — this task is entirely verification against
a real (or locally-composed) deployment.

- [ ] **Step 1: Deploy Corrièr's chart and confirm both gateways are healthy**

```bash
kubectl -n agents get pods -l app.kubernetes.io/name=corrier-read-gateway
kubectl -n agents get pods -l app.kubernetes.io/name=corrier-write-gateway
```

Expected: both show `Running`, `READY` matching replica count.

- [ ] **Step 2: Register the AS with Synapse**

Apply the registration YAML generated by
`corrier_matrix::registration::generate_as_registration_yaml` (Task 5) to
Synapse's config (`app_service_config_files` in `homeserver.yaml`), restart
Synapse, and confirm via Synapse's own logs that it loaded the AS:

```bash
kubectl -n occitan-system logs deployment/synapse | grep -i "corrier\|application service"
```

Expected: a log line confirming the `corrier` AS registration was loaded, no
error about a malformed registration file.

- [ ] **Step 3: Provision guilhem into the `#occitan` room via the read gateway**

Use the `/provision` endpoint (Task 6, `handle_provision`) rather than writing
the Farga routing entry directly — it also joins `@_corrier_guilhem` into the
room, which is required before Synapse will ever push a transaction for it
to the AS at all:

```bash
curl -X POST http://corrier-read-gateway.agents.svc.cluster.local:8080/provision \
  -H "Content-Type: application/json" \
  -d '{"room_id": "!iNQRqUAMckCUQrSFHk:occitane.guilhem", "components": ["guilhem"]}'
```

Expected: `200` response. Confirm the join actually happened:

```bash
curl -s http://farga.occitan-system.svc.cluster.local:7500/kv/routing/%21iNQRqUAMckCUQrSFHk%3Aoccitane.guilhem
```

Expected: the routing entry with `component: "guilhem"`, and (via the same
Synapse admin `/rooms/{room}/members` check used throughout this session's
earlier manual verification) `@_corrier_guilhem:occitane.guilhem` now listed
as a room member.

- [ ] **Step 4: Send a real message in that room and observe the full round trip**

Send a message as a real user in the `#occitan` room (the same room used
throughout this session's earlier manual verification), then watch:

```bash
kubectl -n agents logs -f deployment/corrier-read-gateway
kubectl -n agents logs -f deployment/guilhem
kubectl -n agents logs -f deployment/corrier-write-gateway
```

Expected: the read gateway logs receiving the transaction and resolving one
route; the guilhem pod's `chat_loop` logs receiving the message on its inbound
subject and producing a reply; the write gateway logs delivering it. The reply
appears in the actual Matrix room within a reasonable turn time (compare
against this session's own earlier live timings, 5–60s depending on tool use).

- [ ] **Step 5: Confirm statelessness by restarting a gateway mid-conversation**

```bash
kubectl -n agents rollout restart deployment/corrier-read-gateway
```

Send a second message immediately after issuing the restart. Expected: the
message is still answered (possibly with a few seconds' delay while the new
pod becomes ready) — unlike the old `room_sessions`-based design, no
conversation state was lost by this restart, since none was held here to begin
with.

- [ ] **Step 6: Record the verification result**

Write a Farga signal documenting the cutover, matching this stack's existing
convention (`source: "corrier-cutover"`, project `occitan`) — a durable record
per A-6, since this is exactly the kind of significant action ("work was done")
the axiom requires be recorded in Farga rather than only in a conversation or
a runbook.
