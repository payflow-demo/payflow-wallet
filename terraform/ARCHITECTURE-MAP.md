# PayFlow Terraform Architecture Map

This document maps every resource, dependency order, cycles, IAM roles, security groups, and environment boundaries across the Terraform codebase.

---

## 1. Architecture Diagram (Every Resource → Box, Every Relationship → Arrow)

### 1.1 Module-level view (cross-stack)

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│  HUB VPC (terraform/aws/hub-vpc)                                                          │
│  ┌──────────────┐   ┌─────────────────┐   ┌─────────────┐   ┌──────────────────────────┐  │
│  │ aws_vpc.hub  │──►│ aws_subnet      │   │ aws_ec2_    │   │ aws_route_table          │  │
│  └──────┬───────┘   │ hub_public/     │   │ transit_    │◄──│ hub_public / hub_private │  │
│         │          │ hub_private     │   │ gateway.hub │   └──────────────────────────┘  │
│         │          └─────────────────┘   └──────┬──────┘                                 │
│         │          ┌────────────────────────────▼─────────────────────┐                   │
│         │          │ aws_ec2_transit_gateway_vpc_attachment.hub        │                   │
│         │          │ (hub VPC ↔ TGW)                                   │                   │
│         │          └───────────────────────────────────────────────────┘                   │
│         │          aws_route.hub_public_to_eks → var.spoke_vpc_cidr via TGW                │
└─────────┼─────────────────────────────────────────────────────────────────────────────────┘
          │
          │  (Spoke uses data.aws_vpc.hub, data.aws_ec2_transit_gateway.hub,
          │   data.aws_route_table.hub_private — no Terraform dependency, same account)
          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│  SPOKE VPC EKS (terraform/aws/spoke-vpc-eks)                                             │
│  ┌──────────────┐                                                                       │
│  │ aws_vpc.eks  │──► aws_subnet.eks_public[*], aws_subnet.eks_private[*]                 │
│  └──────┬───────┘   aws_route_table.eks_public/eks_private, route_table_association      │
│         │            aws_internet_gateway.eks, aws_eip.nat, aws_nat_gateway.eks          │
│         │            aws_ec2_transit_gateway_vpc_attachment.eks (spoke ↔ TGW)             │
│         │            aws_route.hub_to_eks (hub private RT → eks_vpc_cidr via TGW)          │
│         │                                                                                │
│         ├──► aws_flow_log.eks (→ flow_logs IAM, cloudwatch_log_group.flow_logs)           │
│         │                                                                                │
│         ├──► aws_eks_cluster.payflow                                                     │
│         │         (vpc_config.subnet_ids = eks_private + eks_public)                      │
│         │         (role_arn = aws_iam_role.eks_cluster)                                  │
│         │         (encryption_config.key_arn = aws_kms_key.eks)                           │
│         │    depends_on: time_sleep.wait_for_cluster_iam, cloudwatch_log_group.eks_cluster│
│         │                                                                                │
│         └──► EKS chain: cluster → wait_for_cluster → tls_certificate.eks → OIDC         │
│                         → IRSA roles → wait_for_irsa → aws_eks_addon.vpc_cni              │
│                         → aws_eks_node_group.on_demand/spot → coredns, kube_proxy,       │
│                           ebs_csi → aws-auth ConfigMap, Helm releases                    │
└─────────────────────────────────────────────────────────────────────────────────────────┘
          │
          │  outputs: eks_cluster_security_group_id (cluster SG, used as “node” SG for managed SGs)
          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│  MANAGED SERVICES (terraform/aws/managed-services)  [input: var.eks_node_security_group_id] │
│  RDS:    aws_security_group.rds (ingress from var.eks_node_security_group_id) → aws_db_instance │
│  Redis:  aws_security_group.elasticache (ingress from var.eks_node_security_group_id)   │
│  MQ:     aws_security_group.mq (ingress from var.eks_node_security_group_id)             │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│  BASTION (terraform/aws/bastion)  [data: hub VPC, hub public subnet]                    │
│  aws_security_group.bastion → aws_instance.bastion (IAM instance profile)               │
│  No SG reference to EKS; egress 10.0.0.0/8:443 for kubectl                              │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Spoke EKS — resource-level dependency graph (arrows = “depends on” or “references”)

