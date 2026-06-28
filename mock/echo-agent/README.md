# mock/echo-agent

> **This is a Python placeholder for showcase and local development.**
>
> All production components of the Occitan stack are written in **Rust**.
> See the real implementations:
> [Gardian](https://github.com/miegjorn/Gardian) ·
> [Farga](https://github.com/miegjorn/Farga) ·
> [Amassada](https://github.com/miegjorn/Amassada) ·
> [Charradissa](https://github.com/miegjorn/Charradissa) ·
> [Cor](https://github.com/miegjorn/Cor) ·
> [Fondament](https://github.com/miegjorn/Fondament)

## Purpose

The echo-agent stands in for any Occitan component in a local cluster. It lets you:

- Verify ArgoCD is deploying and syncing correctly
- Test Kubernetes service discovery (components talk to each other by service name)
- Validate health check wiring before swapping in real images
- Demonstrate the stack topology to someone without exposing private images

## API

| Method | Path | Response |
|---|---|---|
| `GET` | `/health` | `{"status": "ok", "component": "<AGENT_NAME>"}` |
| `POST` | `/invoke` | `{"echo": <request body>, "mock": true, "component": "<AGENT_NAME>"}` |

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `AGENT_NAME` | `echo-agent` | Name reported in `/health` — set to the component name |
| `PORT` | `8080` | Listening port |

## Build & run locally

```bash
docker build -t echo-agent ./mock/echo-agent
docker run -p 8080:8080 -e AGENT_NAME=gardian echo-agent
curl http://localhost:8080/health
# {"status": "ok", "component": "gardian"}
```

## Replacing with the real image

In your `values-production.yaml` (never committed to this repository):

```yaml
# Example: replace gardian with the real Rust image
gardian:
  image: ghcr.io/miegjorn/gardian:latest
```
