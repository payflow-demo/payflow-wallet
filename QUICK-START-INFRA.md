# Quick Start: Get Infrastructure Running

This guide walks you through deploying the PayFlow infrastructure step-by-step.

---

## Infrastructure onboarding (right order)

Deploy in this order. Each step depends on the previous.

| # | Step | Directory | Time |
|---|------|-----------|------|
| 1 | Bootstrap (S3 + DynamoDB for state) | `terraform` | ~2 min |
| 2 | Hub VPC (networking foundation) | `terraform/aws/hub-vpc` | ~3 min |
| 3 | EKS (VPC, cluster, addons, nodes — use targets) | `terraform/aws/spoke-vpc-eks` | ~40–50 min |
| 4 | Managed services (RDS, ElastiCache, MQ) | `terraform/aws/managed-services` | ~25–35 min |
| 5 | Bastion (for kubectl; EKS is private) | `terraform/aws/bastion` | ~3 min |
| 6 | Application (K8s manifests) | `k8s/overlays/eks` | ~2 min |

**Critical:** Step 4 requires Step 3 to be applied first (VPC and subnets must exist). For RDS/Redis/MQ to allow traffic from EKS, **do not** hardcode `tfstate_bucket` in `terraform.tfvars`. Pass it at apply time so the module reads EKS security groups from spoke state. From repo root you can use `./spinup.sh`, which passes `-var=tfstate_bucket=payflow-tfstate-<ACCOUNT>` into managed-services automatically.

**Plain English:** For a short explanation of what `spinup.sh` does and a list of infrastructure issues we fixed (Redis TLS, secrets wiring, ESO, CI→ECR, etc.), see **[SPINUP-AND-INFRA-FIXES.md](SPINUP-AND-INFRA-FIXES.md)**.

---

## Prerequisites Checklist

Before starting, ensure you have:

- [ ] **AWS CLI** installed and configured (`aws configure`)
- [ ] **Terraform** >= 1.5.0 installed (`terraform version`)
- [ ] **kubectl** installed (`kubectl version --client`) - Note: Will be used on bastion host
- [ ] **AWS Account** with permissions for: VPC, EKS, RDS, ElastiCache, Secrets Manager, IAM, SSM
- [ ] **SSM Session Manager Plugin** installed (for node access) - Optional but recommended
- [ ] **Docker** installed (for local testing, optional)

**Verify AWS access:**
```bash
aws sts get-caller-identity
# Should show your AWS account ID and user ARN
```

**⚠️ IMPORTANT ARCHITECTURE NOTE:**
- **EKS cluster endpoint is PRIVATE** (`endpoint_public_access = false`)
- **EKS nodes are in PRIVATE subnets** (no direct internet access)
- **Access methods:**
  - **kubectl**: Via Bastion host (SSH to bastion, then use kubectl)
  - **Node access**: Via SSM Session Manager (no SSH keys needed)
  - **Application**: Via ALB/Ingress (public-facing)

---

## Step 1: Spin Up Infrastructure (One Command)

From repo root, run `./spinup.sh`. It creates the S3 bucket, DynamoDB lock table, patches all `backend.tf` files, and applies all Terraform modules in the correct order (Hub → EKS → Managed services → Bastion → FinOps).

```bash
# From repository root
./spinup.sh
```

**What happens:**
- Creates S3 bucket: `payflow-tfstate-{YOUR_ACCOUNT_ID}`
- Creates DynamoDB table: `payflow-tfstate-lock`
- Patches `backend.tf` in all 5 modules (hub, spoke, managed-services, bastion, finops)
- Applies Hub VPC → EKS → Managed services → Bastion → FinOps

**Time:** ~90 minutes (EKS and RDS are the slowest)

**Verify:**
```bash
# Check S3 bucket exists
aws s3 ls | grep payflow-tfstate

# Check DynamoDB table exists
aws dynamodb list-tables | grep payflow-tfstate-lock
```

---

## Step 2: Deploy Hub VPC (Networking Foundation)

The Hub VPC provides shared networking infrastructure.

```bash
cd terraform/aws/hub-vpc
terraform init
terraform workspace new dev
terraform plan
terraform apply
```

**What this creates:**
- Hub VPC
- Transit Gateway
- Public subnet (for bastion)
- Private subnet (for shared services)
- Route tables

