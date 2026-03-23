variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "payflow"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "azure_region" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "hub_vnet_cidr" {
  description = "CIDR block for Hub VNet"
  type        = string
  default     = "10.1.0.0/16"
}

variable "hub_public_subnet_cidr" {
  description = "CIDR block for Hub public subnet (Bastion)"
  type        = string
  default     = "10.1.1.0/24"
}

variable "hub_gateway_subnet_cidr" {
  description = "CIDR block for Gateway subnet"
  type        = string
  default     = "10.1.2.0/24"
}

variable "authorized_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH to Bastion"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict in production
}

variable "vpn_gateway_sku" {
  description = "SKU for VPN Gateway (Basic, VpnGw1, VpnGw2, etc.)"
  type        = string
  default     = "Basic" # Use VpnGw1 or higher for production
}

