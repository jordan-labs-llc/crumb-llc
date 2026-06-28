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

Secrets **never pass through the deployment** — not as `@secure()` params (which land in
deployment history) and not on the deploy command line (which lands in `ps` / shell
history). Instead:

1. **Bicep** creates the Key Vault + identity and tells the Container App to *reference*
   secrets by name (`{ keyVaultUrl, identity }` → `secretRef` env vars).
2. **`set-secrets.sh`** writes the values into Key Vault out-of-band (read interactively,
   hidden input).
3. The Container App reads them **at runtime** via its managed identity.

| Key Vault secret | App env var | Source |
|---|---|---|
| `shopify-ucp-client-id` | `SHOPIFY_UCP_CLIENT_ID` | Dev Dashboard → Catalogs → Get an API key |
| `shopify-ucp-client-secret` | `SHOPIFY_UCP_CLIENT_SECRET` | same |
| `crumb-broker-key` (optional) | `CRUMB_BROKER_KEY` | your choice; gates the `x-broker-key` header |

`SHOPIFY_CATALOG_URL` is **not** a secret — it lives in `environments/dev.bicepparam`.

The Key Vault references are wired only when `enableShopify` (and `enableBrokerKey`) are
true, so the broker deploys cleanly idle and returns `503` until the secrets exist + are
enabled.

## Deploy

```sh
# 0) Validate
az bicep build --file main.bicep --stdout > /dev/null

# 1) Provision (creates Key Vault, identity, app — idle). No secrets involved.
./deploy.sh

# 2) Write the secrets into Key Vault (interactive, hidden input — nothing in history)
./set-secrets.sh

# 3) Wire the references and roll the app
ENABLE_SHOPIFY=true ./deploy.sh
#   add ENABLE_BROKER_KEY=true if you set a broker key
```

Set `shopifyCatalogUrl` in `environments/dev.bicepparam` before step 3. Outputs include
`brokerBaseUrl` and `agentProfileUrl` — use the base URL as the iOS app's
`CRUMB_API_BASE_URL`.

> For CI later, the pipeline does the same `az keyvault secret set` from its own secret
> store (e.g. GitHub OIDC) — same separation, no secrets in the repo or workflow logs.

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
