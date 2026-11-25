# KQL queries for day-to-day operations

Run in the Log Analytics workspace `log-<prefix>-<env>`.

## Web app

```kusto
// Error rate and latency per 5 minutes
AppServiceHTTPLogs
| where TimeGenerated > ago(6h)
| summarize Requests = count(), Errors5xx = countif(ScStatus >= 500),
            P95ms = percentile(TimeTaken, 95) by bin(TimeGenerated, 5m)
| extend ErrorRatePct = round(100.0 * Errors5xx / Requests, 2)
| order by TimeGenerated desc
```

```kusto
// Slowest endpoints
AppServiceHTTPLogs
| where TimeGenerated > ago(24h)
| summarize Calls = count(), P95ms = percentile(TimeTaken, 95) by CsUriStem
| top 10 by P95ms
```

```kusto
// Instance restarts and platform events
AppServicePlatformLogs
| where TimeGenerated > ago(24h)
| project TimeGenerated, Level, Message
| order by TimeGenerated desc
```

## Application Gateway and WAF

```kusto
// What the WAF blocked, by rule
AGWFirewallLogs
| where TimeGenerated > ago(24h) and Action == "Blocked"
| summarize Hits = count() by RuleId, Message, ClientIp
| top 20 by Hits
```

```kusto
// Backend status codes seen by the gateway
AGWAccessLogs
| where TimeGenerated > ago(1h)
| summarize count() by HttpStatus, ServerStatus
```

## Azure SQL

```kusto
// Failed logins (audit)
AzureDiagnostics
| where Category == "SQLSecurityAuditEvents" and action_name_s == "DATABASE AUTHENTICATION FAILED"
| project TimeGenerated, server_principal_name_s, client_ip_s, additional_information_s
| order by TimeGenerated desc
```

```kusto
// Timeouts, blocks and deadlocks
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SQL" and Category in ("Timeouts", "Blocks", "Deadlocks")
| summarize count() by Category, bin(TimeGenerated, 15m)
```

## Key Vault

```kusto
// Who read or changed what, and what was denied
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT" and Category == "AuditEvent"
| project TimeGenerated, OperationName, httpStatusCode_d, identity_claim_appid_g, CallerIPAddress, id_s
| order by TimeGenerated desc
```

## Azure Firewall (when enabled)

```kusto
// Outbound requests the firewall denied (missing allow rule)
AZFWApplicationRule
| where TimeGenerated > ago(6h) and Action == "Deny"
| summarize count() by Fqdn, SourceIp
```

## Network security groups

```kusto
AzureDiagnostics
| where Category == "NetworkSecurityGroupEvent" and type_s == "block"
| summarize count() by ruleName_s, direction_s, bin(TimeGenerated, 15m)
```
