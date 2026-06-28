# crumb-llc-infra

Infrastructure-as-code (Bicep) for the Crumb **UCP broker** (`../crumb-llc-api`). A lean,
stateless footprint in its **own resource group**, isolated from the legacy app.

> **Compute = Azure Container Apps**, not Functions. This subscription has zero App Service
> VM quota (Functions Consumption can't provision), but Container Apps Consumption is
> available — prod already uses it — and is just as cheap (scale-to-zero).

## What it provisions (`rg-crumb-agent`, eastus)

| Resource | SKU/tier | Why |
|---|---|---|
| Container App | **Consumption, min 0** | the broker; scale-to-zero |
| Container Apps Env + Log Analytics | Consumption / PerGB2018 | host + logs |
| Key Vault | Standard | holds the Shopify secrets (+ optional broker key) |
| User-assigned identity | — | pulls the image **and** reads Key Vault refs |

The image is pulled from the **existing `acrcrumbprod`** registry (in `rg-crumb-prod`) via
an `AcrPull` role on the managed identity — so no new registry. **Est. ~$0–3/mo.**

## Secret model

Secrets are **never** in source. At deploy time they're seeded into Key Vault and exposed
to the Container App as **Key Vault references** (`{ keyVaultUrl, identity }` secrets →
`secretRef` env vars) resolved through the managed identity.

| Key Vault secret | App env var | Source |
|---|---|---|
| `shopify-ucp-client-id` | `SHOPIFY_UCP_CLIENT_ID` | Dev Dashboard → Catalogs → Get an API key |
| `shopify-ucp-client-secret` | `SHOPIFY_UCP_CLIENT_SECRET` | same |
| `crumb-broker-key` (optional) | `CRUMB_BROKER_KEY` | your choice; gates the `x-broker-key` header |
| — | `SHOPIFY_CATALOG_URL` | Dev Dashboard → Catalogs → Copy URL (plain env) |

Key Vault references are wired **only when** the matching secret is supplied, so the broker
deploys cleanly unconfigured and returns `503` until creds exist.

## Deploy

```sh
# Validate locally
az bicep build --file main.bicep --stdout > /dev/null

# Deploy. Builds the image with ACR Tasks (no local Docker), then provisions the app.
# Without creds → broker runs idle (503 on catalog routes).
./deploy.sh

# With credentials (seeds Key Vault):
SHOPIFY_CLIENT_ID=xxx SHOPIFY_CLIENT_SECRET=yyy SHOPIFY_CATALOG_URL=https://... ./deploy.sh
```

Outputs include `brokerBaseUrl` and `agentProfileUrl` — use the base URL as the iOS app's
`CRUMB_API_BASE_URL`.

## Notes

- **ACR reuse coupling:** the broker's identity gets a read-only `AcrPull` on the prod-RG
  registry. To fully isolate later, stand up a Basic ACR in `rg-crumb-agent` (~$5/mo) and
  point `acrName`/`acrLoginServer`/`acrResourceGroup` at it.
- **First-pull race:** if the role assignment hasn't propagated when the first revision
  starts, the image pull can fail once; a revision restart resolves it.
- **Orphans from the earlier Functions attempt** (`stcrumbagent…`, `law-crumb-agent-dev`,
  `appi-crumb-agent-dev`) are unused now and can be deleted; they cost ~nothing.
- Region **eastus**. `dev.bicepparam` holds only non-secret config; secrets come via env
  in `deploy.sh`.
