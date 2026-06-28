#!/usr/bin/env bash
# Occitan Stack — KinD cluster bootstrapper
#
# Creates a local KinD Kubernetes cluster with a Docker registry sidecar,
# then connects them so containerd can pull images from localhost:<REGISTRY_PORT>.
#
# Environment variables (export before running):
#   CLUSTER_NAME     KinD cluster name             (default: occitan)
#   REGISTRY_NAME    Local registry container name  (default: occitan-registry)
#   REGISTRY_PORT    Host port for the registry     (default: 5001)
#   KIND_VERSION     Kubernetes node image tag      (default: v1.29.2)
#
# Usage:
#   export CLUSTER_NAME=occitan REGISTRY_PORT=5001
#   ./bootstrap/kind-up.sh
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-occitan}"
REGISTRY_NAME="${REGISTRY_NAME:-occitan-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
KIND_NODE_IMAGE="kindest/node:${KIND_VERSION:-v1.29.2}"

# ── Registry ────────────────────────────────────────────────────────────────

echo "▶ Local registry '${REGISTRY_NAME}' on port ${REGISTRY_PORT}..."
if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
  echo "  Already running."
else
  docker run -d --restart=always \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --name "${REGISTRY_NAME}" \
    registry:2
  echo "  Started."
fi

# ── KinD cluster ────────────────────────────────────────────────────────────

echo "▶ KinD cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "  Already exists."
else
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
          endpoint = ["http://${REGISTRY_NAME}:5000"]
EOF
fi

# ── Connect registry to cluster network ─────────────────────────────────────

echo "▶ Connecting registry to cluster network..."
docker network connect kind "${REGISTRY_NAME}" 2>/dev/null || true

# ── Annotate registry in cluster (standard convention) ──────────────────────

echo "▶ Documenting registry in cluster ConfigMap..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo ""
echo "✓ Cluster '${CLUSTER_NAME}' is ready."
echo "  Registry: localhost:${REGISTRY_PORT}"
echo "  Push images: docker tag <image> localhost:${REGISTRY_PORT}/<name>:<tag> && docker push localhost:${REGISTRY_PORT}/<name>:<tag>"
echo ""
echo "Next: ./bootstrap/argocd-bootstrap.sh"
