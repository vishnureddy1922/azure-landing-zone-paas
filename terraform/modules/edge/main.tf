variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "subnet_id" { type = string }
variable "backend_fqdn" { type = string }
variable "key_vault_id" { type = string }
variable "certificate_secret_id" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "action_group_id" { type = string }
variable "tags" { type = map(string) }

locals {
  gw_ip_config   = "gw-ipconfig"
  frontend_ip    = "fe-public"
  port_http      = "port-80"
  port_https     = "port-443"
  listener_http  = "listener-http"
  listener_https = "listener-https"
  backend_pool   = "pool-webapp"
  backend_https  = "settings-webapp-https"
  probe          = "probe-webapp-health"
  redirect       = "redirect-http-to-https"
  ssl_cert       = "cert-appgw-tls"
}

# Application Gateway reads the TLS certificate from Key Vault with this
# identity, so certificate renewals in Key Vault roll out with no redeploy.
resource "azurerm_user_assigned_identity" "appgw" {
  name                = "id-${var.name}-appgw"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "appgw_kv" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw.principal_id
}

resource "time_sleep" "rbac_propagation" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.appgw_kv]
}

resource "azurerm_public_ip" "appgw" {
  name                = "pip-${var.name}-appgw"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "waf-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"
    request_body_check          = true
    max_request_body_size_in_kb = 128
    file_upload_limit_in_mb     = 100
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.0"
    }
  }
}

resource "azurerm_application_gateway" "this" {
  name                = "agw-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  zones               = ["1", "2", "3"]
  firewall_policy_id  = azurerm_web_application_firewall_policy.this.id
  tags                = var.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = 1
    max_capacity = 3
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw.id]
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101" # TLS 1.2+ only
  }

  ssl_certificate {
    name                = local.ssl_cert
    key_vault_secret_id = var.certificate_secret_id
  }

  gateway_ip_configuration {
    name      = local.gw_ip_config
    subnet_id = var.subnet_id
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = local.port_http
    port = 80
  }

  frontend_port {
    name = local.port_https
    port = 443
  }

  backend_address_pool {
    name  = local.backend_pool
    fqdns = [var.backend_fqdn]
  }

  probe {
    name                                      = local.probe
    protocol                                  = "Https"
    path                                      = "/health"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true

    match {
      status_code = ["200-399"]
    }
  }

  backend_http_settings {
    name                                = local.backend_https
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 60
    pick_host_name_from_backend_address = true # App Service routes on the Host header
    probe_name                          = local.probe
  }

  http_listener {
    name                           = local.listener_https
    frontend_ip_configuration_name = local.frontend_ip
    frontend_port_name             = local.port_https
    protocol                       = "Https"
    ssl_certificate_name           = local.ssl_cert
  }

  http_listener {
    name                           = local.listener_http
    frontend_ip_configuration_name = local.frontend_ip
    frontend_port_name             = local.port_http
    protocol                       = "Http"
  }

  redirect_configuration {
    name                 = local.redirect
    redirect_type        = "Permanent"
    target_listener_name = local.listener_https
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = "rule-https-to-webapp"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = local.listener_https
    backend_address_pool_name  = local.backend_pool
    backend_http_settings_name = local.backend_https
  }

  request_routing_rule {
    name                        = "rule-http-redirect"
    priority                    = 200
    rule_type                   = "Basic"
    http_listener_name          = local.listener_http
    redirect_configuration_name = local.redirect
  }

  depends_on = [time_sleep.rbac_propagation]
}

resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                           = "diag-to-log-analytics"
  target_resource_id             = azurerm_application_gateway.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs" # access, performance and WAF firewall logs
  }
}

resource "azurerm_monitor_metric_alert" "unhealthy_hosts" {
  name                = "ma-${var.name}-agw-unhealthy-backend"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_application_gateway.this.id]
  description         = "Application Gateway sees an unhealthy backend (web app down, probe failing, or certificate/host name mismatch)."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Network/applicationGateways"
    metric_name      = "UnhealthyHostCount"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = var.action_group_id
  }
}

resource "azurerm_monitor_metric_alert" "failed_requests" {
  name                = "ma-${var.name}-agw-failed-requests"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_application_gateway.this.id]
  description         = "More than 50 failed requests at the gateway in 5 minutes."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Network/applicationGateways"
    metric_name      = "FailedRequests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 50
  }

  action {
    action_group_id = var.action_group_id
  }
}

output "public_ip_address" {
  value = azurerm_public_ip.appgw.ip_address
}

output "application_gateway_id" {
  value = azurerm_application_gateway.this.id
}
