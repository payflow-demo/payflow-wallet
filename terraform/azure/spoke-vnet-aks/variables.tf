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

variable "hub_vnet_name" {
  description = "Name of the Hub VNet"
  type        = string
}

variable "hub_resource_group_name" {
  description = "Name of the Hub resource group"
  type        = string
}

variable "aks_vnet_cidr" {
  description = "CIDR block for AKS VNet"
  type        = string
  default     = "10.20.0.0/16"
}

variable "aks_system_subnet_cidr" {
  description = "CIDR block for AKS system subnet"
  type        = string
  default     = "10.20.1.0/24"
}

variable "aks_user_subnet_cidr" {
  description = "CIDR block for AKS user subnet (for application pods)"
  type        = string
  default     = "10.20.2.0/24"
}

variable "enable_user_subnet" {
  description = "Enable separate subnet for user workloads"
  type        = bool
  default     = false
}

variable "kubernetes_version" {
  description = "Kubernetes version for AKS"
  type        = string
  default     = "1.28" # Update to latest stable
}

variable "aks_service_cidr" {
  description = "CIDR for Kubernetes services"
  type        = string
  default     = "10.20.10.0/24"
}

variable "aks_dns_service_ip" {
  description = "IP address for Kubernetes DNS service"
  type        = string
  default     = "10.20.10.10"
}

# System Node Pool Configuration
variable "system_node_count" {
  description = "Initial number of system nodes"
  type        = number
  default     = 1
}

variable "system_node_min_count" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 3
}

variable "system_node_vm_size" {
  description = "VM size for system nodes"
  type        = string
  default     = "Standard_B2s" # 2 vCPU, 4GB RAM
}

# User Node Pool Configuration
variable "enable_user_node_pool" {
  description = "Enable separate node pool for user workloads"
  type        = bool
  default     = true
}

variable "user_node_count" {
  description = "Initial number of user nodes"
  type        = number
  default     = 2
}

variable "user_node_min_count" {
  description = "Minimum number of user nodes"
  type        = number
  default     = 2
}

variable "user_node_max_count" {
  description = "Maximum number of user nodes"
  type        = number
  default     = 10
}

variable "user_node_vm_size" {
  description = "VM size for user nodes"
  type        = string
  default     = "Standard_B2s" # 2 vCPU, 4GB RAM
}

variable "user_node_taints" {
  description = "Taints for user node pool"
  type        = list(string)
  default     = []
}

# Spot Instances
variable "use_spot_instances" {
  description = "Use spot instances for cost savings"
  type        = bool
  default     = true
}

variable "spot_max_price" {
  description = "Maximum price for spot instances (null = on-demand price)"
  type        = number
  default     = null
}

# Security
variable "enable_private_cluster" {
  description = "Enable private AKS cluster (API server not accessible from internet)"
  type        = bool
  default     = true
}

variable "api_server_authorized_ip_ranges" {
  description = "IP ranges authorized to access API server (if not private)"
  type        = list(string)
  default     = []
}

variable "aks_admin_group_ids" {
  description = "Azure AD group IDs with admin access to AKS"
  type        = list(string)
  default     = []
}

