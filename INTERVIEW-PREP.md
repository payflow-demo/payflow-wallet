# PayFlow — Senior DevOps Interview Preparation Guide

> Every answer in this document is tied directly to the PayFlow project.
> No generic textbook answers. No filler. Treat each answer as if you are
> sitting across from a staff engineer who has already read your repo.

---

## Project Reference Card

| Layer | What's running |
|---|---|
| Services | API gateway, auth, wallet, transaction, notification, frontend (Node 22 / React 18 / Nginx) |
| Data | PostgreSQL 15 (RDS), Redis 7 (ElastiCache), RabbitMQ 3 (Amazon MQ) |
| Orchestration | EKS (prod), AKS (Azure), MicroK8s (local) — all managed via Kustomize overlays |
| IaC | Terraform — hub-spoke VPC, EKS cluster, IRSA, GuardDuty, CloudTrail, WAF, KMS, Secrets Manager |
| CI/CD | GitHub Actions — validate → build (Docker Hub/ECR/ACR) + GitOps self-hosted runner for local MicroK8s |
| Observability | Prometheus + Grafana + Loki + Promtail + Alertmanager + custom `payflow_pending_transactions_total` metric |
| Security | NetworkPolicy default-deny, IRSA, External Secrets Operator, Trivy CronJobs, JWT Redis blacklist, non-root containers |

---

## PART 1 — THE 12 QUESTIONS

---

### Q1 (Troubleshooting) — A user reports their $200 transfer is stuck. All pods show `Running 1/1`. Where do you start?

**Junior answer (sounds like this):**
> "I'd check the pod logs and see if there are any errors."

**Why that's weak:** `Running 1/1` tells you the container started. It tells you nothing about whether it is processing work. If the transaction-timeout-handler CronJob has silently stopped running, there are no error logs anywhere — the pod that was supposed to process the job is gone.

**Production-grade answer:**

My first instinct is not to look at pods — it is to look at the metric that was built precisely for this scenario.

```bash
# Is the CronJob running on schedule?
kubectl get cronjob transaction-timeout-handler -n payflow
kubectl get jobs -n payflow --sort-by=.metadata.creationTimestamp | tail -5

# Check the last job's pod status
kubectl describe job <last-job-name> -n payflow
kubectl logs job/<last-job-name> -n payflow
```

If the CronJob is healthy, I look at the specific transaction:

```bash
# Query the DB directly via a debug pod or the wallet service
kubectl exec -it deploy/wallet-service -n payflow -- \
  node -e "const {Pool} = require('pg'); ..."

# Or port-forward to the DB
kubectl port-forward svc/postgres 5432:5432 -n payflow
psql -h localhost -U payflow -c \
  "SELECT id, status, created_at, updated_at FROM transactions \
   WHERE status = 'PENDING' AND created_at < NOW() - INTERVAL '2 minutes';"
```

I also check `payflow_pending_transactions_total` in Prometheus:

```
http://prometheus:9090/graph?g0.expr=payflow_pending_transactions_total
```

If the value has been climbing for more than 2 minutes, the `PendingTransactionsStuck` alert should have fired already. If it did not, the issue is in the alerting path (Alertmanager routing, Slack webhook). That is its own incident.

**The trade-off here:** The CronJob approach is simple and guaranteed to catch stuck transactions eventually. The downside is a 1-minute recovery window rather than real-time compensating transactions. For a production fintech at scale you would use event-driven sagas with a dead-letter queue — but for this architecture, the CronJob + alert covers the 99% case.

---

### Q2 (Troubleshooting) — After deploying commit `a3f9c12`, error rate on the transaction service jumps to 15% but pod logs show nothing obvious. Walk me through the debugging session.

**Junior answer (sounds like this):**
> "I'd look at the logs more carefully or maybe roll back."

**Why that's weak:** Rolling back without diagnosing is a panic move. And logs are request-level — they tell you about specific failures, not systemic rate changes.

**Production-grade answer:**

First I confirm whether this is a regression by querying Prometheus with a time anchor:

```promql
# Error rate before and after the deploy
rate(http_requests_total{service="transaction-service",status=~"5.."}[5m])

# Compare p95 latency across the deploy boundary
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{service="transaction-service"}[5m]))
```

If the spike correlates exactly with the rollout timestamp, it is the deploy. Next I check whether the rollout itself is still in progress:

```bash
kubectl rollout status deployment/transaction-service -n payflow
kubectl get pods -n payflow -l app=transaction-service -o wide
```

A partial rollout means both old and new pods are serving traffic. If only new pods are erroring, I want their logs with structured fields, not raw tailing:

```bash
# Last 100 lines from new pods only
kubectl logs -l app=transaction-service -n payflow \
  --since=10m --prefix=true | grep -i "error\|FATAL\|unhandled"
```