**Time:** ~3 minutes

**Verify:**
```bash
terraform output
# Should show: hub_vpc_id, transit_gateway_id
```

---

## Step 3: Deploy EKS Cluster (Use Targets!)

**⚠️ CRITICAL:** Deploy in this exact order using Terraform targets to avoid dependency issues.

```bash
cd terraform/aws/spoke-vpc-eks
terraform init
terraform workspace select dev
terraform plan -out=tfplan
```

### Step 3.1: Networking First

```bash
terraform apply -target=module.networking
```

**Why:** VPC, subnets, NAT Gateway must exist before cluster.

**Time:** ~5 minutes

### Step 3.2: EKS Cluster (without nodes)

```bash
terraform apply -target=aws_eks_cluster.payflow
```

**Why:** Cluster API must exist before addons and nodes.

**Time:** ~15 minutes

### Step 3.3: VPC CNI Addon (Critical!)

```bash
terraform apply -target=aws_eks_addon.vpc_cni
```

**Why:** Pods need IP addresses. CNI must be installed before nodes join.

**Time:** ~2 minutes

**⚠️ IMPORTANT:** EKS cluster has **private endpoint only** (`endpoint_public_access = false`). You cannot access it directly from your local machine. All `kubectl` commands below require **bastion** (or VPN). Deploy bastion (Step 5) first if you want to run verifications; or use SSM for node-level checks only.
- **Bastion host** — for kubectl (required for verification steps)
- **SSM Session Manager** — for node access (no kubectl on nodes)

**Verify CNI is ready (run from bastion; see Step 5 for SSH/SSM setup):**

**Option A: Via Bastion Host** (if already deployed):
```bash
# SSH to bastion
ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-ip>

# Configure kubectl on bastion
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

# Check CNI pods
kubectl get pods -n kube-system -l k8s-app=aws-node
# Wait until all pods are Running
```

**Option B: Via SSM Session Manager** (for node access):
```bash
# List EKS nodes (get instance IDs)
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=payflow-eks-on-demand-nodes" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,State.Name]' \
  --output table

# Connect to a node via SSM
aws ssm start-session --target <instance-id>
```

### Step 3.4: On-Demand Node Group

```bash
terraform apply -target=aws_eks_node_group.on_demand
```

**Why:** Stateful services need stable nodes.

**Time:** ~10 minutes

**Verify nodes are ready (run from bastion for kubectl; or use SSM for node-level checks):**

**Via SSM Session Manager (node-level only):**
```bash
# Get node instance IDs
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/payflow-eks-cluster,Values=owned" \
            "Name=tag:eks:nodegroup-name,Values=payflow-on-demand" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,State.Name]' \
  --output table

# Connect to a node via SSM
aws ssm start-session --target <instance-id>

# Once connected to node, check status
sudo systemctl status kubelet
```

**Via Bastion Host (kubectl):**
```bash
# SSH to bastion (see Step 5 for SSH/SSM config), then:
kubectl get nodes -l workload-type=stateful
# Wait until all nodes are Ready
```

### Step 3.5: Spot Node Group

```bash
terraform apply -target=aws_eks_node_group.spot
```

**Why:** Stateless services can run on cheaper spot instances.

**Time:** ~10 minutes

### Step 3.6: CoreDNS Addon

```bash
terraform apply -target=aws_eks_addon.coredns
```

**Why:** DNS resolution needed for services. Requires nodes to be ready.

**Time:** ~2 minutes

### Step 3.7: Everything Else

```bash
terraform apply
```

**What this applies:**
- Remaining addons (kube-proxy, etc.)
- IRSA roles
- Secrets Manager secrets
- Route from Hub to EKS

**Time:** ~5 minutes

**Verify cluster is ready (run from bastion; see Step 5 for SSH/SSM setup):**

**⚠️ IMPORTANT:** EKS endpoint is private. You must access via Bastion host:

```bash
# SSH to bastion host
ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-ip>

# Configure kubectl on bastion
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

# Verify cluster access
kubectl cluster-info
kubectl get nodes
# Should show all nodes Ready
```

