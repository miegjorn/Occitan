#!/usr/bin/env bash
# Applies branch protection to `main` on all Occitan stack repos, requiring a
# Code Owner review (@bedardpl, per each repo's .github/CODEOWNERS) before merge.
# Idempotent — safe to re-run.
#
# Requires: gh CLI authenticated as an account with admin rights on each repo —
# run this as Pierre-Luc, from his own shell, never with Guilhem's shared token.
#
# Usage: scripts/setup-branch-protection.sh
set -euo pipefail

ORG=miegjorn
REPOS=(Gardian Fondament Farga Amassada Charradissa Cor Caissa nervi Occitan)

for repo in "${REPOS[@]}"; do
  echo "Protecting ${ORG}/${repo}@main..."
  gh api --method PUT "repos/${ORG}/${repo}/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true
  },
  "restrictions": null
}
JSON
  echo "✓ ${repo}"
done
