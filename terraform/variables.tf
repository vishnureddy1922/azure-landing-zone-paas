variable "prefix" {
  description = "Short name used in every resource name (lowercase letters and numbers)."
  type        = string
  default     = "alz"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.prefix))
    error_message = "prefix must be 2-8 lowercase letters or numbers."
  }
}

variable "environment" {
  description = "Environment name, for example dev, test or prod."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Primary Azure region."
  type        = string
  default     = "eastus2"
}

variable "secondary_location" {
  description = "Paired region for the Azure SQL geo-secondary (disaster recovery)."
  type        = string
  default     = "centralus"
}

variable "owner" {
  description = "Owner tag value (required by the tagging policy)."
  type        = string
}

variable "alert_email" {
  description = "Email address that receives Azure Monitor alerts."
  type        = string
}

variable "admin_ip_ranges" {
  description = "Public IP ranges (CIDR) of the deployment agent / admins that may reach Key Vault's data plane."
  type        = list(string)
  default     = []
}

variable "sql_admin_group_name" {
  description = "Display name of the Microsoft Entra ID group that administers Azure SQL."
  type        = string
}

variable "sql_admin_group_object_id" {
  description = "Object ID of the Microsoft Entra ID group that administers Azure SQL."
  type        = string
}

variable "sql_sku" {
  description = "Azure SQL Database SKU. GP_S_* is serverless and auto-pauses to save cost."
  type        = string
  default     = "GP_S_Gen5_1"
}

variable "app_service_sku" {
  description = "App Service plan SKU. P0v3 or higher is needed for VNet integration with good performance."
  type        = string
  default     = "P0v3"
}

variable "app_hostname" {
  description = "Host name used for the Application Gateway TLS certificate."
  type        = string
  default     = "app.alz.example.com"
}

variable "enable_firewall" {
  description = "Deploy Azure Firewall in the hub and force app outbound traffic through it (adds roughly 1.25 USD per hour)."
  type        = bool
  default     = false
}

variable "enable_app_gateway" {
  description = "Deploy Application Gateway WAF_v2 in front of the web app."
  type        = bool
  default     = true
}

variable "enable_geo_dr" {
  description = "Create a geo-secondary Azure SQL server and an auto-failover group."
  type        = bool
  default     = true
}

variable "enable_backup_vault" {
  description = "Protect the storage account with an Azure Backup vault (operational blob backup)."
  type        = bool
  default     = true
}

variable "enable_policy" {
  description = "Create and assign the custom Azure Policy definitions (needs Resource Policy Contributor at subscription scope)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}