**Alternative: Verify nodes via SSM:**
```bash
# List all EKS nodes
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/payflow-eks-cluster,Values=owned" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,State.Name,LaunchTime]' \
  --output table

# Connect to a node to verify it's running Kubernetes
aws ssm start-session --target <instance-id>
# Then check: sudo systemctl status kubelet
```

---

## Step 4: Deploy Managed Services (RDS, ElastiCache, MQ)

**Prerequisites:**
- Step 3 (EKS/spoke-vpc-eks) must be applied so the VPC `payflow-eks-vpc` and private subnets exist.
- To allow RDS, ElastiCache, and MQ to accept traffic from EKS nodes, do **one** of:
  - **Option A (recommended):** Set `tfstate_bucket` to your Terraform state bucket (same as EKS) and use the **same workspace** (e.g. `dev`). The module will read the EKS cluster security group from spoke state.
  - **Option B:** After EKS is up, get the EKS node security group ID and pass it: `-var="eks_node_security_group_id=sg-xxxxx"`.

**⚠️ IMPORTANT:** You must provide `db_password` and `rabbitmq_password` (no defaults; use strong passwords).

```bash
cd terraform/aws/managed-services
terraform init
terraform workspace select dev   # must match spoke-vpc-eks workspace

# Optional: use tfvars so EKS SG is wired from spoke state (replace ACCOUNT_ID)
echo 'tfstate_bucket = "payflow-tfstate-ACCOUNT_ID"' >> terraform.tfvars

terraform validate
terraform plan -out=tfplan

# Apply (you will be prompted for db_password and rabbitmq_password)
terraform apply
# Or with vars: terraform apply -var="db_password=YOUR_DB_PASS" -var="rabbitmq_password=YOUR_MQ_PASS"
```

**When prompted, enter:**
- `db_password`: Strong password for PostgreSQL (e.g. `openssl rand -base64 32`)
- `rabbitmq_password`: Strong password for RabbitMQ (e.g. `openssl rand -base64 32`)

**What this creates:**
- **RDS PostgreSQL** — uses default engine version for major version (e.g. 16). Creation typically **15–20+ minutes** (longer if Multi-AZ in prod).
- **ElastiCache Redis** — typically **~8–10 minutes**.
- **Amazon MQ (RabbitMQ 3.13)** — typically **~15 minutes**.
- **Secrets** in AWS Secrets Manager (RDS and RabbitMQ endpoints are written by `null_resource` after creation).

**Time:** ~25–35 minutes (RDS is the bottleneck).

**Key variables (defaults are set):**
- `postgres_version`: Major version only, e.g. `"16"` or `"15"` (default `"16"`). Uses AWS default engine version for that major.
- `rabbitmq_version`: `"3.13"` (Amazon MQ valid values: 3.13, 4.2).
- `snapshot_window` (ElastiCache) and `maintenance_window` must not overlap; defaults are set to avoid overlap.

**Verify:**
```bash
terraform output
# Should show: rds_endpoint, rds_address, redis_endpoint, mq_amqp_endpoint, mq_management_endpoint

# Check secrets exist
aws secretsmanager list-secrets --query "SecretList[?contains(Name, 'payflow')]"
```

---

## Step 5: Deploy Bastion (Required for kubectl Access)

**⚠️ REQUIRED:** Bastion host is your **only way to access the EKS cluster** via kubectl since the cluster endpoint is private.

```bash
cd terraform/aws/bastion
terraform init
terraform workspace select dev
terraform apply
```

**What this creates:**
- EC2 instance in Hub public subnet
- Security group (SSH from authorized IPs; egress for EKS + SSM)
- IAM role with EKS access + **AmazonSSMManagedInstanceCore** (Session Manager)
- Route from bastion to EKS (via Transit Gateway)

**Time:** ~3 minutes

**After deployment — connect via SSM (recommended, no SSH key):**
```bash
cd terraform/aws/bastion
terraform output ssm_connect_command
# Run the printed command, e.g.:
aws ssm start-session --target i-xxxxx --region us-east-1

# Once on the bastion, configure kubectl
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1
kubectl get nodes
```

**Or connect via SSH:** `ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-public-ip>` (get IP from `terraform output bastion_public_ip`).

