output "workload_resource_group" {
  value = azurerm_resource_group.workload.name
}

output "hub_resource_group" {
  value = azurerm_resource_group.hub.name
}

output "web_app_name" {
  value = module.app.web_app_name
}

output "web_app_default_hostname" {
  value = module.app.default_hostname
}

output "app_gateway_public_ip" {
  value = var.enable_app_gateway ? module.edge[0].public_ip_address : null
}

output "sql_endpoint_fqdn" {
  description = "Use this name in connection strings. It is the failover-group listener when geo-DR is on, so it follows the primary after failover."
  value       = module.data.sql_endpoint_fqdn
}

output "sql_failover_group_name" {
  value = module.data.failover_group_name
}

output "key_vault_name" {
  value = module.security.key_vault_name
}

output "log_analytics_workspace_name" {
  value = module.monitoring.log_analytics_workspace_name
}

output "log_analytics_workspace_id" {
  value = module.monitoring.log_analytics_workspace_id
}

output "action_group_id" {
  value = module.monitoring.action_group_id
}
