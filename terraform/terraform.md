# Terraform Architecture

Our architecture uses a **hub-and-spoke design** with **Transit Gateway** connecting VPCs. Each VPC currently manages its own egress (NAT or Internet Gateway), which keeps the setup simple and isolated.

---

## Overview

- **Hub VPC** holds shared network services: the Transit Gateway, bastion host, and (optionally) future shared services. It is the central point for connectivity between VPCs.
- **Spoke VPC (EKS)** holds the Kubernetes cluster and application workloads. It attaches to the same Transit Gateway so the hub (e.g. bastion) can reach the cluster.
- **Egress** is not centralized: the spoke uses its own NAT gateways for outbound internet; the hub’s public subnet uses an Internet Gateway. There is no single egress VPC or shared NAT.

---

## Hub VPC

| Component | Purpose |
|-----------|---------|
| **CIDR** | `10.0.0.0/16` (configurable) |
| **Public subnet** | Bastion host; has route `0.0.0.0/0` → Internet Gateway. Also has a route to the **spoke VPC CIDR** via Transit Gateway so bastion can reach EKS. |
| **Private subnet** | Reserved for shared services; no default route to the internet in this design. |
| **Transit Gateway** | Created in the hub; both hub and spoke attach their VPCs to it. |
| **TGW attachment** | Hub attaches to the TGW using both public and private subnets so the bastion (in public) can use the TGW to reach the spoke. |

**Traffic:** Bastion → EKS uses: Hub public subnet → route to spoke CIDR via TGW → Spoke VPC. Return path: Spoke public subnet has a route for **hub VPC CIDR** via TGW back to the hub.

---

## Spoke VPC (EKS)

| Component | Purpose |
|-----------|---------|
| **CIDR** | `10.10.0.0/16` (configurable) |
| **Public subnets** | One per AZ. Host NAT gateways (when enabled), ALB, and EKS API endpoint ENIs. Routes: hub CIDR → TGW (return path to bastion); optionally `0.0.0.0/0` → Internet Gateway. |
| **Private subnets** | One per AZ. EKS node groups and workloads. Routes: `10.0.0.0/8` → Transit Gateway (reach hub and other private IPs); optionally `0.0.0.0/0` → NAT gateway in same AZ for internet egress. |
| **Transit Gateway attachment** | Spoke attaches to the same TGW via **private subnets** only. |
| **NAT gateways** | Optional (`enable_nat_gateway`). When enabled, one NAT per AZ in public subnets; private subnet default route sends internet traffic through the local NAT. |

**Traffic:**  
- **To hub / bastion:** Private or public subnet → route for `10.0.0.0/8` (or hub CIDR) → TGW → Hub.  
- **To internet:** Private subnet → `0.0.0.0/0` → NAT gateway (in same AZ) → Internet Gateway. VPC endpoints (ECR, S3, etc.) can be used so AWS API traffic does not need the NAT.

---

## How the two VPCs connect

1. **Transit Gateway** is created in the hub and lives in the same account as both VPCs.
2. **Hub** attaches to the TGW (subnets in hub VPC).
3. **Spoke** attaches to the TGW (private subnets in EKS VPC).
4. **Routing:**
   - **Hub → Spoke:** Hub public route table has a route for **spoke VPC CIDR** via TGW. Hub private route table gets a route for **spoke VPC CIDR** via TGW (managed from spoke Terraform).
   - **Spoke → Hub:** Spoke route tables have a route for **hub VPC CIDR** via TGW (public subnets for return path to bastion). Spoke private route tables have `10.0.0.0/8` via TGW so pods/nodes can reach the hub and any other private space.

So **east–west** traffic between hub and spoke goes over the Transit Gateway; **egress to the internet** is handled inside each VPC (hub via IGW, spoke via NAT when enabled).

---

## Summary

| Aspect | Implementation |
|--------|----------------|
| **Pattern** | Hub-and-spoke with one Transit Gateway. |
| **Hub** | Shared TGW + bastion; routes to spoke via TGW. |
| **Spoke** | EKS in private subnets; routes to hub and `10.0.0.0/8` via TGW; optional NAT per AZ for internet. |
| **Egress** | Per-VPC: hub uses IGW for public subnet; spoke uses its own NAT gateways (no centralized egress). |
| **Isolation** | Each VPC has its own egress path and optional VPC endpoints, keeping the design simple and contained. |

For a dependency-level view of resources and Terraform flow, see [ARCHITECTURE-MAP.md](ARCHITECTURE-MAP.md).

---

## Resources: Hub vs Spoke

### Hub (terraform/aws/hub-vpc + terraform/aws/bastion)

