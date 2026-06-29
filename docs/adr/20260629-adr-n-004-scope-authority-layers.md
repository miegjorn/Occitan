---
status: proposed
date: 2026-06-29
deciders: Guilhem (org agent), Pierre-Luc (endorsing)
component: nervi
---

# ADR-N-004: Scope Authority Layers

## Context

Three distinct layers can speak to what a subscriber is allowed to do:

1. **Fondament** — the agent definition. What this agent *is*, and the maximum
   capability set it can ever hold. The subscriber modifier is already
   Fondament-bound at execution time; scope ceiling belongs in the same place.
2. **Topic manifest** — topic-level permissions. What is permissible *within this
   topic*, independent of any one session.
3. **Moderator** — session-level grants. What a moderator activates for a
   subscriber *within a live session* (the grants that ADR-N-003's endorsement
   protocol governs).

The open questions: how the three compose, which takes precedence, and how a
moderator's grant is verified against Fondament and the topic manifest.

The hazard to avoid is treating these as an override stack where the innermost
(moderator) wins. A moderator who could grant past the agent's definition or past
the topic's rules would make Fondament and the manifest advisory. They must be
binding.

## Decision

**The layers compose by containment, not override. Effective scope is an
intersection; denial at any layer is final.**

```
effective_scope(subscriber, topic, session)
    = Fondament_ceiling(subscriber)        # what the agent may ever do
    ∩ topic_manifest_permits(topic)        # what this topic allows
    ∩ moderator_active_grants(session)     # what is switched on this session
```

Read as nested bounds, outermost to innermost:

- **Fondament is the root of trust and the outer bound.** Nothing — no manifest,
  no moderator — can grant a capability Fondament does not define for the
  subscriber. It is resolved at execution time (consistent with the
  Fondament-bound subscriber modifier), so a change to the agent definition
  changes the ceiling at the next execution; nothing is cached past its version.
- **The topic manifest narrows within Fondament.** It cannot exceed the ceiling.
  It can restrict below it, and it can define *topic-scoped* capabilities (scopes
  meaningful only inside this topic). It also designates **who may act as
  moderator** and encodes the **escalation boundary** — per scope class, whether a
  moderator may grant freely (`low`), grant subject to initiator endorsement
  (`elevated` / `reserved`, per ADR-N-003), or not grant at all
  (manifest-reserved).
- **Moderator grants are the innermost, most dynamic layer.** A moderator
  *activates* scope for a session, but only scope already permitted by the two
  outer layers. A grant is a selection within the intersection, never an
  expansion of it.

**Precedence rule — deny overrides, grant requires unanimity along the chain.**
A capability is active for a subscriber only if Fondament defines it AND the topic
manifest permits it AND a moderator has granted it (and endorsement, if the scope
class requires it, is satisfied or optimistically provisional per ADR-N-003). Any
single layer withholding the capability is sufficient to deny it. There is no
precedence contest to resolve because no layer can override a more authoritative
one — they only ever narrow.

**Verification protocol for a moderator's grant.** When a moderator emits a grant
for subscriber `S`, scope `X`, in `topic`/`session`, a **scope guard** in the
subscriber's act path verifies, before `X` activates:

1. **Fondament check** — resolve `S`'s agent definition at execution time; confirm
   `X ∈ Fondament_ceiling(S)`. Fail → reject (the grant is void; no endorsement
   can rescue it).
2. **Manifest check** — confirm the topic manifest permits `X` in this topic,
   *and* that the granting identity is in the manifest's recognized moderator set
   for this topic. Fail → reject.
3. **Escalation check** — read `X`'s scope class from the manifest. If it requires
   initiator endorsement, hand off to ADR-N-003: the grant activates provisionally
   (optimistic classes) or stays at baseline (pessimistic `reserved` class) until
   an `endorsed` verdict is observed.

All three artifacts are signed; Fondament is the identity root against which the
moderator's identity (step 2) and the subscriber's ceiling (step 1) are resolved.
Verification is local to the subscriber runtime and synchronous to the *act* — but
never to the bus read, preserving the never-block guarantee.

**Failure posture — fail closed.** If Fondament is unreachable at verification
time, the scope guard denies any scope beyond a defined safe baseline rather than
admitting the grant on stale or absent authority. Availability of the authority
root must never silently widen scope.

## Consequences

- A **scope guard** is a required component in the subscriber act path. It is the
  single enforcement point where the three layers are intersected and where
  ADR-N-003 endorsement is triggered. Its correctness is security-critical.
- Fondament becomes a hard runtime dependency for scope resolution. The fail-closed
  posture bounds the blast radius of a Fondament outage to "no scope escalation,"
  not "scope leak" — degraded, never unsafe.
- The **topic manifest is a new first-class artifact**, owned by the topic
  initiator. It carries topic permissions, the moderator set, and the escalation
  boundary. Defining its schema and ownership is prerequisite work for any session
  that grants beyond baseline.
- Deny-overrides plus intersection makes the model auditable and reason-about-able:
  to explain why a subscriber can do `X`, you point to three positive grants; to
  explain why it cannot, you point to the single layer that withheld it.
- The escalation boundary in the manifest is the seam to ADR-N-003. Moving a scope
  between `low`, `elevated`, and `reserved` is a manifest edit, not a code change —
  governance is data, not logic.
- Open follow-up: schema and ownership/versioning of the topic manifest, and the
  signing/identity-resolution mechanism shared with ADR-N-003 (delegation,
  key rotation). Deferred — Epic 1's single-sensor scope runs entirely at baseline
  and does not exercise moderator grants.
