# Azure Database for PostgreSQL Flexible Server

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

# Get existing Resource Group (created by AKS deployment)
data "azurerm_resource_group" "payflow" {
  name = var.resource_group_name
}

# Virtual Network (created by AKS deployment)
data "azurerm_virtual_network" "aks" {
  name                = var.vnet_name
  resource_group_name = data.azurerm_resource_group.payflow.name
}

# Subnet for PostgreSQL
resource "azurerm_subnet" "postgres" {
  name                 = "postgres-subnet"
  resource_group_name  = data.azurerm_resource_group.payflow.name
  virtual_network_name = data.azurerm_virtual_network.aks.name
  address_prefixes     = [var.postgres_subnet_cidr]
  service_endpoints   = ["Microsoft.Storage"]
  delegation {
    name = "postgres-delegation"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "payflow" {
  name                   = "payflow-postgres-${var.environment}"
  resource_group_name    = data.azurerm_resource_group.payflow.name
  location               = data.azurerm_resource_group.payflow.location
  version                = var.postgres_version
  delegated_subnet_id    = azurerm_subnet.postgres.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgres.id
  administrator_login    = var.db_username
  administrator_password = var.db_password # In production, use Azure Key Vault

  # SKU Configuration
  sku_name = var.postgres_sku_name

  # Storage Configuration
  storage_mb = var.storage_mb
  backup_retention_days = var.backup_retention_days

  # High Availability
  high_availability {
    mode                      = var.high_availability_mode
    standby_availability_zone = var.standby_availability_zone
  }

  # Maintenance
  maintenance_window {
    day_of_week  = 0 # Monday
    start_hour   = 3
    start_minute = 0
  }

  # Authentication
  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled        = true
  }

  # Note: SSL is always enabled on Flexible Server
  # Logging is configured via Azure Monitor

  # Lifecycle to prevent accidental destruction
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      tags,
      administrator_password,  # Don't recreate if password changes (use Azure Key Vault)
    ]
  }

  depends_on = [
    azurerm_subnet.postgres,
    azurerm_private_dns_zone.postgres,
  ]

  tags = {
    Name        = "payflow-postgres"
    Environment = var.environment
  }
}

# Private DNS Zone for PostgreSQL
resource "azurerm_private_dns_zone" "postgres" {
  name                = "payflow.postgres.database.azure.com"
  resource_group_name = data.azurerm_resource_group.payflow.name
}

# Link Private DNS Zone to VNet
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-dns-link"
  resource_group_name   = data.azurerm_resource_group.payflow.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = data.azurerm_virtual_network.aks.id
}

# Database
resource "azurerm_postgresql_flexible_server_database" "payflow" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.payflow.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

