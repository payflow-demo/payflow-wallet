# PayFlow Troubleshooting Guide

Every failure mode found during a full system audit, with root cause and exact fix.
Run `./scripts/validate.sh` first — it will tell you which layer is broken.

---

## Docker Compose

### api-gateway exits immediately on startup

**Symptom:**
```
payflow-api-gateway exited with code 1
Error: DB_PASSWORD must be set (api-gateway health check requires database access)
```

**Root cause:** The api-gateway health check pool needs database credentials at module load.

**Fix:** Ensure the `api-gateway` environment block in `docker-compose.yml` includes:
```yaml
DB_HOST: postgres
DB_PORT: 5432
DB_NAME: payflow
DB_USER: payflow
DB_PASSWORD: payflow123
```
This is already present in the current `docker-compose.yml`. If you see this error, you may have an old version — pull latest.

---

### Frontend loads but all API calls fail (Network Error / CORS)

**Symptom:** React app loads at `http://localhost`, buttons spin, errors in the browser console like `ERR_CONNECTION_REFUSED` or CORS errors.

**Root cause:** The frontend image was built with `REACT_APP_API_URL=http://localhost:3000/api` baked in (old build), and the api-gateway is not reachable via that URL, OR CORS is misconfigured.

**Fix:**
```bash
# Force a clean rebuild (no cache)
docker compose build --no-cache frontend
docker compose up -d frontend
```
The Dockerfile default (`ARG REACT_APP_API_URL=/api`) must be used — do NOT pass `--build-arg REACT_APP_API_URL=...`.

---

### Services fail with "host not found" for postgres/redis/rabbitmq

**Symptom:** Services log `ECONNREFUSED` or `getaddrinfo ENOTFOUND postgres`.

**Root cause:** Services started before infrastructure was healthy.

**Fix:**
```bash
docker compose down
docker compose up -d postgres redis rabbitmq
sleep 15
docker compose up -d
```
The `depends_on: condition: service_healthy` directives handle this automatically on `docker compose up`, but a partial restart can leave services in the wrong order.

---

### RabbitMQ UI not accessible at localhost:15672

**Symptom:** Browser shows "connection refused" at `http://localhost:15672`.

**Root cause:** The `rabbitmq:3-management-alpine` image is used. If the container hasn't started yet, or the management plugin needs time to initialise, the UI isn't available immediately.

**Fix:**
```bash
docker compose logs rabbitmq
# Wait for: "Server startup complete"
```

---

## MicroK8s / Kubernetes

### api-gateway in CrashLoopBackOff

**Symptom:**
```
kubectl logs -n payflow deploy/api-gateway
Error: DB_PASSWORD must be set
```

**Root cause:** The `db-secrets` Secret doesn't exist or doesn't contain `DB_PASSWORD`.

**Fix (local overlay):**
```bash
kubectl get secret db-secrets -n payflow
# If not found:
kubectl apply -k k8s/overlays/local
# db-secrets is defined in k8s/overlays/local/secrets-db-secrets.yaml
```

**Fix (EKS — ESO not synced yet):**
```bash
kubectl describe externalsecret db-secrets-external -n payflow
# Look for: "SecretSyncedError" or "Store not ready"
# ESO needs a few minutes after install. Check:
kubectl get pods -n external-secrets
```

---

### Pods stuck in Pending

**Symptom:** `kubectl get pods -n payflow` shows `Pending` for multiple pods.

**Root cause A — ResourceQuota exceeded:**
```bash
kubectl describe quota -n payflow
# If used == hard, the quota is exhausted
```
**Fix:** The local overlay applies `local-quota-patch.yaml` which raises limits. Ensure you applied the overlay, not just the base:
```bash
kubectl apply -k k8s/overlays/local   # not: kubectl apply -k k8s/base
```

**Root cause B — Node has insufficient resources:**
```bash
kubectl describe node | grep -A5 "Allocated resources"
```
Stop other processes or increase the MicroK8s VM memory.

---

### Frontend returns 502 for all /api/* requests

**Symptom:** Frontend loads, but every API call returns a 502 Bad Gateway.

**Root cause:** api-gateway is not Ready (see CrashLoopBackOff above), or nginx can't resolve `api-gateway.payflow.svc.cluster.local`.

**Fix:**
```bash
# Check api-gateway pod status
kubectl get pods -n payflow -l app=api-gateway

# Check nginx resolver (MicroK8s DNS addon must be enabled)
microk8s enable dns

# Check nginx config inside the frontend pod
kubectl exec -n payflow deploy/frontend -- cat /etc/nginx/conf.d/default.conf
# Should contain: resolver kube-dns.kube-system.svc.cluster.local valid=10s;
# and: proxy_pass http://api-gateway.payflow.svc.cluster.local:80;
```

---

### Ingress returns 404 for everything

**Symptom:** `curl http://www.payflow.local` returns 404.

**Root cause:** `/etc/hosts` entry missing, or wrong ingress class.

**Fix:**
```bash
# Add hosts entries
bash scripts/setup-hosts-payflow-local.sh

# Verify ingress controller is running
kubectl get pods -n ingress

# Verify ingress rule
kubectl describe ingress -n payflow
```
The local overlay ingress uses `ingressClassName: public` (MicroK8s). If your cluster uses `nginx`, update `k8s/overlays/local/ingress-local.yaml`.

---

### db-migration-job fails on EKS

**Symptom:**
```
kubectl logs -n payflow job/db-migration-job
FATAL: SSL connection is required
```

