# Kustomize Overlays

Kustomize overlays for deploying PayFlow to AWS EKS and Azure AKS.

## Structure

```
overlays/
├── eks/                 # AWS EKS deployment
│   ├── kustomization.yaml
│   ├── db-config-patch.yaml
│   ├── db-migration-patch.yaml
│   ├── ingress-patch.yaml
│   ├── eks-external-secrets.yaml
│   ├── patches/         # JSON patches (e.g. REDIS_URL from secret)
│   └── deploy.sh        # Automated deployment script
└── aks/                 # Azure AKS deployment
    ├── kustomization.yaml
    ├── db-config-patch.yaml
    ├── db-migration-patch.yaml
    ├── ingress-patch.yaml
    └── aks-external-secrets.yaml
```

## Quick Deploy

**EKS (automated):**
```bash
cd eks
./deploy.sh
```

**AKS:**
```bash
cd aks
kubectl apply -k .
```

## Documentation

For complete deployment instructions, database migrations, and troubleshooting, see:
- **[Deployment Guide](../../docs/DEPLOYMENT.md)** - Full deployment walkthrough
- **[Architecture](../../docs/ARCHITECTURE.md)** - System design and infrastructure
- **[Runbook](../../docs/RUNBOOK.md)** - Debugging and operations

## How It Works

- **Base resources** (`../../base/`) define shared microservice deployments
- **Overlays** patch base resources with cloud-specific configs (RDS endpoints, ECR/ACR images, ingress)
- **Database migrations** run automatically before services start
- **External Secrets** sync from AWS Secrets Manager (EKS) or Azure Key Vault (AKS)
- **EKS:** `REDIS_URL` and `RABBITMQ_URL` come from Secrets Manager via External Secrets; Terraform (managed-services) writes the Redis URL after ElastiCache is created

