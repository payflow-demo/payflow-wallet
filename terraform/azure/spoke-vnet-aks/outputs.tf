output "aks_cluster_id" {
  description = "ID of the AKS cluster"
  value       = azurerm_kubernetes_cluster.aks.id
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.aks.name
}

output "aks_cluster_fqdn" {
  description = "FQDN of the AKS cluster"
  value       = azurerm_kubernetes_cluster.aks.fqdn
}

output "aks_cluster_private_fqdn" {
  description = "Private FQDN of the AKS cluster (if private cluster enabled)"
  value       = azurerm_kubernetes_cluster.aks.private_fqdn
}

output "aks_cluster_kube_config" {
  description = "Kubeconfig for the AKS cluster"
  value       = azurerm_kubernetes_cluster.aks.kube_config_raw
  sensitive   = true
}

output "aks_node_resource_group" {
  description = "Resource group containing AKS node resources"
  value       = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "aks_system_subnet_id" {
  description = "ID of the AKS system subnet"
  value       = azurerm_subnet.aks_system.id
}

output "aks_vnet_id" {
  description = "ID of the AKS VNet"
  value       = azurerm_virtual_network.aks.id
}

output "kubectl_command" {
  description = "Command to configure kubectl from Bastion"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.aks.name} --name ${azurerm_kubernetes_cluster.aks.name}"
}

output "acr_login_server" {
  description = "ACR login server URL (use as image prefix in aks-deploy.sh)"
  value       = azurerm_container_registry.payflow.login_server
}

output "acr_name" {
  description = "ACR name (for az acr build / docker push)"
  value       = azurerm_container_registry.payflow.name
}
