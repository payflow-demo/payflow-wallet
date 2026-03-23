# Terraform Backend Configuration for Azure
# This file configures where Terraform stores its state
# 
# IMPORTANT: Create Azure Storage Account and Container FIRST
# Then update the storage_account_name and container_name below

# Backend only; required_providers live in main.tf (one block per module)
terraform {
  backend "azurerm" {
    # State files are automatically separated by workspace:
    # - env:/dev/azure/aks/terraform.tfstate
    # - env:/prod/azure/aks/terraform.tfstate
    resource_group_name  = "payflow-tfstate-rg"      # Resource group for storage account
    storage_account_name = "payflowtfstate5c1c3f34"    # Replace ACCOUNT; run bootstrap first
    container_name       = "tfstate"                  # Container name for state files
    key                  = "azure/aks/terraform.tfstate"  # Workspace prefix added automatically
  }
}