```
[Data: aws_vpc.hub, aws_ec2_transit_gateway.hub, aws_route_table.hub_private]  (external to apply)

aws_vpc.eks
  ├─► aws_subnet.eks_public[*], aws_subnet.eks_private[*]
  ├─► aws_internet_gateway.eks (count)
  ├─► aws_route_table.eks_public[*], aws_route_table.eks_private[*]
  ├─► aws_route_table_association.eks_public/eks_private
  ├─► aws_eip.nat[*]  (no dep on VPC in TF, but logical)
  ├─► aws_nat_gateway.eks[*] ─► aws_subnet.eks_public[*], aws_internet_gateway.eks
  ├─► aws_route.eks_private[*] ─► aws_nat_gateway.eks[*] (dynamic)
  ├─► aws_ec2_transit_gateway_vpc_attachment.eks ─► aws_subnet.eks_private[*]
  ├─► aws_route.hub_to_eks (writes to hub RT; uses data)
  │
  ├─► aws_iam_role.flow_logs, aws_iam_role_policy.flow_logs
  │     └─► time_sleep.wait_for_flow_logs_iam
  ├─► aws_cloudwatch_log_group.flow_logs
  ├─► aws_flow_log.eks ─► time_sleep.wait_for_flow_logs_iam
  │
  ├─► aws_iam_role.eks_cluster, aws_iam_role_policy_attachment.eks_cluster_policy
  │     └─► time_sleep.wait_for_cluster_iam
  ├─► aws_kms_key.eks
  ├─► aws_cloudwatch_log_group.eks_cluster
  ├─► aws_eks_cluster.payflow ─► time_sleep.wait_for_cluster_iam, cloudwatch_log_group.eks_cluster, kms_key.eks
  │     └─► time_sleep.wait_for_cluster
  │           └─► data.tls_certificate.eks
  │                 └─► aws_iam_openid_connect_provider.eks
  │                       └─► (locals.oidc_url)
  │
  ├─► IRSA: vpc_cni_irsa, alb_controller_irsa, external_dns_irsa, ebs_csi_irsa, cluster_autoscaler_irsa
  │         (each depends_on OIDC; policies/attachments on roles)
  │     └─► time_sleep.wait_for_irsa
  │
  ├─► aws_eks_addon.vpc_cni ─► wait_for_cluster, wait_for_irsa
  │
  ├─► aws_iam_role.eks_node + 4 policy attachments ─► time_sleep.wait_for_node_iam
  ├─► aws_eks_node_group.on_demand ─► wait_for_node_iam, aws_eks_cluster.payflow, aws_eks_addon.vpc_cni
  ├─► aws_eks_node_group.spot   ─► same
  │
  ├─► aws_eks_addon.coredns, aws_eks_addon.kube_proxy ─► vpc_cni, on_demand, spot
  ├─► aws_eks_addon.ebs_csi ─► on_demand, spot, vpc_cni, wait_for_irsa
  │
  ├─► kubernetes_config_map_v1_data.aws_auth ─► cluster, on_demand, spot
  │
  ├─► helm_release.alb_controller ─► on_demand, spot, coredns, alb_controller_irsa, wait_for_irsa
  ├─► helm_release.external_dns ─► on_demand, spot, coredns, alb_controller, external_dns_irsa, wait_for_irsa
  ├─► helm_release.metrics_server ─► on_demand, coredns
  ├─► helm_release.cluster_autoscaler ─► on_demand, spot, coredns, metrics_server, cluster_autoscaler_irsa, wait_for_irsa
  ├─► helm_release.external_secrets ─► on_demand, coredns, external_secrets_irsa, wait_for_external_secrets_irsa
  │
  ├─► ECR repos (no dep on EKS), secrets-manager (KMS, secrets, external_secrets_irsa)
  ├─► Route53/ACM (optional), WAF, GuardDuty, CloudTrail, AWS Config, Security Hub
  └─► (Standalone or minimal deps: aws_route53_zone, aws_acm_certificate, etc.)
```

---

## 2. Dependency Order (What Must Exist First)

Apply order that respects all arrows (no parallelization detail; just “A before B”):

