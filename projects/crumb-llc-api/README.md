# crumb-llc-api

The Crumb **UCP broker** — a stateless [Azure Functions](https://learn.microsoft.com/azure/azure-functions/)
(Python) app that fronts Shopify's **UCP Global Catalog** and keeps all credentials
server-side. The iOS app calls *this* broker; the broker holds the Shopify key and talks
to Shopify. This satisfies Shopify App Store rule **5.9** (secrets/tokens never on the
device).

Scope (v1): **discovery only** — `search_catalog` + `get_product`. No cart, no checkout
completion, no customer data. Checkout stays a per-shop `continue_url` handoff.

## Endpoints

`host.json` sets `routePrefix: ""`, so routes are at the domain root:

| Method & path | Auth | Purpose |
|---|---|---|
| `GET /.well-known/ucp` | anonymous | Hosted UCP agent profile (Shopify fetches this) |
| `GET /healthz` | anonymous | Liveness + whether credentials are configured |
| `POST /catalog/search` | function key | `{ "query": "...", "context"?: {...} }` → normalized products |
| `POST /catalog/product` | function key | `{ "productId": "gid://...", "selected"?: [...] }` → product |

## How auth works (no state)

```
POST {SHOPIFY_TOKEN_URL}  grant_type=client_credentials      -> { access_token }  (JWT, ~60 min)
   (cached in the warm instance, refreshed on a buffer; never persisted)
POST {SHOPIFY_CATALOG_URL}  Authorization: Bearer <token>     -> UCP tools/call result
   body: JSON-RPC tools/call {search_catalog|get_product} with meta.ucp-agent.profile
```

`meta.ucp-agent.profile` points at this app's own `/.well-known/ucp` (derived from the
request host when `AGENT_PROFILE_URL` is unset, so it works on `*.azurewebsites.net`).

## Configuration

Application settings (env vars). The two secrets are wired as **Key Vault references** in
Azure (see `../crumb-llc-infra`); locally they live in `local.settings.json` (gitignored —
copy `local.settings.json.example`).

| Setting | Secret? | Notes |
|---|---|---|
| `SHOPIFY_UCP_CLIENT_ID` | ✓ | Dev Dashboard → Catalogs → "Get an API key" |
| `SHOPIFY_UCP_CLIENT_SECRET` | ✓ | same |
| `SHOPIFY_CATALOG_URL` | — | Dev Dashboard → Catalogs → "Copy URL" (the Global Catalog MCP endpoint) |
| `SHOPIFY_TOKEN_URL` | — | default `https://api.shopify.com/auth/access_token` |
| `UCP_VERSION` | — | default `2026-04-08` |
| `AGENT_PROFILE_URL` | — | optional; auto-derived from the request host if unset |

## Run locally

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

cp local.settings.json.example local.settings.json   # fill in real values
func start                                            # needs Azure Functions Core Tools
```

Without real credentials, `/healthz` reports `configured: false` and the catalog routes
return `503 broker_not_configured` — the iOS app stays on its mock client until then.

## Test

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install pydantic pydantic-settings pytest
python -m pytest          # 7 tests, no network (transport is injected)
```

## Deploy

Deployed via `../crumb-llc-infra` (Bicep provisions the Function app, Storage, Key Vault,
managed identity, App Insights). Push code with zip deploy / `func azure functionapp
publish <name>` or a GitHub Actions workflow — no container registry needed.

## Notes / to confirm against a live key

- The exact `SHOPIFY_CATALOG_URL` host comes from the Dev Dashboard.
- The `get_product` `selected` argument schema should be checked with
  `ucp catalog get_product --input-schema` once a real catalog exists; normalization in
  `crumb_agent/models.py` is deliberately tolerant of schema variation.
