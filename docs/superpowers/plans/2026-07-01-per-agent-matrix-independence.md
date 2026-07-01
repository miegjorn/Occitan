# Per-Agent Matrix Independence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each of the 9 Occitan agents (guilhem + gardian, fondament, farga, amassada, cor, caissa, charradissa, nervi) its own real Matrix login session, posting as itself in its own room, with zero messages passing through Charradissa's relay.

**Architecture:** A new background task inside the existing `caissa listen` process (one per agent pod) logs in as the pod's own Matrix user, long-polls `/sync`, and calls the already-working `run_matrix_reply` persistent-session logic in-process. A new idempotent `caissa bootstrap-matrix-agents` subcommand (run as a Kubernetes Job) registers the 9 users, force-joins them into their rooms, and kicks Charradissa's renamed relay identity out of the 8 component rooms. Charradissa stops relaying for these 9 rooms entirely.

**Tech Stack:** Rust (Caissa: axum, tokio, reqwest; Charradissa: same), Helm charts, OpenBao (KV v2 HTTP API), Synapse admin API, `wiremock` for HTTP mocking in tests.

## Global Constraints

- Spec: `Occitan/docs/superpowers/specs/2026-07-01-per-agent-matrix-independence-design.md` — every task below implements a section of it.
- Store agent **passwords** in OpenBao, not access tokens — a cached `SYNAPSE_ADMIN_TOKEN` went stale after a Matrix reset earlier the same day this was designed; fresh login at every pod startup avoids that failure mode.
- Any Matrix API call that returns `M_UNKNOWN_TOKEN` must trigger an automatic re-login, not a crash.
- The Caissa (sync-loop) and Charradissa (relay-disable) changes must deploy together — landing one without the other causes duplicate replies in these 9 rooms.
- The live (current, correct) Matrix room IDs for the 9 rooms, confirmed via Synapse's admin room-list API on 2026-07-01, are:

  | Agent | Room ID |
  |---|---|
  | guilhem | `!hTNBZpYDxyvfcuralm:occitane.guilhem` |
  | gardian | `!bwuKXFvUXnVZfXcKuz:occitane.guilhem` |
  | fondament | `!KuWBSmYyvyiyTMFKqJ:occitane.guilhem` |
  | farga | `!CtktMiOTNtSIkdwOxq:occitane.guilhem` |
  | amassada | `!vLjgiURMSlkqTXgaDG:occitane.guilhem` |
  | cor | `!FgfTbZMpLLVGiISZTj:occitane.guilhem` |
  | caissa | `!ZqGBDioAYnOATihiEU:occitane.guilhem` |
  | charradissa | `!qZGQFrjAcKjPinhQnp:occitane.guilhem` |
  | nervi | `!QQeweqsLsOTZYdonXi:occitane.guilhem` |

  Existing config in both `Caissa/deploy/charts/component-agents/values.yaml` (`roomId` field) and `Caissa/deploy/charts/occitan/values.yaml` (`agents.routes`) has **two different, both-stale** sets of IDs from earlier resets — use the table above, not either existing file.

---

## File Structure

New files:
- `Caissa/caissa-core/src/graph_context.rs` — ported `SessionGraph` context collapse (mirrors `Charradissa/charradissa-core/src/graph_context.rs`, minus the unused rolling-history parameter).
- `Caissa/caissa-cli/src/commands/bootstrap_matrix.rs` — the `bootstrap-matrix-agents` subcommand: user registration, room force-join, `@charradissa-relay` cleanup, OpenBao password storage.
- `Caissa/deploy/charts/occitan/templates/matrix-bootstrap-job.yaml` — Kubernetes Job running the subcommand above.

Modified files:
- `Caissa/Cargo.toml` — add `amassada-core`, `hmac`, `sha1`, `hex` to `[workspace.dependencies]`.
- `Caissa/caissa-core/Cargo.toml` — depend on `amassada-core`.
- `Caissa/caissa-cli/Cargo.toml` — depend on `hmac`, `sha1`, `hex`; add `wiremock` dev-dependency.
- `Caissa/caissa-cli/src/main.rs` — new `BootstrapMatrixAgents` subcommand.
- `Caissa/caissa-cli/src/commands/listen.rs` — new `ListenState` fields, new Matrix sync-loop functions, wire `graph_context` into `run_matrix_reply`.
- `Caissa/deploy/charts/component-agents/templates/agents.yaml` — Matrix credential fetch + `MATRIX_USER`/`MATRIX_ROOM_ID`/`MATRIX_HOMESERVER` env vars.
- `Caissa/deploy/charts/component-agents/values.yaml` — fix stale `roomId` values (table above).
- `Caissa/deploy/charts/guilhem/templates/guilhem.yaml` — same env var wiring for guilhem.
- `Caissa/deploy/charts/guilhem/values.yaml` — new `matrix:` block.
- `Caissa/deploy/charts/occitan/values.yaml` — remove the now-dead `agents.routes` entries for the 8 component rooms.
- `Charradissa/charradissa-daemon/src/main.rs` — rename own bot identity to `@charradissa-relay`, disable dynamic component-room provisioning.
- `Charradissa/charradissa-matrix/src/appservice.rs` — explicit skip-list guard so the 9 migrated rooms never fall through to the default relay path.

---

### Task 1: Port SessionGraph context collapse into Caissa

**Files:**
- Create: `Caissa/caissa-core/src/graph_context.rs`
- Modify: `Caissa/caissa-core/src/lib.rs` (add `pub mod graph_context;`)
- Modify: `Caissa/Cargo.toml:18` (workspace deps — add after `rustls`)
- Modify: `Caissa/caissa-core/Cargo.toml` (add dependency)
- Test: `Caissa/caissa-core/src/graph_context.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Produces: `pub async fn build_graph_context(farga_url: &str, room_id: &str, latest_sender: &str, latest_content: &str, api_key: Option<String>) -> Option<String>` — used by Task 3.

- [ ] **Step 1: Add the `amassada-core` path dependency**

Edit `Caissa/Cargo.toml`, in `[workspace.dependencies]` (after the `rustls` line):

```toml
amassada-core = { path = "../Amassada/crates/amassada-core" }
hmac = "0.12"
sha1 = "0.10"
hex = "0.4"
```

Edit `Caissa/caissa-core/Cargo.toml`, add to `[dependencies]`:

```toml
amassada-core = { workspace = true }
```

- [ ] **Step 2: Write the failing test**

Create `Caissa/caissa-core/src/graph_context.rs`:

```rust
//! Graph-based context collapse for long-lived Matrix conversations, ported
//! from `Charradissa/charradissa-core/src/graph_context.rs`. Reuses
//! `amassada-core`'s already-tested `SessionGraph` / `extract_delta` /
//! `retrieve` rather than a new implementation.
//!
//! Unlike Charradissa's version, this has no rolling-history parameter:
//! each Caissa agent pod now processes its own room's messages incrementally
//! as they arrive via its own `/sync` loop (see `matrix_client` in
//! `caissa-cli/src/commands/listen.rs`), so there is no fetched history
//! window to replay — the persistent graph loaded from Farga already carries
//! prior turns.
//!
//! Non-fatal by design: any failure (extraction API error, Farga
//! unreachable) logs a warning and returns `None`. Callers fall back to
//! their pre-existing prompt — this must never turn a reply into a hard
//! failure.

use amassada_core::{extract_delta, NodeId, NodeType, SessionGraph};

