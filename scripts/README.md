# PayFlow scripts

## deploy-microk8s.sh (recommended for local / beginners)

One script to run PayFlow on MicroK8s: **clone repo → run script**. It will:

- Install MicroK8s if you don’t have it (macOS: VM with 6 CPU, 12 GB RAM by default; Linux: snap).
- Start the VM if it was stopped, enable addons, deploy the app, and wait for DB migration.
- Print how to access the app (port-forward or ingress).

**Usage:**

```bash
./scripts/deploy-microk8s.sh
```

**Requirements:** Docker (and on macOS, Multipass). Optional: set `MICROK8S_VM_CPU` and `MICROK8S_VM_MEM_GB` before running to size the VM (e.g. `MICROK8S_VM_CPU=8 MICROK8S_VM_MEM_GB=16 ./scripts/deploy-microk8s.sh`).

See [MicroK8s deployment guide](../docs/microk8s-deployment.md#quick-start-one-script-deploy).

**Optional — add a worker later (macOS Multipass only):**

```bash
./scripts/deploy-microk8s.sh add-worker [VM_NAME] [CPUS] [MEM_GB] [DISK_GB]
# VM_NAME defaults to the next free payflow-worker-N (2 CPU, 4G RAM, 20G disk if omitted)
```

**Tear down workers + PayFlow namespace** (e.g. before a clean re-deploy):

```bash
./scripts/deploy-microk8s.sh remove-workers
```

---

## setup-hosts-payflow-local.sh

Add `www.payflow.local` and `api.payflow.local` to `/etc/hosts` so you can use the local Ingress without port-forwarding. Run once on your Mac after deploying with the local overlay. See [Access Application](../docs/microk8s-deployment.md#method-2-ingress-with-payflowlocal-no-port-forward-local-overlay-only).

```bash
./scripts/setup-hosts-payflow-local.sh
```

## fix-microk8s-nodes.sh

Start stopped Multipass worker VMs so NotReady nodes become Ready again. See [MicroK8s deployment doc](../docs/microk8s-deployment.md#pods-stuck-pending--notready-nodes-multipass-workers).

---

## build-push-ecr.sh

Build all service images and push to ECR with a single tag (e.g. v5). Use after code changes so the cluster runs the new code.

**Usage:**

```bash
./scripts/build-push-ecr.sh [IMAGE_TAG]
# Default tag: v5
./scripts/build-push-ecr.sh v5
```

**Requirements:** AWS CLI configured, Docker, and ECR repos created (Terraform EKS module creates these).

**Then deploy:**

```bash
cd k8s/overlays/eks
IMAGE_TAG=v5 ./deploy.sh
```

## Terraform (RDS / Redis access)

If pods cannot reach RDS or Redis, add the EKS node security group IDs to Terraform so both RDS and ElastiCache allow traffic:

1. Get EKS node SGs (from AWS console or `aws ec2 describe-security-groups` for the EKS VPC).
2. In `terraform/aws/managed-services/terraform.tfvars` set:
   ```hcl
   additional_rds_security_group_ids = ["sg-xxx", "sg-yyy"]
   ```
3. Run `terraform apply` in `terraform/aws/managed-services`.

The same list is used for RDS (5432) and Redis (6379).
