---
status: proposed
date: 2026-07-01
deciders: Pierre-Luc, Claude (this session) — authored and pushed directly,
  bypassing Guilhem's normal dispatch/PR-review protocol, during the stack's
  bootstrap phase (see Consequences)
component: nervi
extends: ADR-N-001, ADR-N-003, ADR-N-004
---

# ADR-N-005: Aporia Contribution Signal

## Context

Guilhem's own definition (`Fondament/definitions/fondament/guilhem.yaml`) already
describes a fractal reasoning model:

> Level 1 — internal deconstruction: ... inhabit each named part sequentially
> before synthesizing.
> Level 2 — session dispatch: Component agents are separate context owners —
> raw, unresolved voices — whose outputs you synthesize.
> Level 3 — org routing: ... same mechanic, different scale.

Level 2 today is wired through the synchronous `dispatcher-invoke-agent` MCP
tool: Guilhem spawns an agent, waits, and treats the result as raw. Nèrvi
exists to carry the same kind of signal *asynchronously* — an agent's output
reaching Guilhem (or any other consumer) without having been invoked
synchronously in that turn. Nothing currently defines what such a signal looks
like or how a receiver should treat it.

Separately, `Fondament/docs/aporia-empirical-basis.md` establishes that raw,
unresolved composed-part injection ("aporia") reliably beats pre-synthesized
("crystallization") reasoning across 8 experiments, and that its Experiment 8
mixed-consultation condition (`D_mixed`: two models each reason independently
to a resolved output, a final party synthesizes across both) matches or falls
below pure single-model raw-voice reasoning but reliably adds novelty no
single voice raised alone — provided the intermediate resolution genuinely
happened per-voice, and no party pre-reconciled the tension between voices
before the final synthesizer saw them raw. That is exactly the shape of
"component agent resolves its own aporia pass, Guilhem receives N such
resolutions and synthesizes across them" — but only if the wire signal makes
"this is one agent's own resolution, not a reconciled consensus" checkable,
not assumed.

`Fondament/docs/aporia-empirical-basis.md` Experiment 9 (added alongside this
ADR) measures the cost of running aporia per call: ~$0.008/22.7s on Haiku 4.5,
~$0.037/67s on Sonnet 4.6, ~$0.064/50s on Opus 4.8 (measured; Gemini 2.5 Pro
~$0.016 projected, not measured). `project-agent.yaml` already keeps aporia
off by default for component/project agents for exactly this reason. The
signal kind defined here must not require flipping that default.

ADR-N-001 (qualifier vocabulary, downstream of Farga node types),
ADR-N-003 (`<fondament-ref>` identity, signals as first-class Nèrvi traffic),
and ADR-N-004 (scope as `Fondament ∩ manifest ∩ moderator grants`) already
supply identity, vocabulary, and authorization machinery. This ADR does not
invent new primitives in any of those three dimensions — it defines one new
signal kind and its consumption contract, and picks the cheapest fit within
what N-001/N-003/N-004 already allow.

## Decision

**A new signal kind, `nervi.contribution.aporia`, carrying one agent's own
resolved aporia output, published only when that call actually ran the
aporia pass, and consumed by treating N of them as raw material for a further
aporia pass — never as pre-agreed fact.**

### Envelope

```yaml
kind: nervi.contribution.aporia
contribution_id: <uuid>
contributor: <fondament-ref>      # composition address that produced this, e.g.
                                   # farga/project-x+aporia
composed_parts: [...]             # names of the disciplines/stance the contributor
                                   # reasoned over (ComposedPart.name) — audit/
                                   # transparency only, not required for consumption
resolution_scope: self            # fixed value on every instance of this kind —
                                   # declares "resolved only against my own composed
                                   # parts; not reconciled against any other agent"
content: <text>                    # the contributor's resolved position
produced_at: <iso8601>
session_ref: <optional>            # dispatch/session that produced this, if any
```

`resolution_scope: self` is the field that makes the D_mixed licensing
condition checkable rather than assumed: a consumer subscribing to this
signal kind only ever sees self-scoped resolutions, never a chain of prior
syntheses — because there is deliberately no other value this field can take.