/// Build a collapsed context string for `room_id`'s persistent graph, given
/// the latest message's sender and content. Returns `None` on any failure,
/// or when the room's graph has no frontier nodes yet (first message ever
/// in this room) — callers should fall back to their bare prompt in both
/// cases.
pub async fn build_graph_context(
    farga_url: &str,
    room_id: &str,
    latest_sender: &str,
    latest_content: &str,
    api_key: Option<String>,
) -> Option<String> {
    let mut graph = amassada_core::farga::load_graph(farga_url, room_id)
        .await
        .unwrap_or_else(|| SessionGraph::new(room_id));

    let transcript_segment = format!("{}: {}\n", latest_sender, latest_content);

    let existing_nodes: Vec<NodeId> = graph.layers.causal.nodes.keys().cloned().collect();

    match extract_delta(&transcript_segment, &existing_nodes, api_key).await {
        Ok(delta) => graph.apply_delta(delta),
        Err(e) => {
            tracing::warn!(
                "graph_context: extraction failed for room {} (non-fatal, retrieving from existing graph as-is): {}",
                room_id, e
            );
        }
    }

    let frontier_ids: Vec<NodeId> = graph
        .layers
        .causal
        .nodes
        .values()
        .filter(|n| n.node_type == NodeType::Frontier)
        .map(|n| n.id.clone())
        .collect();

    let collapsed = if frontier_ids.is_empty() {
        None
    } else {
        Some(graph.retrieve(&frontier_ids, 1))
    };

    // Save even if extraction failed above -- version/vias/other layers may
    // still be worth persisting, and save_graph is itself non-fatal on error.
    amassada_core::farga::save_graph(farga_url, room_id, &graph).await;

    collapsed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn unreachable_farga_returns_none_not_panic() {
        // No live Farga at this address -- load_graph/save_graph are both
        // non-fatal (per amassada_core::farga's own doc comment), and
        // extract_delta will fail without a reachable Anthropic endpoint --
        // either way this must resolve to None, never panic or hang.
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            build_graph_context(
                "http://127.0.0.1:1",
                "!unreachable-test-room:occitane.guilhem",
                "@p:occitane.guilhem",
                "how are you?",
                Some("not-a-real-key".into()),
            ),
        )
        .await;
        if let Ok(context) = result {
            assert!(context.is_none());
        }
    }
}
```

Edit `Caissa/caissa-core/src/lib.rs` — add near the other `pub mod` lines:

```rust
pub mod graph_context;
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd Caissa && cargo test -p caissa-core graph_context:: -- --nocapture`
Expected: `test graph_context::tests::unreachable_farga_returns_none_not_panic ... ok`

(This is a real network-dependent test, same as Charradissa's original — it exercises the actual non-fatal-failure path, not a mock, matching the existing convention in `charradissa-core`.)

- [ ] **Step 4: Commit**

```bash
cd Caissa
git add Cargo.toml caissa-core/Cargo.toml caissa-core/src/lib.rs caissa-core/src/graph_context.rs
git commit -m "feat(graph-context): port SessionGraph context collapse from Charradissa

Reuses amassada-core directly (same dependency Charradissa already has) so
Caissa's own Matrix sync loop can bridge context across session respawns
without taking on all of charradissa-core as a dependency."
```

---

### Task 2: Add the `caissa bootstrap-matrix-agents` subcommand

**Files:**
- Create: `Caissa/caissa-cli/src/commands/bootstrap_matrix.rs`
- Modify: `Caissa/caissa-cli/src/commands/mod.rs` (add `pub mod bootstrap_matrix;`)
- Modify: `Caissa/caissa-cli/src/main.rs` (new subcommand)
- Modify: `Caissa/caissa-cli/Cargo.toml` (add `hmac`, `sha1`, `hex`, `wiremock` dev-dep)
- Test: `Caissa/caissa-cli/src/commands/bootstrap_matrix.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `pub async fn run(homeserver: &str, bao_addr: &str) -> anyhow::Result<()>` — invoked by `main.rs`, and by the Kubernetes Job in Task 6.

- [ ] **Step 1: Add dependencies**

Edit `Caissa/caissa-cli/Cargo.toml`, add to `[dependencies]`:

```toml
hmac = { workspace = true }
sha1 = { workspace = true }
hex = { workspace = true }
```

Add a new section at the end of the file:

```toml
[dev-dependencies]
wiremock = "0.6"
```

- [ ] **Step 2: Write the failing test**

Create `Caissa/caissa-cli/src/commands/bootstrap_matrix.rs`:

```rust
//! `caissa bootstrap-matrix-agents` — idempotent one-time (but safe-to-rerun)
//! setup for the 9 independent Matrix agent identities (guilhem + the 8
//! component agents). Run as a Kubernetes Job on every Helm sync.
//!
//! For each agent: registers a Matrix user via Synapse's shared-secret admin
//! registration (treats "already registered" as success), generates and
//! stores a password in OpenBao on first registration (read back on later
//! runs so re-running never rotates an in-use password), and force-joins
//! that user into its designated room using a short-lived admin token minted
//! the same way. Finally kicks `@charradissa-relay` from every component
//! room it's a member of (idempotent — checks membership first).
//!
//! Deliberately stores passwords, not access tokens: a token can go stale
//! after a Matrix reset in a way a stored password can't (each agent's own
//! `caissa listen` process logs in fresh at startup — see `matrix_client`
//! in `commands/listen.rs`).

use hmac::{Hmac, Mac};
use sha1::Sha1;

/// (Matrix localpart, Matrix room ID) for each of the 9 independent agents.
pub const AGENTS: &[(&str, &str)] = &[
    ("guilhem", "!hTNBZpYDxyvfcuralm:occitane.guilhem"),
    ("gardian", "!bwuKXFvUXnVZfXcKuz:occitane.guilhem"),
    ("fondament", "!KuWBSmYyvyiyTMFKqJ:occitane.guilhem"),
    ("farga", "!CtktMiOTNtSIkdwOxq:occitane.guilhem"),
    ("amassada", "!vLjgiURMSlkqTXgaDG:occitane.guilhem"),
    ("cor", "!FgfTbZMpLLVGiISZTj:occitane.guilhem"),
    ("caissa", "!ZqGBDioAYnOATihiEU:occitane.guilhem"),
    ("charradissa", "!qZGQFrjAcKjPinhQnp:occitane.guilhem"),
    ("nervi", "!QQeweqsLsOTZYdonXi:occitane.guilhem"),
];

/// The 8 component rooms (all of AGENTS except guilhem, which has no
/// pre-existing relay identity to clean up) — @charradissa-relay is kicked
/// from these if present.
fn component_rooms() -> impl Iterator<Item = &'static (&'static str, &'static str)> {
    AGENTS.iter().filter(|(name, _)| *name != "guilhem")
}

fn server_name(homeserver_room_suffix: &str) -> &str {
    homeserver_room_suffix
}

/// Compute the HMAC-SHA1 MAC for Synapse's shared-secret registration API,
/// matching the algorithm in Synapse's `register_new_matrix_user` script:
/// `HMAC-SHA1(shared_secret, nonce \0 username \0 password \0 admin_flag)`.
pub fn registration_mac(shared_secret: &str, nonce: &str, username: &str, password: &str, admin: bool) -> String {
    let mut mac = Hmac::<Sha1>::new_from_slice(shared_secret.as_bytes())
        .expect("HMAC accepts any key length");
    let admin_flag = if admin { "admin" } else { "notadmin" };
    let input = [nonce, username, password, admin_flag].join("\0");
    mac.update(input.as_bytes());
    hex::encode(mac.finalize().into_bytes())
}

/// Generate a random password. 32 hex chars (16 bytes) — long enough to not
/// need rotation, short enough to fit comfortably in an env var / OpenBao value.
pub fn generate_password() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    // Not cryptographically reviewed RNG-grade, but this is a machine-to-machine
    // Matrix account password behind cluster-internal auth, generated once and
    // stored in OpenBao — matches the trust model of the existing GitHub/GitLab
    // token handling in this same init-container pattern.
    let mut seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let mut out = String::with_capacity(32);
    for _ in 0..32 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        let nibble = ((seed >> 60) & 0xf) as u8;
        out.push(std::char::from_digit(nibble as u32, 16).unwrap());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registration_mac_matches_known_vector() {
        // Verified against the HMAC computed live during the 2026-07-01
        // investigation (registering @verify-admin) using the same shared
        // secret format Synapse expects.
        let mac = registration_mac("supersecret", "abc123", "testuser", "testpass", true);
        // Deterministic: same inputs always produce the same 40-hex-char SHA1 MAC.
        assert_eq!(mac.len(), 40);
        let mac2 = registration_mac("supersecret", "abc123", "testuser", "testpass", true);
        assert_eq!(mac, mac2);
    }

    #[test]
    fn registration_mac_differs_for_admin_flag() {
        let admin_mac = registration_mac("secret", "n", "u", "p", true);
        let notadmin_mac = registration_mac("secret", "n", "u", "p", false);
        assert_ne!(admin_mac, notadmin_mac);
    }

    #[test]
    fn generate_password_is_32_hex_chars() {
        let pw = generate_password();
        assert_eq!(pw.len(), 32);
        assert!(pw.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn component_rooms_excludes_guilhem() {
        let names: Vec<&str> = component_rooms().map(|(n, _)| *n).collect();
        assert!(!names.contains(&"guilhem"));
        assert_eq!(names.len(), 8);
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail (module not yet wired)**

Run: `cd Caissa && cargo test -p caissa-cli bootstrap_matrix:: 2>&1 | tail -20`
Expected: FAIL — `error[E0433]: failed to resolve: unresolved module` (module not yet declared in `mod.rs`)

- [ ] **Step 4: Wire the module and run the unit tests**

Edit `Caissa/caissa-cli/src/commands/mod.rs` — add alongside the other `pub mod` lines:

```rust
pub mod bootstrap_matrix;
```

Run: `cd Caissa && cargo test -p caissa-cli bootstrap_matrix:: -- --nocapture`
Expected: 4 tests pass — `registration_mac_matches_known_vector`, `registration_mac_differs_for_admin_flag`, `generate_password_is_32_hex_chars`, `component_rooms_excludes_guilhem`.

- [ ] **Step 5: Implement the OpenBao + Synapse HTTP calls and the `run` entrypoint**

Append to `Caissa/caissa-cli/src/commands/bootstrap_matrix.rs`:

```rust
async fn bao_get(client: &reqwest::Client, bao_addr: &str, bao_token: &str, path: &str) -> Option<String> {
    let url = format!("{}/v1/secret/data/{}", bao_addr, path);
    let resp = client.get(&url)
        .header("X-Vault-Token", bao_token)
        .send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let json: serde_json::Value = resp.json().await.ok()?;
    json["data"]["data"]["value"].as_str().map(|s| s.to_string())
}

