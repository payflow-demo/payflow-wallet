# EKS access for bastion — runs after spoke-vpc-eks so the role exists
# Reads cluster name from EKS remote state when tfstate_bucket is set (e.g. via spinup).
# When tfstate_bucket is empty (e.g. manual import), remote state is skipped so import works.

variable "tfstate_bucket" {
  description = "S3 bucket used for Terraform state (same bucket as spoke-vpc-eks). Required for EKS access entry; leave empty only for standalone import."
  type        = string
  default     = ""
}

data "terraform_remote_state" "eks" {
  count   = var.tfstate_bucket != "" ? 1 : 0
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = "env:/${terraform.workspace}/aws/eks/terraform.tfstate"
    region = var.aws_region
  }
}

resource "aws_eks_access_entry" "bastion" {
  count          = var.tfstate_bucket != "" ? 1 : 0
  cluster_name   = data.terraform_remote_state.eks[0].outputs.cluster_name
  principal_arn  = aws_iam_role.bastion.arn
  type           = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion_admin" {
  count          = var.tfstate_bucket != "" ? 1 : 0
  cluster_name   = data.terraform_remote_state.eks[0].outputs.cluster_name
  principal_arn  = aws_eks_access_entry.bastion[0].principal_arn
  policy_arn     = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.bastion]
}
