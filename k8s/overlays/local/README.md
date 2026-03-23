# Local / MicroK8s Overlay

Deploy the full PayFlow stack on a local MicroK8s cluster.

## Prerequisites

- MicroK8s installed (`snap install microk8s --classic`)
- Required addons enabled:
  ```bash
  microk8s enable dns ingress storage
  ```
- `/etc/hosts` entries (run once):
  ```bash
  bash scripts/setup-hosts-payflow-local.sh
  ```

## Deploy

```bash
# From repo root — builds and deploys all manifests with local patches applied
kubectl apply -k k8s/overlays/local
```

## Access

| URL | Service |
|-----|---------|
| http://www.payflow.local | Frontend (React app) |
| http://api.payflow.local | API Gateway (curl / Postman) |

## How it differs from the base

| Patch file | What it changes |
|---|---|
| `local-config-patch.yaml` | ConfigMap: self-hosted postgres/redis/rabbitmq hostnames |
| `local-env-patch.yaml` | Sets `NODE_ENV=development` on all services (allows default DB password) |
| `local-probe-delays-patch.yaml` | Extends readiness/liveness `initialDelaySeconds` for slow cold starts |
| `local-quota-patch.yaml` | Raises namespace ResourceQuota so all replicas can schedule |
| `secrets-db-secrets.yaml` | Plain-text dev Secret (no ESO required — local only) |
| `infra/` | Self-hosted Postgres, Redis, RabbitMQ StatefulSets |
| `ingress-local.yaml` | Ingress: `/api` → api-gateway:80, `/` → frontend:80 on `www.payflow.local` |

## Image note

The frontend image is built with `REACT_APP_API_URL=/api` (the Dockerfile default).
**Do not pass `--build-arg REACT_APP_API_URL=http://localhost:3000/api`** — that bakes a
Docker-Compose-only URL into the bundle and breaks all K8s environments.
The same image works for Docker Compose, MicroK8s, EKS, and AKS without rebuilding.

## Testing your own code changes in MicroK8s

MicroK8s uses its own containerd runtime — it does **not** share the local Docker daemon.
If you modify a service and want to test it in MicroK8s, import the image directly:

```bash
# Build with Docker Compose (builds all services, includes shared/ correctly)
docker compose build api-gateway

# Import the built image into MicroK8s containerd
docker save veeno/api-gateway:latest | microk8s ctr images import -

# Restart the deployment so the new image is picked up
kubectl rollout restart deployment/api-gateway -n payflow
kubectl rollout status deployment/api-gateway -n payflow
```

Replace `api-gateway` / `veeno/api-gateway` with the service name you changed.
Repeat the `docker save | microk8s ctr images import` step for each changed service.

## Monitoring (optional)

```bash
kubectl apply -k k8s/monitoring
```

Or locally with Docker Compose:
```bash
docker compose --profile monitoring up
```
Access Grafana at http://localhost:3006 (admin/admin).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| api-gateway CrashLoopBackOff | `DB_PASSWORD` not in env | Already fixed in base deployment — ensure you're applying the latest overlay |
| 502 on /api calls | api-gateway not ready | Check `kubectl logs -n payflow deploy/api-gateway`; wait for `DB_PASSWORD` pod to become Ready |
| frontend shows blank | nginx resolver failure | Ensure MicroK8s DNS addon is enabled: `microk8s enable dns` |
| Pods stuck Pending | ResourceQuota exceeded | `kubectl describe quota -n payflow`; quota patch should have raised limits |
