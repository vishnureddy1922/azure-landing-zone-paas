#!/usr/bin/env bash
# Creates the storage account that holds Terraform remote state (run once per subscription).
# Usage: ./scripts/bootstrap-state.sh <location> [resource-group]
set -euo pipefail

LOCATION="${1:-eastus2}"
RG="${2:-rg-tfstate}"
SA="sttfstate$(openssl rand -hex 3)"
CONTAINER="tfstate"
ME="$(az ad signed-in-user show --query id -o tsv)"

az group create -n "$RG" -l "$LOCATION" -o none
az storage account create -n "$SA" -g "$RG" -l "$LOCATION" \
  --sku Standard_GRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false -o none
az storage account blob-service-properties update -n "$SA" -g "$RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 -o none

SA_ID="$(az storage account show -n "$SA" -g "$RG" --query id -o tsv)"
az role assignment create --assignee "$ME" --role "Storage Blob Data Contributor" --scope "$SA_ID" -o none
sleep 30 # RBAC propagation
az storage container create -n "$CONTAINER" --account-name "$SA" --auth-mode login -o none

cat <<OUT
State storage ready. Put this in terraform/backend.hcl:

resource_group_name  = "$RG"
storage_account_name = "$SA"
container_name       = "$CONTAINER"
key                  = "alz-dev.tfstate"
use_azuread_auth     = true
OUT
