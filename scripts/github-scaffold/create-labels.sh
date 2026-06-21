#!/usr/bin/env bash
set -euo pipefail

OWNER="miegjorn"
REPOS=(Gardian Fondament Farga Amassada Charradissa Cor Caissa)

# Story-level type (Bug/Task/Feature) is the native GitHub Issue Type, not a
# label — these labels only mark which repo an issue belongs to.
create_label() {
  local repo="$1" name="$2" color="$3" desc="$4"
  if gh label list --repo "${OWNER}/${repo}" --json name --jq '.[].name' 2>/dev/null | grep -qx "${name}"; then
    echo "skip ${repo}: ${name} (exists)"
  else
    if gh label create "${name}" --repo "${OWNER}/${repo}" --color "${color}" --description "${desc}" 2>/dev/null; then
      echo "created ${repo}: ${name}"
    else
      echo "skip ${repo}: ${name} (exists)"
    fi
  fi
}

for repo in "${REPOS[@]}"; do
  slug=$(echo "${repo}" | tr '[:upper:]' '[:lower:]')
  create_label "${repo}" "component:${slug}" "BFD4F2" "Scoped to the ${repo} repo"
done
