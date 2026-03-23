output "instance_id" {
  description = "Bootstrap instance ID (SSM: aws ssm start-session --target <id>)"
  value       = aws_instance.bootstrap.id
}

output "security_group_id" {
  description = "Bootstrap instance security group ID"
  value       = aws_security_group.bootstrap.id
}
