# crumb-llc-infra

Infrastructure-as-code (Bicep) for the Crumb **UCP broker** (`../crumb-llc-api`). A lean,
stateless footprint in its **own resource group**, isolated from the legacy app.

## What it provisions (`rg-crumb-agent`, eastus)

| Resource | SKU/tier | Why |
|---|---|---|
| Function App | **Linux Consumption (Y1)** | the broker; scale-to-zero, ~1M free exec/mo |
| Storage account | Standard_LRS | required by the Functions runtime |
| Key Vault | Standard | holds the two Shopify secrets |
| User-assigned identity | — | Function reads Key Vault refs via this identity |
| App Insights + Log Analytics | PerGB2018, 30-day | logging/diagnostics |

No ACR, Postgres, or AI Search. **Est. ~$1–5/mo.**

## Secret model

Secrets are **never** in source. At deploy time they're seeded into Key Vault and exposed
to the Function as **Key Vault references** (`@Microsoft.KeyVault(VaultName=…;SecretName=…)`)
resolved through the managed identity — so values never live in the template, the app
config, or the image. This is the same pattern as the legacy app, minus the heavy bits.

| Key Vault secret | App setting | Source |
|---|---|---|
| `shopify-ucp-client-id` | `SHOPIFY_UCP_CLIENT_ID` | Dev Dashboard → Catalogs → Get an API key |
| `shopify-ucp-client-secret` | `SHOPIFY_UCP_CLIENT_SECRET` | same |
| — | `SHOPIFY_CATALOG_URL` | Dev Dashboard → Catalogs → Copy URL (plain setting) |

The Key Vault references are wired **only when** credentials are supplied, so the broker
deploys cleanly in an unconfigured state and returns `503` until creds exist.

## Deploy

```sh
# 1) Validate locally
az bicep build --file main.bicep --stdout > /dev/null

# 2) Deploy (creates the RG). Without creds → broker runs idle (503 on catalog routes).
./deploy.sh

# 3) Deploy WITH credentials (seeds Key Vault):
SHOPIFY_CLIENT_ID=xxx SHOPIFY_CLIENT_SECRET=yyy SHOPIFY_CATALOG_URL=https://... ./deploy.sh
```

Outputs include `brokerBaseUrl` and `agentProfileUrl` — use the base URL as the iOS app's
`CRUMB_API_BASE_URL`.

Then publish the Function code from `../crumb-llc-api`:

```sh
cd ../crumb-llc-api
func azure functionapp publish <functionAppName>   # name is in the deploy outputs
```

## Adding the custom domain later

Ship on `https://<functionAppName>.azurewebsites.net` first (the agent profile is served
from `/.well-known/ucp` there). To move to `agent.crumb.llc`, add a CNAME at your DNS
provider and bind it as a custom domain on the Function App (managed certificate).

## Notes

- Region **eastus** (matches the existing subscription default).
- `dev.bicepparam` holds only non-secret config; secrets come from env vars via `deploy.sh`.
