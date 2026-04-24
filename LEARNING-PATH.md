# PayFlow Learning Path

> This repo is a **production-shaped** fintech stack on purpose: more moving parts than a toy demo, but every piece is documented. Follow the weeks in order and you will have run the same app on **local Kubernetes**, **broken it on purpose**, **reasoned about architecture like a senior**, and (optionally) **provisioned real cloud infra with Terraform**—a credible “I did not just watch a video” story.

**Navigation:** **[`docs/README.md`](docs/README.md)** — one map for deploy docs (so you never open five “how to deploy” guides at once).

> **Note on `docs/` links:** The `docs/` folder ships inside the cloned repo and every link below works locally. The folder is intentionally not rendered on GitHub — clone first, then open files in your editor or terminal.

---

## The journey (what “done” looks like)

| Week | You will |
|------|----------|
| **1** | Run PayFlow on **MicroK8s**, validate it, use the UI, trace **send money**, read service code and **why** the stack is built this way |
| **2** | Understand **Ingress, Kustomize overlays, network policies**, run **HOME-LAB-DRILLS**, optional **local GitOps** (Argo CD + runner) |
| **3** | Go deep on **architecture, tracing, monitoring, security**—interview-grade synthesis |
| **Optional** | **Minimal triad**: SLO-style metrics, correlation-ID trace + blast radius, idempotency / DB sanity |
| **4** | **AWS EKS** via **`./spinup.sh`** + Terraform module order, **ECR** images, **`deploy.sh`**, plus **CI/CD** workflows |

**Optional shortcut:** If you cannot run MicroK8s yet, start with **Docker Compose** (Week 1 optional block)—fastest feedback, less “real cluster.” You can return to MicroK8s in Week 2.

---

## Who this is for

- **Career switchers** who want to see how production systems are wired, not just CRUD tutorials  
- **Developers** who have not shipped a multi-service system end to end  
- **DevOps learners** who want Kubernetes, Terraform, and CI/CD on a real codebase  
- **Fintech-curious** engineers who want to follow **money** through queues, DB locks, and idempotency  

---

## Week 1 — MicroK8s first: run it, trace money, read the code

**Goal:** The app runs on **Kubernetes on your machine**. You can explain what happens when someone sends money and how each service fits in.

**Prerequisites:** **Docker** running; on macOS, **Multipass** (MicroK8s runs in a VM). Full detail: [`docs/microk8s-deployment.md`](docs/microk8s-deployment.md).

### Day 1–2: Deploy with MicroK8s and validate

From the repo root:

```bash
git clone <your-fork-url>
cd payflow-wallet-2   # or your clone directory name

./scripts/deploy-microk8s.sh
# Answer prompts (build images to local registry when asked if this is your first time)

# Local ingress hostnames (once per machine)
bash scripts/setup-hosts-payflow-local.sh

export KUBECONFIG="${HOME}/.kube/microk8s-config"   # if the script printed this

./scripts/validate.sh --env k8s --host http://api.payflow.local
# Expected: "All checks passed — PayFlow is healthy"
```

Open **http://www.payflow.local** → register two users → send money between them.

**Then read (in order):**

1. [`README.md`](README.md) — architecture diagram and golden paths  
2. [`docs/system-flow.md`](docs/system-flow.md) — every step behind “Send Money”  

**Checkpoint** (answers in `system-flow.md`):

- Which **tables** does a transfer touch? *(wallets, transactions, notifications)*  
- Which **queues**? *(transactions → notifications)*  
- Which **services** in order? *(api-gateway → transaction-service → wallet-service → notification-service)*  

**Stuck?** [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) (MicroK8s) + [`docs/microk8s-deployment.md`](docs/microk8s-deployment.md) troubleshooting.

---

### Optional: Docker Compose first (lighter, no Kubernetes)

Use this if MicroK8s is too heavy for your machine **or** you want the fastest possible UI smoke test before Week 2.

```bash
docker compose up -d
# Wait ~30s for Postgres

./scripts/validate.sh
open http://localhost
```

**Tradeoff:** You skip schedulers, Services, and Ingress until Week 2—you still learn the **product** and **money path** the same way.

**Gotchas:** [`docs/LOCAL-SETUP-GOTCHAS.md`](docs/LOCAL-SETUP-GOTCHAS.md)  