### Subject and qualifier — reuse, don't mint

**Subject:** `occitan.contribution.<component>` — parallel to the existing
`occitan.dispatch.<component>` and `occitan.ops.<source>.<kind>` domains.

**Qualifier:** `cross-project` (existing, per ADR-N-001) — its stated meaning,
"a signal relevant beyond its origin," is exactly what a contribution is. No
new qualifier is minted. Per ADR-N-001's additive-only model, promoting to a
dedicated qualifier later is a non-breaking addition if `cross-project` proves
too coarse to distinguish contributions from other cross-project traffic; it
is not a prerequisite now.

**Identity:** the existing `<fondament-ref>` format (ADR-N-003) on
`contributor`. No new identity primitive.

### Publish-side gate

A call publishes `nervi.contribution.aporia` only if `ResolvedAgent
.structured_reasoning.is_some()` for that specific call (`fondament-core`) —
i.e., the composition address used `+aporia` for *this* call, not because the
agent runs aporia by default. This keeps `project-agent.yaml`'s
off-by-default posture intact: the tax (Experiment 9) is paid only on calls
that are actually going to produce a contribution, not on every routine
invocation. Haiku 4.5 is the recommended model for gated calls where quality
parity holds — it matches Sonnet/Opus scores in the raw-voices condition at
the lowest measured cost.

### Consumption contract

A consumer treating multiple `nervi.contribution.aporia` signals on the same
working question as input to its own reasoning MUST apply the aporia
decomposition again over the *received set* — become each one, name the
tensions, recompose — the same operation `build_aporia_preamble` performs over
an agent's own composed parts. It must not pre-summarize the set into one
paragraph before reasoning about it. This is the fractal repeat: Level 1
(disciplines within one agent) and this cross-agent case use the same
operator at a different scope.

### Scope class (ADR-N-004)

Publishing `nervi.contribution.aporia` is `low` scope: publish-only, no state
mutation, symmetric to the already-baseline SRE-alert and dispatch publish
paths. No moderator grant or initiator endorsement is required to emit it.

## Consequences

- Any Fondament dispatch call site producing a Nèrvi-visible contribution must
  check `structured_reasoning.is_some()` before publishing, and must set
  `resolution_scope: self` unconditionally — there is no pre-resolved variant
  of this signal kind by design.
- `Fondament/definitions/fondament/guilhem.yaml` needs a protocol addition
  describing when Guilhem calls `nervi_subscribe` on `occitan.contribution.*`
  and how it applies the consumption contract above. Not written here — this
  ADR defines the wire contract that addition would consume; the guilhem.yaml
  change is a separate, later piece of work.
- Reuses `cross-project` rather than minting a qualifier — smaller diff, no
  new Farga node type or ruleset-version registration needed to ship this.
- **Process note:** unlike ADR-N-001 through N-004 (`deciders: Guilhem (org
  agent), Pierre-Luc (endorsing)`), this ADR was authored and pushed to `main`
  directly by a Claude session at Pierre-Luc's explicit instruction, without
  Guilhem's review. This is intentional during the stack's bootstrap phase —
  Guilhem is meant to become the autonomous reviewer/dispatcher this kind of
  change would normally route through, but reaching that point requires
  exactly this kind of directly-authored groundwork first. Closing this ADR
  (accepted/superseded) and recording it in Farga is deferred until Pierre-Luc
  requests it, once the corresponding implementation lands.
- Open follow-up: interaction with ADR-N-002's reversal detection — does a
  contribution that contradicts a subscriber's trajectory vector deserve
  reversal-class priority (bypassing winsorization)? Plausible, unresolved.
  Deferred; Epic 1's scope does not yet exercise subscriber trajectory
  vectors.
- Open follow-up: no topic-manifest cost/scale analysis yet for
  `occitan.contribution.*` if it grows beyond baseline-scope publish traffic.
  Deferred until a session actually needs escalation on this topic.
