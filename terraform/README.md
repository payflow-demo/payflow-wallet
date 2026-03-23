# Terraform Infrastructure

**Sensitive variables:** Do not commit real credentials. Use `TF_VAR_db_password=...`, `TF_VAR_jwt_secret=...`, etc., or a local `terraform.tfvars` that is gitignored. Copy from `*.tfvars.example` and never commit the filled-in file.

## Structure

```
terraform/
├── bootstrap.sh              # Single script for all setup
├── aws/
│   ├── hub-vpc/              # Hub VPC (Transit Gateway)
│   ├── bastion/              # Bastion host
│   ├── spoke-vpc-eks/        # EKS cluster + VPC
│   └── managed-services/     # RDS, ElastiCache, MQ
└── azure/
    ├── hub-vnet/             # Hub VNet
    ├── bastion/              # Bastion VM
    ├── spoke-vnet-aks/       # AKS cluster + VNet
    └── managed-services/     # PostgreSQL, Redis, Service Bus
```

## Apply Order — Read This First

**You must apply modules in the correct order.** Applying out of order causes cryptic "no subnets found" or "secret not found" errors.

### AWS (EKS)

```
1. hub-vpc          ← Transit VPC (optional for standalone EKS, required for hub-spoke)
2. spoke-vpc-eks    ← VPC + EKS cluster + Secrets Manager placeholders + IRSA roles
3. managed-services ← RDS + ElastiCache + Amazon MQ  (reads VPC/subnets from spoke state)
4. bastion          ← Bastion host for private EKS endpoint access
```

> **Why bastion must come before `kubectl`:**
> The EKS cluster is configured with `endpoint_public_access = false`.
> You cannot run `kubectl` from your local machine until you open an SSH tunnel
> through the bastion: `ssh -L 6443:$EKS_ENDPOINT:443 ec2-user@$BASTION_IP`

### Azure (AKS)

```
1. hub-vnet         ← Hub VNet
2. spoke-vnet-aks   ← VNet + AKS cluster + ACR
3. managed-services ← Azure PostgreSQL + Redis + Service Bus
4. bastion          ← Bastion VM for private AKS access
```

---

## Quick Start

### 1. Bootstrap (One-Time Setup)

```bash
# Bootstrap everything (AWS + Azure + Workspaces)
./bootstrap.sh

# Or bootstrap only AWS
./bootstrap.sh --aws-only

# Or bootstrap only Azure
./bootstrap.sh --azure-only

# Skip workspace creation
./bootstrap.sh --skip-workspaces
```

**What it does:**
- Creates AWS S3 bucket + DynamoDB table
- Creates Azure Storage Account + Container
- Updates backend.tf files automatically
- Creates workspaces (dev, prod) for AWS and Azure

### 2. Deploy AWS (You'll deploy this first)

```bash
cd aws/spoke-vpc-eks

# Initialize
terraform init

# Select workspace
terraform workspace select dev

# Plan
terraform plan

# Apply (use staged deployment from COMPLETE-DEPENDENCY-CHAIN.md)
terraform apply
```

### 3. Deploy Azure (Later)

```bash
cd azure/spoke-vnet-aks

# Initialize
terraform init

# Select workspace
terraform workspace select dev

# Plan
terraform plan

# Apply
terraform apply
```

## Workspaces

**AWS Workspaces:**
- `dev` - Development environment
- `prod` - Production environment

**Azure Workspaces:**
- `dev` - Development environment
- `prod` - Production environment

**State Files:**
- AWS: `env:/<workspace>/aws/eks/terraform.tfstate`
- Azure: `env:/<workspace>/azure/aks/terraform.tfstate`

**Switch Workspaces:**
```bash
# AWS
cd aws/spoke-vpc-eks
terraform workspace select dev
terraform workspace select prod

# Azure
cd azure/spoke-vnet-aks
terraform workspace select dev
terraform workspace select prod
```

## Documentation

- **[INFRASTRUCTURE-ONBOARDING.md](../INFRASTRUCTURE-ONBOARDING.md)** — Ordered checklist (bootstrap → Hub → EKS → managed services → bastion → app)
- **[QUICK-START-INFRA.md](../QUICK-START-INFRA.md)** — Full step-by-step with Terraform targets, verification, troubleshooting
- **README-BOOTSTRAP.md** - Complete bootstrap guide
- **COMPLETE-DEPENDENCY-CHAIN.md** - EKS dependency chain and staged deployment
- **DEPLOYMENT-GUIDE.md** - Deployment best practices
- **ARCHITECTURE.md** - Infrastructure architecture diagram