Often the real cause is a schema migration that ran before the pods came up but introduced a breaking change (new NOT NULL column, renamed field). I check the migration job:

```bash
kubectl get job db-migration -n payflow
kubectl logs job/db-migration -n payflow
```

If migration passed but the service still errors, I diff the ConfigMap:

```bash
kubectl get configmap app-config -n payflow -o yaml
```

A changed environment variable — wrong service URL, missing Redis key — is almost always in the ConfigMap or a secret rotation.

**Trade-off:** We deliberately do not auto-rollback in this pipeline. Auto-rollback means you can mask a schema migration that already ran and is not reversible. Manual rollback with a conscious decision is slower but safer when database state is involved.

---

### Q3 (Troubleshooting) — `kubectl apply -f ingress.yaml` returns `configured`, but no routing happens and the Ingress resource disappears after 30 seconds. What is the root cause?

**Junior answer (sounds like this):**
> "Maybe the YAML is wrong or the ingress class is missing."

**Production-grade answer:**

This is the IRSA failure mode, and it is the most confusing silent failure in this cluster. The AWS Load Balancer Controller requires the IRSA annotation on its service account to call the EC2 and ELB APIs. Without it, the controller starts cleanly — it is a running pod, no crash, no error in `kubectl logs` — but any attempt to reconcile an Ingress object fails silently because the API call to create the ALB returns an auth error that the controller logs but Kubernetes does not surface to the user.

Debugging sequence:

```bash
# 1. Check the LBC pod logs directly
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
  --since=5m | grep -i "error\|unauthorized\|forbidden"

# 2. Check the service account annotation
kubectl get sa aws-load-balancer-controller -n kube-system -o jsonpath='{.metadata.annotations}'
# Should show: eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/...

# 3. Verify the OIDC provider is registered
aws iam list-open-id-connect-providers
# Should match the cluster's OIDC issuer URL

# 4. Check the subnet tags that the LBC needs to discover subnets
aws ec2 describe-subnets --filters "Name=tag:kubernetes.io/role/elb,Values=1"
```

In PayFlow's Terraform the subnet tags are set explicitly:

```hcl
"kubernetes.io/role/elb" = "1"
"kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
```

If those tags are missing, the LBC finds no public subnets and silently does nothing. The Ingress does not error — it just never gets an address assigned, and Kubernetes eventually garbage-collects it.

**Trade-off:** IRSA is more complex to set up than instance profiles, but instance profiles give every pod on a node the same AWS permissions. IRSA scopes credentials to individual service accounts, which is the least-privilege principle at the pod level. Worth the complexity.

---

### Q4 (System Design) — How does the transaction processing flow stay consistent if the transaction service pod crashes after debiting the source wallet but before crediting the destination?

**Production-grade answer:**

This is the double-spend / fund-loss scenario and it is the core reason several design decisions exist in this codebase.

The flow is: API gateway → transaction service → wallet service (debit) → wallet service (credit) → notification. If the pod dies between debit and credit, the money is gone from source but has not arrived at destination.

Three layers defend against this:

**1. Idempotency keys.** Every transaction has a UUID generated at the API gateway before any service is called. The transaction service checks Redis for this key before processing. If it finds a hit, the request has already been partially or fully processed — it returns the cached result rather than reprocessing. This means even if the request is retried after a crash, it does not debit twice.

**2. Status machine in PostgreSQL.** Transactions move through `PENDING → PROCESSING → COMPLETED / FAILED`. The transition from `PROCESSING` to `COMPLETED` only happens after both the debit and credit have been applied in a database transaction. If the pod crashes mid-flight, the status stays `PROCESSING`.

**3. CronJob recovery.** `jobs/transaction-timeout-handler.yaml` runs every minute. It queries:
```sql
SELECT * FROM transactions
WHERE status IN ('PENDING', 'PROCESSING')
AND updated_at < NOW() - INTERVAL '90 seconds';
```
For each stuck transaction it reverses the debit (re-credits the source) and sets status to `FAILED`. The alert `PendingTransactionsStuck` fires at 2 minutes so the CronJob never needs to run more than once before the on-call knows.

**What this does not cover:** If the credit succeeds but the commit to the `transactions` table fails, the wallet state and the transactions table are inconsistent. The proper fix for this is an outbox pattern — write the transaction record and the wallet change in a single local database transaction, then publish to RabbitMQ from the outbox. We do not have that here; the CronJob is a compensating control, not a perfect one. I would flag this as a known gap in production.

---

### Q5 (System Design) — How would you scale this architecture to 10x current transaction volume? What breaks first?

**Production-grade answer:**

The bottleneck order, based on how this system is built:

