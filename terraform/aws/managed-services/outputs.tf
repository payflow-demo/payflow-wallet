# RDS Outputs
output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.payflow.endpoint
}

output "rds_address" {
  description = "RDS PostgreSQL address"
  value       = aws_db_instance.payflow.address
}

output "rds_port" {
  description = "RDS PostgreSQL port"
  value       = aws_db_instance.payflow.port
}

# ElastiCache Outputs
output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = aws_elasticache_replication_group.payflow.configuration_endpoint_address
}

output "redis_port" {
  description = "ElastiCache Redis port"
  value       = aws_elasticache_replication_group.payflow.port
}

# Amazon MQ Outputs (AWS provider 5.x: instances[0].endpoints[0] = AMQP endpoint; SINGLE_INSTANCE has 1 element)
output "mq_amqp_endpoint" {
  description = "Amazon MQ AMQP endpoint"
  value       = aws_mq_broker.payflow.instances[0].endpoints[0]
}

output "mq_management_endpoint" {
  description = "Amazon MQ Management console URL"
  value       = aws_mq_broker.payflow.instances[0].console_url
}

output "mq_username" {
  description = "Amazon MQ username"
  value       = var.rabbitmq_username
  sensitive   = true
}

