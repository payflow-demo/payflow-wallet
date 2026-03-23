# Spoke VNet for AKS Cluster
# This VNet contains the AKS cluster and application workloads

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Resource Group for AKS
resource "azurerm_resource_group" "aks" {
  name     = "${var.project_name}-aks-rg"
  location = var.azure_region

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Data source for Hub VNet
data "azurerm_virtual_network" "hub" {
  name                = var.hub_vnet_name
  resource_group_name  = var.hub_resource_group_name
}

# Spoke VNet for AKS
resource "azurerm_virtual_network" "aks" {
  name                = "${var.project_name}-aks-vnet"
  address_space       = [var.aks_vnet_cidr]
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# System Subnet for AKS (required by AKS)
resource "azurerm_subnet" "aks_system" {
  name                 = "aks-system-subnet"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [var.aks_system_subnet_cidr]

  # AKS requires delegation
  delegation {
    name = "aks-delegation"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# User Subnet for Application Pods (optional, for advanced networking)
resource "azurerm_subnet" "aks_user" {
  count = var.enable_user_subnet ? 1 : 0

  name                 = "aks-user-subnet"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [var.aks_user_subnet_cidr]

  delegation {
    name = "aks-delegation"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Network Security Group for AKS
resource "azurerm_network_security_group" "aks" {
  name                = "${var.project_name}-aks-nsg"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name

  # Allow inbound from Hub VNet
  security_rule {
    name                       = "AllowFromHub"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range      = "*"
    source_address_prefix      = data.azurerm_virtual_network.hub.address_space[0]
    destination_address_prefix = "*"
  }

  # Allow outbound to internet (for pulling images, etc.)
  security_rule {
    name                       = "AllowOutboundInternet"
    priority                   = 1002
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Associate NSG with subnets
resource "azurerm_subnet_network_security_group_association" "aks_system" {
  subnet_id                 = azurerm_subnet.aks_system.id
  network_security_group_id  = azurerm_network_security_group.aks.id
}

resource "azurerm_subnet_network_security_group_association" "aks_user" {
  count = var.enable_user_subnet ? 1 : 0

  subnet_id                 = azurerm_subnet.aks_user[0].id
  network_security_group_id  = azurerm_network_security_group.aks.id
}

# VNet Peering: Hub to Spoke
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "${var.project_name}-hub-to-aks-peering"
  resource_group_name       = var.hub_resource_group_name
  virtual_network_name      = data.azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.aks.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

# VNet Peering: Spoke to Hub
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "${var.project_name}-aks-to-hub-peering"
  resource_group_name       = azurerm_resource_group.aks.name
  virtual_network_name      = azurerm_virtual_network.aks.name
  remote_virtual_network_id = data.azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

