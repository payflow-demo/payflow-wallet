variable "azure_region" {
  description = "Azure region for FinOps resources"
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name_dev" {
  description = "Name of the dev resource group to apply budgets/policies to"
  type        = string
}

variable "resource_group_name_prod" {
  description = "Name of the prod resource group to apply budgets/policies to"
  type        = string
}

variable "cost_center" {
  description = "Cost center code for all resources (e.g. ENG-001)"
  type        = string
}

variable "team" {
  description = "Owning engineering team for all resources"
  type        = string
}

variable "owner" {
  description = "Primary owner (person or team) for all resources"
  type        = string
}

variable "budget_alert_email" {
  description = "Email address for Azure budget and cost alerts"
  type        = string
}

variable "monthly_budget_dev" {
  description = "Monthly Azure budget for dev environment (USD)"
  type        = number
  default     = 200
}

variable "monthly_budget_prod" {
  description = "Monthly Azure budget for prod environment (USD)"
  type        = number
  default     = 1000
}

variable "budget_alert_threshold_percent" {
  description = "Percentage of monthly budget at which to trigger alerts"
  type        = number
  default     = 80
}

variable "cost_export_storage_account_id" {
  description = "Resource ID of the storage account to receive Azure cost exports"
  type        = string
}

