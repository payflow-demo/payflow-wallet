terraform {
  required_version = ">= 1.5.0"
}

locals {
  # Placeholder estimated monthly costs per module (USD).
  # Calibrate from actual bills and adjust as needed.
  module_estimated_cost = {
    aws_hub_vpc        = 50
    aws_spoke_vpc_eks  = 200
    aws_bastion        = 20
    aws_managed_svcs   = 400
    azure_hub_vnet     = 40
    azure_spoke_aks    = 180
    azure_bastion      = 25
    azure_managed_svcs = 350
  }
}

variable "aws_state_bucket" {
  description = "S3 bucket used for AWS Terraform remote state (same as existing modules)"
  type        = string
}

variable "aws_state_region" {
  description = "AWS region of the Terraform state bucket"
  type        = string
  default     = "us-east-1"
}

variable "aws_hub_state_key" {
  description = "Object key for hub-vpc Terraform state (e.g. aws/hub-vpc/terraform.tfstate)"
  type        = string
}

variable "aws_spoke_state_key" {
  description = "Object key for spoke-vpc-eks Terraform state"
  type        = string
}

variable "aws_bastion_state_key" {
  description = "Object key for bastion Terraform state"
  type        = string
}

variable "aws_managed_state_key" {
  description = "Object key for managed-services Terraform state"
  type        = string
}

variable "azure_resource_group_name" {
  description = "Resource group name used for Azure hub-vnet state (if using azurerm backend)"
  type        = string
  default     = ""
}

variable "azure_storage_account_name" {
  description = "Storage account name used for Azure Terraform state"
  type        = string
  default     = ""
}

variable "azure_container_name" {
  description = "Blob container name for Azure Terraform state"
  type        = string
  default     = ""
}

variable "azure_hub_blob_key" {
  description = "Blob name for hub-vnet Terraform state"
  type        = string
  default     = ""
}

variable "azure_spoke_blob_key" {
  description = "Blob name for spoke-vnet-aks Terraform state"
  type        = string
  default     = ""
}

variable "azure_bastion_blob_key" {
  description = "Blob name for Azure bastion Terraform state"
  type        = string
  default     = ""
}

