# Runbook: secrets and certificate rotation

## What lives in Key Vault

| Object | Used by | How it is read |
|---|---|---|
| `sample-api-key` (secret) | Web app | App setting `SAMPLE_API_KEY = @Microsoft.KeyVault(SecretUri=<versionless>)`, resolved with the app's managed identity |
| `appgw-tls` (certificate) | Application Gateway HTTPS listener | Versionless secret ID, read by user-assigned identity `id-<prefix>-<env>-appgw` |

There are **no SQL passwords**: Azure SQL uses Microsoft Entra-only authentication and the app connects with its managed identity.

## Access model (Azure RBAC on the vault)

| Identity | Role |
|---|---|
| Terraform deployment identity | Key Vault Secrets Officer, Key Vault Certificates Officer |
| Web app and staging slot identities | Key Vault Secrets User |
| Application Gateway identity | Key Vault Secrets User |

## Rotate an application secret

```bash
az keyvault secret set --vault-name <kv> -n sample-api-key \
  --value "$(openssl rand -base64 30)" --expires "$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)"
```

App Service re-reads versionless Key Vault references within 24 hours. To pick the new value now:

```bash
az webapp config appsettings set -g <rg> -n <app> --settings KV_REFRESH="$(date +%s)"   # any change triggers a refresh
```

Terraform ignores later changes to this secret's value (`lifecycle.ignore_changes`), so rotation does not cause drift.

## Certificate renewal

- The certificate policy uses `AutoRenew` 30 days before expiry.
- Application Gateway polls Key Vault every 4 hours and uses the newest version because it references the **versionless** secret ID. No redeploy needed.
- For production, replace the `Self` issuer with a CA issuer (for example DigiCert) configured in Key Vault, and point DNS for `app_hostname` at the gateway public IP.

## Troubleshooting

| Symptom | Check |
|---|---|
| Web app shows a red Key Vault reference status | Identity has `Key Vault Secrets User`? Secret enabled and not expired? `vnetRouteAllEnabled` true and KV private DNS linked? |
| Application Gateway listener fails after renewal | Gateway identity role assignment; Key Vault firewall still allows `snet-appgw` |
| Terraform `403` writing secrets | The deployment agent's public IP is not in `admin_ip_ranges` (Key Vault firewall) |

Key Vault `403` events also raise the `keyvault-access-denied` log alert (see `bicep/monitoring/log-alerts.bicep`).
