#!/usr/bin/env bash
# Planned DR drill for the Azure SQL auto-failover group.
#  1. records the current primary and checks replication health
#  2. fails over to the secondary region (planned, no data loss)
#  3. checks the app's /ready endpoint through the listener
#  4. fails back and prints the measured RTO
#
# Usage: ./scripts/dr-failover-test.sh <workload-rg> <failover-group> <app-url>
set -euo pipefail

RG="$1"; FOG="$2"; APP_URL="$3"

PRIMARY=$(az sql server list -g "$RG" --query "[?!contains(name,'-dr')].name | [0]" -o tsv)
SECONDARY=$(az sql server list -g "$RG" --query "[?contains(name,'-dr')].name | [0]" -o tsv)

echo "== Before: replication state"
az sql failover-group show -g "$RG" -s "$PRIMARY" -n "$FOG" \
  --query "{role:replicationRole, state:replicationState, partner:partnerServers[0].id}" -o table

check_app() {
  for i in $(seq 1 30); do
    if curl -fsS -k "$APP_URL/ready" >/dev/null; then echo "app ready"; return 0; fi
    sleep 10
  done
  echo "app NOT ready after 5 minutes"; return 1
}

echo "== Failing over to $SECONDARY (planned)"
START=$(date +%s)
az sql failover-group set-primary -g "$RG" -s "$SECONDARY" -n "$FOG"
check_app
RTO=$(( $(date +%s) - START ))
echo "== Failover complete. Measured RTO: ${RTO}s"

echo "== Failing back to $PRIMARY"
az sql failover-group set-primary -g "$RG" -s "$PRIMARY" -n "$FOG"
check_app

echo "== After: replication state"
az sql failover-group show -g "$RG" -s "$PRIMARY" -n "$FOG" \
  --query "{role:replicationRole, state:replicationState}" -o table
echo "Record the RTO (${RTO}s) and any errors in docs/runbooks/sql-failover-dr.md -> DR test log."