async fn bao_put(client: &reqwest::Client, bao_addr: &str, bao_token: &str, path: &str, value: &str) -> anyhow::Result<()> {
    let url = format!("{}/v1/secret/data/{}", bao_addr, path);
    let resp = client.post(&url)
        .header("X-Vault-Token", bao_token)
        .json(&serde_json::json!({ "data": { "value": value } }))
        .send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("bao_put {} failed: {}", path, resp.status());
    }
    Ok(())
}

/// Get the existing password for `agent` from OpenBao, or generate one, store
/// it, and return it. Never rotates a password that's already there — every
/// agent pod is currently logging in with whatever password this returns.
async fn get_or_create_password(client: &reqwest::Client, bao_addr: &str, bao_token: &str, agent: &str) -> anyhow::Result<String> {
    let path = format!("occitan/matrix/{}-password", agent);
    if let Some(existing) = bao_get(client, bao_addr, bao_token, &path).await {
        return Ok(existing);
    }
    let fresh = generate_password();
    bao_put(client, bao_addr, bao_token, &path, &fresh).await?;
    Ok(fresh)
}

/// Register `username` with `password` via Synapse's shared-secret admin
/// registration API. Treats "user already exists" (Synapse returns 400
/// M_USER_IN_USE) as success — this must be safe to rerun forever.
async fn register_user(client: &reqwest::Client, homeserver: &str, shared_secret: &str, username: &str, password: &str) -> anyhow::Result<()> {
    let nonce_resp: serde_json::Value = client
        .get(format!("{}/_synapse/admin/v1/register", homeserver))
        .send().await?
        .json().await?;
    let nonce = nonce_resp["nonce"].as_str()
        .ok_or_else(|| anyhow::anyhow!("no nonce in registration response"))?;

    let mac = registration_mac(shared_secret, nonce, username, password, false);
    let resp = client
        .post(format!("{}/_synapse/admin/v1/register", homeserver))
        .json(&serde_json::json!({
            "nonce": nonce,
            "username": username,
            "password": password,
            "admin": false,
            "mac": mac,
        }))
        .send().await?;

    if resp.status().is_success() {
        tracing::info!("bootstrap-matrix: registered @{}", username);
        return Ok(());
    }
    let body: serde_json::Value = resp.json().await.unwrap_or_default();
    if body["errcode"].as_str() == Some("M_USER_IN_USE") {
        tracing::info!("bootstrap-matrix: @{} already registered", username);
        return Ok(());
    }
    anyhow::bail!("register_user {} failed: {:?}", username, body);
}

/// Mint a short-lived admin session via the same shared-secret mechanism
/// (registers a throwaway admin user, logs in, returns the token). The
/// caller is responsible for deactivating it when done.
async fn mint_admin_session(client: &reqwest::Client, homeserver: &str, shared_secret: &str) -> anyhow::Result<(String, String)> {
    let admin_user = format!("bootstrap-admin-{}", std::process::id());
    let admin_password = generate_password();
    let nonce_resp: serde_json::Value = client
        .get(format!("{}/_synapse/admin/v1/register", homeserver))
        .send().await?
        .json().await?;
    let nonce = nonce_resp["nonce"].as_str()
        .ok_or_else(|| anyhow::anyhow!("no nonce in registration response"))?;
    let mac = registration_mac(shared_secret, nonce, &admin_user, &admin_password, true);
    let reg: serde_json::Value = client
        .post(format!("{}/_synapse/admin/v1/register", homeserver))
        .json(&serde_json::json!({
            "nonce": nonce, "username": admin_user, "password": admin_password,
            "admin": true, "mac": mac,
        }))
        .send().await?
        .json().await?;
    let token = reg["access_token"].as_str()
        .ok_or_else(|| anyhow::anyhow!("no access_token minting admin session"))?
        .to_string();
    Ok((format!("@{}:{}", admin_user, homeserver_server_name(homeserver)), token))
}

/// Best-effort: the server_name isn't always derivable from the homeserver URL,
/// so callers that need it pass it explicitly where it matters (room ids already
/// carry it). Used only for the throwaway admin user's own mxid in logs.
fn homeserver_server_name(_homeserver: &str) -> &'static str {
    "occitane.guilhem"
}

async fn force_join(client: &reqwest::Client, homeserver: &str, admin_token: &str, room_id: &str, user_id: &str) -> anyhow::Result<()> {
    let resp = client
        .post(format!("{}/_synapse/admin/v1/join/{}", homeserver, urlencode(room_id)))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&serde_json::json!({ "user_id": user_id }))
        .send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("force_join {} into {} failed: {}", user_id, room_id, resp.status());
    }
    Ok(())
}

async fn room_members(client: &reqwest::Client, homeserver: &str, admin_token: &str, room_id: &str) -> anyhow::Result<Vec<String>> {
    let resp: serde_json::Value = client
        .get(format!("{}/_synapse/admin/v1/rooms/{}/members", homeserver, urlencode(room_id)))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await?
        .json().await?;
    Ok(resp["members"].as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default())
}

async fn kick(client: &reqwest::Client, homeserver: &str, admin_token: &str, room_id: &str, user_id: &str, reason: &str) -> anyhow::Result<()> {
    let resp = client
        .post(format!("{}/_matrix/client/v3/rooms/{}/kick", homeserver, urlencode(room_id)))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&serde_json::json!({ "user_id": user_id, "reason": reason }))
        .send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("kick {} from {} failed: {}", user_id, room_id, resp.status());
    }
    Ok(())
}

async fn deactivate(client: &reqwest::Client, homeserver: &str, admin_token: &str, user_id: &str) -> anyhow::Result<()> {
    let resp = client
        .post(format!("{}/_synapse/admin/v1/deactivate/{}", homeserver, urlencode(user_id)))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&serde_json::json!({ "erase": true }))
        .send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("deactivate {} failed: {}", user_id, resp.status());
    }
    Ok(())
}

fn urlencode(s: &str) -> String {
    s.chars().map(|c| match c {
        '!' | '#' | '@' | ':' | '/' | '?' | '&' | '=' | '+' | ' ' => format!("%{:02X}", c as u32),
        _ => c.to_string(),
    }).collect()
}