**First to break: the transaction service.** It is stateless but does synchronous HTTP calls to the wallet service. At high volume, the wallet service becomes the fan-in point. I would move to async processing: transaction service publishes to a RabbitMQ queue and returns a 202 Accepted with a job ID. The wallet service consumes from the queue. This decouples the two services and lets each scale independently.

**Second: PostgreSQL.** Every transaction does at minimum two writes (debit + credit) plus a status update. At 10x you hit write contention on the `wallets` table. The fix is row-level locking with `SELECT ... FOR UPDATE` (already implied by the idempotency pattern) plus read replicas to offload balance queries. On RDS you enable Multi-AZ for HA and add a read replica endpoint in the app config.

**Third: Redis.** Idempotency keys and session tokens both live here. Redis is single-threaded per shard. The fix is Redis Cluster — which Amazon ElastiCache supports natively. No application code change needed, just a new connection string.

**Kubernetes scaling:** HPA is already configured at 70% CPU / 80% memory. At 10x I would add KEDA (Kubernetes Event-Driven Autoscaler) so the transaction service pods scale based on RabbitMQ queue depth rather than CPU, which is a more accurate signal for a queue-driven workload.

**What I would NOT change:** The network policy structure, the monitoring stack, the Terraform module layout. Those scale without modification.

**Trade-off:** Moving to async processing adds complexity — the client now needs to poll for status or receive a webhook. For a payment system this is often the right call because it also improves resilience (queue buffers spikes), but it makes the client integration harder and the debugging story more complex.

---

### Q6 (Security) — How are database credentials managed in this cluster, and what happens operationally when RDS rotates a password?

**Production-grade answer:**

In the local overlay, a Kubernetes Secret with placeholder values is created by `k8s/overlays/local/secrets.yaml` — this is fine for local dev, the values are fake, and it is excluded from the base so it never reaches EKS.

In the EKS overlay, there are no credentials in the repository at all. The `External Secrets Operator` is installed via Helm (provisioned in Terraform). A `SecretStore` resource is configured with an IRSA-backed service account that has `secretsmanager:GetSecretValue` on the specific ARN of the payflow DB secret. An `ExternalSecret` resource maps the Secrets Manager secret to a Kubernetes Secret in the `payflow` namespace.

```yaml
# Simplified ExternalSecret
spec:
  secretStoreRef:
    name: aws-secrets-manager
  target:
    name: db-credentials
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: payflow/prod/db-credentials
        property: password
```

When RDS rotates the password (we have automatic rotation enabled via Lambda in Secrets Manager), the External Secrets Operator polls on a configurable interval (we set 1 hour) and detects the change. It updates the Kubernetes Secret. The pods do not automatically restart — they need to pick up the new value.

The operational procedure is: after a confirmed rotation, trigger a rolling restart:

```bash
kubectl rollout restart deployment -n payflow
```

This causes zero downtime because Kubernetes replaces pods one at a time. The new pods read the updated secret at start. The in-flight requests are handled by the old pods until they drain.

**What would break without IRSA:** The External Secrets Operator would need a long-lived AWS key stored somewhere (a Kubernetes Secret, an EC2 instance profile, an environment variable). Long-lived keys are the most common source of credential leaks. IRSA eliminates them entirely — pods get a time-limited token via the OIDC federation, and that token is rotated automatically.

---

### Q7 (Security) — A pod in the notification service is compromised and is running malicious code. What can it reach, and what stops it from going further?

**Production-grade answer:**

Starting from `k8s/base/policies/network-policies.yaml`, the blast radius is contained at multiple layers.

**What the notification pod can reach (by policy):**
- Its own localhost
- RabbitMQ on its designated port (it needs to consume events)
- The Postgres exporter metrics endpoint (Prometheus scraping path)
- External internet via the NAT gateway (for sending emails/SMS via SMTP/Twilio)

**What it explicitly cannot reach:**
- The wallet service API (no policy permits this path)
- The transaction service API
- The auth service
- Redis directly (the Redis NetworkPolicy only permits connections from the api-gateway and wallet-service pods)
- The Postgres port on the managed services network — the security group on the RDS instance only permits connections from the EKS node security group, and even then, only authenticated connections with the rotated credentials the notification service does not have

**What the attacker cannot do:**
- Call `wallet-service/api/v1/transfer` — blocked by NetworkPolicy before the TCP handshake
- Read arbitrary Redis keys — Redis allows only designated service accounts; even if they could connect, they do not have the Redis password
- Call the AWS API — the notification service account has no IRSA annotation, so `aws sts get-caller-identity` from inside the pod returns 403
- Reach the Secrets Manager ARN — no IAM role is bound to the notification pod

