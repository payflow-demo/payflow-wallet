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

variable "hub_vnet_name" {
  description = "Name of the Hub VNet"
  type        = string
}

variable "hub_resource_group_name" {
  description = "Name of the Hub resource group"
  type        = string
}

variable "authorized_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH to Bastion"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict in production
}

variable "bastion_vm_size" {
  description = "VM size for Bastion host"
  type        = string
  default     = "Standard_B1s" # 1 vCPU, 1GB RAM - sufficient for kubectl access
}

variable "bastion_admin_username" {
  description = "Admin username for Bastion VM"
  type        = string
  default     = "azureuser"
}

variable "bastion_ssh_public_key" {
  description = "SSH public key for Bastion VM"
  type        = string
  sensitive   = true
}

