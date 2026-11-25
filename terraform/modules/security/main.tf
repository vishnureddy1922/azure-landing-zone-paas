variable "name" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tenant_id" { type = string }
variable "deployer_object_id" { type = string }
variable "resource_group_ids" { type = list(string) }
variable "admin_ip_ranges" { type = list(string) }
variable "allowed_subnet_ids" { type = list(string) }
variable "private_endpoint_subnet_id" { type = string }
variable "private_dns_zone_ids" { type = map(string) }
variable "app_hostname" { type = string }
variable "enable_policy" { type = bool }
variable "log_analytics_workspace_id" { type = string }
variable "tags" { type = map(string) }

# ---------------------------------------------------------------------------
# Key Vault: RBAC authorization, purge protection, network locked down.
# Private endpoint for workloads; firewall allows only the deployment agent IP
# and the Application Gateway subnet (service endpoint) for certificate pulls.
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "this" {
  name                          = "kv-${var.name}-${var.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 30
  public_network_access_enabled = true # data plane is still limited by network_acls below
  tags                          = var.tags

  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    ip_rules                   = var.admin_ip_ranges
    virtual_network_subnet_ids = var.allowed_subnet_ids
  }
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-${azurerm_key_vault.this.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-keyvault"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["keyvault"]]
  }
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs" # includes the AuditEvent category
  }
}

# The identity running Terraform manages secrets and certificates.
resource "azurerm_role_assignment" "deployer_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.deployer_object_id
}

resource "azurerm_role_assignment" "deployer_certs" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = var.deployer_object_id
}

# Azure RBAC can take a minute to propagate before data-plane calls succeed.
resource "time_sleep" "rbac_propagation" {
  create_duration = "90s"
  depends_on      = [azurerm_role_assignment.deployer_secrets, azurerm_role_assignment.deployer_certs]
}

# Example application secret. The web app reads it through a Key Vault
# reference, so the value never appears in app settings or pipeline logs.
resource "random_password" "sample_api_key" {
  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "sample_api_key" {
  name            = "sample-api-key"
  value           = random_password.sample_api_key.result
  key_vault_id    = azurerm_key_vault.this.id
  content_type    = "text/plain"
  expiration_date = timeadd(plantimestamp(), "8760h") # 1 year; rotation runbook in docs/
  depends_on      = [time_sleep.rbac_propagation]

  lifecycle {
    ignore_changes = [expiration_date, value]
  }
}

# TLS certificate for the Application Gateway HTTPS listener. Self-signed here
# so the project runs without a domain; swap issuer_parameters to a CA-backed
# issuer (DigiCert / GlobalSign) for production. AutoRenew handles rotation.
resource "azurerm_key_vault_certificate" "appgw" {
  name         = "appgw-tls"
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [time_sleep.rbac_propagation]

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = false
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=${var.app_hostname}"
      validity_in_months = 12
      key_usage          = ["digitalSignature", "keyEncipherment"]
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"] # server authentication

      subject_alternative_names {
        dns_names = [var.app_hostname]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Azure Policy: custom guardrails assigned to both resource groups.
# ---------------------------------------------------------------------------
locals {
  policies = {
    require-tags = {
      display_name = "Require environment and owner tags"
      mode         = "Indexed"
      effect       = "Audit" # Audit: auto-created resources such as private endpoint NICs carry no tags
      rule = {
        if = {
          anyOf = [
            { field = "tags['environment']", exists = "false" },
            { field = "tags['owner']", exists = "false" },
          ]
        }
        then = { effect = "[parameters('effect')]" }
      }
    }

    sql-deny-public-network = {
      display_name = "Azure SQL servers must disable public network access"
      mode         = "All"
      effect       = "Deny"
      rule = {
        if = {
          allOf = [
            { field = "type", equals = "Microsoft.Sql/servers" },
            { field = "Microsoft.Sql/servers/publicNetworkAccess", notEquals = "Disabled" },
          ]
        }
        then = { effect = "[parameters('effect')]" }
      }
    }

    storage-min-tls = {
      display_name = "Storage accounts must require TLS 1.2 or higher"
      mode         = "All"
      effect       = "Deny"
      rule = {
        if = {
          allOf = [
            { field = "type", equals = "Microsoft.Storage/storageAccounts" },
            { field = "Microsoft.Storage/storageAccounts/minimumTlsVersion", notIn = ["TLS1_2", "TLS1_3"] },
          ]
        }
        then = { effect = "[parameters('effect')]" }
      }
    }

    webapp-https-only = {
      display_name = "App Service apps must only be reachable over HTTPS"
      mode         = "All"
      effect       = "Deny"
      rule = {
        if = {
          allOf = [
            { field = "type", equals = "Microsoft.Web/sites" },
            { field = "Microsoft.Web/sites/httpsOnly", equals = "false" },
          ]
        }
        then = { effect = "[parameters('effect')]" }
      }
    }
  }

  policy_assignments = var.enable_policy ? {
    for pair in setproduct(keys(local.policies), range(length(var.resource_group_ids))) :
    "${pair[0]}-${pair[1]}" => { policy = pair[0], rg_index = pair[1] }
  } : {}
}

resource "azurerm_policy_definition" "this" {
  for_each     = var.enable_policy ? local.policies : {}
  name         = "alz-${each.key}"
  display_name = "[ALZ] ${each.value.display_name}"
  policy_type  = "Custom"
  mode         = each.value.mode
  policy_rule  = jsonencode(each.value.rule)

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = each.value.effect
      metadata      = { displayName = "Effect" }
    }
  })

  metadata = jsonencode({ category = "ALZ Guardrails", version = "1.0.0" })
}

resource "azurerm_resource_group_policy_assignment" "this" {
  for_each             = local.policy_assignments
  name                 = substr("alz-${each.value.policy}-${each.value.rg_index}", 0, 64)
  resource_group_id    = var.resource_group_ids[each.value.rg_index]
  policy_definition_id = azurerm_policy_definition.this[each.value.policy].id
  description          = local.policies[each.value.policy].display_name

  parameters = jsonencode({
    effect = { value = local.policies[each.value.policy].effect }
  })
}

output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "sample_secret_versionless_id" {
  value = azurerm_key_vault_secret.sample_api_key.versionless_id
}

output "appgw_certificate_secret_id" {
  description = "Versionless secret ID, so Application Gateway picks up renewed certificates automatically."
  value       = azurerm_key_vault_certificate.appgw.versionless_secret_id
}