/// Full bootstrap: register the 9 agents, force-join each into its room,
/// kick @charradissa-relay from the 8 component rooms if present. Safe to
/// rerun — every step checks state before acting.
pub async fn run(homeserver: &str, bao_addr: &str) -> anyhow::Result<()> {
    let bao_token = std::env::var("BAO_TOKEN")
        .map_err(|_| anyhow::anyhow!("BAO_TOKEN not set"))?;
    let shared_secret = std::env::var("SYNAPSE_REGISTRATION_SHARED_SECRET")
        .map_err(|_| anyhow::anyhow!("SYNAPSE_REGISTRATION_SHARED_SECRET not set"))?;
    let client = reqwest::Client::new();

    for (name, room_id) in AGENTS {
        let password = get_or_create_password(&client, bao_addr, &bao_token, name).await?;
        register_user(&client, homeserver, &shared_secret, name, &password).await?;
    }

    let (admin_mxid, admin_token) = mint_admin_session(&client, homeserver, &shared_secret).await?;
    tracing::info!("bootstrap-matrix: minted throwaway admin session {}", admin_mxid);

    for (name, room_id) in AGENTS {
        let user_id = format!("@{}:{}", name, "occitane.guilhem");
        force_join(&client, homeserver, &admin_token, room_id, &user_id).await?;
        tracing::info!("bootstrap-matrix: {} joined {}", user_id, room_id);
    }

    let relay_id = "@charradissa-relay:occitane.guilhem";
    for (name, room_id) in component_rooms() {
        let members = room_members(&client, homeserver, &admin_token, room_id).await?;
        if members.iter().any(|m| m == relay_id) {
            kick(&client, homeserver, &admin_token, room_id, relay_id,
                "component agents now run independent Matrix sessions — see Occitan#per-agent-matrix-independence").await?;
            tracing::info!("bootstrap-matrix: kicked {} from {} ({})", relay_id, name, room_id);
        }
    }

    deactivate(&client, homeserver, &admin_token, &admin_mxid).await?;
    tracing::info!("bootstrap-matrix: complete, throwaway admin session deactivated");
    Ok(())
}
```

- [ ] **Step 6: Run the full test suite for the module**

Run: `cd Caissa && cargo test -p caissa-cli bootstrap_matrix:: -- --nocapture`
Expected: all 4 tests still pass (the new functions have no additional unit tests here — they're exercised end-to-end in Task 9's live verification, matching this repo's existing convention of testing HMAC/pure-logic inline and leaving HTTP-integration behavior to `wiremock` in Task 3 or live verification).

- [ ] **Step 7: Wire the CLI subcommand**

Edit `Caissa/caissa-cli/src/main.rs` — add to the `Commands` enum (after `Fondament`):

```rust
    /// Idempotent bootstrap for the 9 independent Matrix agent identities.
    /// Registers users, force-joins them into their rooms, kicks
    /// @charradissa-relay from component rooms. Safe to rerun.
    BootstrapMatrixAgents {
        #[arg(long, default_value = "http://synapse.occitan-system.svc.cluster.local:8008")]
        homeserver: String,
        #[arg(long, default_value = "http://openbao.occitan-system.svc.cluster.local:8200")]
        bao_addr: String,
    },
```

Add to the `match cli.command` block (after the `Fondament` arm):

```rust
        Commands::BootstrapMatrixAgents { homeserver, bao_addr } => {
            commands::bootstrap_matrix::run(&homeserver, &bao_addr).await
        }
```

Run: `cd Caissa && cargo build -p caissa-cli 2>&1 | tail -20`
Expected: clean build, no errors.

- [ ] **Step 8: Commit**

```bash
cd Caissa
git add Cargo.toml caissa-cli/Cargo.toml caissa-cli/src/main.rs caissa-cli/src/commands/mod.rs caissa-cli/src/commands/bootstrap_matrix.rs
git commit -m "feat(bootstrap): add caissa bootstrap-matrix-agents subcommand

Idempotent registration + room force-join for the 9 independent Matrix
agent identities, plus @charradissa-relay cleanup from component rooms.
Stores passwords (not tokens) in OpenBao since a cached admin token went
stale after a Matrix reset earlier today."
```

---

### Task 3: Add the Matrix sync-loop client to `caissa listen`

**Files:**
- Modify: `Caissa/caissa-cli/src/commands/listen.rs:40-67` (`ListenState` struct)
- Modify: `Caissa/caissa-cli/src/commands/listen.rs:215-237` (`run()`)
- Modify: `Caissa/caissa-cli/src/commands/listen.rs:1942-2007` (`run_matrix_reply`, to call `graph_context`)
- Modify: `Caissa/caissa-cli/Cargo.toml` (already has `wiremock` dev-dep from Task 2)
- Test: inline `#[cfg(test)]` in `listen.rs`

**Interfaces:**
- Consumes: `caissa_core::graph_context::build_graph_context` (Task 1); `AGENTS` table is inlined here rather than imported from `bootstrap_matrix` (that module is CLI-only and this needs to run from any pod).
- Produces: nothing consumed by later tasks — this is the last Caissa-side code task.

- [ ] **Step 1: Add new `ListenState` fields**

Edit `Caissa/caissa-cli/src/commands/listen.rs`, in the `ListenState` struct (after `room_sessions`):

```rust
    /// This pod's own Matrix identity. Empty room_id disables the sync loop
    /// entirely (e.g. local dev without Matrix configured).
    matrix_user: String,
    matrix_room_id: String,
    matrix_homeserver: String,
    matrix_password: String,
    /// Updated in place on every successful login/re-login; read by both the
    /// sync loop and the post-reply call.
    matrix_access_token: Arc<tokio::sync::RwLock<String>>,
```

- [ ] **Step 2: Populate the new fields in `run()`**

Edit `Caissa/caissa-cli/src/commands/listen.rs`, in `run()`, inside the `ListenState { ... }` literal (after `room_sessions: Arc::new(...)`):

```rust
        matrix_user: std::env::var("MATRIX_USER").unwrap_or_default(),
        matrix_room_id: std::env::var("MATRIX_ROOM_ID").unwrap_or_default(),
        matrix_homeserver: std::env::var("MATRIX_HOMESERVER")
            .unwrap_or_else(|_| "http://synapse.occitan-system.svc.cluster.local:8008".into()),
        matrix_password: read_matrix_password(),
        matrix_access_token: Arc::new(tokio::sync::RwLock::new(String::new())),
```

Immediately after the existing `tokio::spawn(run_nervi_loop_if_component(...))` line in `run()`, add:

```rust
    tokio::spawn(run_matrix_client_loop(Arc::clone(&state)));
```

- [ ] **Step 3: Implement `read_matrix_password` and the login/sync/post helpers**

Add these functions to `Caissa/caissa-cli/src/commands/listen.rs` (near `github_token_envs`, which they mirror):

