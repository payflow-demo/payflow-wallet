# Azure Service Bus (Alternative to RabbitMQ)

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

# Service Bus Namespace
resource "azurerm_servicebus_namespace" "payflow" {
  name                = "payflow-sb-${var.environment}"
  location            = data.azurerm_resource_group.payflow.location
  resource_group_name = data.azurerm_resource_group.payflow.name
  sku                 = var.servicebus_sku

  # Network Configuration
  public_network_access_enabled = false

  # Minimum TLS Version
  minimum_tls_version = "1.2"

  # Capacity (for Premium SKU)
  capacity = var.servicebus_capacity

  tags = {
    Name        = "payflow-servicebus"
    Environment = var.environment
  }
}

# Private Endpoint for Service Bus
resource "azurerm_private_endpoint" "servicebus" {
  name                = "payflow-sb-endpoint"
  location            = data.azurerm_resource_group.payflow.location
  resource_group_name = data.azurerm_resource_group.payflow.name
  subnet_id           = var.servicebus_subnet_id

  private_service_connection {
    name                           = "payflow-sb-connection"
    private_connection_resource_id = azurerm_servicebus_namespace.payflow.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }
}

# Service Bus Queue (for transaction processing)
resource "azurerm_servicebus_queue" "transactions" {
  name         = "transaction-queue"
  namespace_id = azurerm_servicebus_namespace.payflow.id

  # Queue Configuration
  max_delivery_count                = 10
  dead_lettering_on_message_expiration = true
  lock_duration                     = "PT30S"
  max_size_in_megabytes             = 1024
  requires_duplicate_detection      = true
  duplicate_detection_history_time_window = "PT10M"
  requires_session                 = false
  default_message_ttl               = "P1D"
  # Note: enable_batched_operations and enable_partitioning are not available in Basic SKU
}

# Service Bus Queue (for notifications)
resource "azurerm_servicebus_queue" "notifications" {
  name         = "notification-queue"
  namespace_id = azurerm_servicebus_namespace.payflow.id

  max_delivery_count                = 10
  dead_lettering_on_message_expiration = true
  lock_duration                     = "PT30S"
  max_size_in_megabytes             = 1024
  requires_duplicate_detection      = true
  duplicate_detection_history_time_window = "PT10M"
  requires_session                 = false
  default_message_ttl               = "P1D"
  # Note: enable_batched_operations and enable_partitioning are not available in Basic SKU
}

# Shared Access Policy (for applications)
resource "azurerm_servicebus_namespace_authorization_rule" "payflow" {
  name         = "payflow-send-listen"
  namespace_id = azurerm_servicebus_namespace.payflow.id

  listen = true
  send   = true
  manage = false
}

