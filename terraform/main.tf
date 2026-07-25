data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# ---------------------------------------------------------------------------
# Log Analytics Workspace
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.prefix}-law"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ---------------------------------------------------------------------------
# Azure Container Registry
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = "${var.prefix}acr${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  sku                 = var.acr_sku
  admin_enabled       = false
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# ---------------------------------------------------------------------------
# AKS Cluster
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = "${var.prefix}-aks"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  dns_prefix          = "${var.prefix}-aks"
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name       = "system"
    node_count = var.node_count
    vm_size    = var.vm_size
  }

  identity {
    type = "SystemAssigned"
  }

  # Ship container/node logs to Log Analytics Workspace
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }
}

# Allow AKS's kubelet identity to pull images from ACR (no password needed)
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
