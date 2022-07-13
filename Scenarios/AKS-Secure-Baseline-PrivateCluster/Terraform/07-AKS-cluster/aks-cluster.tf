
#############
# LOCALS #
#############

locals {
  aks_clusters = {
    "aks_blue" = {
      name_prefix="blue"
      aks_is_active=false
      aks_turn_on=false
      k8s_version="1.23.5"
    },
    "aks_green" = {
      name_prefix="green"
      aks_is_active=false
      aks_turn_on=true
      k8s_version="1.23.5"
    }
  }
}

#############
# RESOURCES #
#############

# MSI for Kubernetes Cluster (Control Plane)
# This ID is used by the AKS control plane to create or act on other resources in Azure.
# It is referenced in the "identity" block in the azurerm_kubernetes_cluster resource.

resource "azurerm_user_assigned_identity" "mi-aks-cp" {
  for_each = { for aks_clusters in local.aks_clusters : aks_clusters.name_prefix => aks_clusters if aks_clusters.aks_turn_on == true}
  name                = "mi-${var.prefix}-aks-${each.value.name_prefix}-cp"
  resource_group_name = data.terraform_remote_state.existing-lz.outputs.lz_rg_name
  location            = data.terraform_remote_state.existing-lz.outputs.lz_rg_location
}

# Role Assignments for Control Plane MSI

resource "azurerm_role_assignment" "aks-to-rt" {
  for_each = azurerm_user_assigned_identity.mi-aks-cp
  scope                = data.terraform_remote_state.existing-lz.outputs.lz_rt_id
  role_definition_name = "Contributor"
  principal_id         = each.value.principal_id
}

resource "azurerm_role_assignment" "aks-to-vnet" {
  for_each = azurerm_user_assigned_identity.mi-aks-cp
  scope                = data.terraform_remote_state.existing-lz.outputs.lz_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = each.value.principal_id

}

# Role assignment to to create Private DNS zone for cluster
resource "azurerm_role_assignment" "aks-to-dnszone" {
  for_each = azurerm_user_assigned_identity.mi-aks-cp
  scope                = azurerm_private_dns_zone.aks-dns.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = each.value.principal_id
}

# Log Analytics Workspace for Cluster

resource "azurerm_log_analytics_workspace" "aks" {
  name                = "aks-la-01"
  resource_group_name = data.terraform_remote_state.existing-lz.outputs.lz_rg_name
  location            = data.terraform_remote_state.existing-lz.outputs.lz_rg_location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# AKS Cluster

module "aks" {
  source = "./modules/aks"
  depends_on = [
    azurerm_role_assignment.aks-to-vnet,
    azurerm_role_assignment.aks-to-dnszone
  ]
  for_each = { for aks_clusters in local.aks_clusters : aks_clusters.name_prefix => aks_clusters if aks_clusters.aks_turn_on == true}
  resource_group_name = data.terraform_remote_state.existing-lz.outputs.lz_rg_name
  location            = data.terraform_remote_state.existing-lz.outputs.lz_rg_location
  prefix              = "aks-${var.prefix}-${each.value.name_prefix}"
  vnet_subnet_id      = data.terraform_remote_state.existing-lz.outputs.aks_subnet_id
  mi_aks_cp_id        = azurerm_user_assigned_identity.mi-aks-cp[each.value.name_prefix].id
  la_id               = azurerm_log_analytics_workspace.aks.id
  gateway_name        = data.terraform_remote_state.existing-lz.outputs.gateway_name
  gateway_id          = data.terraform_remote_state.existing-lz.outputs.gateway_id
  private_dns_zone_id = azurerm_private_dns_zone.aks-dns.id
  k8s_version = each.value.k8s_version
  aks_is_active = each.value.aks_is_active

}

# These role assignments grant the groups made in "03-AAD" access to use
# The AKS cluster. 
resource "azurerm_role_assignment" "appdevs_user" {
  for_each = module.aks
  scope                = each.value.aks_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.terraform_remote_state.aad.outputs.appdev_object_id
}

resource "azurerm_role_assignment" "aksops_admin" {
  for_each = module.aks
  scope                = each.value.aks_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.terraform_remote_state.aad.outputs.aksops_object_id
}

# This role assigned grants the current user running the deployment admin rights
# to the cluster. In production, you should use just the AAD groups (above).
resource "azurerm_role_assignment" "aks_rbac_admin" {
  for_each = module.aks
  scope                = each.value.aks_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id

}

# Role Assignment to Azure Container Registry from AKS Cluster
# This must be granted after the cluster is created in order to use the kubelet identity.

resource "azurerm_role_assignment" "aks-to-acr" {
  for_each = module.aks
  scope                = data.terraform_remote_state.aks-support.outputs.container_registry_id
  role_definition_name = "AcrPull"
  principal_id         = each.value.kubelet_id
}

# Role Assignments for AGIC on AppGW
# This must be granted after the cluster is created in order to use the ingress identity.

resource "azurerm_role_assignment" "agic_appgw" {
  for_each = module.aks
  scope                = data.terraform_remote_state.existing-lz.outputs.gateway_id
  role_definition_name = "Contributor"
  principal_id         = each.value.agic_id
}