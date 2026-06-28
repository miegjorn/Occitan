# Bootstrap

Two scripts that take a machine from zero to a running ArgoCD-managed Occitan cluster.

## Order of operations

```
kind-up.sh          # 1. KinD cluster + local registry
argocd-bootstrap.sh # 2. ArgoCD + app-of-apps → GitOps takes over
```

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Docker | 20.10+ | https://docs.docker.com/get-docker/ |
| KinD | 0.20+ | https://kind.sigs.k8s.io |
| kubectl | 1.28+ | https://kubernetes.io/docs/tasks/tools/ |
| Helm | 3.12+ | https://helm.sh |
| ArgoCD CLI | 2.9+ | https://argo-cd.readthedocs.io/en/stable/cli_installation/ |

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | no | `occitan` | KinD cluster name |
| `REGISTRY_NAME` | no | `occitan-registry` | Local registry container name |
| `REGISTRY_PORT` | no | `5001` | Host port for local registry |
| `KIND_VERSION` | no | `v1.29.2` | Kubernetes node image tag |
| `ARGOCD_NAMESPACE` | no | `argocd` | Namespace for ArgoCD installation |
| `ARGOCD_VERSION` | no | `v2.10.0` | ArgoCD install manifest version |
| `ARGOCD_REPO_URL` | no | `https://github.com/miegjorn/Occitan` | Git source for app-of-apps |
| `MATRIX_DOMAIN` | **yes** | — | Your Matrix homeserver domain (e.g. `matrix.example.com`) |

## What you get after both scripts

- A 3-node KinD cluster (1 control-plane, 2 workers)
- A local Docker registry at `localhost:<REGISTRY_PORT>`
- ArgoCD running in the `argocd` namespace
- The `occitan-stack` ArgoCD Application pointing at `deploy/apps/` in this repo
- All components deploying with the mock echo-agent image

## Secrets

Before agent workloads can start, create the following Kubernetes secrets manually:

```bash
# Agent API credentials
kubectl create secret generic agent-secrets -n occitan-system \
  --from-literal=anthropic-api-key=<YOUR_ANTHROPIC_API_KEY> \
  --from-literal=matrix-as-token=<YOUR_MATRIX_AS_TOKEN> \
  --from-literal=matrix-hs-token=<YOUR_MATRIX_HS_TOKEN>

# Synapse registration secret
kubectl create secret generic synapse-secrets -n occitan-system \
  --from-literal=registration-shared-secret=<YOUR_REGISTRATION_SHARED_SECRET>
```

These secrets are **never** stored in this repository.
