# `guilhem-bot` GitHub App Identity

## Problem

Every agent container in the Occitan stack (Guilhem and all 8 component agents) authenticates to GitHub using the same personal token seeded from `$GITHUB_TOKEN` into OpenBao as `occitan/github` — the same credential Pierre-Luc uses himself. GitHub treats every action from that token as coming from `@bedardpl`.

This surfaced concretely when Caissa PR #49 (Authentik/Valkey/OIDC infra) couldn't be self-approved after the branch protection + CODEOWNERS work went live (`Occitan/docs/superpowers/specs/2026-07-01-guilhem-merge-approval-design.md`): GitHub never allows a PR author to approve their own PR, and since Guilhem's token *is* Pierre-Luc's identity, CODEOWNERS can never distinguish "Pierre-Luc reviewing" from "Guilhem's token reviewing." This is the accepted, explicitly-deferred residual risk from that design — Layer 3 (CODEOWNERS/branch protection) structurally can't close this gap while the identity is shared; only Layer 1 (persona rule) and Layer 2 (blocking Matrix approval) currently guard against it.

This design supersedes the earlier draft note at `/Users/bedardpl/project/githubapp.md` (now deleted).

## Goals

- Give every agent container a GitHub identity (`guilhem-bot[bot]`) structurally distinct from Pierre-Luc's own account, so CODEOWNERS' self-approval block correctly applies to the bot.
- Scope the bot's permissions tighter than the current shared PAT (which has full personal-account admin rights) — write access to what agents actually do, nothing more.
- Preserve today's Class 1/2 autonomous merge behavior and the existing `fetch-tokens` / OpenBao-as-source-of-truth credential pattern as closely as possible.

## Non-goals

- Changing CODEOWNERS itself — `@bedardpl` remains the required human reviewer on protected paths.
- Changing Layers 1/2 of the merge-approval design — this closes the identity gap, not the judgment gap.
- Automating GitHub App registration — creating the App and generating its private key is an inherently manual, one-time step in the GitHub UI.

## Architecture

```
One-time manual step (Pierre-Luc, GitHub UI):
  Register GitHub App "guilhem-bot" → App ID, generate + download private key (.pem)
  Install it on all 9 repos (Gardian, Fondament, Farga, Amassada, Charradissa,
  Cor, Caissa, nervi, Occitan) → Installation ID
  Permissions: Contents (write), Pull requests (write), Issues (write),
  Actions (write), Checks (write), Metadata (read)
        │
        ▼
Seed 3 new OpenBao secrets (Caissa/scripts/seed-secret.sh, same pattern as occitan/github):
  occitan/github-app-id             (field: value — the numeric App ID)
  occitan/github-app-installation-id (field: value — the numeric Installation ID)
  occitan/github-app-private-key     (field: value — the PEM private key content)
        │
        ▼
fetch-tokens initContainer (Caissa/deploy/charts/guilhem/templates/guilhem.yaml,
same pattern extends to component-agents chart):
  pulls the 3 App secrets from OpenBao into /creds/, alongside the existing
  GitLab token fetch (GitLab is unaffected by this change)
        │
        ▼
Main container entrypoint (Caissa/sandbox/entrypoint.sh):
  mint_installation_token() — one-time helper:
    1. Build a JWT: header {"alg":"RS256","typ":"JWT"}, payload
       {"iat": now-60, "exp": now+540, "iss": <App ID>}, base64url-encode both,
       sign header.payload with the private key via `openssl dgst -sha256 -sign`,
       base64url-encode the signature → JWT
    2. POST https://api.github.com/app/installations/<installation_id>/access_tokens
       with `Authorization: Bearer <JWT>` → returns a token valid 1 hour
    3. Write GH_TOKEN/GITHUB_TOKEN into /creds/tokens.env (same file/vars as today)
  Task mode: call mint_installation_token() once at startup — Jobs are short-lived,
    one mint is sufficient, no background process needed.
  Interactive mode: call mint_installation_token() at startup, then spawn a
    background loop (`while true; do sleep 2700; mint_installation_token(); done &`)
    that re-mints and rewrites the same file every 45 minutes — comfortably inside
    the 1-hour token lifetime.
        │
        ▼
git/gh: usage at every call site is unchanged (still reads GH_TOKEN/GITHUB_TOKEN from
the sourced tokens.env) — but now authenticates as guilhem-bot[bot], a distinct
principal from @bedardpl. CODEOWNERS still names @bedardpl; the bot structurally
cannot satisfy its own review requirement.
```

## Credential flow — fit with existing philosophy

The App's private key becomes the new long-lived secret in OpenBao, replacing the static PAT there (`occitan/github` is retired once this rolls out). Nothing changes about "OpenBao is the source of truth, `/creds` is ephemeral, no long-lived k8s Secret duplication" — this substitutes *what* gets fetched, not the fetch pattern. The one real departure from today: token minting now also happens in the *main* container (not just the initContainer), because an initContainer can't keep refreshing a token after it exits and interactive Guilhem can outlive a 1-hour token.

## Scope: all 9 agent containers

Even though only Guilhem opens/reviews/merges PRs today (per its persona: "You are NOT: An implementer in component repositories... you do not write code or open PRs"), all 8 component agents switch to the App identity too — this removes Pierre-Luc's personal token from every container's reach, not just the PR-merge path, and it's the same shared `entrypoint.sh` code path regardless.

## Error handling

- If `mint_installation_token()` fails (network error, expired/revoked App installation, bad key), the entrypoint should fail loudly (non-zero exit propagates via `set -e`, matching the existing pattern where a missing `ANTHROPIC_API_KEY` fails the container) rather than silently falling back to no auth.
- The background refresh loop's failures should log to stderr but not kill the main `claude` process mid-session — a transient GitHub API blip 45 minutes in shouldn't tear down an active interactive session. The *next* refresh attempt (45 min later) gets another chance; the current token is still valid until its own expiry.

## Testing

- No unit-test harness exists for `entrypoint.sh` today (it's a shell script baked into the container image, same situation as the room-provisioning work) — verification is manual: build the image, run a container with real OpenBao-backed App secrets, confirm `git ls-remote` against a private repo succeeds using the minted token, and confirm the background loop actually rewrites the token file after the sleep interval (can be verified with a shortened interval in a manual test run).
- Confirm via `gh api /installation/repositories` (using the minted token) that all 9 repos are visible to the installation.
- Confirm a live PR test: open a PR as `guilhem-bot[bot]` touching a CODEOWNERS-protected path, attempt merge without review (expect blocked, same as the Pierre-Luc-authored test PR from the merge-approval work), then have Pierre-Luc approve as himself and confirm merge succeeds — this is the actual proof the identity separation works, unlike the earlier verification where Pierre-Luc's own admin override was the only way through.

## Known limitations (accepted, not solved here)

- The App's private key is itself a single secret whose compromise would let an attacker mint tokens as `guilhem-bot[bot]` — this is a strictly smaller blast radius than today's shared PAT (repo-scoped, no admin, no access to Pierre-Luc's other GitHub activity), but it's still a credential worth rotating occasionally, same as any other OpenBao-held secret.