**Optional — SSH config:** Add to `~/.ssh/config` so you can run `ssh payflow-bastion`:
```sshconfig
# Key-based SSH
Host payflow-bastion
  HostName <bastion-public-ip>
  User ec2-user
  IdentityFile ~/.ssh/payflow-bastion-key.pem
```
To use SSH over SSM (no port 22, use instance ID as HostName):
```sshconfig
Host payflow-bastion-ssm
  HostName <bastion-instance-id>
  User ec2-user
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p
```
Then: `ssh payflow-bastion-ssm` (requires Session Manager plugin: `session-manager-plugin`).

**Note:** For EKS node access (no kubectl on nodes), use `aws ssm start-session --target <node-instance-id>` (see Step 3.3).

---

## Step 6: Deploy Application to Kubernetes

**Build and push images (ECR tag immutability):**  
ECR repositories use **immutable tags** by default, so you cannot overwrite `latest`. Build and push with a **new tag** (e.g. `v1` or `$(git rev-parse --short HEAD)`), then deploy with that tag:

```bash
# From repo root — set one tag for this release
export TAG="${TAG:-v1}"   # or: export TAG=$(git rev-parse --short HEAD)

# ECR login
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 334091769766.dkr.ecr.us-east-1.amazonaws.com

# Build and push (context = services/ so shared/ is included)
for svc in api-gateway auth-service wallet-service transaction-service notification-service frontend; do
  docker build -t 334091769766.dkr.ecr.us-east-1.amazonaws.com/payflow-eks-cluster/${svc}:${TAG} -f services/${svc}/Dockerfile ./services
  docker push 334091769766.dkr.ecr.us-east-1.amazonaws.com/payflow-eks-cluster/${svc}:${TAG}
done
```

Then deploy using that tag:

```bash
cd k8s/overlays/eks
IMAGE_TAG=$TAG ./deploy.sh
```

---

Now deploy the PayFlow application services to your EKS cluster.

```bash
cd k8s/overlays/eks
./deploy.sh
```

**What the script does:**
1. ✅ Verifies Terraform backend files exist
2. ✅ Gets AWS Account ID automatically
3. ✅ Replaces `<ACCOUNT_ID>` in `kustomization.yaml`
4. ✅ Sets environment (dev/prod) in `eks-external-secrets.yaml`
5. ✅ Validates Kustomize build
6. ✅ Prompts for deployment confirmation
7. ✅ Deploys with `kubectl apply -k .`

**Time:** ~2 minutes

**Verify deployment (via Bastion):**

**⚠️ IMPORTANT:** You must SSH to bastion first, then run kubectl commands:

```bash
# SSH to bastion
ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-ip>

# Check all pods are running
kubectl get pods -n payflow

# Check services
kubectl get svc -n payflow

# Check API Gateway logs
kubectl logs -n payflow deployment/api-gateway -f

# Test health endpoint (port-forward from bastion)
kubectl port-forward -n payflow svc/api-gateway 3000:3000
# In another terminal on bastion:
curl http://localhost:3000/health
```

**Verify nodes via SSM Session Manager:**
```bash
# Get node instance IDs
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/payflow-eks-cluster,Values=owned" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,State.Name]' \
  --output table

# Connect to a node
aws ssm start-session --target <instance-id>

# Verify node is healthy
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50
```

---

## Access Your Application

**⚠️ IMPORTANT:** All kubectl commands must be run from the bastion host since EKS endpoint is private.

### Option 1: Port Forward via Bastion (Quick Testing)

```bash
# SSH to bastion
ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-ip>

# Forward API Gateway (on bastion)
kubectl port-forward -n payflow svc/api-gateway 3000:3000

# In another terminal, create SSH tunnel from your local machine
ssh -i ~/.ssh/payflow-bastion-key.pem -L 3000:localhost:3000 ec2-user@<bastion-ip> -N

# Now access from your local browser
open http://localhost:3000/health
```

### Option 2: Via Ingress (Production)

```bash
# SSH to bastion
ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-ip>

# Get ingress URL
kubectl get ingress -n payflow

# Access via ALB URL (from AWS Load Balancer Controller)
# The ALB is public-facing, so you can access it directly from your browser
```

---

## Troubleshooting

### Issue: "Error: Resource depends on resource that doesn't exist"
**Solution:** You skipped a target. Go back and apply the missing resource in order.

