variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "alert_email" { type = string }
variable "retention_days" { type = number }
variable "subscription_id" { type = string }
variable "tags" { type = map(string) }

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_days
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = var.tags
}

resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-${var.name}-ops"
  resource_group_name = var.resource_group_name
  short_name          = "alz-ops"
  tags                = var.tags

  email_receiver {
    name                    = "ops-email"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Azure Service Health: tells the on-call team when Azure itself has an
# incident or planned maintenance in the regions we use.
resource "azurerm_monitor_activity_log_alert" "service_health" {
  name                = "ala-${var.name}-service-health"
  resource_group_name = var.resource_group_name
  location            = "global"
  scopes              = [var.subscription_id]
  description         = "Azure service incidents, maintenance and security advisories."
  tags                = var.tags

  criteria {
    category = "ServiceHealth"
    service_health {
      events = ["Incident", "Maintenance", "Security"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# Resource Health: a resource in the subscription becomes unavailable or degraded.
resource "azurerm_monitor_activity_log_alert" "resource_health" {
  name                = "ala-${var.name}-resource-health"
  resource_group_name = var.resource_group_name
  location            = "global"
  scopes              = [var.subscription_id]
  description         = "A resource became unavailable or degraded."
  tags                = var.tags

  criteria {
    category = "ResourceHealth"
    resource_health {
      current  = ["Degraded", "Unavailable"]
      previous = ["Available"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.this.name
}

output "app_insights_connection_string" {
  value     = azurerm_application_insights.this.connection_string
  sensitive = true
}

output "action_group_id" {
  value = azurerm_monitor_action_group.ops.id
}
