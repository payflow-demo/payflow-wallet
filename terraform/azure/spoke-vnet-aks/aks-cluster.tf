# AKS Cluster Configuration

# Log Analytics Workspace for AKS monitoring
resource "azurerm_log_analytics_workspace" "aks" {
  name                = "${var.project_name}-aks-logs"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.project_name}-aks-cluster"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "${var.project_name}-aks"
  kubernetes_version  = var.kubernetes_version

  # Network Configuration
  network_profile {
    network_plugin     = "azure"
    network_policy     = "azure"
    service_cidr       = var.aks_service_cidr
    dns_service_ip     = var.aks_dns_service_ip
    # docker_bridge_cidr removed in azurerm provider ~> 3.x
  }

  # System Node Pool (required)
  default_node_pool {
    name                = "system"
    node_count          = var.system_node_count
    vm_size             = var.system_node_vm_size
    os_disk_size_gb     = 30
    vnet_subnet_id      = azurerm_subnet.aks_system.id
    type                = "VirtualMachineScaleSets"
    enable_auto_scaling = true
    min_count           = var.system_node_min_count
    max_count           = var.system_node_max_count
    max_pods            = 30

    # Use spot instances for cost savings (optional)
    priority        = var.use_spot_instances ? "Spot" : "Regular"
    eviction_policy = var.use_spot_instances ? "Delete" : null
    spot_max_price  = var.use_spot_instances ? var.spot_max_price : null

    # Node labels and taints
    node_labels = {
      "kubernetes.io/role" = "system"
    }
  }

  # Identity Configuration
  identity {
    type = "SystemAssigned"
  }

  # Role-Based Access Control
  role_based_access_control_enabled = true

  # Azure Active Directory Integration (optional)
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids  = var.aks_admin_group_ids
  }

  # Monitoring
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  # Private Cluster (recommended for production)
  private_cluster_enabled = var.enable_private_cluster

  # API Server Access
  api_server_authorized_ip_ranges = var.enable_private_cluster ? [] : var.api_server_authorized_ip_ranges

  # Lifecycle to prevent accidental destruction
  lifecycle {
    prevent_destroy = false  # Changed from true: allow terraform destroy (e.g. destroy.sh)
    ignore_changes = [
      tags,
      default_node_pool[0].node_count,  # Ignore auto-scaling changes
    ]
  }

  depends_on = [
    azurerm_log_analytics_workspace.aks,
    azurerm_subnet.aks_system,
  ]

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# User Node Pool (for application workloads)
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  count = var.enable_user_node_pool ? 1 : 0

  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.user_node_vm_size
  node_count             = var.user_node_count
  os_disk_size_gb        = 50
  vnet_subnet_id         = var.enable_user_subnet ? azurerm_subnet.aks_user[0].id : azurerm_subnet.aks_system.id
  enable_auto_scaling    = true
  min_count              = var.user_node_min_count
  max_count              = var.user_node_max_count
  max_pods               = 50

  # Use spot instances for cost savings
  priority        = var.use_spot_instances ? "Spot" : "Regular"
  eviction_policy = var.use_spot_instances ? "Delete" : null
  spot_max_price  = var.use_spot_instances ? var.spot_max_price : null

  # Node labels
  node_labels = {
    "kubernetes.io/role" = "user"
  }

  # Node taints (optional)
  node_taints = var.user_node_taints

  # Lifecycle to prevent accidental recreation
  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      node_count,  # Ignore auto-scaling changes
    ]
  }

  depends_on = [
    azurerm_kubernetes_cluster.aks,
  ]

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