**The gap I would fix in production:** The notification service can still reach external internet for legitimate email sending. A compromised pod could exfiltrate data over HTTPS to an attacker-controlled endpoint. The fix is an egress NetworkPolicy that restricts external traffic to known CIDR ranges or uses a proxy with domain allowlisting (e.g. Squid). That is not currently implemented.

The combination of NetworkPolicy + IRSA + Security Groups means the blast radius is one service in one namespace. Without all three, a compromised pod has cluster-admin–equivalent access to everything the node's instance profile can reach.

---

### Q8 (CI/CD) — Walk through what happens from `git push origin main` to a new pod serving traffic in EKS.

**Production-grade answer:**

**Step 1 — Validate (ubuntu-latest runner, ~2 min).**
GitHub Actions triggers on the push. The `validate` job runs `npm install --no-save` inside each of the five backend service directories and the frontend. This is a deliberate early-exit gate — a broken `package.json` or missing lockfile fails here in 2 minutes rather than after 15 minutes of Docker builds. Any service directory that exits non-zero aborts the entire workflow.

**Step 2 — Build (parallel with push-ecr, ~8 min).**
The `build` job uses Docker Buildx with GitHub Actions cache (`cache-from: type=gha`). All six images are built with context `./services` — this is intentional because `services/shared/` (shared utilities, tracing, validators) needs to be available to every Dockerfile. Each image gets two tags: `latest` and the short SHA (e.g. `a3f9c12`). The SHA tag is the immutable artifact — `latest` is just a convenience pointer.

**Step 3 — Push to ECR (conditional, parallel).**
The `push-ecr` job runs if `AWS_ACCESS_KEY_ID` is set. It uses `aws-actions/configure-aws-credentials` (OIDC-based in production, static keys for this project), logs into ECR, and pushes all six images under `ACCOUNT.dkr.ecr.REGION.amazonaws.com/payflow-eks-cluster/SERVICE:SHA`. ECR rather than Docker Hub avoids pull rate limits and keeps images in the same AWS region as the cluster (no egress cost, faster pulls on cold node start).

**Step 4 — Deploy (manual gate, intentional).**
The pipeline does NOT deploy automatically. An engineer runs:

```bash
IMAGE_TAG=a3f9c12 ./k8s/overlays/eks/deploy.sh
```

The deploy script runs `kustomize edit set image` to update the image tag in the overlay kustomization, then applies:

```bash
kubectl apply -k k8s/overlays/eks/
kubectl rollout status deployment/transaction-service -n payflow --timeout=5m
```

**Step 5 — Rolling rollout.**
Kubernetes replaces pods one at a time. Each new pod must pass its `readinessProbe` (HTTP GET `/health` returning 200) before the old pod is terminated. If any pod fails the probe within the timeout, the rollout pauses and old pods continue serving traffic.

**Step 6 — Prometheus picks up new pods.**
Within 15 seconds, Prometheus's next scrape cycle hits the new pods' `/metrics` endpoints. If error rate or latency exceeds alert thresholds, Alertmanager fires within 2 minutes.

**The intentional separation between build and deploy** is the key architectural decision. Every commit produces a versioned, immutable artifact. The decision of what ships to production and when stays with the human.

---

### Q9 (CI/CD) — Why does the pipeline validate before building? What would happen if you ran `npm install` after the Docker build?

**Production-grade answer:**

The `validate` job runs `npm install --no-save` in all five backend service directories before any Docker image is built. This seems trivial but it catches a specific failure class: a broken `package.json`, a mismatched lockfile (`package-lock.json` out of sync), or a package that fails to install — all of which would cause a Docker build to fail at the `RUN npm ci` step.

Without the validate gate, the workflow fails 15 minutes in, after building five of six images, burning compute and GitHub Actions minutes, and the error message comes from inside Docker rather than from a clean npm error.

The ordering also has a security implication. If you run `npm install` inside the Docker build without checking what you installed, a supply-chain attack (a compromised package on npm) makes it into the image and potentially into production. Running validate first gives you a moment to check npm audit output before the image is built and pushed.

In the `gitops-local.yml` workflow, validate runs on the self-hosted runner first — this means the runner's environment (not just GitHub's servers) validates the dependencies. If the runner is on the same network as the internal npm registry (future state), this is where you would enforce that only vetted packages are allowed.

**Trade-off:** The validation adds ~2 minutes. In a very large monorepo with many services, this becomes meaningful. The alternative is to run validate inside each Dockerfile and let Docker layer caching skip unchanged services. The current approach is simpler and more transparent — failures are visible in the GitHub Actions UI without reading Docker build logs.

---

### Q10 — What is IRSA, and why does getting it wrong break multiple things silently instead of one thing loudly?

**Production-grade answer:**

