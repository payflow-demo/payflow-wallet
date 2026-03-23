# Hub VNet - Centralized Network Services
# This VNet contains shared services like Bastion, VPN Gateway, and VNet Gateway

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

# Resource Group
resource "azurerm_resource_group" "hub" {
  name     = "${var.project_name}-hub-rg"
  location = var.azure_region

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Hub Virtual Network
resource "azurerm_virtual_network" "hub" {
  name                = "${var.project_name}-hub-vnet"
  address_space       = [var.hub_vnet_cidr]
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Public Subnet for Bastion
resource "azurerm_subnet" "hub_public" {
  name                 = "hub-public-subnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_public_subnet_cidr]
}

# Private Subnet for Gateway
resource "azurerm_subnet" "hub_gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_gateway_subnet_cidr]
}

# Public IP for Bastion
resource "azurerm_public_ip" "bastion" {
  name                = "${var.project_name}-bastion-pip"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Network Security Group for Public Subnet
resource "azurerm_network_security_group" "hub_public" {
  name                = "${var.project_name}-hub-public-nsg"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  # Allow SSH from authorized IPs
  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes     = var.authorized_ssh_cidrs
    destination_address_prefix  = "*"
  }

  # Allow HTTPS for kubectl
  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefixes     = var.authorized_ssh_cidrs
    destination_address_prefix  = "*"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Associate NSG with Public Subnet
resource "azurerm_subnet_network_security_group_association" "hub_public" {
  subnet_id                 = azurerm_subnet.hub_public.id
  network_security_group_id = azurerm_network_security_group.hub_public.id
}

# Virtual Network Gateway (for VPN connectivity)
resource "azurerm_public_ip" "gateway" {
  name                = "${var.project_name}-gateway-pip"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "azurerm_virtual_network_gateway" "hub" {
  name                = "${var.project_name}-hub-gateway"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  type     = "Vpn"
  vpn_type = "RouteBased"

  active_active = false
  enable_bgp    = false
  sku           = var.vpn_gateway_sku

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.gateway.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.hub_gateway.id
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