### Issue: "Error: VPC CNI pods not starting"
**Solution:** Wait for EKS cluster to be fully ready (all control plane components), then apply CNI addon.

### Issue: "Error: Nodes not joining cluster"
**Solution:** Check that VPC CNI addon is installed and running (via bastion):
```bash
# SSH to bastion first
ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-ip>

# Then check CNI
kubectl get pods -n kube-system -l k8s-app=aws-node
```

**Or verify nodes directly via SSM:**
```bash
# Get node instance ID
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/payflow-eks-cluster,Values=owned" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table

# Connect to node
aws ssm start-session --target <instance-id>

# Check kubelet status
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100
```

### Issue: "Image tag 'latest' already exists... cannot be overwritten because the tag is immutable"
**Solution:** ECR has tag immutability enabled. Push with a **new tag** (e.g. `v1` or a git SHA), then deploy with that tag:
```bash
export TAG=v1   # or: TAG=$(git rev-parse --short HEAD)
# Build/push each service with :${TAG} (see Step 6 "Build and push images" above)
cd k8s/overlays/eks && IMAGE_TAG=$TAG ./deploy.sh
```

### Issue: "Error: ImagePullBackOff"
**Solution:** Run `./deploy.sh` script which automatically replaces `<ACCOUNT_ID>` placeholder.

### Issue: "Error: Null value found in list" (managed-services security groups)
**Solution:** RDS/ElastiCache/MQ security groups need the EKS node security group ID. Set **one** of:
- `tfstate_bucket = "payflow-tfstate-ACCOUNT_ID"` (same bucket and workspace as EKS) so the module reads it from spoke state, or
- `-var="eks_node_security_group_id=sg-xxxxx"` (get the SG from EKS node group or cluster in AWS console).

### Issue: "Error: Cannot find version X.Y for postgres" or "multiple RDS engine versions"
**Solution:** The managed-services module uses the `aws_rds_engine_version` data source with `default_only = true`. Ensure `postgres_version` is a **major version** only (e.g. `"16"` or `"15"`). Override if needed: `-var="postgres_version=15"`.

### Issue: "Error: Cannot connect to RDS"
**Solution:** 
1. Verify RDS endpoint from Terraform output
2. Check security group allows traffic from EKS nodes (requires `tfstate_bucket` or `eks_node_security_group_id` to be set)
3. Verify Secrets Manager has correct credentials:
```bash
aws secretsmanager get-secret-value --secret-id payflow/dev/rds
```

### Issue: Pods in CrashLoopBackOff (api-gateway, auth-service, wallet-service, etc.)
**Diagnose on bastion** — get the real error from a crashing pod:
```bash
# From bastion (SSH or SSM)
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

# Logs from one failing deployment (pick the one that’s crashing)
kubectl logs -n payflow deployment/api-gateway --tail=80
kubectl logs -n payflow deployment/auth-service --tail=80
```

**Common causes and fixes:**

