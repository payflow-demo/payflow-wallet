# What spinup.sh Does and Issues We Fixed

## What spinup.sh does and how it works

**In one sentence:** `spinup.sh` brings up all PayFlow AWS infrastructure in the right order, with no manual steps, so that after it finishes you can run `deploy.sh` to deploy the app.

**Step by step:**

1. **Figures out who you are and where to store state**
   - Uses your AWS CLI to get your **account ID** and sets the **environment** from `TF_WORKSPACE` (default `dev`) and **region** from `AWS_REGION` (default `us-east-1`).
   - The Terraform state bucket name is derived from your account: `payflow-tfstate-<ACCOUNT>` so nothing is hardcoded.

2. **Creates the Terraform “backend” (once)**
   - Ensures an **S3 bucket** exists for storing Terraform state.
   - Ensures a **DynamoDB table** exists for state locking so two people (or two runs) don’t apply at the same time.
   - If they already exist, it skips creating them.

3. **Runs Terraform in a fixed order**
   - **Hub VPC** — Shared network and Transit Gateway.
   - **EKS (spoke)** — The Kubernetes cluster, its VPC, node groups, add-ons, ECR repos, Secrets Manager secrets (with empty placeholders), and the IRSA role for External Secrets.
   - **Managed services** — RDS (Postgres), ElastiCache (Redis), Amazon MQ (RabbitMQ). It passes the state bucket name into this step so Terraform can read the EKS security group IDs from state and open RDS/Redis/MQ to the cluster. After resources are created, Terraform “null_resource” scripts write the real endpoints and URLs into **AWS Secrets Manager** (so the app later gets the right `rediss://`, `amqps://`, and RDS host).
   - **Secrets check** — Verifies that the three secrets (rds host, redis url, rabbitmq url) in Secrets Manager were actually filled in. If any are empty, the script exits with an error so you don’t run `deploy.sh` with missing credentials.
   - **Bastion** — A small EC2 instance you use to run `kubectl` (because the EKS API is private).
   - **FinOps** — Budgets, cost anomaly detection, and a CloudWatch billing alarm so you get alerts if spend goes over threshold.

4. **Done**
   - Prints that spin-up is complete and tells you to run `k8s/overlays/eks/deploy.sh` to deploy the app.

**Why the order matters:** Each step depends on the previous one. The hub gives networking; EKS needs that and creates the cluster and secrets; managed services need EKS (and its security groups from state) to open their firewalls; the bastion needs the cluster to exist; FinOps runs last and can assume everything else is there.

---

## Issues we had and how we solved them

These are the main issues we ran into during infra and deploy setup, and what we changed to fix them.

### 1. **Redis / ElastiCache connection timeouts (wrong URL and TLS)**

- **Problem:** Apps were pointing at the wrong Redis endpoint or using `redis://` while ElastiCache had TLS on, so health checks failed with connection timeouts.
- **Fix:**  
  - In **Terraform** (`terraform/aws/managed-services/elasticache.tf`): enabled `transit_encryption_enabled = true` and added a `null_resource` that, after the replication group exists, writes the real endpoint and a **`rediss://`** URL into the `payflow/<env>/redis` secret in Secrets Manager.  
  - **EKS**: External Secrets syncs that into the `db-secrets` Kubernetes Secret; base deployments and api-gateway read **`REDIS_URL`** from `db-secrets` (and api-gateway uses `process.env.REDIS_URL || 'redis://redis:6379'` so local dev still works).

### 2. **RabbitMQ TLS and wrong port**

- **Problem:** Config used `amqp://` and port 5672; Amazon MQ uses TLS and port 5671.
- **Fix:** In **Terraform** (`terraform/aws/managed-services/mq.tf`): broker security group allows only **5671** (and 15671 for management). A `null_resource` writes an **`amqps://`** URL with port **5671** into the `payflow/<env>/rabbitmq` secret. EKS External Secrets maps that into `db-secrets`; services already read `RABBITMQ_URL` from `db-secrets`.

### 3. **RDS / DB endpoint not in Secrets Manager**

- **Problem:** RDS host and credentials were not reliably in Secrets Manager, so ESO had nothing to sync for DB connection.
- **Fix:** In **Terraform** (`terraform/aws/managed-services/rds.tf`): added a `null_resource` that runs after the RDS instance exists and writes **host, port, username, password, dbname, engine** into the `payflow/<env>/rds` secret. EKS External Secret already mapped these into `db-secrets`; we made sure deployments and the migration job read **DB_HOST** and **DB_PORT** from `db-secrets` (see below).

### 4. **Pods reading DB/Redis/RabbitMQ from ConfigMap instead of Secret**