IRSA (IAM Roles for Service Accounts) is the mechanism by which Kubernetes pods on EKS assume AWS IAM roles without long-lived credentials. The cluster's OIDC provider issues a signed token to each pod whose service account has an `eks.amazonaws.com/role-arn` annotation. The AWS SDK exchanges this token for temporary credentials via STS. The IAM role's trust policy specifies exactly which OIDC provider and service account are allowed to assume it.

In PayFlow's Terraform, the OIDC provider registration and IRSA role creation happen in `terraform/aws/spoke-vpc-eks/`. The roles cover:
- AWS Load Balancer Controller (needs EC2, ELB, WAF API access)
- External Secrets Operator (needs Secrets Manager `GetSecretValue`)
- EBS CSI driver (needs EC2 volume operations)
- The Cluster Autoscaler (needs EC2 autoscaling API)

**Why it breaks silently across multiple systems:** Every one of these controllers is a Kubernetes pod that starts successfully regardless of whether IRSA is configured. There is no startup error. The pod enters `Running` state. The problem only manifests when the controller tries to call an AWS API:

- LBC: `kubectl apply` on Ingress succeeds (Kubernetes accepted the manifest) but the ALB is never created. The Ingress never gets an address. No error message is surfaced to kubectl.
- External Secrets: The `ExternalSecret` resource shows `SecretSyncedError` in its status, but if you are not watching ExternalSecret resources (most engineers are not), you do not notice. Pods start with missing environment variables and may fail silently on first request.
- EBS CSI: PersistentVolumeClaims stay in `Pending` state indefinitely. Pods that depend on them never start.

The debugging command when things do not work and you suspect IRSA:

```bash
# Check what role the controller is actually assuming
kubectl exec -n kube-system deploy/aws-load-balancer-controller -- \
  aws sts get-caller-identity

# Should return the IRSA role ARN. If it returns the node instance role, IRSA is broken.

# Check the token mount
kubectl get sa aws-load-balancer-controller -n kube-system -o yaml | grep eks.amazonaws.com
```

---

### Q11 — What is the difference between `kubectl get pods` showing `Running 1/1` and the service actually being healthy?

**Production-grade answer:**

`Running 1/1` means the container process started and has not crashed. The `1/1` means 1 of 1 containers in the pod is running. It says nothing about:

- Whether the process inside is actually handling requests
- Whether the process is in a deadlock or stuck in an infinite loop
- Whether the dependent services (Postgres, Redis, RabbitMQ) are reachable
- Whether the CronJobs scheduled to run alongside the service are completing

In PayFlow, the transaction-timeout-handler `CronJob` is the clearest example. The CronJob runs every minute. If its container image has a bug, the Job pod fails but the application pods remain `Running`. There is no event on the Deployment. There is no alert unless you have specifically configured one.

The correct indicators of service health in this stack are:

```bash
# Application-level: is the /health endpoint returning 200?
kubectl exec deploy/transaction-service -n payflow -- \
  wget -qO- http://localhost:3002/health

# Is the readiness probe passing?
kubectl describe pod <pod-name> -n payflow | grep -A5 "Readiness"

# Are CronJobs completing on schedule?
kubectl get cronjob -n payflow
kubectl get jobs -n payflow --sort-by=.metadata.completionTime

# Is the business metric healthy?
# In Prometheus: payflow_pending_transactions_total < threshold
```

The monitoring stack's `NoTransactionsProcessed` alert — fires if no transaction is completed in 10 minutes — is the most important signal because it catches the system appearing healthy while doing nothing. This is the gap that `Running 1/1` cannot cover.

---

### Q12 — How does the transaction timeout CronJob work, and what alerts you if the CronJob itself breaks?

**Production-grade answer:**

The CronJob (`k8s/base/jobs/transaction-timeout-handler.yaml`) runs every minute on a schedule (`*/1 * * * *`). Each run creates a Kubernetes Job, which creates a Pod. The Pod queries:

```sql
SELECT id, user_id, amount, type FROM transactions
WHERE status IN ('PENDING', 'PROCESSING')
AND updated_at < NOW() - INTERVAL '90 seconds';
```

For each stuck transaction, it calls the wallet service to reverse the debit and updates the transaction status to `FAILED`. The Job then completes (exit 0), and Kubernetes cleans up the Pod. `successfulJobsHistoryLimit: 3` and `failedJobsHistoryLimit: 3` keep the last few runs visible for debugging.

**The CronJob-is-broken alert:** This is `OldestPendingTransactionTooOld` in `k8s/monitoring/alerts.yml`. It fires when:

```promql
payflow_oldest_pending_transaction_age_seconds > 120
```

Because the CronJob runs every 60 seconds, any transaction older than 120 seconds means the CronJob ran at least once and did not clear it. That points to one of:
- The CronJob pod is failing (check `kubectl get jobs -n payflow`)
- The wallet service is not responding to reversal calls (check wallet service logs)
- The database query is timing out (check the DB connection pool metric)

