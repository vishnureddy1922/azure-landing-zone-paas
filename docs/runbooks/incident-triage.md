# Runbook: production incident triage

Use this when an alert from the `ag-<prefix>-<env>-ops` action group fires or a user reports the app is down or slow.

## 1. Scope it (first 5 minutes)

| Question | Where to look |
|---|---|
| Is Azure itself having an issue? | Service Health alert email, or Portal > Service Health |
| Is the gateway seeing healthy backends? | Application Gateway > Backend health |
| Is the app up on every instance? | Web app > Health check (per-instance status) |
| Did something change? | Azure DevOps last run, Activity Log for the resource group (last 2 hours) |
| Which dependency is failing? | `https://<app>/ready` returns a per-dependency status |

## 2. Match the symptom

| Symptom | Likely cause | First action |
|---|---|---|
| `UnhealthyHostCount > 0`, users get 502 | App down, probe path failing, or app access restriction blocking the gateway subnet | Check web app Health check, then Access restrictions (rule `allow-app-gateway` present) |
| `Http5xx` spike right after a deploy | Bad release | Swap the `staging` slot back (`az webapp deployment slot swap ... --slot staging`) — rollback takes about a minute |
| `/ready` shows `sql: error` with login failed | Managed identity has no database user, or Entra admin changed | Run `scripts/grant-app-db-access.sql` |
| `/ready` shows `sql: error` with timeout | DNS or network path | Run `scripts/connectivity-check.sh` and follow the hints |
| `key_vault_reference: error` | App identity lost `Key Vault Secrets User`, secret disabled/expired, or KV firewall | Web app > Environment variables shows the reference error reason |
| `failed-connections` SQL alert | Network change, firewall rule, or identity | Check `AzureDiagnostics` SQL audit query in `docs/kql-queries.md` |
| WAF blocks spike | Attack or false positive on a new endpoint | `AGWFirewallLogs` query; if false positive, add a scoped exclusion in the WAF policy via Terraform |
| CPU > 80% on SQL | Missing index or runaway query | Query Performance Insight; autoscale does not cover SQL — scale the SKU via `sql_sku` if sustained |

## 3. Communicate

- Post status within 15 minutes: impact, start time, current hypothesis, next update time.
- Severity 1 (outage, data at risk): page the owner, open a bridge.

## 4. Close out

1. Confirm alerts auto-resolved and `/ready` is green.
2. Write the post-incident review: timeline, root cause, why monitoring did or did not catch it, follow-up actions with owners.
3. If a manual fix was made in the portal, put it into Terraform so the next `apply` does not revert it.