1. **Hub (if applied first):** `aws_vpc.hub` → subnets → route tables → TGW → TGW attachment → route `hub_public_to_eks`.
2. **Spoke – networking:** `aws_vpc.eks` → subnets → IGW (if NAT) → EIP → NAT GW → route tables and associations → TGW attachment → `aws_route.hub_to_eks`.
3. **Spoke – flow logs:** `aws_iam_role.flow_logs` + `aws_iam_role_policy.flow_logs` → `time_sleep.wait_for_flow_logs_iam` → `aws_cloudwatch_log_group.flow_logs` → `aws_flow_log.eks`.
4. **Spoke – EKS cluster IAM:** `aws_iam_role.eks_cluster` + `aws_iam_role_policy_attachment.eks_cluster_policy` → `time_sleep.wait_for_cluster_iam`.
5. **Spoke – EKS cluster:** `aws_kms_key.eks`, `aws_cloudwatch_log_group.eks_cluster` → `aws_eks_cluster.payflow` → `time_sleep.wait_for_cluster`.
6. **OIDC:** `data.tls_certificate.eks` → `aws_iam_openid_connect_provider.eks`.
7. **IRSA roles:** All five IRSA roles + their policies/attachments (depend on OIDC) → `time_sleep.wait_for_irsa`.  
   **External Secrets IRSA** (in secrets-manager.tf) + policy → `time_sleep.wait_for_external_secrets_irsa`.
8. **VPC CNI addon:** `aws_eks_addon.vpc_cni` (after wait_for_cluster, wait_for_irsa).
9. **Node IAM:** `aws_iam_role.eks_node` + four policy attachments → `time_sleep.wait_for_node_iam`.
10. **Node groups:** `aws_eks_node_group.on_demand`, `aws_eks_node_group.spot` (after wait_for_node_iam, cluster, vpc_cni addon).
11. **Addons:** `aws_eks_addon.coredns`, `aws_eks_addon.kube_proxy`, `aws_eks_addon.ebs_csi`.
12. **Kubernetes:** `kubernetes_config_map_v1_data.aws_auth` (after cluster + node groups).
13. **Helm:** `helm_release.alb_controller` → `helm_release.external_dns`; `helm_release.metrics_server`; `helm_release.cluster_autoscaler`; `helm_release.external_secrets`.
14. **Managed services (separate apply):** After spoke is applied, pass `eks_cluster_security_group_id` (or node SG) into managed-services; then RDS/ElastiCache/MQ SGs and instances.

---

## 3. Cycle Check (Trace Every Arrow)

**Rule:** If you can follow a path from Resource A back to Resource A, there is a loop.

- **Spoke EKS:**  
  All edges go in one direction: VPC → subnets/networking → cluster IAM → cluster → wait → OIDC → IRSA → wait_for_irsa → vpc_cni addon → node groups → coredns/kube_proxy/ebs_csi → aws-auth and Helm.  
  **No path from any node back to itself.** ✓

- **Hub:**  
  VPC → subnets → route tables → TGW → TGW attachment → route. No back-edge into VPC or TGW. ✓

- **Managed services:**  
  Data sources (VPC, subnets) and variable `eks_node_security_group_id`; SGs reference that variable (input from spoke). No output of managed-services is consumed by spoke in Terraform. ✓

- **Bastion:**  
  Data (hub VPC, subnet) → SG → instance. No cycle. ✓

- **Cross-stack:**  
  Spoke uses **data** (hub VPC, TGW, hub route table) and **writes** `aws_route.hub_to_eks` in the same apply (assuming hub already exists or is in same state). No Terraform dependency from hub to spoke; state or apply order is operational, not a graph cycle. ✓

**Conclusion: No dependency cycles.**

---

## 4. IAM Roles and What They Attach To

