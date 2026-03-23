variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "hub_tfstate_bucket" {
  description = "S3 bucket for Terraform state. If set (same as Hub module), Hub VPC/TGW/route table are read from state instead of by tag. Use same workspace as Hub."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "eks_vpc_cidr" {
  description = "CIDR block for EKS VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "hub_vpc_cidr" {
  description = "CIDR block for Hub VPC (bastion). EKS API allows 443 from this so bastion can run kubectl."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for EKS subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "payflow-eks-cluster"
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for outbound internet (costs ~$32/month)"
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS. EKS supports one minor version upgrade at a time (e.g. 1.30 → 1.31). Use 1.31 for new clusters."
  type        = string
  default     = "1.31"
}

variable "manage_aws_auth_configmap" {
  description = "Deprecated: aws-auth is applied by bootstrap-node user_data. Ignored."
  type        = bool
  default     = true
}

variable "admin_iam_users" {
  description = "List of IAM usernames with admin access to the cluster"
  type        = list(string)
  default     = []
}

variable "domain_name" {
  description = "Domain name for External DNS (e.g., example.com)"
  type        = string
  default     = ""
}

variable "enable_external_dns" {
  description = "Enable External DNS for Route 53 management"
  type        = bool
  default     = false
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "payflow"
}

variable "db_name" {
  description = "RDS database name (used in Secrets Manager secret for app connection)"
  type        = string
  default     = "payflow"
}

# Secrets Manager Variables
variable "db_username" {
  description = "RDS database username"
  type        = string
  default     = "payflow"
  sensitive   = true
}

variable "db_password" {
  description = "RDS database password (stored in Secrets Manager, not state)"
  type        = string
  sensitive   = true
}

variable "mq_username" {
  description = "Amazon MQ username"
  type        = string
  default     = "payflow"
  sensitive   = true
}

variable "mq_password" {
  description = "Amazon MQ password (stored in Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT secret key for application (stored in Secrets Manager)"
  type        = string
  sensitive   = true
}

# FinOps / tagging variables
variable "cost_center" {
  description = "Cost center code for all resources (e.g. ENG-001)"
  type        = string
  default     = "ENG-001"
}

variable "team" {
  description = "Owning engineering team for all resources"
  type        = string
  default     = "engineering"
}

variable "owner" {
  description = "Primary owner (person or team) for all resources"
  type        = string
  default     = "engineering"
}
