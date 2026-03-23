output "hub_vnet_id" {
  description = "ID of the Hub VNet"
  value       = azurerm_virtual_network.hub.id
}

output "hub_vnet_name" {
  description = "Name of the Hub VNet"
  value       = azurerm_virtual_network.hub.name
}

output "hub_public_subnet_id" {
  description = "ID of the Hub public subnet"
  value       = azurerm_subnet.hub_public.id
}

output "hub_resource_group_name" {
  description = "Name of the Hub resource group"
  value       = azurerm_resource_group.hub.name
}

output "hub_resource_group_location" {
  description = "Location of the Hub resource group"
  value       = azurerm_resource_group.hub.location
}

output "gateway_public_ip" {
  description = "Public IP of the Virtual Network Gateway"
  value       = azurerm_public_ip.gateway.ip_address
}