| Symptom in logs | Cause | Fix |
|-----------------|--------|-----|
| `Cannot find module '../shared/metrics'` | Image built without `shared/` | Rebuild images with context `./services` and redeploy with a new tag (see Step 6 and ECR troubleshooting above). |
| `ECONNREFUSED` to Redis or RDS host | EKS nodes can’t reach Redis/RDS | RDS/Redis SGs must allow EKS **node** SG. See [RDS-CONNECTIVITY.md](terraform/aws/managed-services/RDS-CONNECTIVITY.md); re-apply managed-services with same workspace as spoke or `-var="eks_node_sg_id=sg-xxx"`. |
| `transactions_total already registered` (api-gateway crash) | Duplicate Prometheus metric in same process | Fixed in `services/shared/metrics.js` (getSingleMetric). Rebuild api-gateway image and redeploy. |
| `InvalidProviderConfig` / no EC2 IMDS role for External Secrets | External Secrets SA not bound to IRSA role | See [External Secrets IRSA](#external-secrets-irsa-required-once) below. |
| `RABBITMQ_URL` empty / connection failed | Secret not synced or Amazon MQ URL missing | Ensure `payflow/dev/rabbitmq` in Secrets Manager has key `url` (managed-services `null_resource` updates it). On bastion: `kubectl get externalsecret -n payflow` and `kubectl get secret db-secrets -n payflow -o yaml` to confirm keys. |
| DB auth / password error | Wrong credentials in secret | Verify `payflow/dev/rds` in Secrets Manager; re-sync: delete `db-secrets` in payflow and let ESO recreate it. |

After fixing, restart rollouts:
```bash
kubectl rollout restart deployment -n payflow
kubectl get pods -n payflow -w
```

### External Secrets IRSA (verify first; manual only if missing)

The External Secrets ServiceAccount must have `eks.amazonaws.com/role-arn` set so ESO can read Secrets Manager. It is **set automatically** in two cases:

1. **Terraform bootstrap-node** — When the cluster is created, the bootstrap instance installs ESO via Helm with `--set serviceAccount.annotations.eks.amazonaws.com/role-arn=$EXTERNAL_SECRETS_IRSA_ARN`.
2. **deploy.sh** — When you run `k8s/overlays/eks/deploy.sh`, it gets the IRSA ARN from `terraform output` and injects it into the bastion script so the Helm upgrade keeps the annotation.

**Verify** (on bastion):
```bash
kubectl get sa external-secrets -n external-secrets -o yaml | grep eks.amazonaws.com/role-arn
```
If you see a line like `eks.amazonaws.com/role-arn: arn:aws:iam::...`, no manual step is needed.

**Only if the annotation is missing** (e.g. ESO was installed manually without it), annotate and restart:
```bash
cd terraform/aws/spoke-vpc-eks
ARN=$(terraform output -raw external_secrets_irsa_arn)
# On bastion:
kubectl annotate serviceaccount external-secrets -n external-secrets \
  eks.amazonaws.com/role-arn="$ARN" --overwrite
kubectl rollout restart deployment external-secrets -n external-secrets
```

### Issue: Pods stuck in Pending
**Solution:**
```bash
# Check pod events
kubectl describe pod <pod-name> -n payflow

# Check node resources
kubectl describe nodes

# Check if nodes have capacity
kubectl top nodes
```

---

## Time Estimates

| Phase | Time | Notes |
|-------|------|-------|
| Bootstrap | 2 min | One-time setup |
| Hub VPC | 3 min | Quick |
| EKS VPC & Cluster | 40-50 min | Use targets in order |
| Managed Services | 25-35 min | RDS 15-20+ min; set tfstate_bucket or eks_node_sg |
| Bastion | 3 min | Required for kubectl (EKS private) |
| Application | 2 min | Fast with script |
| **Total** | **~75-95 min** | First deployment |

Subsequent deployments are faster (infrastructure already exists).

---

## Next Steps

- ✅ Infrastructure is running!
- 📖 Read [Deployment Guide](docs/DEPLOYMENT.md) for rollback procedures
- 📖 Read [Runbook](docs/RUNBOOK.md) for monitoring and debugging
- 🌐 Add Cloudflare DNS/CDN (see earlier conversation)

---

## Quick Reference Commands

**⚠️ REMEMBER:** All kubectl commands must be run from bastion host (EKS endpoint is private).

### Access via Bastion

```bash
# SSH to bastion
ssh -i ~/.ssh/payflow-bastion-key.pem ec2-user@<bastion-ip>

# Configure kubectl (on bastion)
aws eks update-kubeconfig --name payflow-eks-cluster --region us-east-1

# Check cluster status
kubectl cluster-info
kubectl get nodes

# Check application status
kubectl get pods -n payflow
kubectl get svc -n payflow
kubectl get ingress -n payflow

# View logs
kubectl logs -n payflow deployment/api-gateway -f

# Port forward for testing
kubectl port-forward -n payflow svc/api-gateway 3000:3000
kubectl port-forward -n payflow svc/frontend 80:80
```

### Access Nodes via SSM Session Manager

```bash
# List all EKS nodes
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/payflow-eks-cluster,Values=owned" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,State.Name,LaunchTime]' \
  --output table

# Connect to a node
aws ssm start-session --target <instance-id>

# Once connected, check node status
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100
kubectl get nodes  # If kubectl is installed on node
```

### Terraform Commands

```bash
# Check Terraform state
cd terraform/aws/spoke-vpc-eks
terraform output
terraform state list

# Get bastion IP
cd terraform/aws/bastion
terraform output
```

