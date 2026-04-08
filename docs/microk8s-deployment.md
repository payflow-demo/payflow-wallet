# MicroK8s Deployment Guide - PayFlow Wallet

> **Learning path:** Week 1 of [`LEARNING-PATH.md`](../LEARNING-PATH.md) is built around MicroK8s first; Docker Compose is optional for a lighter start.

> **Quick Start (beginners)**: Clone the repo, then run **one script**. It installs MicroK8s for you if needed (with enough CPU/RAM for all services), enables addons, and deploys the app. See [One-script deploy](#quick-start-one-script-deploy) below.

### Platforms

| OS | What the script does |
|----|----------------------|
| **macOS** | Multipass + MicroK8s VM; optional **0–3 worker VMs** (Multipass) joined automatically. |
| **Linux** | MicroK8s on the host via **snap** (single-node). Extra workers are **not** auto-created — use `microk8s add-node` if you need more nodes. |
| **Windows** | **Not** supported in Git Bash / PowerShell / CMD. Use **WSL2** (e.g. Ubuntu): the script sees **Linux**, so install Docker (WSL integration or `docker.io` in WSL) and **snap** MicroK8s inside WSL, then run the script from **bash in WSL**. |

---

## Quick Start: One-script deploy

**For everyone (including if you don’t have MicroK8s yet):**

1. **Prerequisites**: Docker installed and running (Docker Desktop or Docker Engine).  
   On macOS, [Multipass](https://multipass.run/) is also required (e.g. `brew install multipass`).

2. **Clone and run:**
   ```bash
   git clone <repo-url> payflow-wallet && cd payflow-wallet
   ./scripts/deploy-microk8s.sh
   ```
   The script will:
   - Install MicroK8s if it’s not installed (macOS: VM with 6 CPU, 12 GB RAM by default so the stack doesn’t run out of resources; Linux: snap install).
   - Start the MicroK8s VM if it was stopped.
   - Enable addons: dns, storage, registry, ingress, metrics-server.
   - Deploy the app with `kubectl apply -k k8s/overlays/local` and wait for infra + DB migration.
   - Print how to access the app (port-forward or ingress).

3. **Access the app** (as printed at the end):
   ```bash
   kubectl port-forward service/api-gateway 3000:80 -n payflow &
   kubectl port-forward service/frontend 8080:80 -n payflow &
   # Open: http://localhost:8080
   ```

To give the VM more resources (before first install), set env vars and run the script:
`MICROK8S_VM_CPU=8 MICROK8S_VM_MEM_GB=16 ./scripts/deploy-microk8s.sh`

---

## Manual Quick Start (if you already have MicroK8s)

If MicroK8s is already installed and running:

```bash
# 1. Enable addons and kubectl
microk8s enable dns storage registry ingress metrics-server
microk8s config > ~/.kube/microk8s-config
export KUBECONFIG=~/.kube/microk8s-config

# 2. Deploy (local overlay includes built-in db-secrets)
kubectl apply -k k8s/overlays/local

# 3. Wait for deployment
kubectl wait --for=condition=ready pod -l app=postgres -n payflow --timeout=120s
kubectl wait --for=condition=complete job/db-migration-job -n payflow --timeout=120s

# 4. Access application
kubectl port-forward service/frontend 8080:80 -n payflow &
kubectl port-forward service/api-gateway 3000:80 -n payflow &
# Open: http://localhost:8080
```

For more detail, see sections below.

---

## Table of Contents

1. [Quick Start: One-script deploy](#quick-start-one-script-deploy)
2. [Manual Quick Start](#manual-quick-start-if-you-already-have-microk8s)
3. [Prerequisites](#prerequisites)
4. [MicroK8s Setup](#microk8s-setup)
5. [Deploy Application](#deploy-application)
6. [Access Application](#access-application)
7. [Optional Features](#optional-features)
8. [Troubleshooting](#troubleshooting)
9. [Reference](#reference)

---

## Prerequisites

### Required Tools
- **Docker** Desktop or Engine (running). On **WSL2**, enable Docker Desktop’s **WSL integration** for your distro, or install Docker Engine inside WSL.
- **MicroK8s** — the [one-script deploy](#quick-start-one-script-deploy) installs it on **macOS** (via Homebrew + VM) and **Linux/WSL2** (via snap) when missing; see [Platforms](#platforms) above.
- **kubectl** — the script writes `~/.kube/microk8s-config` from `microk8s config`.

### Install MicroK8s

**macOS**:
```bash
brew install ubuntu/microk8s/microk8s
microk8s install
```

**Linux**:
```bash
sudo snap install microk8s --classic
sudo usermod -a -G microk8s $USER
newgrp microk8s
```

**Windows**: See [Platform Notes](#platform-notes) below.

---

## MicroK8s Setup

### Enable Required Add-ons
```bash
microk8s enable dns storage registry ingress metrics-server
microk8s status
```

### Configure kubectl
```bash
# macOS/Linux
microk8s config > ~/.kube/microk8s-config
export KUBECONFIG=~/.kube/microk8s-config

# Windows (PowerShell)
multipass exec microk8s-vm -- microk8s config > $env:USERPROFILE\.kube\microk8s-config
$env:KUBECONFIG = "$env:USERPROFILE\.kube\microk8s-config"

# Verify
kubectl get nodes
```

### Platform Notes

**macOS**: Runs in Multipass VM (`microk8s-vm`). Access VM: `multipass shell microk8s-vm`

**Windows**: 
- Option 1: Multipass VM (requires VirtualBox/Hyper-V)
- Option 2: WSL2 (better performance)

**Linux**: Native installation (best performance)

---

## Deploy Application

### Step 1: Secrets (local overlay — nothing to create)

If you deploy using the **local overlay** (`k8s/overlays/local`), you **do not need to create any secret files**.
The overlay includes a plain-text dev Secret at `k8s/overlays/local/secrets-db-secrets.yaml` (local-only; no External Secrets Operator required).

If you want to change dev credentials (optional), edit that file and re-apply:

```bash
kubectl apply -k k8s/overlays/local
```

**Note (cloud):** EKS/AKS use External Secrets Operator to sync from AWS Secrets Manager / Azure Key Vault. Don’t copy local dev secrets into cloud deployments.

### Step 2: Deploy with Kustomize (Recommended)

```bash
# Deploys everything: infrastructure, services, policies, HPAs
kubectl apply -k k8s/overlays/local

# Wait for infrastructure
kubectl wait --for=condition=ready pod -l app=postgres -n payflow --timeout=120s
kubectl wait --for=condition=ready pod -l app=redis -n payflow --timeout=120s
kubectl wait --for=condition=ready pod -l app=rabbitmq -n payflow --timeout=120s

# Wait for migration
kubectl wait --for=condition=complete job/db-migration-job -n payflow --timeout=120s

# Check all pods
kubectl get pods -n payflow
```

**What gets deployed**:
- Infrastructure: PostgreSQL, Redis, RabbitMQ
- Services: API Gateway, Auth, Wallet, Transaction, Notification, Frontend
- Policies: Network Policies, PDBs, Resource Quotas
- Autoscaling: HPAs for all services
- Jobs: Database migration, transaction timeout handler

### Step 3: Verify Deployment

```bash
# Check all resources
kubectl get all -n payflow

# Check specific services
kubectl get pods -n payflow -l app=auth-service
kubectl get services -n payflow

# View logs
kubectl logs -n payflow -l app=auth-service --tail=10
```

**Expected**: All pods in `Running` status, services have endpoints.

---

## Access Application

### Method 1: Port Forwarding (Development)

```bash
# Terminal 1: API Gateway
kubectl port-forward service/api-gateway 3000:80 -n payflow

# Terminal 2: Frontend
kubectl port-forward service/frontend 8080:80 -n payflow

# Access: http://localhost:8080
```

### Method 2: Ingress with HTTPS (Production-like)

```bash
# Generate self-signed certificate
cd k8s/ingress
./generate-tls-cert.sh

# Create TLS secret
kubectl create secret tls payflow-local-tls \
  --cert=certs/tls.crt --key=certs/tls.key -n payflow

# Deploy ingress
kubectl apply -f k8s/ingress/tls-ingress-local.yaml

# Add to /etc/hosts
echo "127.0.0.1 www.payflow.local api.payflow.local" | sudo tee -a /etc/hosts

# Access: https://www.payflow.local (accept self-signed cert warning)
```

---

## Optional Features

### Database Backups

```bash
# Deploy backup CronJob (daily at 2 AM UTC)
kubectl apply -f k8s/backup/postgres-backup.yaml

# Manual backup
kubectl create job --from=cronjob/postgres-backup manual-backup-$(date +%s) -n payflow
```

### Image Scanning

```bash
# Deploy security scanning (daily at 3 AM UTC)
kubectl apply -f k8s/security/image-scanning-cronjob-containerd.yaml

# Manual scan
kubectl create job --from=cronjob/image-scanning test-scan-$(date +%s) -n payflow
```

### Horizontal Pod Autoscaling

Already deployed via Kustomize. HPAs automatically scale services based on CPU (70%) and memory (80%).

```bash
# View HPAs
kubectl get hpa -n payflow

# Check scaling
kubectl describe hpa api-gateway-hpa -n payflow
```

---

## Troubleshooting

### Common Issues

**Pods not starting**:
```bash
kubectl describe pod <pod-name> -n payflow
kubectl logs <pod-name> -n payflow
```

**Image pull errors (`ImagePullBackOff` / `ErrImagePull`)**

This is the most common error on macOS + Multipass multi-node clusters. There are two separate failure modes — read both before acting.

**Why it happens (macOS + Multipass):**
- Docker on Mac cannot reach `localhost:32000` — that port lives inside the Multipass VM, not on the Mac's loopback. `docker push localhost:32000/...` times out.
- Even if you use `ctr image import` to load images into the control-plane VM's containerd, worker nodes (`payflow-worker-1`, `payflow-worker-2`) schedule pods that still try to pull from `localhost:32000`. They fail because the registry pod has nothing — `ctr import` bypassed it.
- `imagePullPolicy: Always` (the default in the base manifests) makes this worse: every pod restart hits the registry, even if the image is already present.

**What the deploy script does automatically:**
1. Builds with `--provenance=false` so `docker save` produces a plain single-manifest tar (not a manifest list that `ctr import` rejects with `unexpected EOF`).
2. Saves to a temp file and transfers via `multipass transfer` (not `exec` pipe — the exec channel truncates large binary streams).
3. Imports into the control-plane containerd with `ctr image import`.
4. Pushes from containerd into the registry pod with `ctr image push --plain-http localhost:32000/...` — this makes the image available to worker nodes.
5. Applies `local-pull-policy-patch.yaml` which sets `imagePullPolicy: IfNotPresent` for all services in the local overlay only.

**If you hit it manually (e.g. you only ran `ctr import` without the push step):**
```bash
# Replace with your actual tag (check kustomization.yaml images: section)
IMAGE_TAG=<your-tag>

for svc in api-gateway auth-service frontend notification-service transaction-service wallet-service; do
  multipass exec microk8s-vm -- sudo microk8s ctr image push --plain-http \
    "localhost:32000/${svc}:${IMAGE_TAG}"
done

# Re-apply so imagePullPolicy patch takes effect
kubectl apply -k k8s/overlays/local
```

**Verify images are in the registry:**
```bash
# Should list your tag for each service
multipass exec microk8s-vm -- sudo microk8s ctr image ls | grep localhost:32000
```

**Check which node a failing pod landed on:**
```bash
kubectl get pods -n payflow -o wide   # NODE column shows which VM the pod is on
kubectl describe pod <pod-name> -n payflow  # Events section shows the exact pull error
```

**Service connection issues**:
```bash
# Check network policies
kubectl get networkpolicies -n payflow

# Test connectivity
kubectl exec -n payflow <pod-name> -- wget -qO- http://<service>:<port>/health
```

**Database connection failed**:
```bash
# Check PostgreSQL is running
kubectl get pods -n payflow -l app=postgres

# Check resource quota (may block pod creation)
kubectl describe resourcequota payflow-resource-quota -n payflow
```

**Pods stuck Pending / NotReady nodes (Multipass workers)**:
```bash
# If scheduler says "node(s) had untolerated taint {node.kubernetes.io/unreachable}"
# and you use Multipass worker VMs, start the stopped VMs:
multipass list   # see which VMs are Stopped
multipass start kubelab-worker-1 kubelab-worker-2   # or your worker names

# Or use the script (starts workers and waits for Ready):
./scripts/fix-microk8s-nodes.sh
```
After nodes are Ready, pending pods should schedule.

**Pods Pending with "Insufficient cpu" (need more nodes)**:
```bash
# Add a new worker VM so the cluster has more capacity (instead of scaling down replicas):
./scripts/deploy-microk8s.sh add-worker [VM_NAME] [CPUS] [MEM_GB] [DISK_GB]
# Example: add payflow-worker-4 with 2 CPU and 4G RAM (20G disk default)
./scripts/deploy-microk8s.sh add-worker payflow-worker-4 2 4
```
Then run `kubectl get nodes` and wait for the new node to be Ready; pending pods will schedule. See [scripts/README.md](../scripts/README.md#deploy-microk8ssh-recommended-for-local--beginners).

### Login Issues

**502/504 Gateway Timeout**:
1. Check backend services are running: `kubectl get pods -n payflow`
2. Verify network policies allow API Gateway → backend: `kubectl get networkpolicies -n payflow`
3. Check service logs: `kubectl logs -n payflow -l app=auth-service`

**Transaction Failures**:
1. Verify transaction-service → wallet-service connectivity
2. Check network policy: `kubectl get networkpolicy wallet-service-allow-ingress-from-transaction -n payflow`
3. Review logs: `kubectl logs -n payflow -l app=transaction-service`

See [Detailed Troubleshooting](#detailed-troubleshooting) for more.

---

## Reference

### Kubernetes Structure

```
k8s/
├── base/                    # Base resources (shared)
│   ├── kustomization.yaml
│   └── db-migration-job.yaml
├── overlays/
│   ├── local/              # Local development (MicroK8s)
│   ├── eks/                # AWS EKS deployment
│   └── aks/                # Azure AKS deployment
├── deployments/            # Service deployments
├── infrastructure/         # Self-hosted infra (local only)
├── policies/               # Network policies, PDBs, quotas
├── autoscaling/            # HPAs
└── secrets/                # Secrets (gitignored)
```

### Key Commands

```bash
# Deploy
kubectl apply -k k8s/overlays/local

# Check status
kubectl get all -n payflow
kubectl get pods -n payflow
kubectl get hpa -n payflow

# View logs
kubectl logs -n payflow -l app=<service-name>

# Scale manually
kubectl scale deployment <service> --replicas=3 -n payflow

# Delete everything
kubectl delete namespace payflow
```

### Service Ports

| Service | Port | Health Check |
|---------|------|--------------|
| API Gateway | 3000 | `/health` |
| Auth Service | 3004 | `/health` |
| Wallet Service | 3001 | `/health` |
| Transaction Service | 3002 | `/health` |
| Notification Service | 3003 | `/health` |
| Frontend | 80 | `/health` |

### Resource Limits

All services have resource requests/limits defined:
- **Requests**: CPU 250m, Memory 256Mi
- **Limits**: CPU 500m, Memory 512Mi

### HPA Configuration

| Service | Min | Max | CPU Target | Memory Target |
|---------|-----|-----|------------|---------------|
| API Gateway | 2 | 10 | 70% | 80% |
| Auth Service | 2 | 8 | 70% | 80% |
| Wallet Service | 2 | 8 | 70% | 80% |
| Transaction Service | 2 | 10 | 70% | 80% |
| Notification Service | 2 | 6 | 70% | 80% |
| Frontend | 2 | 6 | 70% | 80% |

---

## Detailed Troubleshooting

### Issue: Pod CrashLoopBackOff

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n payflow
kubectl logs <pod-name> -n payflow --previous
```

**Common causes**:
- Missing ConfigMap/Secret
- Database connection failed
- Port already in use
- Resource quota exceeded

### Issue: Network Policy Blocking Traffic

**Symptoms**: Services can't communicate

**Fix**:
```bash
# Check policies
kubectl get networkpolicies -n payflow
kubectl describe networkpolicy <policy-name> -n payflow

# Verify both ingress and egress rules exist
# Network policies are bidirectional - both sides need rules
```

### Issue: Resource Quota Preventing Pod Creation

**Error**: `exceeded quota: payflow-resource-quota`

**Fix**:
```bash
# Check quota usage
kubectl describe resourcequota payflow-resource-quota -n payflow

# Add resources to missing pods or increase quota
kubectl edit resourcequota payflow-resource-quota -n payflow
```

### Issue: Node disk-pressure or Pods Pending (Insufficient cpu)

**Scheduler message**: `node(s) had untolerated taint {node.kubernetes.io/disk-pressure}` or `Insufficient cpu`

**Causes**: A node is low on disk (Kubernetes taints it so no new pods schedule there), or total CPU requested exceeds allocatable capacity.

**Fix (disk-pressure on a Multipass worker)**:
```bash
# See which node has the taint
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Free disk on the VM (e.g. kubelab-worker-3)
multipass exec kubelab-worker-3 -- sudo microk8s ctr images prune --all  # remove unused images
multipass exec kubelab-worker-3 -- sudo snap set microk8s disk.size=50G  # if using expandable disk
# Or: multipass exec kubelab-worker-3 -- df -h   # then clear logs/temp: sudo journalctl --vacuum-size=50M
```
After free disk crosses the threshold, the kubelet removes the taint and the node is schedulable again. If the node is still critical, you can remove the taint manually (not recommended unless you've freed space): `kubectl taint nodes kubelab-worker-3 node.kubernetes.io/disk-pressure:NoSchedule-`

**Fix (Insufficient cpu)**: Scale down old/crashing ReplicaSets to free CPU, or add a worker: `./scripts/deploy-microk8s.sh add-worker`. To scale down old RS: `kubectl get rs -n payflow` then `kubectl scale rs -n payflow <name> --replicas=0` for the ones that are crashing or redundant.

### Issue: HPA Shows `<unknown>` Metrics

**Cause**: Metrics-server not running

**Fix**:
```bash
microk8s enable metrics-server
kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=60s
kubectl top pods -n payflow  # Should show metrics now
```

---

## Platform-Specific Notes

### macOS (Multipass VM)

- MicroK8s runs in `microk8s-vm` Multipass VM; worker nodes may be `kubelab-worker-1`, `kubelab-worker-2`.
- If worker VMs are **Stopped**, nodes show NotReady and pods stay Pending. Start them: `multipass start kubelab-worker-1 kubelab-worker-2`, or run `./scripts/fix-microk8s-nodes.sh`.
- Access VM: `multipass shell microk8s-vm`
- Transfer files: `multipass transfer <local> microk8s-vm:<remote>`
- Import images: Build on host, transfer to VM, import to containerd

### Windows

**Multipass VM**:
- Requires VirtualBox or Hyper-V
- Similar to macOS workflow

**WSL2**:
- Better performance than Multipass
- Direct access (no VM commands)
- Use WSL paths: `/mnt/c/...`

### Linux (Native)

- Direct installation (best performance)
- No VM overhead
- Standard Linux commands

---

## Cleanup

```bash
# Delete application
kubectl delete namespace payflow

# Stop MicroK8s
microk8s stop

# Reset MicroK8s (⚠️ deletes everything)
microk8s reset
```

---

## Next Steps

1. ✅ Application running in MicroK8s
2. 🔄 Set up CI/CD pipeline
3. 🔄 Configure monitoring (Prometheus/Grafana)
4. 🔄 Set up logging (ELK/Loki)
5. 🔄 Production deployment (EKS/AKS)
6. 🔄 Optional: share your lab on a real HTTPS hostname — [Cloudflare Tunnel / DNS](cloudflare-setup.md)

---

*Last updated: December 25, 2025*
