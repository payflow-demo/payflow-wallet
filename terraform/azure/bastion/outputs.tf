output "bastion_public_ip" {
  description = "Public IP address of the Bastion host"
  value       = azurerm_public_ip.bastion.ip_address
}

output "bastion_ssh_command" {
  description = "SSH command to connect to Bastion"
  value       = "ssh ${var.bastion_admin_username}@${azurerm_public_ip.bastion.ip_address}"
}

