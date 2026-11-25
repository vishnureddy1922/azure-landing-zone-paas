# Security scan findings and decisions

Checkov runs on every push (GitHub Actions) and pipeline run (Azure DevOps). It is set to report-only so a finding never blocks an emergency fix, but every finding must be either fixed or listed here with a reason.

## Controls in place

| Area | Control |
|---|---|
| Identity | Microsoft Entra-only auth on Azure SQL; managed identities for app, slot and gateway; Key Vault RBAC, no access policies |
| Secrets | No secrets in app settings or pipelines; Key Vault references; secret expiry set; certificate auto-renewal |
| Network | SQL, Key Vault, Blob reachable only through private endpoints; SQL and storage public access disabled; app reachable only from the gateway subnet; NSGs on every subnet; optional Azure Firewall egress filtering |
| Edge | WAF_v2 in Prevention mode (OWASP 3.2 + bot rules); TLS 1.2+ policy; HTTP redirected to HTTPS |
| Data | TLS 1.2 minimum everywhere; storage shared keys disabled; blob versioning, soft delete, Azure Backup |
| Governance | Custom Azure Policy: deny public SQL, deny storage below TLS 1.2, deny HTTP-only web apps, audit missing tags |
| Logging | Diagnostics from every resource to Log Analytics; SQL auditing; Key Vault audit events |

## Accepted findings

| Finding | Resource | Reason |
|---|---|---|
| Key Vault public network access enabled | `azurerm_key_vault.this` | Public endpoint stays enabled but `default_action = Deny`; only the deployment agent IP and the gateway subnet are allowed. Needed for Terraform to manage certificates from a hosted agent. Use a self-hosted agent in the VNet to remove this. |
| App Service public network access enabled | `azurerm_linux_web_app.this` | Inbound locked to the Application Gateway subnet via access restrictions (default action Deny). |
| Storage not encrypted with a customer-managed key | `azurerm_storage_account.this` | Microsoft-managed keys are acceptable for this data classification. |
| SQL TDE without a customer-managed key | `azurerm_mssql_server.this` | Service-managed TDE is on by default; CMK adds key-management overhead not needed here. |
| Defender for SQL not enabled | `azurerm_mssql_server.this` | Available via `enable_defender_for_sql` in the data module; off by default to avoid per-server cost in dev. |

Update this table when a new finding appears in the CI output.

Match each row to the Checkov check ID shown in the CI log when you review the first run.
