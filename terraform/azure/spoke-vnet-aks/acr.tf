# Azure Container Registry — image repository for AKS

resource "azurerm_resource_group" "acr" {
  name     = "${var.project_name}-acr-rg"
  location = var.azure_region

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "azurerm_container_registry" "payflow" {
  name                = "${var.project_name}acr${var.environment}"  # must be globally unique, alphanumeric
  resource_group_name = azurerm_resource_group.acr.name
  location            = azurerm_resource_group.acr.location
  sku                 = "Basic"  # Basic: ~$5/mo. Standard for geo-replication, Premium for private link.
  admin_enabled       = false    # Use managed identity — never admin credentials

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Grant AKS kubelet identity AcrPull on the registry.
# Without this role assignment, AKS nodes get 401 Unauthorized on every image pull.
# This is the Azure equivalent of the AWS ECR KMS node-role gap.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.payflow.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id

  depends_on = [azurerm_kubernetes_cluster.aks]
}
