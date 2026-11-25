variable "name" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "secondary_location" { type = string }
variable "sql_sku" { type = string }
variable "sql_admin_group_name" { type = string }
variable "sql_admin_group_object_id" { type = string }
variable "enable_geo_dr" { type = bool }
variable "private_endpoint_subnet_id" { type = string }
variable "private_dns_zone_ids" { type = map(string) }
variable "log_analytics_workspace_id" { type = string }
variable "action_group_id" { type = string }
variable "tags" { type = map(string) }

variable "enable_defender_for_sql" {
  description = "Turn on Microsoft Defender for SQL threat detection on the servers (billed per server)."
  type        = bool
  default     = false
}

locals {
  is_serverless = startswith(var.sql_sku, "GP_S_")
  servers = merge(
    { primary = { location = var.location, name = "sql-${var.name}-${var.suffix}" } },
    var.enable_geo_dr ? { secondary = { location = var.secondary_location, name = "sql-${var.name}-${var.suffix}-dr" } } : {}
  )
}

# ---------------------------------------------------------------------------
# Logical servers: Microsoft Entra-only authentication (no SQL logins or
# passwords), TLS 1.2 minimum, public network access disabled.
# ---------------------------------------------------------------------------
resource "azurerm_mssql_server" "this" {
  for_each                      = local.servers
  name                          = each.value.name
  resource_group_name           = var.resource_group_name
  location                      = each.value.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = var.tags

  azuread_administrator {
    login_username              = var.sql_admin_group_name
    object_id                   = var.sql_admin_group_object_id
    azuread_authentication_only = true
  }

  identity {
    type = "SystemAssigned"
  }
}

# Private endpoints for both servers live in the primary spoke. A private
# endpoint can point at a resource in another region, so the failover-group
# listener keeps resolving privately after a regional failover.
resource "azurerm_private_endpoint" "sql" {
  for_each            = local.servers
  name                = "pe-${azurerm_mssql_server.this[each.key].name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-sql-${each.key}"
    private_connection_resource_id = azurerm_mssql_server.this[each.key].id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["sql"]]
  }
}

resource "azurerm_mssql_database" "app" {
  name                 = "sqldb-app"
  server_id            = azurerm_mssql_server.this["primary"].id
  sku_name             = var.sql_sku
  max_size_gb          = 32
  zone_redundant       = false
  storage_account_type = "Geo" # geo-redundant backup storage: restore into the paired region
  tags                 = var.tags

  # Serverless scales down to 0.5 vCore when idle. Auto-pause is disabled (-1)
  # because Azure does not support it together with geo-replication or LTR.
  min_capacity                = local.is_serverless ? 0.5 : null
  auto_pause_delay_in_minutes = local.is_serverless ? -1 : null

  # Point-in-time restore window and differential backup frequency.
  short_term_retention_policy {
    retention_days           = 14
    backup_interval_in_hours = 12
  }

  # Long-term retention for compliance.
  long_term_retention_policy {
    weekly_retention  = "P4W"
    monthly_retention = "P12M"
    yearly_retention  = "P5Y"
    week_of_year      = 1
  }
}

# ---------------------------------------------------------------------------
# Auto-failover group: async geo-replication to the paired region with a
# read-write listener that follows the primary.
# ---------------------------------------------------------------------------
resource "azurerm_mssql_failover_group" "this" {
  count     = var.enable_geo_dr ? 1 : 0
  name      = "fog-${var.name}-${var.suffix}"
  server_id = azurerm_mssql_server.this["primary"].id
  databases = [azurerm_mssql_database.app.id]
  tags      = var.tags

  partner_server {
    id = azurerm_mssql_server.this["secondary"].id
  }

  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = 60
  }

  readonly_endpoint_failover_policy_enabled = true
}

# ---------------------------------------------------------------------------
# Auditing and diagnostics to Log Analytics.
# ---------------------------------------------------------------------------
resource "azurerm_mssql_server_extended_auditing_policy" "this" {
  for_each               = local.servers
  server_id              = azurerm_mssql_server.this[each.key].id
  log_monitoring_enabled = true
}

# Server-level audit events are emitted by the master database.
resource "azurerm_monitor_diagnostic_setting" "sql_audit" {
  for_each                   = local.servers
  name                       = "diag-audit-to-log-analytics"
  target_resource_id         = "${azurerm_mssql_server.this[each.key].id}/databases/master"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "SQLSecurityAuditEvents"
  }

  depends_on = [azurerm_mssql_server_extended_auditing_policy.this]
}

resource "azurerm_monitor_diagnostic_setting" "database" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_mssql_database.app.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "Errors"
  }
  enabled_log {
    category = "Timeouts"
  }
  enabled_log {
    category = "Blocks"
  }
  enabled_log {
    category = "Deadlocks"
  }
  enabled_log {
    category = "AutomaticTuning"
  }
}

resource "azurerm_mssql_server_security_alert_policy" "this" {
  for_each            = var.enable_defender_for_sql ? local.servers : {}
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mssql_server.this[each.key].name
  state               = "Enabled"
}

# ---------------------------------------------------------------------------
# Metric alerts.
# ---------------------------------------------------------------------------
locals {
  sql_alerts = {
    cpu = {
      metric    = "cpu_percent"
      agg       = "Average"
      op        = "GreaterThan"
      threshold = 80
      severity  = 2
      desc      = "Database CPU above 80% for 15 minutes."
    }
    storage = {
      metric    = "storage_percent"
      agg       = "Maximum"
      op        = "GreaterThan"
      threshold = 85
      severity  = 2
      desc      = "Database storage above 85% of max size."
    }
    failed-connections = {
      metric    = "connection_failed"
      agg       = "Total"
      op        = "GreaterThan"
      threshold = 10
      severity  = 1
      desc      = "More than 10 failed connections in 15 minutes (networking, firewall or identity issue)."
    }
    deadlocks = {
      metric    = "deadlock"
      agg       = "Total"
      op        = "GreaterThan"
      threshold = 0
      severity  = 3
      desc      = "Deadlocks detected."
    }
  }
}

resource "azurerm_monitor_metric_alert" "sql" {
  for_each            = local.sql_alerts
  name                = "ma-${var.name}-sql-${each.key}"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_mssql_database.app.id]
  description         = each.value.desc
  severity            = each.value.severity
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Sql/servers/databases"
    metric_name      = each.value.metric
    aggregation      = each.value.agg
    operator         = each.value.op
    threshold        = each.value.threshold
  }

  action {
    action_group_id = var.action_group_id
  }
}

output "sql_endpoint_fqdn" {
  value = var.enable_geo_dr ? "${azurerm_mssql_failover_group.this[0].name}.database.windows.net" : azurerm_mssql_server.this["primary"].fully_qualified_domain_name
}

output "database_name" {
  value = azurerm_mssql_database.app.name
}

output "primary_server_name" {
  value = azurerm_mssql_server.this["primary"].name
}

output "failover_group_name" {
  value = var.enable_geo_dr ? azurerm_mssql_failover_group.this[0].name : null
}
