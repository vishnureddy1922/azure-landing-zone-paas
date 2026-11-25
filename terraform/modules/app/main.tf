variable "name" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "sku_name" { type = string }
variable "integration_subnet_id" { type = string }
variable "appgw_subnet_id" {
  description = "When set, only Application Gateway can reach the app. When null the app is reachable directly over HTTPS."
  type        = string
  default     = null
}
variable "app_insights_connection_string" {
  type      = string
  sensitive = true
}
variable "key_vault_id" { type = string }
variable "sample_secret_versionless_id" { type = string }
variable "sql_fqdn" { type = string }
variable "sql_database_name" { type = string }
variable "storage_account_id" { type = string }
variable "storage_blob_endpoint" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "action_group_id" { type = string }
variable "tags" { type = map(string) }

locals {
  locked_to_appgw = var.appgw_subnet_id != null

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING      = var.app_insights_connection_string
    ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
    SCM_DO_BUILD_DURING_DEPLOYMENT             = "true"
    SQL_SERVER                                 = var.sql_fqdn
    SQL_DATABASE                               = var.sql_database_name
    STORAGE_BLOB_ENDPOINT                      = var.storage_blob_endpoint
    # Key Vault reference: resolved by App Service with the managed identity
    # over the VNet. The secret value never lands in Terraform state for the app.
    SAMPLE_API_KEY = "@Microsoft.KeyVault(SecretUri=${var.sample_secret_versionless_id})"
  }
}

resource "azurerm_service_plan" "this" {
  name                = "asp-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.sku_name
  tags                = var.tags
}

resource "azurerm_linux_web_app" "this" {
  name                          = "app-${var.name}-${var.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  service_plan_id               = azurerm_service_plan.this.id
  https_only                    = true
  public_network_access_enabled = true # inbound is restricted by ip_restriction rules below
  virtual_network_subnet_id     = var.integration_subnet_id
  app_settings                  = local.app_settings
  tags                          = var.tags

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                         = true
    ftps_state                        = "Disabled"
    http2_enabled                     = true
    minimum_tls_version               = "1.2"
    vnet_route_all_enabled            = true
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 5
    app_command_line                  = "gunicorn --bind=0.0.0.0:8000 --timeout 120 --workers 2 main:app"

    application_stack {
      python_version = "3.12"
    }

    ip_restriction_default_action     = local.locked_to_appgw ? "Deny" : "Allow"
    scm_ip_restriction_default_action = "Allow" # deployment agents use the SCM site

    dynamic "ip_restriction" {
      for_each = local.locked_to_appgw ? [1] : []
      content {
        name                      = "allow-app-gateway"
        priority                  = 100
        action                    = "Allow"
        virtual_network_subnet_id = var.appgw_subnet_id
      }
    }
  }

  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }
}

# Staging slot: the pipeline deploys here, smoke-tests /health, then swaps,
# so a bad release can be rolled back with one swap.
resource "azurerm_linux_web_app_slot" "staging" {
  name                          = "staging"
  app_service_id                = azurerm_linux_web_app.this.id
  https_only                    = true
  public_network_access_enabled = true
  virtual_network_subnet_id     = var.integration_subnet_id
  app_settings                  = local.app_settings
  tags                          = var.tags

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on              = true
    ftps_state             = "Disabled"
    minimum_tls_version    = "1.2"
    vnet_route_all_enabled = true
    health_check_path      = "/health"
    app_command_line       = "gunicorn --bind=0.0.0.0:8000 --timeout 120 --workers 2 main:app"

    application_stack {
      python_version = "3.12"
    }

    ip_restriction_default_action     = "Deny" # staging is reached only by the pipeline through SCM
    scm_ip_restriction_default_action = "Allow"
  }
}

# ---------------------------------------------------------------------------
# Least-privilege access for the app's managed identities.
# ---------------------------------------------------------------------------
locals {
  app_principals = {
    production = azurerm_linux_web_app.this.identity[0].principal_id
    staging    = azurerm_linux_web_app_slot.staging.identity[0].principal_id
  }
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  for_each             = local.app_principals
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "blob_contributor" {
  for_each             = local.app_principals
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

# ---------------------------------------------------------------------------
# Autoscale: scale out on CPU and memory, never below 1 instance.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_autoscale_setting" "plan" {
  name                = "autoscale-${azurerm_service_plan.this.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_service_plan.this.id
  tags                = var.tags

  profile {
    name = "default"

    capacity {
      default = 1
      minimum = 1
      maximum = 3
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT20M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT20M"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Diagnostics and alerts.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "web_app" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_linux_web_app.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AppServiceHTTPLogs"
  }
  enabled_log {
    category = "AppServiceConsoleLogs"
  }
  enabled_log {
    category = "AppServiceAppLogs"
  }
  enabled_log {
    category = "AppServicePlatformLogs"
  }
  enabled_log {
    category = "AppServiceAuditLogs"
  }
}

locals {
  web_alerts = {
    http-5xx = {
      metric    = "Http5xx"
      agg       = "Total"
      op        = "GreaterThan"
      threshold = 10
      severity  = 1
      desc      = "More than 10 HTTP 5xx responses in 5 minutes."
    }
    health-check = {
      metric    = "HealthCheckStatus"
      agg       = "Average"
      op        = "LessThan"
      threshold = 100
      severity  = 1
      desc      = "One or more instances are failing the /health check."
    }
    response-time = {
      metric    = "HttpResponseTime"
      agg       = "Average"
      op        = "GreaterThan"
      threshold = 3
      severity  = 2
      desc      = "Average response time above 3 seconds."
    }
  }
}

resource "azurerm_monitor_metric_alert" "web" {
  for_each            = local.web_alerts
  name                = "ma-${var.name}-app-${each.key}"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_web_app.this.id]
  description         = each.value.desc
  severity            = each.value.severity
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = each.value.metric
    aggregation      = each.value.agg
    operator         = each.value.op
    threshold        = each.value.threshold
  }

  action {
    action_group_id = var.action_group_id
  }
}

output "web_app_name" {
  value = azurerm_linux_web_app.this.name
}

output "web_app_id" {
  value = azurerm_linux_web_app.this.id
}

output "default_hostname" {
  value = azurerm_linux_web_app.this.default_hostname
}
