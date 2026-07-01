# guilhem-bot GitHub App Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every Occitan agent container a GitHub identity (`guilhem-bot[bot]`) structurally distinct from Pierre-Luc's own `@bedardpl` account, so CODEOWNERS' self-approval block actually applies to the bot instead of being defeated by shared identity.

**Architecture:** Register a GitHub App once (manual), seed its App ID/Installation ID/private key into OpenBao as three new secrets, teach the shared `fetch-tokens` initContainer (both the `guilhem` chart and the `component-agents` chart) to pull those raw secrets instead of the static PAT, and teach `entrypoint.sh` to mint a short-lived installation token from them at startup — with a background refresh loop for the long-lived interactive case.

**Tech Stack:** POSIX shell (`entrypoint.sh` is `#!/bin/sh`), Helm templates, OpenBao (`bao kv`), GitHub REST API (App JWT auth flow).

**Reference spec:** `Occitan/docs/superpowers/specs/2026-07-01-guilhem-github-app-identity-design.md`

## Global Constraints

- No changes to CODEOWNERS — `@bedardpl` remains the required reviewer on protected paths.
- No changes to the merge-approval Layers 1/2 (persona rule, blocking Matrix approval).
- All 9 agent containers (Guilhem + 8 component agents) switch to the App identity — not Guilhem alone.
- App permissions: Contents, Pull requests, Issues, Actions, Checks — all write; Metadata — read. No admin.
- Installation tokens expire after 1 hour. Task-mode Jobs mint once at startup (short-lived, no refresh needed). Interactive Guilhem mints at startup and refreshes every 45 minutes via a background loop.
- OpenBao secret paths: `occitan/github-app-id`, `occitan/github-app-installation-id`, `occitan/github-app-private-key` (field `value` for all three, matching the existing `occitan/github`/`occitan/gitlab` convention). `occitan/github` (the old static PAT) is retired once this rolls out — GitLab (`occitan/gitlab`) is unaffected.

---

### Task 1: Register the GitHub App (manual, Pierre-Luc)

**Files:** None — this is a manual GitHub UI runbook, no code changes. It's a hard prerequisite: nothing in Tasks 2-6 can be verified without its output.

**Interfaces:**
- Produces: an App ID (numeric), an Installation ID (numeric), and a downloaded private key `.pem` file — Task 2 consumes all three.

- [ ] **Step 1: Create the App**

Go to `https://github.com/organizations/miegjorn/settings/apps/new` (org-level, not personal — this must be an org-owned App so it can be installed across all 9 `miegjorn` repos).

