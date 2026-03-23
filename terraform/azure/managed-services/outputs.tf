# PostgreSQL Outputs
output "postgres_fqdn" {
  description = "PostgreSQL fully qualified domain name"
  value       = azurerm_postgresql_flexible_server.payflow.fqdn
}

output "postgres_host" {
  description = "PostgreSQL host"
  value       = azurerm_postgresql_flexible_server.payflow.fqdn
}

output "postgres_port" {
  description = "PostgreSQL port"
  value       = 5432
}

# Redis Outputs
output "redis_hostname" {
  description = "Redis hostname"
  value       = azurerm_redis_cache.payflow.hostname
}

output "redis_port" {
  description = "Redis port"
  value       = azurerm_redis_cache.payflow.port
}

output "redis_ssl_port" {
  description = "Redis SSL port"
  value       = azurerm_redis_cache.payflow.ssl_port
}

# Service Bus Outputs
output "servicebus_namespace" {
  description = "Service Bus namespace"
  value       = azurerm_servicebus_namespace.payflow.name
}

output "servicebus_connection_string" {
  description = "Service Bus connection string"
  value       = azurerm_servicebus_namespace_authorization_rule.payflow.primary_connection_string
  sensitive   = true
}

output "transaction_queue_name" {
  description = "Transaction queue name"
  value       = azurerm_servicebus_queue.transactions.name
}

output "notification_queue_name" {
  description = "Notification queue name"
  value       = azurerm_servicebus_queue.notifications.name
}

