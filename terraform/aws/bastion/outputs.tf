output "bastion_instance_id" {
  description = "Bastion instance ID — use for SSM: aws ssm start-session --target <this-id>"
  value       = aws_instance.bastion.id
}

output "bastion_public_ip" {
  description = "Bastion public IP (for SSH if needed)"
  value       = aws_eip.bastion.public_ip
}

output "ssm_connect_command" {
  description = "Run this to connect via SSM (no SSH key required)"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.aws_region}"
}