There is also `kube-state-metrics` which exposes `kube_cronjob_status_last_schedule_time` — a PromQL query on this metric can alert when the CronJob has not scheduled in more than 2 minutes, which would catch a scenario where the CronJob is suspended or has a broken schedule expression.

The combination of the business metric alert AND the kube-state-metrics alert provides two independent detection paths for the same failure — defense in depth in monitoring.

---

## PART 2 — HYBRID / REAL-WORLD CONSTRAINTS

### Could PayFlow run in a hybrid model (on-premises + cloud)?

**The short answer:** Yes, with significant redesign of the data path and identity layer.

**What would work without changes:**
- The Kubernetes manifests (Kustomize base) are cloud-agnostic. A third overlay targeting bare-metal or vSphere-hosted Kubernetes would follow the same pattern as the local and EKS overlays.
- The application code is fully containerised and has no cloud SDK calls.
- The monitoring stack (Prometheus, Grafana, Loki, Alertmanager) runs anywhere.
- The CI/CD pipeline pushes images; the target registry would need to change (Harbor on-prem instead of ECR) but the workflow structure is the same.

**What breaks or needs redesign:**

**1. IRSA has no equivalent on-prem.**
IRSA relies on the EKS OIDC provider and IAM STS. On-premises Kubernetes can use Vault's Kubernetes auth method as a direct replacement — pods authenticate with their Kubernetes service account token, Vault issues short-lived credentials, and those credentials are used for secret retrieval. The External Secrets Operator supports Vault as a backend.

**2. Managed services (RDS, ElastiCache, Amazon MQ) disappear.**
On-prem you run PostgreSQL as a StatefulSet with persistent volumes and a streaming replication setup. Redis as a StatefulSet with Sentinel or Redis Cluster. RabbitMQ as a StatefulSet. The in-cluster manifests in `k8s/infrastructure/` (postgres.yaml, rabbitmq.yaml) exist for this reason — the local overlay already does this. The operational burden increases substantially: you own backups, failover, patching, and storage provisioning.

**3. Networking and ingress.**
The AWS Load Balancer Controller and its IRSA role are AWS-specific. On-prem you replace this with MetalLB (for bare metal load balancing) or an external Nginx Ingress Controller pointing at a hardware load balancer. The Terraform hub-spoke VPC layout would be replaced with physical network segmentation (VLANs, firewall rules between on-prem zones).

**4. CloudTrail / GuardDuty / Security Hub have no direct on-prem equivalents.**
You would replace them with: Falco for runtime threat detection (syscall-level, runs as a DaemonSet), auditd for host-level audit logging, and a SIEM (Splunk, Elastic SIEM) to aggregate logs. The financial audit requirement (7-year retention) becomes your responsibility to manage on-prem storage.

**5. Cost model inverts.**
In AWS, you pay per NAT gateway hour, per data transfer GB, per EKS control plane hour. On-prem you pay capex (hardware) up front and opex (power, cooling, maintenance). For a fintech startup, the hybrid model typically means keeping sensitive PII data on-prem (regulatory requirement) while running stateless compute in cloud. The data path between the two zones needs encrypted transit (VPN or Direct Connect equivalent) and added latency tolerance in the services.

---

## PART 3 — FINAL REFINEMENT

---

### A) 60-Second Interview Summary

> Use this when the interviewer says "tell me about a project you've worked on."

PayFlow is a production-style fintech platform I built to understand what operating a payment system actually requires — not just writing the application code.

The core stack is six Node.js microservices — API gateway, auth, wallet, transaction, notification, and a React frontend — communicating over HTTP and RabbitMQ, with data in PostgreSQL, Redis, and RabbitMQ. It runs on AWS EKS, provisioned entirely by Terraform using a hub-and-spoke VPC layout with managed services in a separate network tier.

The infrastructure has four layers I can explain end-to-end: Terraform builds the environment — VPC, subnets, NAT, IRSA roles, CloudTrail, GuardDuty, KMS; Kubernetes runs and enforces the application with NetworkPolicy default-deny, HPA, PodDisruptionBudgets, and External Secrets pulling credentials from Secrets Manager; a GitHub Actions pipeline validates dependencies before building images, pushes to ECR with immutable SHA tags, but keeps deployment as a conscious human step; and an observability stack — Prometheus, Grafana, Loki, Alertmanager — with custom business metrics like `payflow_pending_transactions_total` that catch money stuck in PENDING before a user has to call.

The specific scenario that the whole stack was designed around: a pod shows `Running 1/1`, the pipeline is green, and $200 is frozen because the CronJob that reverses stuck transactions silently stopped running. That scenario taught me that "infrastructure is up" and "system is healthy" are different statements.

---

