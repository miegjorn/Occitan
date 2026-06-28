# Dream — nightly consolidation

Dream is a daily self-observation session that runs at 03:00 UTC. The stack reads its own recent history, identifies improvement opportunities, and creates GitHub issues for actionable gaps.

## Protocol

Three phases run sequentially in a single Claude session (Guilhem, `claude-sonnet-4-6`):

### 1. Gather
- Farga signals from the past 24h via `search_signals(since=yesterday)`
- GitHub commits (past 24h), open issues, and open PRs across all 8 repos
- Farga project context (current todos, trajectory)

### 2. Synthesize
- What was built or fixed in the past 24h
- Cross-repo implications (a change in one repo that creates a gap in another)
- Pattern signals: recurring themes across multiple signals pointing to a structural issue
- Architectural drift: docs, stubs, or integrations that have fallen behind code
- Stack trajectory: what does today's activity imply about where the stack is heading?

### 3. Act
For each improvement opportunity (3–8 per dream, quality over quantity):
1. Verify no duplicate open issue exists
2. Create a GitHub issue in the appropriate repo with context and proposed approach
3. Record in the dream report

The dream report is written to Farga as a `source: dream` signal and optionally posted to a Matrix room.

## Infrastructure

- **Trigger**: `POST /trigger/dream` on the Guilhem pod (`caissa listen`)
- **CronJob**: `guilhem-dream` in the `agents` namespace, `0 3 * * *`, `concurrencyPolicy: Forbid`, 30-minute deadline
- **Canvas**: `canvases/stdlib/dream-session.yaml` in Amassada (current reference; target architecture for full Amassada-mediated session)
- **Model**: `claude-sonnet-4-6` (configurable via `dream.model` in guilhem values)

## Configuration

In `deploy/charts/guilhem/values.yaml`:

```yaml
dream:
  schedule: "0 3 * * *"      # daily 03:00 UTC
  matrixRoomId: ""            # empty = Matrix posting disabled
  model: "claude-sonnet-4-6"
```

Set `DREAM_MATRIX_ROOM_ID` env var or `dream.matrixRoomId` to post the dream summary to a Matrix room after each run.

## Distinction from manual sweeps

The nightly dream is lightweight: it reads Farga and the GitHub API — no repo clones. It surfaces what the stack noticed about itself.

A manual deep sweep (like `caissa sweep` or a session with Claude Code) clones all repos and does structural analysis. Both have their place: dream runs automatically every night, deep sweeps are intentional and more thorough.

## Farga record

Each dream writes a signal with `source: dream` to the `occitan` project in Farga. These accumulate as the stack's long-term self-observation record — the sequence of what the stack noticed about itself, night after night.