| IAM Role | Principal / Used By | Policies Attached | Purpose |
|-----------|---------------------|-------------------|---------|
| **aws_iam_role.eks_cluster** | `eks.amazonaws.com` | AmazonEKSClusterPolicy | EKS control plane |
| **aws_iam_role.eks_node** | `ec2.amazonaws.com` (node groups) | AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy, AmazonEC2ContainerRegistryReadOnly, AmazonSSMManagedInstanceCore | Worker nodes |
| **aws_iam_role.vpc_cni_irsa** | OIDC `kube-system:aws-node` | AmazonEKS_CNI_Policy | VPC CNI addon (IRSA) |
| **aws_iam_role.alb_controller_irsa** | OIDC `kube-system:aws-load-balancer-controller` | Inline policy (ALB/NLB, EC2, tags) | ALB Ingress Controller |
| **aws_iam_role.external_dns_irsa** | OIDC `kube-system:external-dns` | Inline (Route53 ChangeResourceRecordSets, List*) | External DNS |
| **aws_iam_role.ebs_csi_irsa** | OIDC `kube-system:ebs-csi-controller-sa` | AmazonEBSCSIDriverPolicy | EBS CSI addon |
| **aws_iam_role.cluster_autoscaler_irsa** | OIDC `kube-system:cluster-autoscaler` | Inline (ASG describe/set desired, EC2 describe) | Cluster Autoscaler |
| **aws_iam_role.external_secrets_irsa** | OIDC `external-secrets:external-secrets` | Inline (Secrets Manager GetSecretValue, KMS Decrypt) | External Secrets Operator |
| **aws_iam_role.flow_logs** | `vpc-flow-logs.amazonaws.com` | Inline (logs CreateLog*, PutLogEvents, Describe*) | VPC Flow Logs |
| **aws_iam_role.config** | `config.amazonaws.com` | AWS_ConfigRole, custom S3 delivery | AWS Config |
| **aws_iam_role.bastion** | `ec2.amazonaws.com` (instance profile) | Inline (eks:DescribeCluster, ListClusters) | Bastion host |

**Diagram (attach relationship):**

```
EKS cluster        → aws_iam_role.eks_cluster
Node groups        → aws_iam_role.eks_node
VPC CNI addon      → aws_iam_role.vpc_cni_irsa (via service_account_role_arn)
EBS CSI addon      → aws_iam_role.ebs_csi_irsa
Helm alb_controller → aws_iam_role.alb_controller_irsa
Helm external_dns  → aws_iam_role.external_dns_irsa
Helm cluster_autoscaler → aws_iam_role.cluster_autoscaler_irsa
Helm external_secrets → aws_iam_role.external_secrets_irsa
aws_flow_log.eks   → aws_iam_role.flow_logs
AWS Config         → aws_iam_role.config
Bastion instance   → aws_iam_instance_profile.bastion → aws_iam_role.bastion
```

---

## 5. Security Groups: Ingress/Egress and References to Other SGs

### 5.1 Spoke EKS module

- **No custom security groups** are defined in the EKS Terraform. The cluster uses the **AWS-managed cluster security group** from `aws_eks_cluster.payflow.vpc_config[0].cluster_security_group_id`. Node groups use the same cluster SG (or the managed node SG, depending on EKS behavior; the output used for “node” access is the cluster SG).
- **Output:** `eks_cluster_security_group_id` = that cluster SG. Passed to managed-services as `var.eks_node_security_group_id`.

### 5.2 Managed services (RDS, ElastiCache, MQ)

| SG Resource | VPC | Ingress | Egress | References other SG? |
|-------------|-----|---------|--------|-----------------------|
| **aws_security_group.rds** | EKS VPC (data) | TCP 5432 from `var.eks_node_security_group_id` | All outbound 0.0.0.0/0 | **Yes** → EKS node/cluster SG (input) |
| **aws_security_group.elasticache** | EKS VPC (data) | TCP 6379 from `var.eks_node_security_group_id` | All outbound 0.0.0.0/0 | **Yes** → EKS node/cluster SG (input) |
| **aws_security_group.mq** | EKS VPC (data) | TCP 5671, 15671 from `var.eks_node_security_group_id` | All outbound 0.0.0.0/0 | **Yes** → EKS node/cluster SG (input) |

No SG in these modules references another SG defined in the same module; they only reference the **input** SG from the EKS spoke.

### 5.3 Bastion

| SG Resource | VPC | Ingress | Egress | References other SG? |
|-------------|-----|---------|--------|-----------------------|
| **aws_security_group.bastion** | Hub VPC (data) | TCP 22 from `var.authorized_ssh_cidrs` | TCP 443 to 10.0.0.0/8; UDP 53 to 0.0.0.0/0 | **No** (CIDR only) |

**Summary:** No circular SG references. Only RDS, ElastiCache, and MQ reference another SG (the EKS node/cluster SG), one-way.

---

## 6. Environment Boundaries: Shared vs Environment-Specific, Remote State

### 6.1 What is shared vs environment-specific