| Resource | Purpose |
|----------|---------|
| **VPC** | `aws_vpc.hub` — CIDR `10.0.0.0/16`. |
| **Subnets** | Public (bastion), private (reserved for shared services). |
| **Internet Gateway** | `aws_internet_gateway.hub` — internet for public subnet. |
| **Route tables** | Public: `0.0.0.0/0` → IGW, spoke CIDR → TGW. Private: no default route; route to spoke CIDR via TGW is added by spoke Terraform. |
| **Transit Gateway** | `aws_ec2_transit_gateway.hub` — shared by hub and spoke. |
| **TGW attachment** | Hub VPC attached to TGW (public + private subnets). |
| **Bastion** (bastion module) | EC2 in hub public subnet; IAM role (EKS describe, SSM); security group (see [Security](#security)). |

### Spoke (terraform/aws/spoke-vpc-eks)

| Resource | Purpose |
|----------|---------|
| **VPC** | `aws_vpc.eks` — CIDR `10.10.0.0/16`. |
| **Subnets** | Public and private, one per AZ; EKS uses both. |
| **Internet Gateway** | Optional (`enable_nat_gateway`); for NAT and ALB. |
| **NAT gateways** | Optional; one per AZ in public subnets for private subnet egress. |
| **Route tables** | Public: hub CIDR → TGW, optional `0.0.0.0/0` → IGW. Private: `10.0.0.0/8` → TGW, optional `0.0.0.0/0` → NAT. |
| **TGW attachment** | Spoke VPC attached to TGW (private subnets). |
| **EKS cluster** | Control plane; API endpoint in public subnets. |
| **EKS node groups** | Worker nodes in private subnets; explicit node SG + cluster SG. |
| **VPC endpoints** | ECR, S3, STS, Secrets Manager (private DNS); reduce NAT dependency. |
| **Bootstrap node** (optional) | EC2 in private subnet for one-off tasks; SSM-only access. |

### Managed services (terraform/aws/managed-services)

RDS, ElastiCache (Redis), and Amazon MQ live **in the same spoke VPC** (EKS VPC), in the same private subnets used by EKS. They are not in a separate VPC.

| Resource | Purpose |
|----------|---------|
| **RDS** | PostgreSQL in EKS VPC private subnets; SG allows ingress from EKS node (and cluster) SG. |
| **ElastiCache** | Redis in EKS VPC; SG allows ingress from same EKS SGs. |
| **Amazon MQ** | RabbitMQ in EKS VPC; SG allows AMQP from same EKS SGs. |

---

## How they connect

1. **Transit Gateway** — Created in the hub; hub and spoke each have one VPC attachment to it.
2. **Hub → Spoke (bastion to EKS):**  
   Bastion (hub public) → hub public route (spoke CIDR via TGW) → TGW → spoke attachment → EKS API (in spoke public subnets). Return: EKS endpoint → spoke public route (hub CIDR via TGW) → TGW → hub.
3. **Spoke → Hub / private:**  
   EKS nodes or pods (spoke private) → private route (`10.0.0.0/8` or hub CIDR via TGW) → TGW → hub. Used for reaching hub or other private IPs.
4. **Spoke → RDS/Redis/MQ:**  
   Same VPC; no TGW. EKS nodes (and pods, which use node SG) have security group rules allowing them to reach RDS (5432), Redis (6379), and MQ (AMQP). Managed services SGs allow ingress only from EKS cluster + node SGs.
5. **Spoke → Internet:**  
   Private subnet → NAT in same AZ → IGW (when NAT is enabled). VPC endpoints allow ECR/S3/STS/Secrets Manager without NAT.

---

## Security

### Network and access control

| Where | Control | Purpose |
|-------|---------|---------|
| **Bastion** | Security group: **ingress** 22 (SSH) from `authorized_ssh_cidrs` only; **egress** 443 (HTTPS) and 53 (DNS) to `0.0.0.0/0`. | Limit who can SSH; only HTTPS/DNS out (e.g. EKS API, SSM). |
| **Bastion** | IAM role with EKS describe, SSM (StartSession, etc.), EC2 describe; SSM Managed Instance Core. | No long-lived keys; SSM for session access. |
| **Bastion** | IMDSv2 required; root volume encrypted. | Hardening and encryption at rest. |
| **EKS API** | Cluster security group: **ingress** 443 from (1) EKS node SG, (2) hub VPC CIDR. | Only nodes and bastion (hub) can reach the API. |
| **EKS nodes** | Node SG: **egress** all; no ingress from internet. Ingress only from cluster SG and other cluster traffic. | Nodes can pull images and talk to control plane; no direct internet ingress. |
| **RDS / Redis / MQ** | Each has an SG allowing **ingress** only from EKS cluster SG + node SG (and any optional extra SGs). | Only EKS workloads can reach DB, cache, and queue. |
| **VPC endpoints** | Endpoint SG allows **ingress** HTTPS from EKS node SG only. | Only nodes use endpoints; no exposure to rest of VPC. |
| **Bootstrap node** | SG: **egress** only; no SSH. Access via SSM only (private, no open 22). | One-off tasks without opening SSH. |

### Summary

- **Ingress to bastion:** SSH only from authorized IPs.
- **Ingress to EKS API:** Only from EKS nodes and from hub VPC (bastion).
- **Ingress to data plane:** RDS/Redis/MQ only from EKS SGs; no 0.0.0.0/0.
- **Egress:** Bastion and nodes are constrained by SGs and IAM; no centralized egress inspection in this design.

---

## FinOps

### Purpose and why

FinOps (financial operations) in this repo is about **visibility, allocation, and guardrails** for cloud spend:

- **Visibility** — Know what you spend and where (by environment, module, cost-center).
- **Allocation** — Attribute cost to teams/projects via tags so you can charge back or optimize.
- **Guardrails** — Budgets and alerts so overspend is caught early, not at invoice time.

It does **not** provision application or network resources; it configures billing, budgets, cost allocation, and (optionally) anomaly detection so cost is predictable and traceable.

### What it does

There are **three** FinOps-related pieces:

| Piece | Location | What it does |
|-------|----------|--------------|
| **AWS FinOps** | `terraform/aws/finops` | **Cost allocation tags** — Marks tag keys (e.g. `environment`, `project`, `cost-center`, `module`) as cost-allocation tags in Cost Explorer so spend can be broken down by tag. **Budgets** — Monthly cost budgets for dev and prod, filtered by `environment` tag; email when threshold (e.g. 80%) is hit. **Cost Anomaly Detection** (optional) — Monitor by service; email when anomaly is detected. **Billing alarm** — SNS topic + CloudWatch alarm on account `EstimatedCharges` (us-east-1); email when spend exceeds a USD threshold. **CloudWatch dashboard** — Single widget for EstimatedCharges. |
| **Azure FinOps** | `terraform/azure/finops` | **Azure Policy** — Audits resource groups missing required tags (`environment`, `project`, `team`, `cost-center`, `owner`, `managed-by`). **Budgets** — Monthly consumption budgets per resource group (dev/prod) with threshold notifications. **Action Group** — Email receiver for budget alerts. **Cost Management export** — Daily export of cost data to a storage account (e.g. CSV) for analysis by tag. |
| **FinOps report module** | `terraform/finops` | **Report-only** — No cloud resources. Reads **remote state** from hub, spoke, bastion, managed-services (AWS and optionally Azure) and outputs: static estimated cost per module, aggregated outputs from those modules, tagging notes, and where budget variables are defined. Use it to get a single view of “what’s deployed and what we expect it to cost” without calling each stack. |

### How it connects

- **Tags** — Hub, spoke (EKS), bastion, and managed-services all set **the same tag set** in their `common_tags`: `project`, `environment`, `team`, `cost-center`, `owner`, `managed-by`, `module`. FinOps **consumes** those tags: AWS budgets filter by `environment`; AWS cost allocation uses those keys; Azure Policy checks for them on resource groups; Azure budgets and cost export use them for reporting. No direct Terraform dependency: infra modules don’t reference FinOps; FinOps (and the report module) reference infra only via **remote state** or billing APIs.
- **Deploy order** — In `spinup.sh`, **FinOps is applied last** (step 5). That way all tagged resources (hub, EKS, managed-services, bastion) already exist; Cost Explorer can see the tags; budgets and anomaly detection run against real usage. The **report module** (`terraform/finops`) is optional and is not applied by spinup; you run it when you want a consolidated view and pass it the same state bucket/keys (and workspace for spoke) so it can read every other stack’s state.
- **No reverse dependency** — Nothing in hub, spoke, bastion, or managed-services depends on FinOps. FinOps only reads (state or billing) and writes (budgets, alarms, policies, exports). You can deploy or change FinOps without touching app or network code.

### Summary

| Aspect | Detail |
|--------|--------|
| **Purpose** | Visibility, cost allocation by tag, and spend guardrails (budgets + alerts). |
| **AWS** | Cost allocation tags, dev/prod budgets by `environment`, optional anomaly detection, SNS + CloudWatch billing alarm, cost dashboard. |
| **Azure** | Tag audit policy, dev/prod budgets per RG, action group, cost export to storage. |
| **Report module** | Read-only; remote state from all stacks → estimated cost per module + outputs + tagging/budget notes. |
| **Connection** | Same tags applied everywhere; FinOps uses tags and state; applied after infra; no dependency from infra to FinOps. |
