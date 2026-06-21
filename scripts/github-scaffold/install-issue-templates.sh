#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/Users/bedardpl/project"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS=(Gardian Fondament Farga Amassada Charradissa Cor Caissa)

for repo in "${REPOS[@]}"; do
  slug=$(echo "${repo}" | tr '[:upper:]' '[:lower:]')
  dest="${WORKSPACE}/${repo}/.github/ISSUE_TEMPLATE"
  mkdir -p "${dest}"
  for tmpl in bug_report feature_request; do
    sed "s/__COMPONENT__/${slug}/" "${SCRIPT_DIR}/templates/${tmpl}.yml" > "${dest}/${tmpl}.yml"
    echo "installed ${repo}/.github/ISSUE_TEMPLATE/${tmpl}.yml"
  done
done