**Root cause:** Missing `PGSSLMODE=require` in the base migration job.

**Status:** The EKS overlay patch (`k8s/overlays/eks/db-migration-patch.yaml`) adds `PGSSLMODE: require`. Ensure you're applying the overlay, not the base:
```bash
IMAGE_TAG=<tag> ./k8s/overlays/eks/deploy.sh   # not: kubectl apply -k k8s/base
```

---

### EKS — kubectl times out

**Symptom:** `kubectl get nodes` hangs or returns `dial tcp: i/o timeout`.

**Root cause:** EKS cluster has `endpoint_public_access: false` — only accessible from within the VPC.

**Fix:** Open an SSH tunnel through the bastion host:
```bash
BASTION_IP=$(terraform -chdir=terraform/aws/bastion output -raw bastion_public_ip)
EKS_ENDPOINT=$(aws eks describe-cluster --name payflow-eks-cluster \
  --query 'cluster.endpoint' --output text | sed 's|https://||')
ssh -i ~/.ssh/payflow-bastion.pem \
    -L 6443:${EKS_ENDPOINT}:443 \
    ec2-user@${BASTION_IP} -N -f
```
Then retry `kubectl`.

---

### EKS — ImagePullBackOff

**Symptom:**
```
kubectl describe pod -n payflow <pod>
Failed to pull image "<ACCOUNT_ID>.dkr.ecr...": 
```

**Root cause:** `kustomization.yaml` still has literal `<ACCOUNT_ID>` / `<REGION>` / `<IMAGE_TAG>` placeholders. `kubectl apply -k` was run directly instead of via the deploy script.

**Fix:**
```bash
# Always use the deploy script, never kubectl apply -k directly on EKS:
IMAGE_TAG=<git-sha-from-ci> ./k8s/overlays/eks/deploy.sh
```

---

### AKS — Services crash with "Redis connection refused"

**Symptom:** auth-service / api-gateway logs show `ECONNREFUSED` to Redis.

**Root cause:** Azure Cache for Redis requires `rediss://` (TLS, port 6380), not `redis://`. The `REDIS_URL` in the AKS `db-secrets` Secret must use the correct scheme.

**Fix:** In Azure Key Vault, set the `payflow-redis` secret → `url` property to:
```
rediss://:YOUR_REDIS_PASSWORD@YOUR_INSTANCE.redis.cache.windows.net:6380
```
After updating Key Vault, force ESO to re-sync:
```bash
kubectl annotate externalsecret db-secrets-external -n payflow \
  force-sync=$(date +%s) --overwrite
```

---

### AKS — Pods crash with "certificate verify failed" for PostgreSQL

**Symptom:** Services log `SSL connection error: certificate verify failed`.

**Root cause:** Azure PostgreSQL Flexible Server requires SSL. The `PGSSLMODE=require` patch is applied by the AKS kustomization, but `rejectUnauthorized: false` in the service code accepts any certificate. If you see this error, the PGSSLMODE env var is missing.

**Fix:**
```bash
kubectl exec -n payflow deploy/auth-service -- env | grep PGSSLMODE
# Should print: PGSSLMODE=require
# If missing, ensure you're using the AKS overlay deploy script
```

---

## CI/CD

### GitHub Actions build passes but pods still run old image

**Root cause:** CI pushed new images to ECR/ACR, but no deploy step ran. The pipeline only builds and pushes — deployment is manual.

**Fix:** After CI completes, get the image tag from the Actions summary and run:
```bash
# EKS
IMAGE_TAG=<tag-from-ci-summary> ./k8s/overlays/eks/deploy.sh

# AKS
ACR_NAME=<your-acr> IMAGE_TAG=<tag-from-ci-summary> ./k8s/overlays/aks/deploy.sh
```

---

### GitHub Actions: "push" step skipped silently

**Symptom:** CI passes but images are not pushed to Docker Hub.

**Root cause:** `DOCKERHUB_USERNAME` secret is not set in the repository.

**Fix:** Go to GitHub → Settings → Secrets → Actions → add:
- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

---

## Terraform

### `managed-services` apply fails with "no subnets found"

**Root cause:** Applied `managed-services` before `spoke-vpc-eks`. The managed services module reads VPC subnets from the spoke state.

**Fix:** Apply in the correct order:
```
hub-vpc → spoke-vpc-eks → managed-services → bastion
```
See `terraform/README.md` for the full sequence.

---

### `terraform apply` fails with "Secret may not exist yet"

**Root cause:** The `null_resource` that writes RDS credentials to Secrets Manager ran before the secret placeholder was created by `spoke-vpc-eks`.

**Fix:**
```bash
# Re-run spoke-vpc-eks first to create the Secrets Manager placeholders
cd terraform/aws/spoke-vpc-eks && terraform apply
# Then retry managed-services
cd ../managed-services && terraform apply
```

---

## General

### How do I completely reset and start fresh?

```bash
# Docker Compose
docker compose down -v --remove-orphans
docker compose up -d

# MicroK8s
kubectl delete namespace payflow
kubectl apply -k k8s/overlays/local

# EKS — delete and re-apply app layer only (leave infra)
kubectl delete namespace payflow
IMAGE_TAG=<tag> ./k8s/overlays/eks/deploy.sh
```

### How do I run the smoke test?

```bash
# Docker Compose
./scripts/validate.sh

# MicroK8s
./scripts/validate.sh --env k8s --host http://api.payflow.local

# EKS / AKS
./scripts/validate.sh --env cloud --host https://your-api-domain.com
```
