variable "name" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "enable_backup_vault" { type = bool }
variable "private_endpoint_subnet_id" { type = string }
variable "private_dns_zone_ids" { type = map(string) }
variable "log_analytics_workspace_id" { type = string }
variable "tags" { type = map(string) }

# ---------------------------------------------------------------------------
# App data storage: private only, Entra ID auth only (no shared keys),
# geo-zone-redundant, with versioning and soft delete as a first line of
# recovery before restoring from the backup vault.
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "this" {
  name                            = substr(replace("st${var.name}${var.suffix}", "-", ""), 0, 24)
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "GZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false
  tags                            = var.tags

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = 14
    }

    container_delete_retention_policy {
      days = 14
    }
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_storage_container" "uploads" {
  name                  = "uploads"
  storage_account_id    = azurerm_storage_account.this.id # created through ARM, not the data plane
  container_access_type = "private"
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-${azurerm_storage_account.this.name}-blob"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["blob"]]
  }
}

resource "azurerm_monitor_diagnostic_setting" "blob" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = "${azurerm_storage_account.this.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
}

# ---------------------------------------------------------------------------
# Azure Backup: operational (continuous) blob backup with 30-day
# point-in-time restore, held by a geo-redundant backup vault with soft delete.
# ---------------------------------------------------------------------------
resource "azurerm_data_protection_backup_vault" "this" {
  count                      = var.enable_backup_vault ? 1 : 0
  name                       = "bvault-${var.name}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  datastore_type             = "VaultStore"
  redundancy                 = "GeoRedundant"
  soft_delete                = "On"
  retention_duration_in_days = 14
  tags                       = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "backup_vault_storage" {
  count                = var.enable_backup_vault ? 1 : 0
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Account Backup Contributor"
  principal_id         = azurerm_data_protection_backup_vault.this[0].identity[0].principal_id
}

resource "azurerm_data_protection_backup_policy_blob_storage" "this" {
  count                                  = var.enable_backup_vault ? 1 : 0
  name                                   = "bkpol-blob-30d"
  vault_id                               = azurerm_data_protection_backup_vault.this[0].id
  operational_default_retention_duration = "P30D"
}

resource "azurerm_data_protection_backup_instance_blob_storage" "this" {
  count              = var.enable_backup_vault ? 1 : 0
  name               = "bkinst-${azurerm_storage_account.this.name}"
  vault_id           = azurerm_data_protection_backup_vault.this[0].id
  location           = var.location
  storage_account_id = azurerm_storage_account.this.id
  backup_policy_id   = azurerm_data_protection_backup_policy_blob_storage.this[0].id

  depends_on = [azurerm_role_assignment.backup_vault_storage]
}

output "storage_account_id" {
  value = azurerm_storage_account.this.id
}

output "primary_blob_endpoint" {
  value = azurerm_storage_account.this.primary_blob_endpoint
}
