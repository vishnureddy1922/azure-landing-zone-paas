// KQL-based log alerts on the shared Log Analytics workspace.
// Deployed by the pipeline after Terraform, using Terraform outputs as parameters.
//
//   az deployment group create -g <hub-rg> -f bicep/monitoring/log-alerts.bicep \
//     -p workspaceId=<id> actionGroupId=<id> namePrefix=alz-dev

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('Resource ID of the action group that receives the alerts.')
param actionGroupId string

@description('Prefix used in alert names, for example alz-dev.')
param namePrefix string

param location string = resourceGroup().location

var alerts = [
  {
    name: 'waf-blocks-spike'
    description: 'Application Gateway WAF blocked more than 100 requests in 15 minutes (possible attack or false positive after a release).'
    severity: 2
    threshold: 100
    query: '''
AGWFirewallLogs
| where Action == "Blocked"
| summarize Blocked = count() by bin(TimeGenerated, 15m)
| project TimeGenerated, AggregatedValue = Blocked
'''
  }
  {
    name: 'keyvault-access-denied'
    description: 'Key Vault returned 403 (RBAC or firewall denied). Often a missing role assignment or a new outbound IP.'
    severity: 2
    threshold: 5
    query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT" and Category == "AuditEvent"
| where httpStatusCode_d == 403
| summarize Denied = count() by bin(TimeGenerated, 15m)
| project TimeGenerated, AggregatedValue = Denied
'''
  }
  {
    name: 'app-5xx-by-path'
    description: 'A single URL path returned more than 20 server errors in 15 minutes.'
    severity: 2
    threshold: 20
    query: '''
AppServiceHTTPLogs
| where ScStatus >= 500
| summarize Errors = count() by CsUriStem, bin(TimeGenerated, 15m)
| summarize AggregatedValue = max(Errors) by TimeGenerated
'''
  }
  {
    name: 'sql-audit-failed-logins'
    description: 'More than 10 failed Azure SQL logins in 15 minutes.'
    severity: 1
    threshold: 10
    query: '''
AzureDiagnostics
| where Category == "SQLSecurityAuditEvents" and action_name_s == "DATABASE AUTHENTICATION FAILED"
| summarize Failed = count() by bin(TimeGenerated, 15m)
| project TimeGenerated, AggregatedValue = Failed
'''
  }
]

resource logAlerts 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [for a in alerts: {
  name: 'sqa-${namePrefix}-${a.name}'
  location: location
  properties: {
    displayName: 'sqa-${namePrefix}-${a.name}'
    description: a.description
    severity: a.severity
    enabled: true
    scopes: [
      workspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: a.query
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'AggregatedValue'
          operator: 'GreaterThan'
          threshold: a.threshold
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    // Tables such as AGWFirewallLogs only appear after the first log arrives.
    skipQueryValidation: true
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
  }
}]

output alertNames array = [for (a, i) in alerts: logAlerts[i].name]
