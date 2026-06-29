---
status: proposed
date: 2026-06-29
deciders: Guilhem (org agent), Pierre-Luc (endorsing)
component: nervi
---

# ADR-N-001: Triager Rule Schema

## Context

The Nèrvi insertion pipeline is `producer → triager → insert → insertion hook
recomputes global Winsorized Mean`. The triager sits in the hot path of every
signal entering the fabric. Its single job is to assign a **qualifier** to each
incoming signal, drawn from the locked vocabulary `info | cross-project | data`,
which maps one-to-one onto Farga node types.

Two properties of the locked architecture constrain this ADR:

1. **The triager is a rule engine, not a model.** Reversal recognition was
   deliberately pushed subscriber-side precisely because the triager lacks
   trajectory awareness and cannot make semantic judgments. Whatever schema we
   adopt must keep the triager fast and deterministic. No LLM call belongs in the
   insertion hot path.
2. **The qualifier vocabulary is downstream of Farga's node type system.** A
   qualifier is not free vocabulary the bus invents; it is the projection of a
   Farga node type into the subscription fabric. This is what "maps directly to
   Farga node types" means, made load-bearing.

Three sub-questions are open: what format the rules take, how the triager decides
a qualifier, and where the ruleset physically lives (static config file, a table
in Farga, or a Fondament-registered artifact).

## Decision

**Rule format — ordered match→qualifier rules, evaluated first-match-wins, over
the signal envelope only.**

A ruleset is an ordered list of rules plus a mandatory default:

```yaml
ruleset_version: 3
emits: [info, cross-project, data]   # closed set, validated against Farga node types
rules:
  - match: { subject: "ops.sre.alerts.>", source: "sensor:sre-log-monitor" }
    qualifier: data
    stop: true
  - match: { subject: "*.*.crossref.>" }
    qualifier: cross-project
    stop: true
  - match: { header: { "x-nervi-kind": "datum" } }
    qualifier: data
    stop: true
default: info
```

Predicates match **only on metadata available at insertion time** — the NATS
subject, the producer identity, and declared envelope headers. They do **not**
inspect deep content semantics; that is the boundary that keeps the triager
deterministic and model-free. Anything requiring semantic judgment (above all,
reversal) is, by the locked architecture, not the triager's job.

**Vocabulary source of truth — Farga node types.** The closed `emits` set of a
ruleset is validated at registration against the live Farga node type vocabulary.
A rule that emits a qualifier with no backing Farga node type is rejected at
registration, not discovered at runtime. The vocabulary is therefore extended by
a deliberate two-step act: (1) add the Farga node type, then (2) register a
ruleset version whose `emits` set includes the new qualifier.

**Extensibility without breaking subscribers — additive-only, with `info` as the
universal floor.** Qualifiers are append-only: never removed, never repurposed
(repurposing silently changes the meaning of historical signals and of
subscribers' standing affinities). A subscriber that does not recognize a newly
introduced qualifier degrades it to `info` semantics — it still reads the signal
(the anti-starvation guarantee holds: all signals are read), it simply applies no
special amplitude or voice handling to it until its own configuration learns the
new qualifier. New qualifiers are thus backward-compatible by construction.

**Home — a Fondament-registered artifact.** We reject the static config file
(requires redeploy, not introspectable by agents at runtime, no identity binding)
and the Farga table (Farga is narrative and memory; mutable classification logic
living there mixes governance with chronicle and invites unaudited change). The
ruleset is a **versioned Fondament artifact**, bound at triager execution time.
This is the same layer that already binds the subscriber modifier and holds scope
authority (see ADR-N-004); placing the ruleset there keeps all execution-time
binding and all governed vocabulary in one authority plane. Each ruleset carries
a monotonic `ruleset_version`; the triager records the version it applied in the
signal envelope so any classification is reproducible after the fact.

## Consequences

- The insertion hot path stays deterministic and cheap. No model inference, no
  network call beyond the Fondament binding (resolved at execution, cacheable per
  version).
- Adding a content category is now a governed, two-system act (Farga node type +
  Fondament ruleset version). This is intentional friction: the bus vocabulary
  cannot drift independently of the memory it projects into.
- Backward compatibility is guaranteed by the `info` floor plus the additive-only
  discipline. The cost is that `info` is a genuine catch-all — subscribers must
  treat it as "unclassified or not-yet-understood," not as a positive category.
- A registration-time validator is required: it must reject any ruleset whose
  `emits` set references a qualifier absent from the live Farga node type
  vocabulary. This validator is the enforcement point for the
  vocabulary-downstream-of-Farga invariant.
- Every signal carries the `ruleset_version` that classified it, making
  misclassification auditable and reclassification (on a vocabulary change) a
  well-defined operation rather than a guess.
- Open follow-up: reclassification policy for already-inserted signals when a new
  qualifier subsumes cases previously caught by `info`. Deferred — not needed for
  Epic 1's narrow scope (SRE sensor → developer consumer).
