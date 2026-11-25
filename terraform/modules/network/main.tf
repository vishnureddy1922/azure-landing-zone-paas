variable "name" { type = string }
variable "location" { type = string }
variable "hub_resource_group_name" { type = string }
variable "spoke_resource_group_name" { type = string }
variable "enable_firewall" { type = bool }
variable "log_analytics_workspace_id" { type = string }
variable "tags" { type = map(string) }

variable "hub_address_space" {
  type    = string
  default = "10.0.0.0/16"
}

variable "spoke_address_space" {
  type    = string
  default = "10.1.0.0/16"
}

locals {
  private_dns_zones = {
    sql      = "privatelink.database.windows.net"
    keyvault = "privatelink.vaultcore.azure.net"
    blob     = "privatelink.blob.core.windows.net"
  }
}

# ---------------------------------------------------------------------------
# Hub VNet: shared connectivity (firewall, DNS zones). A VPN or ExpressRoute
# gateway for on-premises connectivity would also live here.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.name}-hub"
  resource_group_name = var.hub_resource_group_name
  location            = var.location
  address_space       = [var.hub_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet" # name required by Azure
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_address_space, 10, 0)] # 10.0.0.0/26
}

# ---------------------------------------------------------------------------
# Spoke VNet: the workload.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${var.name}-spoke"
  resource_group_name = var.spoke_resource_group_name
  location            = var.location
  address_space       = [var.spoke_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = var.spoke_resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.spoke_address_space, 8, 0)] # 10.1.0.0/24
  service_endpoints    = ["Microsoft.Web", "Microsoft.KeyVault"]
}

resource "azurerm_subnet" "app_integration" {
  name                 = "snet-app-integration"
  resource_group_name  = var.spoke_resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.spoke_address_space, 8, 1)] # 10.1.1.0/24

  delegation {
    name = "app-service"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-private-endpoints"
  resource_group_name               = var.spoke_resource_group_name
  virtual_network_name              = azurerm_virtual_network.spoke.name
  address_prefixes                  = [cidrsubnet(var.spoke_address_space, 8, 2)] # 10.1.2.0/24
  private_endpoint_network_policies = "Enabled"                                   # lets the NSG below apply to private endpoints
}

# ---------------------------------------------------------------------------
# Peering (both directions).
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-hub-to-spoke"
  resource_group_name       = var.hub_resource_group_name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-spoke-to-hub"
  resource_group_name       = var.spoke_resource_group_name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
  use_remote_gateways       = false
}

# ---------------------------------------------------------------------------
# Network security groups.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-${var.name}-appgw"
  resource_group_name = var.spoke_resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "Allow-GatewayManager"
    description                = "Required by Application Gateway v2 for health and management traffic."
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Internet-HTTP-HTTPS"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "app_integration" {
  name                = "nsg-${var.name}-app-integration"
  resource_group_name = var.spoke_resource_group_name
  location            = var.location
  tags                = var.tags
  # Outbound-only subnet. Default rules are enough; egress is filtered by
  # Azure Firewall when enable_firewall = true.
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-${var.name}-private-endpoints"
  resource_group_name = var.spoke_resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "Allow-App-To-Data"
    description                = "Web app (VNet integration subnet) to SQL, Key Vault and Blob private endpoints."
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["1433", "443"]
    source_address_prefix      = azurerm_subnet.app_integration.address_prefixes[0]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-Other-VNet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

resource "azurerm_subnet_network_security_group_association" "app_integration" {
  subnet_id                 = azurerm_subnet.app_integration.id
  network_security_group_id = azurerm_network_security_group.app_integration.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

resource "azurerm_monitor_diagnostic_setting" "nsg" {
  for_each = {
    appgw             = azurerm_network_security_group.appgw.id
    app_integration   = azurerm_network_security_group.app_integration.id
    private_endpoints = azurerm_network_security_group.private_endpoints.id
  }

  name                       = "diag-to-log-analytics"
  target_resource_id         = each.value
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
}

# ---------------------------------------------------------------------------
# Private DNS zones, linked to hub and spoke so private endpoints resolve.
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "this" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each              = local.private_dns_zones
  name                  = "link-hub"
  resource_group_name   = var.hub_resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  for_each              = local.private_dns_zones
  name                  = "link-spoke"
  resource_group_name   = var.hub_resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false
  tags                  = var.tags
}

# ---------------------------------------------------------------------------
# Optional Azure Firewall: all outbound traffic from the web app goes through
# the hub and only allow-listed FQDNs are reachable.
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "firewall" {
  count               = var.enable_firewall ? 1 : 0
  name                = "pip-${var.name}-afw"
  resource_group_name = var.hub_resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_firewall_policy" "this" {
  count                    = var.enable_firewall ? 1 : 0
  name                     = "afwp-${var.name}"
  resource_group_name      = var.hub_resource_group_name
  location                 = var.location
  sku                      = "Standard"
  threat_intelligence_mode = "Deny"
  tags                     = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "app_egress" {
  count              = var.enable_firewall ? 1 : 0
  name               = "rcg-app-egress"
  firewall_policy_id = azurerm_firewall_policy.this[0].id
  priority           = 200

  application_rule_collection {
    name     = "allow-app-outbound"
    priority = 200
    action   = "Allow"

    rule {
      name             = "azure-monitor-and-platform"
      source_addresses = [azurerm_subnet.app_integration.address_prefixes[0]]
      destination_fqdns = [
        "*.applicationinsights.azure.com",
        "*.monitor.azure.com",
        "*.in.applicationinsights.azure.com",
        "login.microsoftonline.com",
        "management.azure.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name              = "python-packages"
      source_addresses  = [azurerm_subnet.app_integration.address_prefixes[0]]
      destination_fqdns = ["pypi.org", "files.pythonhosted.org"]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }
}

resource "azurerm_firewall" "this" {
  count               = var.enable_firewall ? 1 : 0
  name                = "afw-${var.name}"
  resource_group_name = var.hub_resource_group_name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.this[0].id
  zones               = ["1", "2", "3"]
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.app_egress]
}

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  count                          = var.enable_firewall ? 1 : 0
  name                           = "diag-to-log-analytics"
  target_resource_id             = azurerm_firewall.this[0].id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_route_table" "app_egress" {
  count               = var.enable_firewall ? 1 : 0
  name                = "rt-${var.name}-app-egress"
  resource_group_name = var.spoke_resource_group_name
  location            = var.location
  tags                = var.tags

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.this[0].ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "app_integration" {
  count          = var.enable_firewall ? 1 : 0
  subnet_id      = azurerm_subnet.app_integration.id
  route_table_id = azurerm_route_table.app_egress[0].id
}

output "hub_vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "spoke_vnet_id" {
  value = azurerm_virtual_network.spoke.id
}

output "subnet_ids" {
  value = {
    appgw             = azurerm_subnet.appgw.id
    app_integration   = azurerm_subnet.app_integration.id
    private_endpoints = azurerm_subnet.private_endpoints.id
  }
}

output "private_dns_zone_ids" {
  value = { for k, z in azurerm_private_dns_zone.this : k => z.id }
}

output "firewall_private_ip" {
  value = var.enable_firewall ? azurerm_firewall.this[0].ip_configuration[0].private_ip_address : null
}