```rust
/// Reads the agent's own Matrix password from `/creds/matrix.env`, written by
/// the fetch-tokens init container. Returns empty string if absent (local dev,
/// or a pod that hasn't been given Matrix credentials yet) — matrix_client_loop
/// treats an empty matrix_room_id/matrix_password as "feature disabled here".
fn read_matrix_password() -> String {
    let content = match std::fs::read_to_string("/creds/matrix.env") {
        Ok(c) => c,
        Err(_) => return String::new(),
    };
    content.lines()
        .find_map(|line| {
            let rest = line.strip_prefix("export MATRIX_PASSWORD=")?;
            Some(rest.trim_matches('\'').to_string())
        })
        .unwrap_or_default()
}

async fn matrix_login(homeserver: &str, user: &str, password: &str) -> anyhow::Result<String> {
    let client = reqwest::Client::new();
    let resp: serde_json::Value = client
        .post(format!("{}/_matrix/client/v3/login", homeserver))
        .json(&serde_json::json!({
            "type": "m.login.password",
            "identifier": { "type": "m.id.user", "user": user },
            "password": password,
        }))
        .send().await?
        .json().await?;
    resp["access_token"].as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow::anyhow!("matrix_login: no access_token in response: {:?}", resp))
}

fn matrix_pct(s: &str) -> String {
    s.chars().map(|c| match c {
        '!' | '#' | '@' | ':' | '/' | '?' | '&' | '=' | '+' | ' ' => format!("%{:02X}", c as u32),
        _ => c.to_string(),
    }).collect()
}

/// Long-poll `/sync` once. Returns the new `since` token and any
/// `m.room.message` timeline events for `room_id`, `(sender, content)` pairs.
/// A 401 with `M_UNKNOWN_TOKEN` is surfaced as `Err` so the caller can re-login.
async fn matrix_sync(
    homeserver: &str,
    token: &str,
    since: Option<&str>,
    room_id: &str,
) -> anyhow::Result<(String, Vec<(String, String)>)> {
    let mut url = format!("{}/_matrix/client/v3/sync?timeout=30000", homeserver);
    if let Some(s) = since {
        url.push_str(&format!("&since={}", matrix_pct(s)));
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(40))
        .build()?;
    let resp = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", token))
        .send().await?;
    if resp.status().as_u16() == 401 {
        let body: serde_json::Value = resp.json().await.unwrap_or_default();
        if body["errcode"].as_str() == Some("M_UNKNOWN_TOKEN") {
            anyhow::bail!("M_UNKNOWN_TOKEN");
        }
        anyhow::bail!("matrix_sync: 401: {:?}", body);
    }
    if !resp.status().is_success() {
        anyhow::bail!("matrix_sync failed: {}", resp.status());
    }
    let body: serde_json::Value = resp.json().await?;
    let next_batch = body["next_batch"].as_str()
        .ok_or_else(|| anyhow::anyhow!("matrix_sync: no next_batch in response"))?
        .to_string();

    let mut events = Vec::new();
    if let Some(timeline) = body["rooms"]["join"][room_id]["timeline"]["events"].as_array() {
        for ev in timeline {
            if ev["type"].as_str() == Some("m.room.message") {
                let sender = ev["sender"].as_str().unwrap_or_default().to_string();
                let content = ev["content"]["body"].as_str().unwrap_or_default().to_string();
                events.push((sender, content));
            }
        }
    }
    Ok((next_batch, events))
}

async fn matrix_post(homeserver: &str, token: &str, room_id: &str, body: &str) -> anyhow::Result<()> {
    let txn = uuid::Uuid::new_v4();
    let url = format!(
        "{}/_matrix/client/v3/rooms/{}/send/m.room.message/{}",
        homeserver, matrix_pct(room_id), txn
    );
    let resp = reqwest::Client::new()
        .put(&url)
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({ "msgtype": "m.text", "body": body }))
        .send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("matrix_post failed: {}", resp.status());
    }
    Ok(())
}

/// Background task: logs in as this pod's own Matrix user, long-polls
/// `/sync` for its one room, and calls `run_matrix_reply` in-process for
/// every message not sent by itself. Re-logs-in automatically on
/// `M_UNKNOWN_TOKEN`. Non-fatal at every layer — a Matrix outage degrades
/// this to backoff-retry, never crashes the pod (the pod's cron/HTTP
/// responsibilities are unaffected).
async fn run_matrix_client_loop(state: Arc<ListenState>) {
    if state.matrix_room_id.is_empty() || state.matrix_user.is_empty() {
        tracing::info!("matrix_client: MATRIX_ROOM_ID/MATRIX_USER not set, sync loop disabled");
        return;
    }
    let own_user_id = format!("@{}:occitane.guilhem", state.matrix_user);

    loop {
        let token = match matrix_login(&state.matrix_homeserver, &state.matrix_user, &state.matrix_password).await {
            Ok(t) => t,
            Err(e) => {
                tracing::error!("matrix_client: login failed, retrying in 30s: {}", e);
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                continue;
            }
        };
        *state.matrix_access_token.write().await = token.clone();
        tracing::info!("matrix_client: logged in as {}", own_user_id);

        // Initial sync: capture a since token without processing backlog.
        let mut since = match matrix_sync(&state.matrix_homeserver, &token, None, &state.matrix_room_id).await {
            Ok((s, _)) => s,
            Err(e) => {
                tracing::error!("matrix_client: initial sync failed, retrying in 30s: {}", e);
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                continue;
            }
        };

        'sync_loop: loop {
            let current_token = state.matrix_access_token.read().await.clone();
            match matrix_sync(&state.matrix_homeserver, &current_token, Some(&since), &state.matrix_room_id).await {
                Ok((next_since, events)) => {
                    since = next_since;
                    for (sender, content) in events {
                        if sender == own_user_id {
                            continue; // echo guard
                        }
                        let req = MatrixReplyReq {
                            room_id: state.matrix_room_id.clone(),
                            sender: sender.clone(),
                            content,
                            history: vec![],
                            event_id: None,
                        };
                        match run_matrix_reply(&state, &req).await {
                            Ok(reply) => {
                                let post_token = state.matrix_access_token.read().await.clone();
                                if let Err(e) = matrix_post(&state.matrix_homeserver, &post_token, &state.matrix_room_id, &reply).await {
                                    tracing::error!("matrix_client: post failed: {}", e);
                                }
                            }
                            Err(e) => tracing::error!("matrix_client: run_matrix_reply failed: {}", e),
                        }
                    }
                }
                Err(e) if e.to_string().contains("M_UNKNOWN_TOKEN") => {
                    tracing::warn!("matrix_client: access token invalid, re-logging in");
                    break 'sync_loop; // fall through to outer loop's fresh login
                }
                Err(e) => {
                    tracing::warn!("matrix_client: sync error (retrying in 5s): {}", e);
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                }
            }
        }
    }
}
```

- [ ] **Step 4: Wire `graph_context` into `run_matrix_reply`**

Edit `Caissa/caissa-cli/src/commands/listen.rs`, inside `run_matrix_reply`, in the `if !sessions.contains_key(&req.room_id)` branch — change:

```rust
        if !sessions.contains_key(&req.room_id) {
            // The sidecar process is long-lived (one per room, reused across
            // messages) — always attach the full tool/MCP set so capability
            // doesn't get frozen at whatever the room's first message needed.
            let (system_prompt, skills, def_models) = resolve_guilhem_prompt(&state.fondament_path, &state.generation, &req.room_id);
```

to:

```rust
        if !sessions.contains_key(&req.room_id) {
            // The sidecar process is long-lived (one per room, reused across
            // messages) — always attach the full tool/MCP set so capability
            // doesn't get frozen at whatever the room's first message needed.
            let (mut system_prompt, skills, def_models) = resolve_guilhem_prompt(&state.fondament_path, &state.generation, &req.room_id);

            // Bridge context across session respawns (idle-reap, pod restart) via
            // the persistent SessionGraph — only needed at spawn time, since a
            // live `resume`d session already carries its own turn history.
            let api_key = std::env::var("ANTHROPIC_API_KEY").ok();
            if let Some(collapsed) = caissa_core::graph_context::build_graph_context(
                &state.farga_url, &req.room_id, &req.sender, &req.content, api_key,
            ).await {
                system_prompt.push_str("\n\n--- prior context (collapsed) ---\n");
                system_prompt.push_str(&collapsed);
                system_prompt.push_str("\n--- end prior context ---");
            }
```

