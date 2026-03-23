# Azure Bastion Host - Secure Access to AKS
# Access AKS cluster via this bastion host

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

# Data source for Hub VNet
data "azurerm_virtual_network" "hub" {
  name                = var.hub_vnet_name
  resource_group_name = var.hub_resource_group_name
}

# Data source for Hub public subnet
data "azurerm_subnet" "hub_public" {
  name                 = "hub-public-subnet"
  virtual_network_name = data.azurerm_virtual_network.hub.name
  resource_group_name  = var.hub_resource_group_name
}

# Network Security Group for Bastion
resource "azurerm_network_security_group" "bastion" {
  name                = "${var.project_name}-bastion-nsg"
  location            = data.azurerm_virtual_network.hub.location
  resource_group_name = var.hub_resource_group_name

  # Allow SSH from authorized IPs
  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.authorized_ssh_cidrs
    destination_address_prefix = "*"
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
    source_address_prefixes    = var.authorized_ssh_cidrs
    destination_address_prefix = "*"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Associate NSG with subnet
resource "azurerm_subnet_network_security_group_association" "bastion" {
  subnet_id                 = data.azurerm_subnet.hub_public.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

# Public IP for Bastion
resource "azurerm_public_ip" "bastion" {
  name                = "${var.project_name}-bastion-pip"
  location            = data.azurerm_virtual_network.hub.location
  resource_group_name = var.hub_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Network Interface for Bastion
resource "azurerm_network_interface" "bastion" {
  name                = "${var.project_name}-bastion-nic"
  location            = data.azurerm_virtual_network.hub.location
  resource_group_name = var.hub_resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.hub_public.id
    private_ip_address_allocation  = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion.id
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Bastion Virtual Machine
resource "azurerm_linux_virtual_machine" "bastion" {
  name                = "${var.project_name}-bastion-vm"
  location            = data.azurerm_virtual_network.hub.location
  resource_group_name = var.hub_resource_group_name
  size                = var.bastion_vm_size
  admin_username      = var.bastion_admin_username

  network_interface_ids = [
    azurerm_network_interface.bastion.id,
  ]

  admin_ssh_key {
    username   = var.bastion_admin_username
    public_key = var.bastion_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Install Azure CLI and kubectl
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y curl apt-transport-https ca-certificates gnupg lsb-release
    
    # Install Azure CLI
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash
    
    # Install kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
    
    # Install Helm
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  EOF
  )

  tags = {
    Environment = var.environment
    Project     = var.project_name
    Role        = "bastion"
  }
}