| Scope | Shared | Environment-specific |
|-------|--------|----------------------|
| **Account/Region** | Same AWS account and region for hub, spoke, managed-services, bastion (typical). | Can use separate accounts per env (not in current TF). |
| **Hub VPC** | One hub per account (or per “network” boundary). TGW, hub subnets, hub route table. | `var.environment`, `var.aws_region`, `var.hub_vpc_cidr`, `var.spoke_vpc_cidr` can differ per env. |
| **Spoke EKS** | Same Terraform module layout. | `var.environment`, `var.eks_cluster_name`, `var.eks_vpc_cidr`, `var.availability_zones`, `var.kubernetes_version`, `var.domain_name`, `var.admin_iam_users`, feature flags (e.g. `var.enable_nat_gateway`, `var.enable_external_dns`). Workspace (`terraform.workspace`) used in locals for node config. |
| **Managed services** | Same module layout; EKS VPC/subnets looked up by tags. | `var.environment`, `var.eks_node_security_group_id` (from spoke output), DB/Redis/MQ sizing and options. |
| **Bastion** | One per hub (or per env in hub). | `var.environment`, `var.authorized_ssh_cidrs`. |

### 6.2 Where is remote state?

| Module / Stack | Backend | State key (conceptual) |
|----------------|---------|--------------------------|
| **Spoke EKS** | S3 + DynamoDB (backend.tf) | `bucket = "payflow-tfstate-ACCOUNT_ID"`, `key = "aws/eks/terraform.tfstate"`. Workspace prefix applied (e.g. `env:/dev/` or `env:/prod/`). |
| **Hub VPC** | Not shown in provided files; often S3 in same or separate bucket. | Typically e.g. `aws/hub/terraform.tfstate` or per-workspace. |
| **Managed services** | Not shown; often S3. | Often separate key, e.g. `aws/managed-services/terraform.tfstate`. |
| **Bastion** | Not shown; often S3. | Often `aws/bastion/terraform.tfstate`. |

**Cross-stack wiring:**  
Spoke outputs (e.g. `eks_cluster_security_group_id`) are passed into managed-services via **variable** (e.g. CLI, CI, or `terraform_remote_state` data source). No `backend` block in the snippets for hub, managed-services, or bastion—so remote state location for those is defined wherever they are actually run.

### 6.3 Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REMOTE STATE (S3 + DynamoDB lock)                                           │
│  Bucket: payflow-tfstate-ACCOUNT_ID                                          │
│  Keys (example): env:/dev/aws/eks/terraform.tfstate, env:/prod/aws/eks/...   │
└─────────────────────────────────────────────────────────────────────────────┘
                    │
                    │ read/write (spoke-vpc-eks only in backend.tf)
                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  SHARED (by design, one per account or per “network”)                        │
│  • Hub VPC, TGW, hub route tables, TGW attachment                            │
│  • Data lookups in spoke: hub VPC, TGW, hub_private RT                       │
└─────────────────────────────────────────────────────────────────────────────┘
                    │
                    │ aws_route.hub_to_eks (spoke writes to hub RT)
                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  ENVIRONMENT-SPECIFIC (per workspace or var.environment)                    │
│  • Spoke VPC, EKS cluster, node groups, addons, Helm, IRSA, ECR, secrets    │
│  • Managed services RDS/Redis/MQ (when passed eks_cluster_security_group_id)│
│  • Bastion (optional; can be shared or per-env)                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Quick Reference

| Question | Answer |
|----------|--------|
| **Dependency loop?** | No. Spoke, hub, managed-services, bastion are acyclic. |
| **Security group circular reference?** | No. Only RDS/ElastiCache/MQ reference EKS node SG (input). |
| **First resource in spoke EKS?** | `aws_vpc.eks` (and parallel: cluster IAM, KMS, flow log IAM). |
| **Order of EKS pieces?** | Cluster IAM → cluster → wait → OIDC → IRSA → wait_for_irsa → vpc_cni addon → node IAM → node groups → coredns/kube-proxy/ebs_csi → aws-auth → Helm. |
| **IAM roles** | See §4; 11 roles (cluster, node, 5 IRSA + external_secrets, flow_logs, config, bastion). |
| **Remote state** | Spoke EKS: S3 + DynamoDB, key `aws/eks/terraform.tfstate` with workspace prefix. Other stacks: define in their backend config. |