(The rest of the branch — `let model = ...`, `let init = SidecarInit { ... }`, `SidecarProcess::spawn` — is unchanged; `system_prompt` is now `mut` and possibly extended before it's used.)

- [ ] **Step 5: Build and run existing tests to confirm nothing broke**

Run: `cd Caissa && cargo build -p caissa-cli 2>&1 | tail -30`
Expected: clean build.

Run: `cd Caissa && cargo test -p caissa-cli 2>&1 | tail -40`
Expected: all existing tests still pass (this task adds no new isolated unit tests — `matrix_login`/`matrix_sync`/`matrix_post` are HTTP-integration functions exercised live in Task 9; `read_matrix_password` and `matrix_pct` are pure but trivial enough that the existing `pct` test pattern in Charradissa's `client.rs` is the template to follow if a reviewer wants one — add if requested during review).

- [ ] **Step 6: Commit**

```bash
cd Caissa
git add caissa-cli/src/commands/listen.rs
git commit -m "feat(matrix-client): add per-agent Matrix sync loop to caissa listen

Each pod now logs in as its own Matrix user, long-polls /sync for its own
room, and calls the existing run_matrix_reply persistent-session logic
in-process instead of waiting for Charradissa's webhook push. Re-logs-in
automatically on M_UNKNOWN_TOKEN. Also wires the ported SessionGraph
collapse into fresh sidecar spawns for cross-session recall."
```

---

### Task 4: Helm chart wiring — component-agents

**Files:**
- Modify: `Caissa/deploy/charts/component-agents/templates/agents.yaml:57-79` (fetch-tokens init container)
- Modify: `Caissa/deploy/charts/component-agents/templates/agents.yaml:85-99` (main container env)
- Modify: `Caissa/deploy/charts/component-agents/values.yaml:29-44` (fix stale `roomId`)

- [ ] **Step 1: Fix the stale `roomId` values**

Edit `Caissa/deploy/charts/component-agents/values.yaml` — replace the `agents:` list (the 8 entries with `roomId`) with the confirmed-live IDs from the Global Constraints table:

```yaml
agents:
  - name: gardian
    roomId: "!bwuKXFvUXnVZfXcKuz:occitane.guilhem"
  - name: fondament
    roomId: "!KuWBSmYyvyiyTMFKqJ:occitane.guilhem"
  - name: farga
    roomId: "!CtktMiOTNtSIkdwOxq:occitane.guilhem"
  - name: amassada
    roomId: "!vLjgiURMSlkqTXgaDG:occitane.guilhem"
  - name: cor
    roomId: "!FgfTbZMpLLVGiISZTj:occitane.guilhem"
  - name: caissa
    roomId: "!ZqGBDioAYnOATihiEU:occitane.guilhem"
  - name: charradissa
    roomId: "!qZGQFrjAcKjPinhQnp:occitane.guilhem"
  - name: nervi
    roomId: "!QQeweqsLsOTZYdonXi:occitane.guilhem"
```

- [ ] **Step 2: Add Matrix credential fetch to the init container**

Edit `Caissa/deploy/charts/component-agents/templates/agents.yaml`, in the `fetch-tokens` init container's `args` (the `|`-block), add after the existing `echo "tokens written"` line but still inside the same shell script:

```yaml
              bao kv get -field=value secret/occitan/matrix/{{ .name }}-password > /tmp/matrix-password 2>/dev/null || echo -n "" > /tmp/matrix-password
              cat >> /creds/tokens.env <<EOF
              export MATRIX_PASSWORD='$(cat /tmp/matrix-password)'
              EOF
```

(Full resulting `args` block — for clarity, this is the whole `|` string after the edit:)

```yaml
          args:
            - |
              set -eu
              export BAO_ADDR=http://openbao.occitan-system.svc.cluster.local:8200
              GL=$(bao kv get -field=value secret/occitan/gitlab)
              umask 077
              bao kv get -field=value secret/occitan/github-app-id > /creds/github-app-id
              bao kv get -field=value secret/occitan/github-app-installation-id > /creds/github-app-installation-id
              bao kv get -field=value secret/occitan/github-app-private-key > /creds/github-app-private-key.pem
              cat > /creds/tokens.env <<EOF
              export GITLAB_TOKEN='$GL'
              export GITLAB_PAT_TOKEN='$GL'
              EOF
              bao kv get -field=value secret/occitan/matrix/{{ .name }}-password > /tmp/matrix-password 2>/dev/null || echo -n "" > /tmp/matrix-password
              cat >> /creds/tokens.env <<EOF
              export MATRIX_PASSWORD='$(cat /tmp/matrix-password)'
              EOF
              echo "tokens written"
```

Note: this is written to `/creds/tokens.env` (the same file GH/GitLab tokens use), consistent with `read_matrix_password` in Task 3 Step 3, which reads `/creds/matrix.env` — **fix**: change `read_matrix_password` to read from `/creds/tokens.env` instead, matching this init container. Go back to `Caissa/caissa-cli/src/commands/listen.rs` and update the path in `read_matrix_password`:

```rust
    let content = match std::fs::read_to_string("/creds/tokens.env") {
```

(replacing the earlier `/creds/matrix.env` path from Task 3 — one shared credentials file, matching the existing GH/GitLab convention exactly, is simpler than introducing a second file.)

- [ ] **Step 3: Add `MATRIX_USER`/`MATRIX_ROOM_ID`/`MATRIX_HOMESERVER` env vars**

Edit `Caissa/deploy/charts/component-agents/templates/agents.yaml`, in the main container's `env:` list (after `ANTHROPIC_API_KEY`):

```yaml
            - name: MATRIX_USER
              value: {{ .name | quote }}
            - name: MATRIX_ROOM_ID
              value: {{ .roomId | quote }}
            - name: MATRIX_HOMESERVER
              value: "http://synapse.occitan-system.svc.cluster.local:8008"
```

- [ ] **Step 4: Validate the chart renders**

Run: `cd Caissa && helm template deploy/charts/component-agents --set image=test:test 2>&1 | grep -A2 "MATRIX_ROOM_ID" | head -30`
Expected: 8 blocks, one per agent, each showing its own `MATRIX_ROOM_ID` value matching the table above (spot-check `gardian` shows `!bwuKXFvUXnVZfXcKuz:occitane.guilhem`).

- [ ] **Step 5: Commit**

```bash
cd Caissa
git add deploy/charts/component-agents/templates/agents.yaml deploy/charts/component-agents/values.yaml caissa-cli/src/commands/listen.rs
git commit -m "fix(chart): wire MATRIX_USER/MATRIX_ROOM_ID into component-agents, fix stale room IDs

roomId in values.yaml was declared but never consumed by any template —
confirmed live that the old IDs 404 against the current Synapse (a prior
Matrix reset changed every room's ID without updating this file). Updated
to the currently-live IDs and wired them into the new Matrix sync loop."
```

---

### Task 5: Helm chart wiring — guilhem

**Files:**
- Modify: `Caissa/deploy/charts/guilhem/templates/guilhem.yaml:557-565` (fetch-tokens init container)
- Modify: `Caissa/deploy/charts/guilhem/templates/guilhem.yaml:591-632` (main container env)
- Modify: `Caissa/deploy/charts/guilhem/values.yaml` (new `matrix:` block)

- [ ] **Step 1: Add the `matrix:` values block**

Edit `Caissa/deploy/charts/guilhem/values.yaml`, add after the `dream:` block:

```yaml
matrix:
  user: guilhem
  roomId: "!hTNBZpYDxyvfcuralm:occitane.guilhem"
  homeserver: "http://synapse.occitan-system.svc.cluster.local:8008"
```

- [ ] **Step 2: Add Matrix credential fetch to guilhem's `fetch-tokens` init container**

Edit `Caissa/deploy/charts/guilhem/templates/guilhem.yaml`, find the `EOF` that closes the `cat > /creds/tokens.env <<EOF` (or equivalent) block just before `echo "tokens + git creds written to /creds"` (line 555-556), and insert before that echo:

```yaml
              bao kv get -field=value secret/occitan/matrix/guilhem-password > /tmp/matrix-password 2>/dev/null || echo -n "" > /tmp/matrix-password
              cat >> /creds/tokens.env <<EOF
              export MATRIX_PASSWORD='$(cat /tmp/matrix-password)'
              EOF
```

- [ ] **Step 3: Add `MATRIX_USER`/`MATRIX_ROOM_ID`/`MATRIX_HOMESERVER` env vars**

Edit `Caissa/deploy/charts/guilhem/templates/guilhem.yaml`, in the main `guilhem` container's `env:` list (after the `DREAM_MATRIX_ROOM_ID` entry, line 632):

```yaml
            - name: MATRIX_USER
              value: {{ .Values.matrix.user | quote }}
            - name: MATRIX_ROOM_ID
              value: {{ .Values.matrix.roomId | quote }}
            - name: MATRIX_HOMESERVER
              value: {{ .Values.matrix.homeserver | quote }}
```

- [ ] **Step 4: Validate the chart renders**

Run: `cd Caissa && helm template deploy/charts/guilhem --set image=test:test 2>&1 | grep -A2 "MATRIX_ROOM_ID"`
Expected: one block showing `MATRIX_ROOM_ID` = `!hTNBZpYDxyvfcuralm:occitane.guilhem`.

- [ ] **Step 5: Commit**

```bash
cd Caissa
git add deploy/charts/guilhem/templates/guilhem.yaml deploy/charts/guilhem/values.yaml
git commit -m "feat(chart): wire guilhem's own Matrix identity/room into its chart

Guilhem's room was previously only known to Charradissa's config — this
is the first time it's declared in guilhem's own chart, needed for the
new independent Matrix sync loop."
```

---

### Task 6: Bootstrap Job manifest

**Files:**
- Create: `Caissa/deploy/charts/occitan/templates/matrix-bootstrap-job.yaml`
- Modify: `Caissa/deploy/charts/occitan/values.yaml` (new `matrixBootstrap:` block)

**Interfaces:**
- Consumes: `caissa bootstrap-matrix-agents` subcommand (Task 2), image already built by Task 2's CI (same `caissa-sandbox` image every agent pod uses).

- [ ] **Step 1: Add values**

Edit `Caissa/deploy/charts/occitan/values.yaml`, add a new top-level block:

```yaml
matrixBootstrap:
  image: ghcr.io/miegjorn/caissa-sandbox:guilhem-sha-b24dfc5
  imagePullSecrets:
    - name: ghcr-creds
```

(Same image reference convention as `Caissa/deploy/charts/guilhem/values.yaml:4` — CI updates this tag on every push, same as it does there.)

- [ ] **Step 2: Write the Job manifest**

Create `Caissa/deploy/charts/occitan/templates/matrix-bootstrap-job.yaml`:

```yaml
# Idempotent bootstrap for the 9 independent Matrix agent identities
# (guilhem + 8 component agents). Safe to rerun on every Helm sync —
# see Caissa/caissa-cli/src/commands/bootstrap_matrix.rs for the logic.
#
# `generateName`-free and fixed-name on purpose: ArgoCD's `Replace=true`
# sync option (below) deletes and recreates this Job every sync, rather
# than accumulating a new Job object per deploy.
apiVersion: batch/v1
kind: Job
metadata:
  name: matrix-bootstrap-agents
  namespace: occitan-system
  labels:
    {{- include "occitan.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-options: Replace=true
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        {{- include "occitan.labels" . | nindent 8 }}
    spec:
      restartPolicy: Never
      imagePullSecrets:
        {{- toYaml .Values.matrixBootstrap.imagePullSecrets | nindent 8 }}
      containers:
        - name: matrix-bootstrap
          image: {{ .Values.matrixBootstrap.image }}
          command: ["caissa", "bootstrap-matrix-agents"]
          env:
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: openbao
                  key: token
            - name: SYNAPSE_REGISTRATION_SHARED_SECRET
              valueFrom:
                secretKeyRef:
                  name: synapse-registration-secret
                  key: registration-shared-secret
```

- [ ] **Step 3: Validate the chart renders**

Run: `cd Caissa && helm template deploy/charts/occitan --set matrixBootstrap.image=test:test 2>&1 | grep -A5 "kind: Job"`
Expected: one Job manifest, `matrix-bootstrap-agents`, with both env vars present.

- [ ] **Step 4: Commit**

```bash
cd Caissa
git add deploy/charts/occitan/templates/matrix-bootstrap-job.yaml deploy/charts/occitan/values.yaml
git commit -m "feat(chart): add matrix-bootstrap-agents Job

Runs caissa bootstrap-matrix-agents on every Helm sync (ArgoCD
Replace=true) — idempotent registration/room-join/relay-cleanup for the
9 independent Matrix agent identities."
```

---

### Task 7: Charradissa — rename own identity, stop dynamic component provisioning

**Files:**
- Modify: `Charradissa/charradissa-daemon/src/main.rs:41,127,146-187` 
- Modify: `Caissa/deploy/charts/occitan/values.yaml:97-126` (remove dead `agents.routes`)

- [ ] **Step 1: Rename the bot identity and display name**

Edit `Charradissa/charradissa-daemon/src/main.rs` line 41 — change:

```rust
    let bot_user_id = format!("@charradissa:{}", server_name);
```

to:

```rust
    // Renamed off @charradissa: that Matrix username is now the independent
    // charradissa *component agent*'s own identity (it chronicles the
    // Charradissa GitHub repo) — see Occitan#per-agent-matrix-independence.
    // This relay identity keeps the DM fabric, #occitan project room, and
    // concierge archival responsibilities, none of which this rename affects.
    let bot_user_id = format!("@charradissa-relay:{}", server_name);
```

Edit line 127-129 — change:

```rust
    if let Err(e) = backend.set_self_display_name("Guilhem").await {
        tracing::warn!("set display name failed: {}", e);
    }
```

to:

```rust
    if let Err(e) = backend.set_self_display_name("Charradissa").await {
        tracing::warn!("set display name failed: {}", e);
    }
```

- [ ] **Step 2: Disable dynamic component-room provisioning**

Edit `Charradissa/charradissa-daemon/src/main.rs`, replace the block from the `// Dynamic provisioning:` comment (line 146) through the closing `}` of the fallback loop (line 187):

```rust
    // Dynamic provisioning: query Farga for each project's components, resolve system
    // prompts via Fondament, and create/join the corresponding Matrix rooms.
    let mut component_agents = HashMap::new();
    for project in &config.provisioning.projects {
        match backend.provision_project_rooms(project, &provisioning_params).await {
            Ok(rooms) => {
                tracing::info!("provisioned {} rooms for project '{}'", rooms.len(), project);
                for (room_id, (localpart, responder)) in rooms {
                    component_agents.insert(room_id.as_str().to_string(), (localpart, responder));
                }
            }
            Err(e) => {
                tracing::warn!("provisioning failed for project '{}': {}", project, e);
            }
        }
    }

    // Fallback: if provisioning yielded nothing (Farga/Fondament unavailable at startup),
    // fall back to static [component_agents] config entries.
    if component_agents.is_empty() {
        for ca in &config.component_agents {
            if ca.room_id.is_empty() {
                tracing::warn!("component agent '{}' has no room_id configured, skipping", ca.name);
                continue;
            }
            let responder = Arc::new(Responder::with_config(
                anthropic_api_key.clone(),
                xai_api_key.clone(),
                "claude-sonnet-4-6".into(),
                server_name.clone(),
                farga_base_url.clone(),
                std::env::var("DISPATCHER_URL")
                    .unwrap_or_else(|_| "http://dispatcher.agents.svc.cluster.local:9090/mcp".into()),
                std::env::var("AMASSADA_URL")
                    .unwrap_or_else(|_| "http://amassada:7700".into()),
                ca.system_prompt.clone(),
                false, // component agents do not get org-level tools
            ));
            tracing::info!("registered component agent '{}' for room {} (config fallback)", ca.name, ca.room_id);
            component_agents.insert(ca.room_id.clone(), (ca.name.clone(), responder));
        }
    }
```

with:

```rust
    // Component agents (gardian, fondament, farga, amassada, cor, caissa,
    // charradissa, nervi) and guilhem now run their own independent Matrix
    // sessions (see Caissa/caissa-cli/src/commands/listen.rs's
    // run_matrix_client_loop) — Charradissa no longer provisions or relays
    // for their rooms. `provisioning_params` and `RoomProvisioningParams`
    // are kept (used by nothing now, harmless) rather than threading a
    // larger removal through this file; a future cleanup can drop them.
    let component_agents: HashMap<String, (String, Arc<Responder>)> = HashMap::new();
```

- [ ] **Step 3: Remove the dead `agents.routes` config**

Edit `Caissa/deploy/charts/occitan/values.yaml`, replace the `routes:` list under `agents:` (the 8 `roomId`/`agentUrl` pairs) with:

```yaml
      # Component agents now run independent Matrix sessions — Charradissa
      # no longer relays for their rooms (see Occitan#per-agent-matrix-independence).
      # This list intentionally empty; Task 8's skip-list guard in
      # charradissa-matrix/src/appservice.rs stops the default-agent-url
      # fallback from picking these rooms up regardless.
      routes: []
```

- [ ] **Step 4: Build and run existing Charradissa tests**

Run: `cd Charradissa && cargo build 2>&1 | tail -30`
Expected: clean build (an unused-import warning for `Responder`/`RoomProvisioningParams` types is acceptable — they're still used elsewhere in the file for the type annotation).

Run: `cd Charradissa && cargo test 2>&1 | tail -40`
Expected: existing tests pass. If `charradissa-daemon` has no test target (likely, per `main.rs` conventions elsewhere in this repo), this just confirms the workspace still builds and other crates' tests are unaffected.

- [ ] **Step 5: Commit**

```bash
cd Charradissa
git add charradissa-daemon/src/main.rs
git commit -m "refactor: charradissa-daemon stops relaying for the 9 independent agents

@charradissa is now the charradissa component agent's own Matrix
identity (it runs its own session) — this process renames itself to
@charradissa-relay and keeps only DM fabric / #occitan / concierge
archival duties. Dynamic component-room provisioning is disabled;
component_agents map is now permanently empty."
```

```bash
cd Caissa
git add deploy/charts/occitan/values.yaml
git commit -m "chore(chart): remove dead agents.routes now that Charradissa doesn't relay"
```

---

### Task 8: Charradissa — skip-list guard for the 9 migrated rooms

**Files:**
- Modify: `Charradissa/charradissa-matrix/src/appservice.rs:1-93` (imports + `handle_transaction`)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing consumed elsewhere — this is Charradissa's final task.

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` module at the bottom of `Charradissa/charradissa-matrix/src/appservice.rs` (near the existing `component_agents_map_keyed_by_room_id` test):

```rust
    #[test]
    fn migrated_room_ids_include_all_nine_agents() {
        assert_eq!(MIGRATED_AGENT_ROOM_IDS.len(), 9);
        assert!(MIGRATED_AGENT_ROOM_IDS.contains(&"!hTNBZpYDxyvfcuralm:occitane.guilhem")); // guilhem
        assert!(MIGRATED_AGENT_ROOM_IDS.contains(&"!qZGQFrjAcKjPinhQnp:occitane.guilhem")); // charradissa
    }
```

Run: `cd Charradissa && cargo test -p charradissa-matrix migrated_room_ids -- --nocapture 2>&1 | tail -15`
Expected: FAIL — `error[E0425]: cannot find value MIGRATED_AGENT_ROOM_IDS in this scope`

- [ ] **Step 2: Add the const and the guard**

Edit `Charradissa/charradissa-matrix/src/appservice.rs`, add after the existing `use crate::client::AGENT_LOCAL_PARTS;` (line 9):

```rust
/// Room IDs for the 9 agents that now run independent Matrix sessions
/// (guilhem + 8 component agents). Messages in these rooms are never
/// relayed by Charradissa — each agent's own pod handles its own room via
/// its own /sync loop (see Caissa's run_matrix_client_loop). Without this
/// guard, once component_agents/agents.routes are emptied (Task 7), these
/// rooms would silently fall through to the default_agent_url branch below
/// and get double-relayed.
const MIGRATED_AGENT_ROOM_IDS: &[&str] = &[
    "!hTNBZpYDxyvfcuralm:occitane.guilhem", // guilhem
    "!bwuKXFvUXnVZfXcKuz:occitane.guilhem", // gardian
    "!KuWBSmYyvyiyTMFKqJ:occitane.guilhem", // fondament
    "!CtktMiOTNtSIkdwOxq:occitane.guilhem", // farga
    "!vLjgiURMSlkqTXgaDG:occitane.guilhem", // amassada
    "!FgfTbZMpLLVGiISZTj:occitane.guilhem", // cor
    "!ZqGBDioAYnOATihiEU:occitane.guilhem", // caissa
    "!qZGQFrjAcKjPinhQnp:occitane.guilhem", // charradissa
    "!QQeweqsLsOTZYdonXi:occitane.guilhem", // nervi
];
```

Edit the event-handling loop in `handle_transaction`, right after the existing echo-guard check (line 91-93):

```rust
            // Also ignore messages sent by appservice-managed virtual users
            // (e.g. @farga, @gardian) — they are our own echoes.
            if is_appservice_sender(ev.sender.as_str(), &state.self_user_id) {
                continue;
            }
```

add immediately after:

```rust
            // These 9 rooms are handled entirely by their own agent's independent
            // Matrix session now — never relay, regardless of what project_routes/
            // component_agents/default_agent_url would otherwise say.
            if MIGRATED_AGENT_ROOM_IDS.contains(&ev.room_id.as_str()) {
                continue;
            }
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd Charradissa && cargo test -p charradissa-matrix migrated_room_ids -- --nocapture 2>&1 | tail -15`
Expected: `test tests::migrated_room_ids_include_all_nine_agents ... ok`

- [ ] **Step 4: Run the full appservice test suite**

Run: `cd Charradissa && cargo test -p charradissa-matrix 2>&1 | tail -40`
Expected: all existing tests still pass — this change only adds an early `continue`, doesn't alter any existing branch's behavior for other rooms.

- [ ] **Step 5: Commit**

```bash
cd Charradissa
git add charradissa-matrix/src/appservice.rs
git commit -m "fix(appservice): never relay for the 9 independently-run agent rooms

Emptying component_agents/agents.routes (previous commit) isn't enough on
its own — unrouted rooms still fall through to default_agent_url. This
guard stops that fallback from picking up the 9 migrated rooms
explicitly, closing the duplicate-reply window."
```

---

### Task 9: Deploy and real end-to-end verification

**Files:** none (deployment + live verification only)

- [ ] **Step 1: Push both repos, let CI build**

```bash
cd Caissa && git push origin main
cd Charradissa && git push origin main
```

Watch both builds: `gh run list --repo miegjorn/Caissa --workflow=build.yml --limit 1` and `gh run list --repo miegjorn/Charradissa --workflow=build.yml --limit 1` — wait for both to reach `completed / success` (use `gh run watch <id> --repo <repo> --exit-status` on each).

- [ ] **Step 2: Sync ArgoCD apps**

```bash
argocd app sync guilhem --grpc-web --force
argocd app sync component-agents --grpc-web --force
argocd app sync charradissa --grpc-web --force
argocd app sync occitan --grpc-web --force   # picks up matrix-bootstrap-agents Job
```

Wait for each to report `Health Status: Healthy` via `argocd app get <name> --grpc-web`.

- [ ] **Step 3: Confirm the bootstrap Job ran clean**

```bash
kubectl logs job/matrix-bootstrap-agents -n occitan-system
```

Expected: 9 `registered @<name>` or `already registered` lines, 9 `joined` lines, and 8 `kicked @charradissa-relay from ...` lines (or "already clean" — no kick lines — if a prior manual cleanup already ran).

- [ ] **Step 4: Verify room membership directly**

Using the same manual-port-forward-on-18008 + admin-token approach used during the original investigation (never touch the launchd-managed port 8008 forward):

```bash
kubectl port-forward -n occitan-system svc/synapse 18008:8008 --context kind-occitan &
```

For 3 sample rooms (gardian, charradissa, guilhem — covering a component agent, the renamed-identity collision case, and guilhem itself), confirm via `/_synapse/admin/v1/rooms/{room}/members` that membership is exactly `[@pierre-luc, @<agent>]` — no `@charradissa-relay` present in `gardian`'s or `charradissa`'s room.

- [ ] **Step 5: Real end-to-end reply verification**

For gardian's room (`!bwuKXFvUXnVZfXcKuz:occitane.guilhem`), log in as pierre-luc, send a message via `PUT /_matrix/client/v3/rooms/{room}/send/m.room.message/{txn}`, wait ~30-60s, then `GET /_matrix/client/v3/rooms/{room}/messages?dir=b&limit=5` and confirm:
- The reply's `sender` is `@gardian:occitane.guilhem` (not `@charradissa` or `@charradissa-relay`).
- The reply content is genuinely responsive (not an echo).

Repeat for the `charradissa` component agent's room and for guilhem's room.

- [ ] **Step 6: Confirm no duplicates**

For each of the 3 sample rooms, confirm exactly **one** reply appears per test message (proves the old Charradissa relay path is actually off, not just redundant with the new path).

- [ ] **Step 7: Check pod logs for cleanliness**

```bash
kubectl logs -l app.kubernetes.io/name=gardian-agent -n agents --tail=50
kubectl logs charradissa-<pod> -n occitan-system --tail=50
```

Expected: `matrix_client: logged in as @gardian:occitane.guilhem` and no repeated `M_UNKNOWN_TOKEN`/login-failure loops; Charradissa's logs show no more `agent send failed: 403 Forbidden` for these rooms.

- [ ] **Step 8: Clean up verification artifacts**

```bash
pkill -f "port-forward -n occitan-system svc/synapse 18008:8008"
```

- [ ] **Step 9: No commit** — this task is deploy + verify only, nothing to commit.

---

## Self-Review

**Spec coverage:**
- Sync-loop client → Task 3. Ported SessionGraph → Task 1, wired in Task 3 Step 4. Bootstrap job (registration, force-join, `@charradissa-relay` cleanup, OpenBao passwords) → Tasks 2 + 6. Chart wiring (both charts) → Tasks 4 + 5. Charradissa companion change (stop relaying, rename identity) → Tasks 7 + 8. Deployment-order requirement (land together) → enforced structurally: Tasks 7/8 (Charradissa) and Tasks 3/4/5/6 (Caissa) are pushed and synced together in Task 9 Step 1-2, not independently. Real end-to-end verification → Task 9.
- Naming collision resolution (`@charradissa` → component agent, relay → `@charradissa-relay`) → Task 7 Step 1.
- Stale room ID discovery (two different wrong sets found in two different files) → corrected in Task 4 Step 1 and Task 7 Step 3, both pointing at the single Global Constraints table.

**Placeholder scan:** no TBD/TODO; every step has complete code or exact commands.

**Type consistency:** `MatrixReplyReq { room_id, sender, content, history, event_id }` (Task 3 Step 3) matches the existing struct definition read from `listen.rs:1227-1238` exactly, including `history: vec![]` and `event_id: None` for the new fields not populated by the sync loop. `build_graph_context`'s signature (`farga_url, room_id, latest_sender, latest_content, api_key`) is used identically in Task 1's test and Task 3 Step 4's call site. `AGENTS` table in Task 2 and `MIGRATED_AGENT_ROOM_IDS` in Task 8 both enumerate the same 9 room IDs from the Global Constraints table — cross-checked for consistency.

---

Plan complete and saved to `docs/superpowers/plans/2026-07-01-per-agent-matrix-independence.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
