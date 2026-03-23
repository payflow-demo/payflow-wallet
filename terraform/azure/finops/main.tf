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

locals {
  common_tags = {
    project       = "payflow"
    environment   = var.environment
    team          = var.team
    owner         = var.owner
    "cost-center" = var.cost_center
    "managed-by"  = "terraform"
    module        = "azure-finops"
  }
}

# ---------------------------------------------------------------------------
# Azure Policy: enforce required tags on resource groups
# ---------------------------------------------------------------------------

resource "azurerm_policy_definition" "required_tags_rg" {
  name         = "payflow-required-tags-rg"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "PayFlow - Required tags on resource groups"

  metadata = jsonencode({
    category = "Cost Management"
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field = "type"
          equals = "Microsoft.Resources/subscriptions/resourceGroups"
        },
        {
          anyOf = [
            { field = "tags['environment']", equals = "" },
            { field = "tags['project']",     equals = "" },
            { field = "tags['team']",        equals = "" },
            { field = "tags['cost-center']", equals = "" },
            { field = "tags['owner']",       equals = "" },
            { field = "tags['managed-by']",  equals = "" }
          ]
        }
      ]
    }
    then = {
      effect = "audit"
    }
  })
}

resource "azurerm_policy_assignment" "required_tags_rg_dev" {
  name                 = "payflow-required-tags-rg-dev"
  display_name         = "PayFlow - Required tags on dev RG"
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name_dev}"
  policy_definition_id = azurerm_policy_definition.required_tags_rg.id
}

resource "azurerm_policy_assignment" "required_tags_rg_prod" {
  name                 = "payflow-required-tags-rg-prod"
  display_name         = "PayFlow - Required tags on prod RG"
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name_prod}"
  policy_definition_id = azurerm_policy_definition.required_tags_rg.id
}

# ---------------------------------------------------------------------------
# Azure Monitor Action Group for budget notifications
# ---------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "finops" {
  name                = "payflow-finops-action-group"
  resource_group_name = var.resource_group_name_prod
  short_name          = "pf-finops"

  email_receiver {
    name                    = "finops-email"
    email_address           = var.budget_alert_email
    use_common_alert_schema = true
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Azure Budgets per resource group (dev and prod)
# ---------------------------------------------------------------------------

resource "azurerm_consumption_budget_resource_group" "dev" {
  name              = "payflow-dev-monthly-budget"
  resource_group_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name_dev}"

  amount     = var.monthly_budget_dev
  time_grain = "Monthly"

  time_period {
    start_date = "2024-01-01T00:00:00Z"
    end_date   = "2030-01-01T00:00:00Z"
  }

  filter {
    tag {
      name = "environment"
      values = ["dev"]
    }
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = var.budget_alert_threshold_percent
    threshold_type = "Percentage"

    contact_emails = [var.budget_alert_email]
    contact_groups = [azurerm_monitor_action_group.finops.id]
  }
}

resource "azurerm_consumption_budget_resource_group" "prod" {
  name              = "payflow-prod-monthly-budget"
  resource_group_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name_prod}"

  amount     = var.monthly_budget_prod
  time_grain = "Monthly"

  time_period {
    start_date = "2024-01-01T00:00:00Z"
    end_date   = "2030-01-01T00:00:00Z"
  }

  filter {
    tag {
      name = "environment"
      values = ["prod"]
    }
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = var.budget_alert_threshold_percent
    threshold_type = "Percentage"

    contact_emails = [var.budget_alert_email]
    contact_groups = [azurerm_monitor_action_group.finops.id]
  }
}

# ---------------------------------------------------------------------------
# Azure Cost Management Export
# ---------------------------------------------------------------------------

resource "azurerm_cost_management_export" "tagged_costs" {
  name                = "payflow-tagged-costs"
  scope               = "/subscriptions/${var.subscription_id}"
  recurrence_type     = "Daily"
  recurrence_period_start = "2024-01-01T00:00:00Z"
  recurrence_period_end   = "2030-01-01T00:00:00Z"
  format              = "Csv"
  time_period        = "TheLastMonth"

  storage_location {
    container_id = "${var.cost_export_storage_account_id}/blobServices/default/containers/cost-exports"
    root_folder_path = "payflow"
  }
}

