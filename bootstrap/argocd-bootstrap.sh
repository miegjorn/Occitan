#!/usr/bin/env bash
# Occitan Stack — ArgoCD bootstrapper
#
# Installs ArgoCD into the cluster, then applies the app-of-apps manifest
# that hands GitOps control to this repository.
#
# Environment variables (export before running):
#   ARGOCD_NAMESPACE   Namespace to install ArgoCD in      (default: argocd)
#   ARGOCD_VERSION     ArgoCD install manifest version      (default: v2.10.0)
#   ARGOCD_REPO_URL    Git URL for the app-of-apps source   (default: https://github.com/miegjorn/Occitan)
#   MATRIX_DOMAIN      Your Matrix homeserver domain        (REQUIRED — e.g. matrix.example.com)
#
# Usage:
#   export MATRIX_DOMAIN=matrix.example.com
#   ./bootstrap/argocd-bootstrap.sh
#
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.10.0}"
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-https://github.com/miegjorn/Occitan}"
MATRIX_DOMAIN="${MATRIX_DOMAIN:?Error: MATRIX_DOMAIN must be set (e.g. matrix.example.com)}"

# ── ArgoCD install ───────────────────────────────────────────────────────────

echo "▶ Installing ArgoCD ${ARGOCD_VERSION} → namespace '${ARGOCD_NAMESPACE}'..."
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${ARGOCD_NAMESPACE}" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "▶ Waiting for ArgoCD server (up to 3 min)..."
kubectl rollout status deployment/argocd-server \
  -n "${ARGOCD_NAMESPACE}" --timeout=180s

# ── App-of-apps ──────────────────────────────────────────────────────────────

echo "▶ Applying app-of-apps → ${ARGOCD_REPO_URL} / deploy/apps..."
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: occitan-stack
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: occitan
spec:
  project: default
  source:
    repoURL: ${ARGOCD_REPO_URL}
    targetRevision: HEAD
    path: deploy/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# ── Credentials hint ─────────────────────────────────────────────────────────

ARGOCD_PASSWORD=$(
  kubectl get secret argocd-initial-admin-secret \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath="{.data.password}" | base64 -d
)

echo ""
echo "✓ ArgoCD is running. App-of-apps applied."
echo ""
echo "  Admin password : ${ARGOCD_PASSWORD}"
echo "  UI (port-fwd)  : kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
echo "  CLI login      : argocd login localhost:8080 --username admin --password '${ARGOCD_PASSWORD}' --insecure"
echo ""
echo "  MATRIX_DOMAIN  : ${MATRIX_DOMAIN}"
echo ""
echo "  Before syncing agent workloads, create the required Kubernetes secrets:"
echo "    kubectl create secret generic agent-secrets -n occitan-system \\"
echo "      --from-literal=anthropic-api-key=<YOUR_KEY> \\"
echo "      --from-literal=matrix-as-token=<YOUR_TOKEN>"
echo ""
echo "  The mock echo-agent image is used by default. Override with your own"
echo "  values-production.yaml (never committed to this repository)."
