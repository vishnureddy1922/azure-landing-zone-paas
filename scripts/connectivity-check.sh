#!/usr/bin/env bash
# Connectivity triage for the web app -> SQL / Key Vault / Blob private path.
# Checks everything visible from the control plane, then prints the commands
# to run inside the app (az webapp ssh) where DNS and routing match the app.
#
# Usage: ./scripts/connectivity-check.sh <workload-rg> <hub-rg> <web-app-name>
set -euo pipefail

RG="$1"; HUB_RG="$2"; APP="$3"

echo "== 1. VNet integration on the web app"
az webapp vnet-integration list -g "$RG" -n "$APP" --query "[].{subnet:vnetResourceId}" -o table
az webapp show -g "$RG" -n "$APP" --query "{routeAll:siteConfig.vnetRouteAllEnabled, state:state, httpsOnly:httpsOnly}" -o table

echo "== 2. Private endpoint connections (all should be Approved / Succeeded)"
az network private-endpoint list -g "$RG" \
  --query "[].{name:name, status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status, state:provisioningState}" -o table

echo "== 3. Private DNS A records (each should point at a 10.1.2.x address)"
for zone in privatelink.database.windows.net privatelink.vaultcore.azure.net privatelink.blob.core.windows.net; do
  echo "-- $zone"
  az network private-dns record-set a list -g "$HUB_RG" -z "$zone" \
    --query "[].{name:name, ip:aRecords[0].ipv4Address}" -o table
done

echo "== 4. DNS zone links (zones must be linked to the spoke VNet)"
for zone in privatelink.database.windows.net privatelink.vaultcore.azure.net privatelink.blob.core.windows.net; do
  az network private-dns link vnet list -g "$HUB_RG" -z "$zone" --query "[].{zone:'$zone', link:name, state:virtualNetworkLinkState}" -o table
done

echo "== 5. NSG rules on the private endpoint subnet"
az network nsg rule list -g "$RG" --nsg-name "$(az network nsg list -g "$RG" --query "[?contains(name,'private-endpoints')].name | [0]" -o tsv)" \
  --query "[].{name:name, priority:priority, access:access, ports:destinationPortRanges, source:sourceAddressPrefix}" -o table

echo "== 6. Route tables on the integration subnet (0.0.0.0/0 -> firewall when enabled)"
az network route-table list -g "$RG" --query "[].{name:name, routes:routes[].{prefix:addressPrefix, nextHop:nextHopIpAddress}}" -o json

SQL=$(az webapp config appsettings list -g "$RG" -n "$APP" --query "[?name=='SQL_SERVER'].value | [0]" -o tsv)
cat <<NEXT

== 7. Inside the app (what the app actually sees). Run:
   az webapp ssh -g $RG -n $APP
then:
   nslookup $SQL            # expect a 10.1.2.x address via privatelink
   nc -zvw5 $SQL 1433       # expect "succeeded"
   curl -s localhost:8000/ready | python3 -m json.tool

If DNS returns a public IP: the private DNS zone is not linked to the spoke VNet, or vnetRouteAllEnabled is false.
If DNS is private but TCP fails: check the NSG rule above, then the route table / Azure Firewall logs (AZFWApplicationRule).
If TCP works but login fails: the app identity has no database user -> scripts/grant-app-db-access.sql.
NEXT
