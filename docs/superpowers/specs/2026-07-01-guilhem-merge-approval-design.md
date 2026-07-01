# Guilhem PR-Merge Approval — Layered Enforcement

## Problem

Guilhem's PR review/merge procedure is already declared in `Fondament/definitions/fondament/guilhem.yaml`: a Class 1-4 risk table (`system-defence.md`), a review protocol (`gh pr diff` → evaluate → approve only at high confidence → `gh pr merge`), and an escalation tool (`matrix_request_approval`) for Class 3/4 changes. None of it is structurally enforced:

- `matrix_request_approval` (`charradissa-matrix/src/mcp.rs:274`) posts to Matrix and returns advisory text ("stop and wait") immediately — nothing stops Guilhem from proceeding to merge in the same or a later turn.
- No GitHub branch protection or CODEOWNERS exists on any of the 9 repos — `gh pr merge` succeeds unconditionally for anyone holding the shared `occitan/github` token.
- The `occitan-code-approval` Matrix room referenced by the protocol is never provisioned — `matrix-reset.sh` creates the 9 component rooms + Occitan space but not this one, and `APPROVAL_ROOM_ID` isn't wired into the guilhem Helm chart (charradissa-daemon logs a warning and fails to post if unset).
- As of 2026-07-01, the interactive Bash approval prompt — previously the one real backstop against an unreviewed `kubectl`/`gh` action — was removed stack-wide (`defaultMode: bypassPermissions` in `Caissa/sandbox/entrypoint.sh`), making this gap more consequential than before.

## Goals

- Guilhem continues to self-merge Class 1/2 PRs autonomously — no new friction there.
- For Class 3/4 PRs, or any PR touching an architecturally-sensitive path, Guilhem must not be able to merge without Pierre-Luc's involvement, enforced at more than one layer so no single failure (LLM non-compliance, a missed persona instruction, a stuck Matrix room) results in a silent unreviewed merge.
- No new bot identity / GitHub App for Guilhem — out of scope by explicit decision. The GitHub-side gate is the final, most authoritative layer, and Guilhem is deliberately excluded from acting within it (no review, no merge attempt) rather than trying to distinguish his reviews from Pierre-Luc's programmatically.

## Non-goals

- Building a separate GitHub bot/machine identity for Guilhem.
- Changing Class 1/2 behavior.
- Retrofitting this onto component agents — they don't open PRs directly reviewed by this mechanism; only Guilhem's merge authority is in scope (component agents already route all cross-component tasking through Guilhem per his persona).

## Architecture

```
Component agent opens PR
        │
        ▼
Guilhem reviews (gh pr diff / gh pr view)
        │
        ├─ Class 1/2, no protected path touched
        │       → gh pr review --approve → gh pr merge --squash   [autonomous, unchanged]
        │
        └─ Class 3/4 OR touches a CODEOWNERS-protected path
                → does NOT call review/merge (Layer 1 rule)
                → matrix_request_approval(component, description)   [Layer 2: blocks]
                        │
                        ├─ Pierre-Luc /approve or /reject in Matrix → unblocks Guilhem's turn
                        └─ timeout → fail closed, re-notify, Guilhem's turn ends without merging
                │
                → Pierre-Luc separately reviews + merges on GitHub himself
                        (Layer 3: branch protection requires his review before merge
                         is even possible — structurally independent of Matrix)
```

### Layer 1 — Persona rule (Fondament)

Update `guilhem.yaml`'s PR review protocol (currently step 8, "If the PR is architectural (Class 3): use matrix_request_approval... before merging") to be unambiguous: Guilhem must not call `gh pr review --approve` or `gh pr merge` at all for Class 3/4 or protected-path PRs — not "review carefully then decide," a hard stop. Update `system-defence.md` if its Class 1-4 wording currently implies Guilhem still merges after approval arrives.

### Layer 2 — Blocking `matrix_request_approval` (Charradissa)

Currently: registers a `PersistentApprovalQueue` entry (JSON file, survives pod restarts), posts to Matrix, returns immediately. Change `charradissa-matrix/src/mcp.rs:274`'s handler to poll the queue after posting until status is `Approved`/`Rejected`, or until `APPROVAL_TIMEOUT_MINUTES` (new env var, default 30) elapses. On timeout: treat as rejected, write a Farga signal (`source="guilhem-escalation-timeout"`), return a rejection result so Guilhem's turn ends without merging.

**Room provisioning (new — the gap Pierre-Luc flagged):**
- Add `ROOM_APPROVAL=$(create_room "Code Approval" "occitan-code-approval")` to `Caissa/scripts/matrix-reset.sh`'s Step 4, alongside the 9 existing rooms, and add it as an Occitan space child in Step 5.
- Wire `APPROVAL_ROOM_ID` into the guilhem Helm chart (`Caissa/deploy/charts/guilhem/`) as an env var sourced from the room ID matrix-reset.sh outputs, same pattern as the other component room IDs consumed by `charradissa.toml`.

### Layer 3 — CODEOWNERS + branch protection (all 9 repos)

New `.github/CODEOWNERS` in Gardian, Fondament, Farga, Amassada, Charradissa, Cor, Caissa, nervi, Occitan naming Pierre-Luc's GitHub handle as required reviewer for:
- `Caissa/deploy/**` (Helm charts, RBAC manifests)
- `Fondament/definitions/fondament/**` (agent personas, `system-defence.md`)
- `.github/CODEOWNERS` itself (so Guilhem can't widen his own leash unreviewed)

Branch protection on `main`: "require pull request reviews before merging" + "require review from Code Owners." No separate bot identity for Guilhem — accepted residual risk is that the shared `occitan/github` token could technically self-satisfy a review; this is mitigated (not eliminated) by Layer 1 forbidding the attempt outright.

## Data flow / error handling

- Approval records persist to JSON — a Guilhem pod restart mid-wait doesn't lose the escalation; Pierre-Luc can still `/approve` a pending record, and the next cron tick (chronicle/dream) picks up the resolved state.
- Fail-closed on timeout is a real behavior change: today nothing times out, so a stuck escalation currently defaults to neither progressing nor being cleaned up. After this change, timeout = rejection, requiring explicit human action to revive it.
- Every escalation outcome (approved/rejected/timed out) writes a Farga signal under `source="guilhem-review"`, extended to carry the classification (Class 3/4, or which protected path triggered it).

## Testing

- Extend `Charradissa/charradissa-core/tests/approval_tests.rs` with a timeout case for the in-memory `ApprovalQueue`.
- New integration test for the MCP handler: register → simulate a delayed `/approve` arriving after the poll starts → confirm the tool call itself blocks until resolution, not just that the queue record changes.
- Layer 3 isn't unit-testable — verify manually once: open a test PR touching a protected path (e.g. a no-op change under `Caissa/deploy/`) and confirm GitHub refuses merge without Pierre-Luc's review.
- Layer 2 room provisioning: run `matrix-reset.sh` in a dev cluster, confirm `occitan-code-approval` room exists and `APPROVAL_ROOM_ID` is populated in the guilhem pod's env.

## Known limitations (accepted, not solved here)

- Guilhem's GitHub token is the same token Pierre-Luc's own `gh`/`git` operations would use if seeded from his shell — no identity separation. A determined or malfunctioning Guilhem could technically issue an approving review that appears to come from Pierre-Luc's account. Layer 1's hard behavioral rule is the only defense against this specific case; building a separate bot identity to close it structurally is explicitly out of scope for this design.