Fill in:
- **GitHub App name:** `guilhem-bot`
- **Homepage URL:** `https://github.com/miegjorn/Occitan` (required field, doesn't need to be meaningful beyond passing validation)
- **Webhook:** uncheck "Active" — this App doesn't need webhook events, it's used purely for API authentication
- **Permissions → Repository permissions:**
  - Contents: Read and write
  - Pull requests: Read and write
  - Issues: Read and write
  - Actions: Read and write
  - Checks: Read and write
  - Metadata: Read-only (this one is mandatory and auto-selected)
- **Where can this GitHub App be installed?:** "Only on this account" (the `miegjorn` org)

Click **Create GitHub App**.

- [ ] **Step 2: Record the App ID**

On the App's settings page (`https://github.com/organizations/miegjorn/settings/apps/guilhem-bot`), copy the **App ID** shown near the top. Save it somewhere you'll paste from in Task 2 — do not commit it to git (it's not secret by itself, but keep it with the other two values for convenience).

- [ ] **Step 3: Generate and download the private key**

Scroll to **Private keys** on the same page, click **Generate a private key**. This downloads a file like `guilhem-bot.2026-07-01.private-key.pem` to your Downloads folder. This file is the actual secret — treat it like any other credential (don't leave it sitting in Downloads long-term).

- [ ] **Step 4: Install the App on all 9 repos**

Click **Install App** in the left sidebar of the App's settings page. Choose the `miegjorn` organization. Select **Only select repositories** and choose all 9: Gardian, Fondament, Farga, Amassada, Charradissa, Cor, Caissa, nervi, Occitan. Click **Install**.

- [ ] **Step 5: Record the Installation ID**

After installing, you'll land on a URL like `https://github.com/organizations/miegjorn/settings/installations/12345678` — the trailing number is the **Installation ID**. Save it alongside the App ID from Step 2.

---

### Task 2: Seed the three OpenBao secrets

**Files:** None — uses the existing `Caissa/scripts/seed-secret.sh`, no code changes.

**Interfaces:**
- Consumes: the App ID, Installation ID, and private key `.pem` file path from Task 1.
- Produces: three OpenBao secrets at `secret/occitan/github-app-id`, `secret/occitan/github-app-installation-id`, `secret/occitan/github-app-private-key` (field `value`) — Task 4/5's initContainer changes read these.

- [ ] **Step 1: Seed the App ID**

```bash
cd /Users/bedardpl/project/Caissa
echo -n "<paste App ID from Task 1 Step 2>" | scripts/seed-secret.sh occitan/github-app-id
```
Expected output: `✓ seeded secret/occitan/github-app-id (len=<N>, prefix=<first 6 chars>…)`

- [ ] **Step 2: Seed the Installation ID**

```bash
echo -n "<paste Installation ID from Task 1 Step 5>" | scripts/seed-secret.sh occitan/github-app-installation-id
```
Expected output: `✓ seeded secret/occitan/github-app-installation-id (len=<N>, prefix=<first 6 chars>…)`

- [ ] **Step 3: Seed the private key**

Use `cat`, not `echo -n` — the key is multi-line and internal newlines must be preserved:

```bash
cat ~/Downloads/guilhem-bot.*.private-key.pem | scripts/seed-secret.sh occitan/github-app-private-key
```
Expected output: `✓ seeded secret/occitan/github-app-private-key (len=<N>, prefix=-----B…)` (a PEM file always starts with `-----BEGIN`, confirming the newlines weren't collapsed by an `echo -n` mistake).

- [ ] **Step 4: Verify all three are readable**

```bash
OBPOD=$(kubectl get pod -n occitan-system -l app.kubernetes.io/name=openbao -o name | head -1)
ROOT_TOKEN=$(kubectl get secret openbao -n occitan-system -o jsonpath='{.data.token}' | base64 -d)
for path in github-app-id github-app-installation-id github-app-private-key; do
  echo "=== $path ==="
  kubectl exec -n occitan-system "$OBPOD" -- sh -c "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN='$ROOT_TOKEN' bao kv get -field=value secret/occitan/$path" | head -c 60
  echo
done
```
Expected: the App ID and Installation ID print as plain numbers; the private key starts with `-----BEGIN`.

---

### Task 3: Mint installation tokens in entrypoint.sh

**Files:**
- Modify: `Caissa/sandbox/entrypoint.sh`

**Interfaces:**
- Consumes: `/creds/github-app-id`, `/creds/github-app-installation-id`, `/creds/github-app-private-key.pem` (raw files — produced by Task 4/5's initContainer changes).
- Produces: a `mint_installation_token` shell function that (re)writes `GH_TOKEN`/`GITHUB_TOKEN` lines into `/creds/tokens.env`, callable from both task mode and interactive mode.

- [ ] **Step 1: Add the `mint_installation_token` function**

In `Caissa/sandbox/entrypoint.sh`, insert this new function right after the `MODEL="${MODEL:-claude}"` line (line 36) and before `set -e` (line 38):

```sh

# Mints a short-lived (1h) GitHub App installation token from the App
# credentials fetch-tokens wrote to /creds/, and (re)writes GH_TOKEN /
# GITHUB_TOKEN into /creds/tokens.env. Safe to call repeatedly — each call
# fully overwrites those two lines, preserving GITLAB_*/SYNAPSE_* lines.
mint_installation_token() {
  APP_ID=$(cat /creds/github-app-id)
  INSTALLATION_ID=$(cat /creds/github-app-installation-id)
  PRIVATE_KEY_FILE=/creds/github-app-private-key.pem

  NOW=$(date +%s)
  IAT=$((NOW - 60))
  EXP=$((NOW + 540))

  JWT_HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  JWT_PAYLOAD=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$IAT" "$EXP" "$APP_ID" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  JWT_UNSIGNED="${JWT_HEADER}.${JWT_PAYLOAD}"
  JWT_SIGNATURE=$(printf '%s' "$JWT_UNSIGNED" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  JWT="${JWT_UNSIGNED}.${JWT_SIGNATURE}"

  INSTALL_TOKEN=$(curl -sf -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
    | python3 -c 'import sys, json; print(json.load(sys.stdin).get("token", ""))')

  if [ -z "$INSTALL_TOKEN" ]; then
    echo "[entrypoint] failed to mint GitHub App installation token" >&2
    return 1
  fi

  grep -v '^export GH_TOKEN=\|^export GITHUB_TOKEN=' /creds/tokens.env > /creds/tokens.env.tmp 2>/dev/null || true
  {
    cat /creds/tokens.env.tmp 2>/dev/null
    echo "export GH_TOKEN='${INSTALL_TOKEN}'"
    echo "export GITHUB_TOKEN='${INSTALL_TOKEN}'"
  } > /creds/tokens.env
  rm -f /creds/tokens.env.tmp

  export GH_TOKEN="$INSTALL_TOKEN"
  export GITHUB_TOKEN="$INSTALL_TOKEN"
}
```

- [ ] **Step 2: Call it once in task mode, right after the existing tokens.env sourcing**

Change (currently lines 83-87):

```sh
  # Source OpenBao-provided git/gh credentials if the fetch-tokens init
  # container ran (it always does for dispatched agent Jobs — see
  # build_job in caissa-cli/src/commands/dispatch.rs).
  [ -f /creds/tokens.env ] && . /creds/tokens.env
  export GIT_CONFIG_GLOBAL=/creds/.gitconfig
```

to:

```sh
  # Source OpenBao-provided git/gh credentials if the fetch-tokens init
  # container ran (it always does for dispatched agent Jobs — see
  # build_job in caissa-cli/src/commands/dispatch.rs).
  [ -f /creds/tokens.env ] && . /creds/tokens.env
  [ -f /creds/github-app-id ] && mint_installation_token
  export GIT_CONFIG_GLOBAL=/creds/.gitconfig
```

(Task-mode Jobs are short-lived — one mint at startup is sufficient, no refresh loop.)

- [ ] **Step 3: Call it in interactive mode, with a background refresh loop**

Change (currently lines 179-182):

```sh
else
  # ── Interactive mode ───────────────────────────────────────────────────────
  exec claude "$@"
fi
```

to:

```sh
else
  # ── Interactive mode ───────────────────────────────────────────────────────
  [ -f /creds/tokens.env ] && . /creds/tokens.env
  if [ -f /creds/github-app-id ]; then
    mint_installation_token
    # Refresh every 45 minutes (installation tokens expire after 1h). This
    # rewrites /creds/tokens.env; BASH_ENV below makes each freshly-spawned
    # bash subshell (i.e. every Bash tool call claude makes) re-read it, so
    # long sessions don't run on a stale token past the 1h mark.
    (while true; do sleep 2700; mint_installation_token; done) &
    export BASH_ENV=/creds/tokens.env
  fi
  export GIT_CONFIG_GLOBAL=/creds/.gitconfig
  exec claude "$@"
fi
```

- [ ] **Step 4: Verify the script is still valid shell syntax**

```bash
cd /Users/bedardpl/project/Caissa
sh -n sandbox/entrypoint.sh
echo "exit: $?"
```
Expected: `exit: 0`, no output (a syntax-only check — this does not execute the script, which needs a real container environment with `/creds/*` files present).

- [ ] **Step 5: Commit**

```bash
git add sandbox/entrypoint.sh
git commit -m "feat(auth): mint GitHub App installation tokens instead of static PAT"
```

---

### Task 4: Update the guilhem chart's fetch-tokens initContainer

**Files:**
- Modify: `Caissa/deploy/charts/guilhem/templates/guilhem.yaml`

**Interfaces:**
- Consumes: `secret/occitan/github-app-id`, `secret/occitan/github-app-installation-id`, `secret/occitan/github-app-private-key` (Task 2).
- Produces: `/creds/github-app-id`, `/creds/github-app-installation-id`, `/creds/github-app-private-key.pem` files in the shared `/creds` volume — consumed by Task 3's `mint_installation_token`.

- [ ] **Step 1: Replace the GH fetch with the three App secret fetches**

Find the `fetch-tokens` initContainer's `args` block (currently):

```yaml
              set -eu
              export BAO_ADDR=http://openbao.occitan-system.svc.cluster.local:8200
              GH=$(bao kv get -field=value secret/occitan/github)
              GL=$(bao kv get -field=value secret/occitan/gitlab)
              SYNAPSE_ADMIN=$(bao kv get -field=token secret/occitan/synapse-admin-token)
              umask 077
              cat > /creds/tokens.env <<EOF
              export GH_TOKEN='$GH'
              export GITHUB_TOKEN='$GH'
              export GITLAB_TOKEN='$GL'
              export GITLAB_PAT_TOKEN='$GL'
              export SYNAPSE_ADMIN_TOKEN='$SYNAPSE_ADMIN'
              export SYNAPSE_URL='http://synapse.occitan-system.svc.cluster.local:8008'
              EOF
```

Replace with:

```yaml
              set -eu
              export BAO_ADDR=http://openbao.occitan-system.svc.cluster.local:8200
              GL=$(bao kv get -field=value secret/occitan/gitlab)
              SYNAPSE_ADMIN=$(bao kv get -field=token secret/occitan/synapse-admin-token)
              umask 077
              bao kv get -field=value secret/occitan/github-app-id > /creds/github-app-id
              bao kv get -field=value secret/occitan/github-app-installation-id > /creds/github-app-installation-id
              bao kv get -field=value secret/occitan/github-app-private-key > /creds/github-app-private-key.pem
              cat > /creds/tokens.env <<EOF
              export GITLAB_TOKEN='$GL'
              export GITLAB_PAT_TOKEN='$GL'
              export SYNAPSE_ADMIN_TOKEN='$SYNAPSE_ADMIN'
              export SYNAPSE_URL='http://synapse.occitan-system.svc.cluster.local:8008'
              EOF
```

- [ ] **Step 2: Verify the chart still renders**

```bash
cd /Users/bedardpl/project/Caissa
helm template deploy/charts/guilhem > /tmp/guilhem-rendered.yaml
echo "exit: $?"
grep -c "github-app" /tmp/guilhem-rendered.yaml
```
Expected: `exit: 0`, and the grep count is at least 3 (one per new `bao kv get` line).

- [ ] **Step 3: Commit**

```bash
git add deploy/charts/guilhem/templates/guilhem.yaml
git commit -m "feat(auth): guilhem fetch-tokens pulls GitHub App credentials, not the static PAT"
```

---

### Task 5: Update the component-agents chart's fetch-tokens initContainer(s)

**Files:**
- Modify: `Caissa/deploy/charts/component-agents/templates/agents.yaml` (3 occurrences — the per-agent Deployment, the per-agent CronJob, and the global CronJobs block)

**Interfaces:**
- Consumes: same 3 OpenBao secrets as Task 4.
- Produces: same 3 `/creds/github-app-*` files, for all 8 component agent containers.

The 3 occurrences are NOT identical — they have different indentation, and 2 of the 3 lack the GitLab fetch. Handle each individually with the exact before/after below.

- [ ] **Step 1: Fix occurrence 1 — the per-agent Deployment (~line 58-76)**

Before:

```yaml
        - name: fetch-tokens
          image: openbao/openbao:latest
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              export BAO_ADDR=http://openbao.occitan-system.svc.cluster.local:8200
              GH=$(bao kv get -field=value secret/occitan/github)
              GL=$(bao kv get -field=value secret/occitan/gitlab)
              umask 077
              cat > /creds/tokens.env <<EOF
              export GH_TOKEN='$GH'
              export GITHUB_TOKEN='$GH'
              export GITLAB_TOKEN='$GL'
              export GITLAB_PAT_TOKEN='$GL'
              EOF
              echo "tokens written"
```

After:

```yaml
        - name: fetch-tokens
          image: openbao/openbao:latest
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
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
              echo "tokens written"
```

- [ ] **Step 2: Fix occurrence 2 — the per-agent CronJob (~line 170-188)**

Before:

```yaml
            - name: fetch-tokens
              image: openbao/openbao:latest
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  export BAO_ADDR=http://openbao.occitan-system.svc.cluster.local:8200
                  GH=$(bao kv get -field=value secret/occitan/github)
                  umask 077
                  cat > /creds/tokens.env <<EOF
                  export GH_TOKEN='$GH'
                  export GITHUB_TOKEN='$GH'
                  EOF
                  echo "tokens written"
```

After:

```yaml
            - name: fetch-tokens
              image: openbao/openbao:latest
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  export BAO_ADDR=http://openbao.occitan-system.svc.cluster.local:8200
                  umask 077
                  bao kv get -field=value secret/occitan/github-app-id > /creds/github-app-id
                  bao kv get -field=value secret/occitan/github-app-installation-id > /creds/github-app-installation-id
                  bao kv get -field=value secret/occitan/github-app-private-key > /creds/github-app-private-key.pem
                  echo "tokens written"
```

(No `tokens.env` content remains here — this occurrence never fetched GitLab or anything else; task-mode's `mint_installation_token` reads the 3 `/creds/github-app-*` files directly and creates `tokens.env` itself if it doesn't already exist, since `grep -v ... /creds/tokens.env` in Task 3's function tolerates a missing file via `|| true`.)

- [ ] **Step 3: Fix occurrence 3 — the global CronJobs block (~line 336-347)**

Before:

```yaml
            - name: fetch-tokens
              image: openbao/openbao:latest
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  export BAO_ADDR=http://openbao.occitan-system.svc.cluster.local:8200
                  GH=$(bao kv get -field=value secret/occitan/github)
                  umask 077
                  echo "export GH_TOKEN='$GH'" > /creds/tokens.env
                  echo "export GITHUB_TOKEN='$GH'" >> /creds/tokens.env
```

After:

```yaml
            - name: fetch-tokens
              image: openbao/openbao:latest
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  export BAO_ADDR=http://openbao.occitan-system.svc.cluster.local:8200
                  umask 077
                  bao kv get -field=value secret/occitan/github-app-id > /creds/github-app-id
                  bao kv get -field=value secret/occitan/github-app-installation-id > /creds/github-app-installation-id
                  bao kv get -field=value secret/occitan/github-app-private-key > /creds/github-app-private-key.pem
```

- [ ] **Step 4: Verify the chart still renders**

```bash
helm template deploy/charts/component-agents > /tmp/agents-rendered.yaml
echo "exit: $?"
grep -c "github-app-id" /tmp/agents-rendered.yaml
```
Expected: `exit: 0`, and the grep count is 3 (one per fetch-tokens occurrence — confirms all 3 were updated, not just 1 or 2).

- [ ] **Step 5: Commit**

```bash
git add deploy/charts/component-agents/templates/agents.yaml
git commit -m "feat(auth): component agents fetch-tokens pulls GitHub App credentials, not the static PAT"
```

---

### Task 6: Manual end-to-end verification (dev cluster)

**Files:** None — this is operational verification, not code.

- [ ] **Step 1: Redeploy and confirm the initContainer succeeds**

After Tasks 1-5's images/charts are built and synced (via the normal ArgoCD path, or a manual `kubectl rollout restart deployment/guilhem -n agents` on a dev cluster with the updated chart already applied), check the initContainer logs:

```bash
kubectl logs -n agents deployment/guilhem -c fetch-tokens --tail=20
```
Expected: no errors; the container exits 0 (initContainers run to completion before the main container starts).

- [ ] **Step 2: Confirm the minted token authenticates as guilhem-bot, not bedardpl**

```bash
POD=$(kubectl get pods -n agents -l app=guilhem -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n agents "$POD" -- sh -c '. /creds/tokens.env 2>/dev/null; gh api user --jq .login' 2>&1
```
Expected: the command errors or returns nothing useful for `/user` (Apps don't have a "user" — that's expected and fine), so instead confirm identity via:
```bash
kubectl exec -n agents "$POD" -- sh -c '. /creds/tokens.env 2>/dev/null; gh api /installation/repositories --jq ".repositories[].full_name"' 2>&1
```
Expected: lists all 9 `miegjorn/*` repos, confirming the token is a valid App installation token with the expected repo access.

- [ ] **Step 3: Confirm the background refresh loop is running (interactive pod only)**

```bash
kubectl exec -n agents "$POD" -- ps aux | grep "sleep 2700"
```
Expected: a process matching the refresh loop's `sleep 2700` is present.

- [ ] **Step 4: Live PR test — confirm the identity separation actually works**

Open a real PR as `guilhem-bot[bot]` (e.g. by having Guilhem itself open one, or manually via `gh` using the minted token) touching a CODEOWNERS-protected path (e.g. a no-op comment under `Caissa/deploy/`). Attempt to merge without any review:

```bash
gh pr merge <PR#> --repo miegjorn/Caissa --squash
```
Expected: blocked with "base branch policy prohibits the merge" — same message as the Pierre-Luc-authored test PR from the merge-approval work, but this time the author (`guilhem-bot[bot]`) and the required reviewer (`@bedardpl`) are genuinely different accounts, so there is no admin-override ambiguity about who is reviewing whom.

Have Pierre-Luc approve the PR as himself (`gh pr review <PR#> --repo miegjorn/Caissa --approve`), then confirm the merge succeeds normally (no `--admin` flag needed this time):

```bash
gh pr merge <PR#> --repo miegjorn/Caissa --squash
```
Expected: succeeds without any admin override — this is the concrete proof the identity separation works, unlike the earlier verification where admin override was the only path through.

- [ ] **Step 5: Retire the old shared PAT**

Once Steps 1-4 all pass, the `occitan/github` OpenBao secret is no longer read by any container. Leave the secret in place for now (no immediate deletion needed — it's inert once nothing reads it), but note in the ledger that it's safe to delete in a future cleanup pass once you're confident the App-based flow has been running reliably for a while.

## Self-Review Notes

- **Spec coverage:** Task 1 covers App registration (spec's manual bootstrap step), Task 2 covers OpenBao seeding, Task 3 covers the JWT-mint/refresh mechanism (including the `BASH_ENV` detail needed to make the background refresh loop actually reach subprocess `gh`/`git` calls — this wasn't spelled out explicitly in the spec's shell recipe but is required for the spec's stated architecture to actually work, so it's included here as an implementation-level necessity, not a scope change), Task 4/5 cover both charts' initContainers (guilhem + component-agents, matching the spec's "all 9 agent containers" scope), Task 6 covers the spec's testing section including the live PR self-approval-block proof.
- **Placeholder scan:** no TBD/TODO; all code blocks are complete.
- **Type consistency:** `mint_installation_token` is defined once in Task 3 and its file dependencies (`/creds/github-app-id`, `/creds/github-app-installation-id`, `/creds/github-app-private-key.pem`) exactly match what Task 4/5's initContainer changes produce.