**Monitoring add-on (optional):** `docker compose --profile monitoring up -d` — useful for the [minimal triad](#prod-driven-lab-minimal-triad-no-extra-platform) later.

---

### Day 3–4: Read the service code

For each folder: read **`README.md`**, then **`server.js`** (or main entry).

1. [`services/auth-service`](services/auth-service/README.md)  
2. [`services/wallet-service`](services/wallet-service/README.md) — **most important for fintech**  
3. [`services/transaction-service`](services/transaction-service/README.md) — **most complex**  
4. [`services/notification-service`](services/notification-service/README.md)  
5. [`services/api-gateway`](services/api-gateway/README.md)  
6. [`services/frontend`](services/frontend/README.md)  

**Checkpoint:**

- **Circuit breaker** (transaction-service): *stops calling a failing dependency so it can recover*  
- **`FOR UPDATE`** (wallet-service): *row lock so two transfers cannot corrupt balance reads*  

---

### Day 5: Why this stack exists

Read [`docs/technology-choices.md`](docs/technology-choices.md) — PostgreSQL vs document DB, RabbitMQ vs synchronous HTTP, Redis for sessions, etc. This is senior-interview vocabulary.

---

## Week 2 — Kubernetes depth (you are already on the cluster)

**Goal:** Name what Kubernetes adds vs Compose; break things safely; optionally wire **GitOps** locally.

### Day 1: Traffic and manifests

Read in order:

- [`docs/understanding-ingress.md`](docs/understanding-ingress.md)  
- [`k8s/overlays/local/README.md`](k8s/overlays/local/README.md)  

**Checkpoint:** Why `kubectl apply -k k8s/overlays/local` and **not** `k8s/base` alone?  
*Base = shared YAML for every environment. Local overlay adds dev secrets, quotas, `localhost:32000` images, probes, ingress. Always apply an **overlay**, not raw base.*

---

### Day 2: Isolation in the cluster

Skim [`k8s/base/policies/network-policies.yaml`](k8s/base/policies/network-policies.yaml) and one Deployment under `k8s/base/deployments/` (e.g. `api-gateway`). Tie labels to Services.

---

### Day 3–4: Deliberate failure (drills + snippets)

**Structured exercises:** [`docs/HOME-LAB-DRILLS.md`](docs/HOME-LAB-DRILLS.md) — wrong hosts, RabbitMQ down, scale to zero, validate smoke.

**Quick chaos (run on MicroK8s):**

```bash
kubectl delete pod -n payflow -l app=transaction-service
kubectl rollout status deployment/transaction-service -n payflow
kubectl get events -n payflow --sort-by='.lastTimestamp' | tail -20
```

Scale: `kubectl scale deployment api-gateway -n payflow --replicas=3`

**Resource pressure (undo after):**

```bash
kubectl patch deployment api-gateway -n payflow \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"api-gateway","resources":{"requests":{"cpu":"99"}}}]}}}}'
kubectl get pods -n payflow
kubectl rollout undo deployment/api-gateway -n payflow
```

**Checkpoint:** You can explain **Deployment + Service + Ingress** and why all three matter.

---

### Day 5 (optional): Local GitOps capstone

End-to-end **push → build → registry → manifest bump → Argo CD sync** (no AWS): [`docs/cicd-local.md`](docs/cicd-local.md) and `.github/workflows/gitops-local.yml`.

---

## Week 3 — Architecture at interview depth

**Goal:** Whiteboard this system in ~30 minutes.

### Deep dives (pick order by interest)

| Doc | You learn |
|-----|-----------|
| [`docs/architecture.md`](docs/architecture.md) | System design |
| [`docs/ARCHITECTURE-MICROSERVICES-VS-MONOLITH.md`](docs/ARCHITECTURE-MICROSERVICES-VS-MONOLITH.md) | When to split services |
| [`docs/tracing-a-single-request.md`](docs/tracing-a-single-request.md) | One request end to end |
| [`docs/monitoring.md`](docs/monitoring.md) | Prometheus, Grafana, SLIs/SLOs |
| [`docs/SECURITY-AND-RELIABILITY-FIXES.md`](docs/SECURITY-AND-RELIABILITY-FIXES.md) | Hardening patterns |

### Patterns to name out loud

- **Idempotency** — `POST /transactions` safe to retry  
- **Atomic transactions** — wallet transfers do not half-complete  
- **Event-driven** — notifications via queue, not synchronous fan-out  
- **Circuit breakers** — fail fast on unhealthy wallet dependency  

**Checkpoint:** Could you draw data flow and justify each boundary?

---

## Prod-driven lab: minimal triad (no extra platform)

Three habits that separate “it runs” from “I can operate it”: **measurable**, **recoverable**, **honest about consistency**.

Works on **MicroK8s** or **Compose**. **Easiest metrics path:** `docker compose --profile monitoring up -d` (Grafana/Prometheus in README) even if your day-to-day app is on K8s—or follow [`docs/monitoring.md`](docs/monitoring.md) for cluster-side metrics when you are ready.

### 1. SLO-style thresholds + deliberate breakage

Pick 2–3 **SLIs** (e.g. accept-path latency, wallet error rate, queue depth). Write one-line informal SLOs. **Break** something (CPU throttle, kill pod, stop RabbitMQ). Note which graph and which log moves first.

**Read:** [`docs/monitoring.md`](docs/monitoring.md). **Mental model:** [RED](https://sre.google/sre-book/monitoring-distributed-systems/).

### 2. Correlation ID + one failure + blast radius note

Capture correlation ID across services ([`services/api-gateway/README.md`](services/api-gateway/README.md)). One drill from [`docs/HOME-LAB-DRILLS.md`](docs/HOME-LAB-DRILLS.md). Write four lines: blast radius, symptom, first signal, recovery order.

**Read:** [`docs/tracing-a-single-request.md`](docs/tracing-a-single-request.md), [`docs/system-flow.md`](docs/system-flow.md).

### 3. Idempotency + balance sanity

Same idempotency key twice → one ledger effect ([`services/transaction-service/README.md`](services/transaction-service/README.md)). After load or chaos, a simple **DB check** that balances match expectations ([`docs/system-flow.md`](docs/system-flow.md)).

**Checkpoint:** You can show **metrics + logs + DB** for one happy path and one failure.

---

## Week 4 — Cloud (EKS / AKS), Terraform, CI/CD

**Goal:** Same app on **real** infra: Terraform in the **correct module order**, images in a cloud registry, rollout via `deploy.sh`, and you understand **GitHub Actions**.

### Before you type commands

- AWS: account, `aws configure`, `aws sts get-caller-identity`  
- Tools: Terraform ≥ 1.5, `kubectl`, `helm`  
- **Read the map first:** [`docs/README.md`](docs/README.md) → **AWS EKS infrastructure** table  
- Then skim **[`docs/INFRASTRUCTURE-ONBOARDING.md`](docs/INFRASTRUCTURE-ONBOARDING.md)** (§1–2 minimum) so you know *why* Hub → Spoke → managed services → bastion  

### EKS path (canonical — matches this repo’s Terraform layout)

**Do not** run a single `terraform apply` in a random folder. Use the scripted order or the manual module sequence documented in onboarding.

```bash
# Repo root — interactive; creates remote state, applies modules in order (Hub, EKS spoke, RDS/Redis/MQ, bastion, FinOps)
./spinup.sh
# Choose: aws
# Workspace: dev (or prod)

# When spinup prints success, continue with "After infrastructure" in README Environment 3:
#   bastion tunnel (if private API), aws eks update-kubeconfig, External Secrets Operator if not already installed,
#   then deploy the app with an image tag from CI or a local ECR push.
```

**Concrete next steps** (copy-paste blocks and timing): **[`README.md`](README.md)** → section **Environment 3: AWS EKS** → **After infrastructure (both options)** through validate.

**Images:**

- **CI:** Push to `main` → `.github/workflows/build-and-deploy.yml` can push to **ECR** when AWS secrets are set; use the **short SHA** from the Actions summary as `IMAGE_TAG`.  
- **CLI:** From repo root, `./scripts/build-push-ecr.sh <tag>` when your AWS/ECR context is configured (see script and [`docs/INFRASTRUCTURE-AND-DEPLOYMENT-GUIDE.md`](docs/INFRASTRUCTURE-AND-DEPLOYMENT-GUIDE.md)).

**Deploy app to EKS:**

```bash
cd k8s/overlays/eks && IMAGE_TAG=<git-sha-from-ci-or-script> ./deploy.sh
```

**If something fails:** [`docs/DEPLOY-TROUBLESHOOTING.md`](docs/DEPLOY-TROUBLESHOOTING.md) + [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) (EKS sections).

**Manual Terraform** (no script): same order as `spinup.sh` — see [`docs/DEPLOYMENT-ORDER.md`](docs/DEPLOYMENT-ORDER.md) and [`terraform/README.md`](terraform/README.md).

---

### AKS path

```bash
./spinup.sh
# Choose: aks
```

Then deploy with `k8s/overlays/aks` and vars as in README short form. Read [`docs/AKS-AMQP-INCOMPATIBILITY.md`](docs/AKS-AMQP-INCOMPATIBILITY.md) for a real compatibility lesson.

---

### CI/CD

- **Cloud runners:** [`.github/workflows/build-and-deploy.yml`](.github/workflows/build-and-deploy.yml) — header comments list secrets.  
- **MicroK8s + self-hosted:** [`docs/cicd-local.md`](docs/cicd-local.md).  
- **Index:** [`docs/README.md`](docs/README.md) → CI/CD section.

**Checkpoint:** You can describe **edit → image → registry → manifest / deploy → running pods** for one change.

---

## When things go wrong

1. **`./scripts/validate.sh`** — with `--env k8s --host http://api.payflow.local` on MicroK8s, or default for Compose, or `--env cloud` for EKS ingress URL.  
2. **[`docs/README.md`](docs/README.md)** — which doc to open (deploy vs runtime).  
3. **[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)** — quick fixes.  
4. **[`docs/troubleshooting.md`](docs/troubleshooting.md)** — deep dives.  

| Environment | Start with |
|-------------|------------|
| Compose | `TROUBLESHOOTING.md` → Docker |
| MicroK8s | `TROUBLESHOOTING.md` + [`docs/microk8s-deployment.md`](docs/microk8s-deployment.md) |
| EKS / AKS | `TROUBLESHOOTING.md` + [`docs/DEPLOY-TROUBLESHOOTING.md`](docs/DEPLOY-TROUBLESHOOTING.md) |

---

## What interviewers will ask that this prepares you for

- “Design a payment flow” — you shipped one  
- “Double-charging / retries” — idempotency keys  
- “Slow dependency” — circuit breaker + queues  
- “Deployment vs StatefulSet” — Postgres on K8s  
- “Debug a 500 across services” — correlation IDs + drill habit  
- “Network policy” — you have read and broken the cluster  
- “CI/CD” — `.github/workflows/` + [`docs/README.md`](docs/README.md)  

---

## Quick reference

| I want to… | Go to |
|------------|--------|
| **Follow the curriculum** | This file, top to bottom |
| **Pick one deploy doc** | [`docs/README.md`](docs/README.md) |
| **Run on Kubernetes (recommended)** | `./scripts/deploy-microk8s.sh` + [`docs/microk8s-deployment.md`](docs/microk8s-deployment.md) |
| **Run without K8s (fast)** | `docker compose up -d` + [`README.md`](README.md) |
| **Money path** | [`docs/system-flow.md`](docs/system-flow.md) |
| **Architecture** | [`docs/architecture.md`](docs/architecture.md) |
| **Drills** | [`docs/HOME-LAB-DRILLS.md`](docs/HOME-LAB-DRILLS.md) |
| **Prod-style triad** | [Minimal triad](#prod-driven-lab-minimal-triad-no-extra-platform) above |
| **AWS first time** | [`docs/INFRASTRUCTURE-ONBOARDING.md`](docs/INFRASTRUCTURE-ONBOARDING.md) → [`docs/DEPLOYMENT-ORDER.md`](docs/DEPLOYMENT-ORDER.md) → `./spinup.sh` → README EKS “After infrastructure” |
| **App / rollback commands** | [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) |
| **Expose home lab (HTTPS)** | [`docs/cloudflare-setup.md`](docs/cloudflare-setup.md) |

---

## You are done when you can do all of this

| Can you… | Where you proved it |
|---|---|
| Run PayFlow on Kubernetes and validate it is healthy | Week 1 — `./scripts/validate.sh` passes |
| Explain what happens to money between debit and credit | Week 1 — `docs/system-flow.md` checkpoint |
| Kill a pod and explain why traffic keeps flowing | Week 2 — deliberate failure drills |
| Read a NetworkPolicy and describe what it blocks | Week 2 — `k8s/base/policies/network-policies.yaml` |
| Trace a request end-to-end using correlation IDs | Week 3 — minimal triad |
| Explain idempotency keys and when they fire | Week 3 — `services/transaction-service` code |
| Provision EKS with Terraform in the correct module order | Week 4 — `./spinup.sh` or manual apply |
| Describe the full CI/CD path from `git push` to running pod | Week 4 — `.github/workflows/build-and-deploy.yml` |
| Say why `Running 1/1` does not mean the service is healthy | Week 4 — CronJob + `payflow_pending_transactions_total` |

If you can answer every row without looking it up, you have completed PayFlow.