### B) Deep Technical Walkthrough

> Use this when the interviewer says "walk me through the architecture in detail."

**Starting point — Terraform.**
Before a single container runs, Terraform provisions the foundation in dependency order. The VPC first: a spoke network at `10.1.0.0/16` with public subnets (for NAT and the ALB) and private subnets (for EKS worker nodes). The NAT gateway gives private nodes outbound internet for image pulls without exposing them to inbound. VPC Flow Logs write to CloudWatch with one-year retention for network-level audit. CloudTrail captures every AWS API call to an encrypted S3 bucket — seven-year retention, financial compliance requirement.

The EKS cluster is provisioned next, followed immediately by the OIDC provider registration and IRSA roles. IRSA is the identity layer for pods — it binds Kubernetes service accounts to IAM roles via STS token exchange. Without it, the AWS Load Balancer Controller and External Secrets Operator start cleanly but silently fail every AWS API call, making it appear that Ingress resources and ExternalSecret resources just don't work. The Helm releases for these controllers are provisioned last, after the IAM plumbing is in place.

Managed services — RDS PostgreSQL, ElastiCache Redis, Amazon MQ — live in a separate network tier accessible only from the EKS node security group. The RDS security group has one inbound rule: port 5432 from the EKS node security group. Nothing else, including the bastion host, can reach the database directly.

**Kubernetes layer.**
The cluster is managed with Kustomize overlays. The base at `k8s/base/` defines everything environment-agnostic: the `payflow` namespace, six Deployments, a DB migration Job (runs at deploy time, ensures schema is current before pods start), the transaction-timeout CronJob (runs every minute, reverses stuck transactions), NetworkPolicies, PodDisruptionBudgets, resource quotas (4 CPU / 8GB hard cap on the namespace), and HPA at 70% CPU / 80% memory.

The NetworkPolicy configuration starts with a default-deny on all pods in the namespace, then opens only required paths: API gateway accepts external traffic; backend services can reach Postgres, Redis, RabbitMQ; transaction service can call wallet service; Prometheus can scrape metrics ports. No other paths exist. A compromised notification pod cannot open a TCP connection to the wallet service — the packet is dropped before the TCP handshake.

Secrets in EKS come from External Secrets Operator pulling from Secrets Manager. The ESO service account has an IRSA annotation scoped to a specific Secrets Manager ARN. The Kubernetes Secret it creates is the only place credentials live in the cluster — never in a manifest, never in a ConfigMap, never in a Dockerfile.

**CI/CD layer.**
`build-and-deploy.yml` has three stages. Validate first: `npm install --no-save` in each service directory on `ubuntu-latest`. This fails fast on a broken lockfile or missing package before wasting build time. Build second: Docker Buildx with GHA cache, context `./services` (includes `shared/`), tagged with short SHA and `latest`. Push to ECR third: conditional on AWS credentials being set, pushes to `ACCOUNT.dkr.ecr.REGION.amazonaws.com/payflow-eks-cluster/SERVICE:SHA`.

The pipeline never deploys. A human runs `IMAGE_TAG=<sha> ./deploy.sh` which calls `kustomize edit set image`, applies the overlay, and watches the rollout status. This separation means every commit has an immutable artifact, but the decision to promote that artifact to production is explicit.

**Observability layer.**
Prometheus scrapes all six services every 15 seconds on their `/metrics` endpoints. The critical custom metric is `payflow_pending_transactions_total` — incremented when a transaction enters PENDING, decremented when it completes or fails. The `PendingTransactionsStuck` alert fires when this value has been above zero for more than two minutes. `kube-state-metrics` exposes CronJob schedule compliance so a silent CronJob failure fires its own alert within 2 minutes.

Loki aggregates logs from all pods via the Promtail DaemonSet. When an alert fires, the on-call engineer jumps from the Prometheus alert directly to the correlated log lines in Grafana without searching raw pod logs. This is the difference between observability and logging.

---

### C) Three Story Answers

---

#### Story 1 — The Failure (Silent Money Freeze)

> Use for: "Tell me about a production incident."

The scenario: pipeline was green, all pods showing `Running 1/1`, and I was about to close my laptop. Then I noticed `payflow_pending_transactions_total` climbing in Prometheus — the metric had been increasing for four minutes.

The root cause: the transaction-timeout-handler CronJob had a broken image tag after a recent deploy. The Job pod was failing with `ImagePullBackOff`. Kubernetes was logging this, but only on the Job pod, not on the application Deployment. There was no signal anywhere near the application — the only signal was the business metric.

```bash
kubectl get jobs -n payflow
# NAME                                   COMPLETIONS   DURATION   AGE
# transaction-timeout-handler-28XXX      0/1           4m         4m

kubectl describe pod transaction-timeout-handler-28XXX-xxx -n payflow
# Events: Failed to pull image "...transaction-timeout-handler:badtag"
```

