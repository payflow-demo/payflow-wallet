# Fix RDS/Redis/MQ not reachable from EKS (migration job "no response")

The migration pod runs on EKS nodes. Traffic uses the **EKS node security group**, not the cluster SG. RDS/Redis/MQ must allow ingress from that node SG.

## Option A: Spoke state has the output (recommended)

1. **Apply spoke** so state has `eks_node_security_group_id`:
   ```bash
   cd terraform/aws/spoke-vpc-eks
   terraform workspace select default   # or dev, must match managed-services
   terraform apply
   ```

2. **Apply managed-services** (same workspace):
   ```bash
   cd terraform/aws/managed-services
   terraform workspace select default
   terraform apply
   ```
   Plan should show an ingress rule change on RDS/Redis/MQ SGs adding the node SG.

## Option B: Pass node SG manually

If you can’t re-apply spoke or workspaces differ:

1. **Get the EKS node security group ID** (VPC ID from your EKS VPC, e.g. `vpc-04c7b1d5780496879`):
   ```bash
   aws ec2 describe-security-groups \
     --filters "Name=group-name,Values=*nodes-sg*" "Name=vpc-id,Values=vpc-04c7b1d5780496879" \
     --query 'SecurityGroups[0].GroupId' --output text --region us-east-1
   ```

2. **Apply managed-services** with that ID:
   ```bash
   cd terraform/aws/managed-services
   terraform apply -var="eks_node_sg_id=sg-XXXXXXXX"
   ```

## Verify

- In AWS Console: RDS → your DB → VPC security groups → `payflow-rds-sg` → Inbound rules should allow **5432** from both the cluster SG and the node SG (or a rule that includes the node SG).
- Then redeploy: `cd k8s/overlays/eks && IMAGE_TAG=<your-tag> ./deploy.sh`. The deploy script deletes and recreates the migration job, so migration will run again after RDS is reachable.
