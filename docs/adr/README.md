# Architecture Decision Records

ADRs track significant architectural decisions for the Occitan stack.

Format: `YYYYMMDD-title.md` with frontmatter: `status: proposed|accepted|superseded`, `date`, `deciders`.

## Index

### Nèrvi (async subscription fabric)

- [ADR-N-001: Triager Rule Schema](20260629-adr-n-001-triager-rule-schema.md) — qualifier vocabulary extensibility; ordered match→qualifier rules as a Fondament-registered artifact, vocabulary downstream of Farga node types.
- [ADR-N-002: Subscriber Weight Factorization and Reversal Recognition](20260629-adr-n-002-subscriber-weight-reversal-recognition.md) — two-stage reversal detector (threshold gate + selective LLM judge), biased toward recall.
- [ADR-N-003: Endorsement Protocol](20260629-adr-n-003-endorsement-protocol.md) — endorsement as first-class Nèrvi signals; class-tiered optimistic/pessimistic activation, blocking-free detection.
- [ADR-N-004: Scope Authority Layers](20260629-adr-n-004-scope-authority-layers.md) — Fondament / topic manifest / moderator compose by containment; deny-overrides, grant requires unanimity; fail-closed verification.
- [ADR-N-005: Aporia Contribution Signal](20260701-adr-n-005-aporia-contribution-signal.md) — `nervi.contribution.aporia` signal kind carrying one agent's own resolved aporia output; gated on that call actually running `+aporia`; consumed by re-applying aporia decomposition across received contributions, never pre-summarized.

Other decisions to date are in commit history and component docs.
