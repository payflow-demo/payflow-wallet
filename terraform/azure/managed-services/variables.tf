variable "azure_region" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "resource_group_name" {
  description = "Resource group name (created by AKS deployment)"
  type        = string
  default     = "payflow-rg"
}

variable "vnet_name" {
  description = "Virtual network name (created by AKS deployment)"
  type        = string
  default     = "payflow-aks-vnet"
}

# PostgreSQL Variables
variable "postgres_version" {
  description = "PostgreSQL version"
  type        = string
  default     = "16"
}

variable "postgres_sku_name" {
  description = "PostgreSQL SKU (e.g., B_Standard_B1ms, GP_Standard_D2s_v3)"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_subnet_cidr" {
  description = "CIDR for PostgreSQL subnet"
  type        = string
  default     = "10.20.10.0/24"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "payflow"
}

variable "db_username" {
  description = "Database administrator username"
  type        = string
  default     = "payflow"
}

variable "db_password" {
  description = "Database administrator password (use Key Vault in production)"
  type        = string
  sensitive   = true
}

variable "storage_mb" {
  description = "Storage size in MB"
  type        = number
  default     = 32768 # 32GB
}

variable "backup_retention_days" {
  description = "Backup retention in days"
  type        = number
  default     = 7
}

variable "high_availability_mode" {
  description = "High availability mode: SameZone or ZoneRedundant"
  type        = string
  default     = "Disabled"
}

variable "standby_availability_zone" {
  description = "Standby availability zone"
  type        = string
  default     = null
}

# Redis Variables
variable "redis_capacity" {
  description = "Redis cache capacity (0, 1, 2, 3, 4, 5, 6)"
  type        = number
  default     = 0 # C0 = 250MB
}

variable "redis_family" {
  description = "Redis family: C or P"
  type        = string
  default     = "C"
}

variable "redis_sku_name" {
  description = "Redis SKU: Basic, Standard, or Premium"
  type        = string
  default     = "Basic"
}

variable "redis_subnet_id" {
  description = "Subnet ID for Redis (optional)"
  type        = string
  default     = null
}

variable "maxmemory_reserved" {
  description = "Max memory reserved in MB"
  type        = number
  default     = 2
}

variable "maxmemory_delta" {
  description = "Max memory delta in MB"
  type        = number
  default     = 2
}

variable "replicas_per_master" {
  description = "Number of replicas per master"
  type        = number
  default     = 0
}

variable "replicas_per_primary" {
  description = "Number of replicas per primary"
  type        = number
  default     = 0
}

variable "aks_subnet_cidr_start" {
  description = "AKS subnet CIDR start (for firewall rule)"
  type        = string
  default     = "10.20.1.0"
}

variable "aks_subnet_cidr_end" {
  description = "AKS subnet CIDR end (for firewall rule)"
  type        = string
  default     = "10.20.1.255"
}

# Service Bus Variables
variable "servicebus_sku" {
  description = "Service Bus SKU: Basic, Standard, or Premium"
  type        = string
  default     = "Basic"
}

variable "servicebus_capacity" {
  description = "Service Bus capacity (for Premium SKU)"
  type        = number
  default     = 1
}

variable "servicebus_subnet_id" {
  description = "Subnet ID for Service Bus private endpoint"
  type        = string
}

