---
status: proposed
date: 2026-06-29
deciders: Guilhem (org agent), Pierre-Luc (endorsing)
component: nervi
---

# ADR-N-003: Endorsement Protocol

## Context

A moderator can grant a subscriber additional scope within a live session
(session-level grant; see ADR-N-004 for the authority layers). Some of those
grants are not the moderator's to make unilaterally — they require **endorsement
from the session initiator**, the agent who opened the session/topic.

The problem is to define this without violating Nèrvi's defining ethos.
Nèrvi never blocks: the anti-starvation guarantee says all signals are read, and
the fabric is asynchronous by construction. A subscriber must not stall on a
synchronous round-trip waiting for an initiator to answer. So the protocol must
specify what artifact travels upward, what constitutes approval, and how approval
is detected **without the subscriber blocking**.

## Decision

**Endorsement requests and verdicts are first-class signals on Nèrvi itself.**
Nèrvi carries its own governance traffic — the fabric is the transport for its
own scope-grant protocol. This is deliberate self-reference, consistent with the
stack's design principle, and it means "detection without blocking" requires no
new primitive: the subscriber already reads signals; reading the verdict is just
another subscription.

**The artifact that travels upward — an `EndorsementRequest` signal:**

```yaml
kind: nervi.endorsement.request
endorsement_id: <uuid>
subscriber: <fondament-ref>          # who is being granted scope
granting_moderator: <fondament-ref>  # who granted it
session: <session-ref>
topic: <topic-ref>
initiator: <fondament-ref>           # the target endorser
baseline_scope: [...]                # what the subscriber already held
granted_scope: [...]                 # the full scope after the grant
delta_scope: [...]                   # granted minus baseline — what needs endorsing
scope_class: low | elevated | reserved
justification: <text>                # why the moderator granted it
requested_at: <iso8601>
expires_at: <iso8601>                # endorsement window
```

The endorsable unit is `delta_scope` — the increment over what the subscriber
already legitimately held — not the whole grant. The `scope_class` (carried from
the topic manifest, ADR-N-004) drives the activation model below.

**What constitutes approval — a matching `Endorsement` signal:**

```yaml
kind: nervi.endorsement.verdict
endorsement_id: <uuid>               # references the request
endorser: <fondament-ref>            # must resolve to the initiator (or delegate)
verdict: endorsed | rejected
decided_at: <iso8601>
```

A grant is approved when, before `expires_at`, an `Endorsement` signal exists
that (a) references the `endorsement_id`, (b) carries `verdict: endorsed`, and
(c) comes from an identity the topic manifest and Fondament recognize as the
session initiator or its delegate (identity verification is shared with
ADR-N-004). The topic manifest may require an N-of-M quorum for `reserved`-class
scopes; the default is a single initiator.

**Activation model — blocking-free, with class-tiered optimism:**

The subscriber never waits. The `scope_class` decides whether the grant is live
during the endorsement window:

- **`low` / `elevated` → optimistic (provisional-grant).** The moderator's grant
  takes effect immediately; the subscriber operates under `granted_scope` while
  the `EndorsementRequest` travels upward asynchronously. If a `rejected` verdict
  arrives, or the window expires with no `endorsed` verdict, the scope reverts to
  `baseline_scope` via a `nervi.scope.revoke` signal. This matches the fabric's
  never-block ethos: the common path costs zero latency.
- **`reserved` → pessimistic (provisional-deny).** The grant stays inactive at
  `baseline_scope` until an `endorsed` verdict is observed. Still non-blocking:
  the subscriber keeps working at its baseline scope and reads the verdict when
  it arrives, rather than stalling. High-authority scope simply does not activate
  on a moderator's word alone.

Detection is, in all cases, ordinary subscription: the requesting subscriber (and
the scope guard, ADR-N-004) reads the verdict signal off the bus. There is no
wait primitive, no synchronous call, no held lock. Silence is a defined outcome —
expiry — not an indefinite hang.

## Consequences

- Endorsement is auditable for free. Request and verdict are durable signals
  (JetStream retention plus the Farga chronicle), so every scope escalation has a
  permanent, ordered record of who granted, who endorsed, and when.
- A timeout sweep is required: something must emit `nervi.scope.revoke` for
  optimistic grants whose window expires unendorsed. This is the one active
  component the protocol adds; everything else is signal traffic.
- Optimistic activation opens a bounded window of provisional over-scope for
  `low`/`elevated` grants. This is the accepted tradeoff for never blocking; it is
  contained by gating `reserved` scopes to pessimistic activation, so the most
  dangerous capabilities never activate provisionally.
- Revocation must be safe to apply mid-operation: a subscriber operating under a
  provisional grant must tolerate losing the delta scope when a revoke arrives. The
  subscriber runtime needs a defined "scope narrowed under me" handling path.
- The protocol composes directly with ADR-N-004: `scope_class` and the
  initiator-identity check both come from the topic manifest / Fondament layers,
  and the endorsement boundary (which scopes need endorsement at all) is encoded
  there, not here.
- Open follow-up: delegation chains (initiator delegating endorsement authority)
  and quorum semantics for `reserved` scopes are sketched but not specified.
  Deferred — Epic 1's narrow scope does not exercise them.