variable "azure_managed_blob_key" {
  description = "Blob name for Azure managed-services Terraform state"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Remote state reads (no resources created here)
# ---------------------------------------------------------------------------

data "terraform_remote_state" "aws_hub_vpc" {
  backend = "s3"

  config = {
    bucket = var.aws_state_bucket
    key    = var.aws_hub_state_key
    region = var.aws_state_region
  }
}

data "terraform_remote_state" "aws_spoke_vpc_eks" {
  backend = "s3"

  config = {
    bucket = var.aws_state_bucket
    key    = var.aws_spoke_state_key
    region = var.aws_state_region
  }
}

data "terraform_remote_state" "aws_bastion" {
  backend = "s3"

  config = {
    bucket = var.aws_state_bucket
    key    = var.aws_bastion_state_key
    region = var.aws_state_region
  }
}

data "terraform_remote_state" "aws_managed_services" {
  backend = "s3"

  config = {
    bucket = var.aws_state_bucket
    key    = var.aws_managed_state_key
    region = var.aws_state_region
  }
}

data "terraform_remote_state" "azure_hub_vnet" {
  count   = var.azure_storage_account_name == "" ? 0 : 1
  backend = "azurerm"

  config = {
    resource_group_name  = var.azure_resource_group_name
    storage_account_name = var.azure_storage_account_name
    container_name       = var.azure_container_name
    key                  = var.azure_hub_blob_key
  }
}

data "terraform_remote_state" "azure_spoke_aks" {
  count   = var.azure_storage_account_name == "" ? 0 : 1
  backend = "azurerm"

  config = {
    resource_group_name  = var.azure_resource_group_name
    storage_account_name = var.azure_storage_account_name
    container_name       = var.azure_container_name
    key                  = var.azure_spoke_blob_key
  }
}

data "terraform_remote_state" "azure_bastion" {
  count   = var.azure_storage_account_name == "" ? 0 : 1
  backend = "azurerm"

  config = {
    resource_group_name  = var.azure_resource_group_name
    storage_account_name = var.azure_storage_account_name
    container_name       = var.azure_container_name
    key                  = var.azure_bastion_blob_key
  }
}

data "terraform_remote_state" "azure_managed_services" {
  count   = var.azure_storage_account_name == "" ? 0 : 1
  backend = "azurerm"

  config = {
    resource_group_name  = var.azure_resource_group_name
    storage_account_name = var.azure_storage_account_name
    container_name       = var.azure_container_name
    key                  = var.azure_managed_blob_key
  }
}

# ---------------------------------------------------------------------------
# Outputs: summary only (no resources)
# ---------------------------------------------------------------------------

output "estimated_monthly_cost_per_module" {
  description = "Static estimated monthly cost per module (USD). Calibrate from actual bills."
  value       = local.module_estimated_cost
}

output "aws_hub_vpc_outputs" {
  description = "Selected outputs from aws/hub-vpc module"
  value       = data.terraform_remote_state.aws_hub_vpc.outputs
}

output "aws_spoke_vpc_eks_outputs" {
  description = "Selected outputs from aws/spoke-vpc-eks module"
  value       = data.terraform_remote_state.aws_spoke_vpc_eks.outputs
}

output "aws_bastion_outputs" {
  description = "Selected outputs from aws/bastion module"
  value       = data.terraform_remote_state.aws_bastion.outputs
}

output "aws_managed_services_outputs" {
  description = "Selected outputs from aws/managed-services module"
  value       = data.terraform_remote_state.aws_managed_services.outputs
}

output "azure_hub_vnet_outputs" {
  description = "Selected outputs from azure/hub-vnet module"
  value       = length(data.terraform_remote_state.azure_hub_vnet) == 0 ? {} : data.terraform_remote_state.azure_hub_vnet[0].outputs
}

output "azure_spoke_aks_outputs" {
  description = "Selected outputs from azure/spoke-vnet-aks module"
  value       = length(data.terraform_remote_state.azure_spoke_aks) == 0 ? {} : data.terraform_remote_state.azure_spoke_aks[0].outputs
}

output "azure_bastion_outputs" {
  description = "Selected outputs from azure/bastion module"
  value       = length(data.terraform_remote_state.azure_bastion) == 0 ? {} : data.terraform_remote_state.azure_bastion[0].outputs
}

output "azure_managed_services_outputs" {
  description = "Selected outputs from azure/managed-services module"
  value       = length(data.terraform_remote_state.azure_managed_services) == 0 ? {} : data.terraform_remote_state.azure_managed_services[0].outputs
}

output "tagging_compliance_notes" {
  description = "High-level notes on tagging compliance; detailed enforcement is via AWS Tag Policies and Azure Policy."
  value = {
    aws   = "All core modules use local.common_tags including environment, project, team, cost-center, owner, managed-by, module."
    azure = "Hub, AKS, bastion, and managed-services modules apply mandatory tags; Azure Policy audits missing tags on RGs."
  }
}

output "budget_thresholds" {
  description = "Summarised budget thresholds configured in AWS and Azure FinOps modules"
  value = {
    aws = {
      monthly_budget_dev             = "Use terraform/aws/finops with monthly_budget_dev"
      monthly_budget_prod            = "Use terraform/aws/finops with monthly_budget_prod"
      budget_alert_threshold_percent = "Use terraform/aws/finops with budget_alert_threshold_percent"
    }
    azure = {
      monthly_budget_dev             = "Use terraform/azure/finops with monthly_budget_dev"
      monthly_budget_prod            = "Use terraform/azure/finops with monthly_budget_prod"
      budget_alert_threshold_percent = "Use terraform/azure/finops with budget_alert_threshold_percent"
    }
  }
}

