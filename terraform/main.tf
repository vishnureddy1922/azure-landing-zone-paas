data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  name   = "${var.prefix}-${var.environment}"
  suffix = random_string.suffix.result

  tags = {
    environment = var.environment
    owner       = var.owner
    workload    = "alz-paas"
    managed_by  = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Resource groups: one for shared connectivity (hub), one for the workload.
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "hub" {
  name     = "rg-${local.name}-hub"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "workload" {
  name     = "rg-${local.name}-workload"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Observability first, so every other module can send diagnostics to it.
# ---------------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  name                = local.name
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  alert_email         = var.alert_email
  retention_days      = var.log_retention_days
  subscription_id     = data.azurerm_subscription.current.id
  tags                = local.tags
}

module "network" {
  source = "./modules/network"

  name                       = local.name
  location                   = var.location
  hub_resource_group_name    = azurerm_resource_group.hub.name
  spoke_resource_group_name  = azurerm_resource_group.workload.name
  enable_firewall            = var.enable_firewall
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  tags                       = local.tags
}

module "security" {
  source = "./modules/security"

  name                       = local.name
  suffix                     = local.suffix
  resource_group_name        = azurerm_resource_group.workload.name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  deployer_object_id         = data.azurerm_client_config.current.object_id
  resource_group_ids         = [azurerm_resource_group.hub.id, azurerm_resource_group.workload.id]
  admin_ip_ranges            = var.admin_ip_ranges
  allowed_subnet_ids         = [module.network.subnet_ids["appgw"]]
  private_endpoint_subnet_id = module.network.subnet_ids["private_endpoints"]
  private_dns_zone_ids       = module.network.private_dns_zone_ids
  app_hostname               = var.app_hostname
  enable_policy              = var.enable_policy
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  tags                       = local.tags
}

module "data" {
  source = "./modules/data"

  name                       = local.name
  suffix                     = local.suffix
  resource_group_name        = azurerm_resource_group.workload.name
  location                   = var.location
  secondary_location         = var.secondary_location
  sql_sku                    = var.sql_sku
  sql_admin_group_name       = var.sql_admin_group_name
  sql_admin_group_object_id  = var.sql_admin_group_object_id
  enable_geo_dr              = var.enable_geo_dr
  private_endpoint_subnet_id = module.network.subnet_ids["private_endpoints"]
  private_dns_zone_ids       = module.network.private_dns_zone_ids
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  action_group_id            = module.monitoring.action_group_id
  tags                       = local.tags
}

module "storage" {
  source = "./modules/storage"

  name                       = local.name
  suffix                     = local.suffix
  resource_group_name        = azurerm_resource_group.workload.name
  location                   = var.location
  enable_backup_vault        = var.enable_backup_vault
  private_endpoint_subnet_id = module.network.subnet_ids["private_endpoints"]
  private_dns_zone_ids       = module.network.private_dns_zone_ids
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  tags                       = local.tags
}

module "app" {
  source = "./modules/app"

  name                           = local.name
  suffix                         = local.suffix
  resource_group_name            = azurerm_resource_group.workload.name
  location                       = var.location
  sku_name                       = var.app_service_sku
  integration_subnet_id          = module.network.subnet_ids["app_integration"]
  appgw_subnet_id                = var.enable_app_gateway ? module.network.subnet_ids["appgw"] : null
  app_insights_connection_string = module.monitoring.app_insights_connection_string
  key_vault_id                   = module.security.key_vault_id
  sample_secret_versionless_id   = module.security.sample_secret_versionless_id
  sql_fqdn                       = module.data.sql_endpoint_fqdn
  sql_database_name              = module.data.database_name
  storage_account_id             = module.storage.storage_account_id
  storage_blob_endpoint          = module.storage.primary_blob_endpoint
  log_analytics_workspace_id     = module.monitoring.log_analytics_workspace_id
  action_group_id                = module.monitoring.action_group_id
  tags                           = local.tags
}

module "edge" {
  source = "./modules/edge"
  count  = var.enable_app_gateway ? 1 : 0

  name                       = local.name
  resource_group_name        = azurerm_resource_group.workload.name
  location                   = var.location
  subnet_id                  = module.network.subnet_ids["appgw"]
  backend_fqdn               = module.app.default_hostname
  key_vault_id               = module.security.key_vault_id
  certificate_secret_id      = module.security.appgw_certificate_secret_id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  action_group_id            = module.monitoring.action_group_id
  tags                       = local.tags
}