- **Problem:** Base Kubernetes deployments (and the migration job) were using **ConfigMap** for `DB_HOST`, `DB_PORT`, and `REDIS_URL`. On EKS we want those to come from Secrets Manager (via ESO) so they stay correct and secret.
- **Fix:**  
  - In **base deployments** (`k8s/base/deployments/*.yaml`): switched **DB_HOST**, **DB_PORT**, and **REDIS_URL** to **`secretKeyRef` → `db-secrets`**. Left **DB_NAME** and service URLs (e.g. `AUTH_SERVICE_URL`) in ConfigMap.  
  - In **migration job** (`k8s/base/db-migration-job.yaml`): switched **DB_HOST** and **DB_PORT** to **`secretKeyRef` → `db-secrets`**.  
  - In **EKS overlay** (`k8s/overlays/eks/db-config-patch.yaml`): removed DB/Redis/RabbitMQ endpoint keys so the ConfigMap only has static service URLs.  
  - Removed the EKS-only REDIS_URL JSON patches; base now consistently uses `db-secrets` for REDIS_URL.

### 5. **Static “fallback” secret missing fields for local dev**

- **Problem:** The base `db-secrets` Secret didn’t define **DB_HOST**, **DB_PORT**, or **REDIS_URL**, so when ESO wasn’t used (e.g. local), those env vars could be missing or wrong.
- **Fix:** In **`k8s/base/secrets/db-secrets.yaml`**: added local-safe placeholders: **DB_HOST: postgres**, **DB_PORT: "5432"**, **REDIS_URL: redis://redis:6379** (and kept RABBITMQ_URL for docker-compose). Documented that this file is **bootstrap-only / local dev** and that on EKS, ESO overwrites these from Secrets Manager.

### 6. **External Secrets IRSA not set → SecretStore failing**

- **Problem:** External Secrets Operator had no IAM identity, so the ClusterSecretStore failed (e.g. InvalidProviderConfig) and secrets didn’t sync.
- **Fix:**  
  - In **Terraform** (`terraform/aws/spoke-vpc-eks/secrets-manager.tf`): IRSA role for ESO with `secretsmanager:GetSecretValue` and `kms:Decrypt`; trust policy for `system:serviceaccount:external-secrets:external-secrets`.  
  - In **deploy.sh** (bastion script): Helm install/upgrade of ESO is done with **`--set serviceAccount.annotations.eks\.amazonaws\.com/role-arn=<IRSA_ARN>`** (ARN from Terraform output). So the annotation is applied automatically and survives upgrades.

### 7. **Migration job running before secrets were synced**

- **Problem:** The bastion script applied manifests and then immediately ran the DB migration job; sometimes ESO hadn’t finished syncing `db-secrets`, so the job saw empty DB_HOST/DB_PASSWORD and failed.
- **Fix:** In **deploy.sh** (bastion script): after the first `kubectl apply`, we **wait for ClusterSecretStore `aws-secrets-manager` to be Ready**, then **wait for ExternalSecret `db-secrets-external` to be Ready**, and only then delete/re-apply and run the migration job.

### 8. **Managed services security groups not allowing EKS traffic**

- **Problem:** RDS/Redis/MQ security groups didn’t know the EKS node/cluster security group IDs, so they couldn’t allow traffic from the cluster.
- **Fix:** In **Terraform** (`terraform/aws/managed-services/data.tf`): use **remote state** from the EKS (spoke) module to read cluster and node security group IDs when **`tfstate_bucket`** is set. **spinup.sh** passes **`-var=tfstate_bucket=payflow-tfstate-<ACCOUNT>`** into the managed-services apply so this works without hardcoding the account.

### 9. **Secrets Manager not actually populated after apply**

- **Problem:** The Terraform `null_resource` steps that write RDS/Redis/RabbitMQ data into Secrets Manager can fail (e.g. IAM or CLI) without failing the apply; then deploy would run with empty secrets.
- **Fix:** In **spinup.sh**: after the managed-services apply, a **verification loop** checks that `payflow/<env>/rds` has **host**, `payflow/<env>/redis` has **url**, and `payflow/<env>/rabbitmq` has **url**. If any is empty, the script errors out with a clear message so you don’t run deploy with missing credentials.

### 10. **CI only pushed to Docker Hub; EKS pulls from ECR**

- **Problem:** The GitHub Actions workflow only pushed images to Docker Hub, while the EKS kustomization pulls from ECR. Fresh spinups had no images in ECR → ImagePullBackOff.
- **Fix:** In **`.github/workflows/build-and-deploy.yml`**: added an optional **`push-ecr`** job that runs when **AWS_ACCESS_KEY_ID** (and secret key) are set. It configures AWS, logs into ECR, and builds and pushes all six service images to ECR with the same tag (short SHA and `latest`). So after the first successful run with AWS secrets set, ECR has the images and deploy.sh works.

