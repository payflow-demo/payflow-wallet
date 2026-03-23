variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "hub_vpc_cidr" {
  description = "CIDR block for Hub VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "hub_public_subnet_cidr" {
  description = "CIDR block for Hub public subnet (Bastion)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "hub_private_subnet_cidr" {
  description = "CIDR block for Hub private subnet (Shared Services)"
  type        = string
  default     = "10.0.10.0/24"
}

variable "spoke_vpc_cidr" {
  description = "CIDR block for Spoke VPC (EKS VPC) - used for routing from bastion"
  type        = string
  default     = "10.10.0.0/16"
}

