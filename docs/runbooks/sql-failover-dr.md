# Runbook: Azure SQL disaster recovery

## Design

| Item | Setting |
|---|---|
| Replication | Auto-failover group `fog-<prefix>-<env>-<suffix>`, async geo-replication to `secondary_location` |
| Failover policy | Automatic, 60-minute grace period (Azure fails over only for a prolonged regional outage) |
| Connection string | Always the listener `<fog>.database.windows.net`, never a server name, so the app follows the primary |
| Private access | Private endpoints for both servers in the spoke; the listener resolves to the current primary's private IP |
| Backups | Point-in-time restore 14 days, differential every 12 h, geo-redundant backup storage |
| Long-term retention | Weekly 4 weeks, monthly 12 months, yearly 5 years |
| Targets | RPO: under 5 seconds typical replication lag (geo-replication), RTO: under 1 hour (grace period) — planned failover in minutes |

## Planned failover (drill or maintenance)

```bash
./scripts/dr-failover-test.sh <workload-rg> <failover-group> https://<app-gateway-ip-or-host>
```

The script checks replication health, fails over with no data loss, waits for the app's `/ready` to pass, records the RTO, and fails back.

## Unplanned failover (region down, Azure has not failed over yet)

Only when the business accepts possible loss of the last few seconds of writes:

```bash
az sql failover-group set-primary -g <rg> -s <secondary-server> -n <fog> --allow-data-loss
```

Then:
1. Confirm `/ready` reports `sql: ok` and `server` shows the secondary.
2. Note: the web app itself runs in the primary region. For a full regional outage, redeploy the workload to the secondary region with `location = <secondary>` in a new state key (Terraform is region-agnostic). This is the documented, untested-by-default part of the plan.

## Point-in-time restore (bad data change, dropped table)

```bash
az sql db restore -g <rg> -s <primary-server> -n sqldb-app \
  --dest-name sqldb-app-restore-$(date +%Y%m%d%H%M) \
  --time "2026-11-20T14:30:00Z"
```

Restore to a new database, copy the needed rows back, then drop the restored copy. Never overwrite the live database.

## DR test log

| Date | Type | Measured RTO | Data loss | Issues found | Run by |
|---|---|---|---|---|---|
| | Planned failover | | | | |
