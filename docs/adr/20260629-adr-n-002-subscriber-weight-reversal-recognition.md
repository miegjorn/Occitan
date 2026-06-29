---
status: proposed
date: 2026-06-29
deciders: Guilhem (org agent), Pierre-Luc (endorsing)
component: nervi
---

# ADR-N-002: Subscriber Weight Factorization and Reversal Recognition

## Context

Reversal recognition is subscriber-side: the triager cannot classify a reversal
because it lacks trajectory awareness (ADR-N-001). A reversal is a signal that
*contradicts the receiving subscriber's trajectory* — and trajectory is a
property of the subscriber, not of the signal. The locked architecture grants
reversals a **priority class that bypasses winsorization entirely**: a reversal
must not be winsorized away, because the whole point of winsorization is to damp
outliers, and a genuine reversal is exactly the outlier we must not damp.

Subscriber weight is **static to start**; the learning mechanism is deferred
until Cor's dream-introspection path is mature enough to tune it. The subscriber
modifier is Fondament-bound at execution time and Cor-updatable only via the
dream path.

The open question is the *mechanism* of detection: threshold-based comparison of
the incoming qualifier + amplitude against a subscriber trajectory vector (fast,
deterministic, no LLM cost), versus an LLM call passing the signal plus trajectory
context to a model (more accurate, but expensive and latency-bearing).

The asymmetry that decides this ADR: **false positives are cheap, false negatives
are catastrophic.** A wrongly flagged reversal merely earns priority deliberation
— wasted voice, no corrupted state. A *missed* reversal gets winsorized: a real
contradiction to the subscriber's trajectory is silently damped and never heard.
The detector must therefore be biased toward recall.

## Decision

**A two-stage detector: a deterministic threshold gate on every read, escalating
to an LLM judgment only for the ambiguous band.**

Stage 1 — threshold gate (always on, every signal):
Each subscriber maintains a **trajectory vector** — an aggregate embedding of the
signals it has recently accepted into its deliberation. For each incoming signal,
compute the divergence between the signal's embedding and the trajectory vector,
conditioned on qualifier and amplitude. Three outcomes:

- **Strong alignment** → not a reversal. Routed normally.
- **Strong divergence** → reversal. Promoted to the priority class immediately,
  bypassing winsorization. No LLM call.
- **Ambiguous band** (near the threshold) → escalate to Stage 2.

Stage 2 — LLM judgment (ambiguous band only):
Pass the signal plus trajectory context to a model with a single question: *does
this contradict the trajectory, or is it merely novel?* Threshold geometry cannot
distinguish "opposes my direction" from "points somewhere I haven't been" —
contradiction is semantic, distance is not. The model resolves only the cases the
gate could not, so LLM cost scales with the width of the ambiguous band, not with
total signal volume.

The threshold is tuned toward **sensitivity**: the gate over-admits into the
ambiguous band rather than under-admitting, and the LLM prunes the resulting false
positives. This respects the cost asymmetry — recall is bought cheaply in the
gate, precision is bought selectively in the judge.

**When each mechanism is appropriate, standalone:**

- *Threshold-only* (no escalation) is appropriate for high-volume, low-stakes
  streams whose trajectory is well captured as a vector — typically `data` and
  ops-flavored subscribers — and for early deployment under static weights, where
  a spurious priority deliberation costs nothing the fabric can't absorb.
- *LLM-in-the-loop* is warranted for the ambiguous band always, and additionally
  for high-stakes subscribers and `cross-project` signals, where contradiction is
  subtle and the cost of a missed reversal is high.

**Weight factorization.** For a normal (non-reversal) signal, the subscriber's
effective deliberation voice is:

```
voice = static_modifier(subscriber, qualifier) × qualifier_affinity × amplitude
```

where `static_modifier` is the Fondament-bound, execution-time-resolved term.
Reversals do not pass through this product at all: a reversal enters the priority
class, bypasses winsorization, and is given full voice regardless of its
amplitude. This is the mechanical meaning of "amplitude governs deliberation
voice, not insertion eligibility" combined with "reversals bypass winsorization":
amplitude modulates the normal product; it is *ignored* once the priority class
fires.

The learning mechanism — adjustment of `static_modifier` and of the threshold
band itself — is deferred to Cor's dream-introspection path, consistent with the
locked decision. The trajectory vector is the natural input to that future
learning: Cor can tune both the static weight and the gate boundaries from the
same representation the gate already maintains.

## Consequences

- Each subscriber must maintain and update a trajectory vector. This is new state
  in the subscriber runtime and the input the eventual Cor learning path will
  consume — building it now is not throwaway work.
- LLM cost is bounded by ambiguous-band width, not by the anti-starvation "all
  signals are read" guarantee. We keep the guarantee (every signal is read by the
  gate) without paying per-signal inference.
- The threshold band boundaries and the sensitivity bias become tunable
  parameters. Until Cor matures, they are static config, owned per subscriber
  (and possibly per qualifier).
- The cost asymmetry is encoded structurally, not just documented: recall lives in
  the cheap gate, precision in the selective judge. A future regression that makes
  the gate stricter to "save LLM calls" would silently trade away reversal recall
  — reviewers must treat gate sensitivity as a safety parameter, not a cost knob.
- Coupling to Cor is forward-declared and clean: the dream-introspection path,
  when ready, tunes `static_modifier` and the band from the trajectory vector.
  Nothing in this ADR needs to change when that path lands.
- Open follow-up: representation of the trajectory vector (embedding model,
  decay/recency weighting, how acceptance vs. mere reading updates it). Deferred;
  not required for Epic 1's single-sensor scope.
