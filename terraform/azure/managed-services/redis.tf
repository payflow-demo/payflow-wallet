# Azure Cache for Redis

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Get existing Resource Group
data "azurerm_resource_group" "payflow" {
  name = var.resource_group_name
}

# Redis Cache
resource "azurerm_redis_cache" "payflow" {
  name                = "payflow-redis-${var.environment}"
  location            = data.azurerm_resource_group.payflow.location
  resource_group_name = data.azurerm_resource_group.payflow.name
  capacity            = var.redis_capacity
  family              = var.redis_family
  sku_name            = var.redis_sku_name

  # Network Configuration
  subnet_id = var.redis_subnet_id # Optional: deploy in VNet

  # Redis Configuration
  redis_configuration {
    maxmemory_reserved = var.maxmemory_reserved
    maxmemory_delta   = var.maxmemory_delta
    maxmemory_policy  = "allkeys-lru"
  }

  # High Availability
  replicas_per_master = var.replicas_per_master
  replicas_per_primary = var.replicas_per_primary

  # Patch Schedule
  patch_schedule {
    day_of_week    = "Monday"
    start_hour_utc = 3
  }

  # Minimum TLS Version
  minimum_tls_version = "1.2"

  # Public Network Access (disable for security)
  public_network_access_enabled = false
  
  # Note: Non-SSL port is automatically disabled when minimum_tls_version is set

  tags = {
    Name        = "payflow-redis"
    Environment = var.environment
  }
}

# Firewall Rule (allow AKS subnet)
resource "azurerm_redis_firewall_rule" "aks" {
  name                = "allow-aks-subnet"
  redis_cache_name    = azurerm_redis_cache.payflow.name
  resource_group_name = azurerm_resource_group.payflow.name
  start_ip            = var.aks_subnet_cidr_start
  end_ip              = var.aks_subnet_cidr_end
}