### 11. **API gateway Redis client hardcoded**

- **Problem:** In **api-gateway** the health-check Redis client used a hardcoded `redis://redis:6379` instead of the env-driven URL, so on EKS it wouldn’t use the `rediss://` URL from `db-secrets`.
- **Fix:** In **`services/api-gateway/server.js`**: changed the Redis client to use **`process.env.REDIS_URL || 'redis://redis:6379'`** so EKS uses the secret and local dev still works.

---

## Troubleshooting: Avoiding common errors

### Workspace "dev" (or "prod") already exists

- **Cause:** The Terraform workspace already exists in the backend; the script tried to create it again (e.g. after `select` failed briefly).
- **Avoid:** The script now does `select || new || select`, so a re-run should succeed. No action needed.

### "The selected workspace is currently overridden using the TF_WORKSPACE environment variable"

- **Cause:** Terraform was using a workspace from the `TF_WORKSPACE` env var instead of the one chosen in the script.
- **Avoid:** The script now sets `TF_WORKSPACE` to the environment you choose (dev/prod), so Terraform and the script always match. You can leave `TF_WORKSPACE` unset when running `./spinup.sh`.

### Error acquiring the state lock (ConditionalCheckFailedException)

- **Cause:** A previous `terraform plan` or `apply` was interrupted (e.g. Ctrl+C or closed terminal) and did not release the lock in DynamoDB.
- **Avoid:**
  - Prefer not to interrupt plan/apply. If you must, use Ctrl+C once and wait for Terraform to exit.
  - If you see the lock error on the next run, force-unlock using the **Lock ID** from the error (e.g. `7ea64f4b-b602-5f3a-9a07-885870ec1443`):
    ```bash
    cd terraform/aws/hub-vpc   # or the module that failed
    terraform init -input=false -reconfigure
    terraform workspace select dev
    terraform force-unlock <LOCK_ID>
    cd ../../..
    ./spinup.sh
    ```
  - Only force-unlock when you are sure no other Terraform process is still running for that state.

### EKS destroy hangs on subnets or Internet Gateway (teardown.sh)

- **Cause:** After the EKS cluster is removed, Load Balancer ENIs (from ALB/Ingress) can linger in the **public subnets**. AWS may take a long time to release them, so `terraform destroy` on `aws_subnet.eks_public[*]` and `aws_internet_gateway.eks` can sit for 30+ minutes.
- **What we did:**
  - **Timeouts:** In `terraform/aws/spoke-vpc-eks/main.tf`, `aws_subnet.eks_public`, `aws_subnet.eks_private`, and `aws_internet_gateway.eks` have `timeouts { delete = "20m" }` (or 15m for IGW). After that, Terraform fails instead of hanging so you can clean up and re-run.
  - **Order:** `teardown.sh` runs the EKS destroy with `TF_CLI_ARGS_destroy="-parallelism=1"` so resources are destroyed one at a time, which can avoid some ordering issues.
- **If it still hangs or times out:**
  1. Cancel the destroy (Ctrl+C). If you get a state lock message, run `terraform force-unlock <LOCK_ID>` in `terraform/aws/spoke-vpc-eks`.
  2. In **AWS Console** → **VPC** → **Subnets**, find subnets named `payflow-eks-public-subnet-*` (or your EKS public subnets).
  3. For each public subnet, open it → **Network interfaces** tab. Delete any ENIs that are free (or delete the interface if it’s a leftover from a deleted LB). ENIs from an existing LB will show attachment; wait for the LB to be gone (EKS destroy should have removed it) and retry.
  4. In **VPC** → **Internet gateways**, if the EKS IGW still exists, detach it from the VPC (select IGW → **Actions** → **Detach from VPC**).
  5. Re-run: `./teardown.sh` (or from `terraform/aws/spoke-vpc-eks`: `terraform destroy -auto-approve -var=...`). Remaining resources should destroy.

---

## Summary

- **spinup.sh** = one script that sets up backend state, then Terraform in order (hub → EKS → managed services → secrets check → bastion → FinOps), with no manual steps and no hardcoded account.
- The **issues** above were fixed by: (1) using Secrets Manager as the single source of truth for endpoints and credentials, (2) Terraform `null_resource`s populating those secrets after RDS/Redis/MQ exist, (3) ESO + IRSA syncing them into `db-secrets`, (4) base K8s manifests and migration job reading DB_HOST, DB_PORT, REDIS_URL (and RABBITMQ_URL) from `db-secrets`, (5) spinup verifying secrets are populated, (6) deploy.sh waiting for ClusterSecretStore and ExternalSecret before migration, and (7) CI optionally pushing to ECR so EKS has images.

After these fixes, **`./spinup.sh`** then **`./deploy.sh`** should get you from zero to a running app with no manual steps.