Fix was a one-line kustomize patch to correct the image tag and a rolling restart of the CronJob. Total time from alert to fix: 8 minutes.

What I changed afterward: added `OldestPendingTransactionTooOld` alert based on `kube-state-metrics`' CronJob last-schedule metric, independent of the business metric. Two separate detection paths for the same failure class.

**What this shows:** I understand that "infrastructure healthy" and "business logic executing" are separate concerns, and I built monitoring that covers both.

---

#### Story 2 — The Debugging Session (IRSA Silent Failure)

> Use for: "Tell me about a technically complex problem you debugged."

After running `terraform apply` on a fresh EKS cluster, everything looked correct. Cluster nodes were ready, all system pods were Running, `kubectl apply -k k8s/overlays/eks/` returned no errors. But traffic never reached the services. The Ingress resource showed no `ADDRESS` in `kubectl get ingress`.

I spent 30 minutes looking at the wrong layer — checking Ingress class annotations, testing DNS, verifying the Nginx config. None of that was the problem.

The actual failure was that the OIDC provider had been created but the trust relationship on the Load Balancer Controller IAM role referenced the wrong OIDC issuer URL. The LBC pod was running, but every AWS API call returned a 403. The LBC logs had the error, but I was not looking there.

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller | grep "AccessDenied"
# AccessDenied: User: arn:aws:sts::ACCOUNT:assumed-role/nodes-role/...
#   is not authorized to perform ec2:DescribeVpcs
```

The pod was using the node instance role, not the IRSA role. The fix was correcting the OIDC issuer URL in the Terraform IAM role trust policy and re-running `terraform apply`.

**What I learned:** When things fail silently in Kubernetes, check the controller logs, not the resource state. Resource state (Ingress with no address) is a symptom. The cause is always in a controller's logs or in the AWS API response.

---

#### Story 3 — The Decision (Manual Deploy Gate)

> Use for: "Tell me about a technical decision you made and the trade-off."

Early in the project I set up the pipeline to auto-deploy to EKS on every push to main. It felt like good CI/CD hygiene — the whole point is continuous deployment.

Then I ran a database migration that added a NOT NULL column with no default, forgot to backfill existing rows, and the deploy went out automatically. The new pods crashed immediately because they tried to insert rows without the required column. The rollback was straightforward — `kubectl rollout undo deployment/wallet-service` — but the migration had already run and was not reversible without manual SQL.

The lesson was that in a system that handles money, the schema and the code are not the same artifact. The image can be rolled back; the database cannot. Automatic deploy makes sense when all rollback paths are clean. In a fintech service where a bad migration can lock user funds, the deploy gate should be human.

I changed the pipeline to stop after ECR push and added `IMAGE_TAG=<sha> ./deploy.sh` as the explicit manual step. The trade-off is velocity — you cannot merge and go home, you have to watch the rollout. But the operational risk reduction is worth it. A human verifying the migration job logs before the deploy proceeds catches the class of failure that automated deployment cannot.

**What this shows:** I make infrastructure decisions based on failure modes, not on what the CI/CD tool makes easy by default.

---

## Quick Reference — Commands You Should Know Cold

```bash
# Check stuck transactions in cluster
kubectl get cronjob transaction-timeout-handler -n payflow
kubectl get jobs -n payflow --sort-by=.metadata.creationTimestamp | tail -5

# Check IRSA is working
kubectl exec -n kube-system deploy/aws-load-balancer-controller -- \
  aws sts get-caller-identity

# Rollout management
kubectl rollout status deployment/wallet-service -n payflow
kubectl rollout history deployment/wallet-service -n payflow
kubectl rollout undo deployment/wallet-service -n payflow

# Check External Secrets sync status
kubectl get externalsecret -n payflow
kubectl describe externalsecret db-credentials -n payflow

# NetworkPolicy debugging (packet drop is silent — use this)
kubectl exec -it deploy/notification-service -n payflow -- \
  wget --timeout=3 http://wallet-service:3001/health
# If it times out: NetworkPolicy is blocking (expected)
# If it succeeds: NetworkPolicy gap

# Business metric
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
curl -s 'http://localhost:9090/api/v1/query?query=payflow_pending_transactions_total'

# Prometheus scrape health
kubectl port-forward svc/prometheus 9090:9090 -n monitoring
# Navigate: Status → Targets — check for DOWN targets

# Force CronJob run for testing
kubectl create job --from=cronjob/transaction-timeout-handler manual-test -n payflow

# Trivy scan results
kubectl logs -n payflow -l job-name=image-scanning --tail=100
```

---

*Generated from the PayFlow project — github.com/[your-handle]/payflow-wallet-2*
