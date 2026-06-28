# crumb-llc-api

The Crumb **UCP broker** — a stateless **FastAPI** service (containerized, runs on
**Azure Container Apps**) that fronts Shopify's **UCP Global Catalog** and keeps all
credentials server-side. The iOS app calls *this* broker; the broker holds the Shopify
key and talks to Shopify. This satisfies Shopify App Store rule **5.9** (secrets/tokens
never on the device).

> Runs on Container Apps rather than Azure Functions because this subscription has zero
> App Service VM quota; Container Apps (also scale-to-zero) is available and already used
> in prod. The HTTP layer is the only thing that differs — the core logic in
> `crumb_agent/` is framework-agnostic and unit-tested.

Scope (v1): **discovery only** — `search_catalog` + `get_product`. No cart, no checkout
completion, no customer data. Checkout stays a per-shop `continue_url` handoff.

## Endpoints

| Method & path | Auth | Purpose |
|---|---|---|
| `GET /.well-known/ucp` | open | Hosted UCP agent profile (Shopify fetches this) |
| `GET /healthz` | open | Liveness + whether credentials are configured |
| `POST /catalog/search` | `x-broker-key`* | `{ "query": "...", "context"?: {...} }` → products |
| `POST /catalog/product` | `x-broker-key`* | `{ "productId": "gid://...", "selected"?: [...] }` |

\* Catalog routes require the `x-broker-key` header **only if** `CRUMB_BROKER_KEY` is set.

## How auth works (no state)

```
POST {SHOPIFY_TOKEN_URL}  grant_type=client_credentials      -> { access_token }  (JWT, ~60 min)
   (cached in the running container, refreshed on a buffer; never persisted)
POST {SHOPIFY_CATALOG_URL}  Authorization: Bearer <token>     -> UCP tools/call result
   body: JSON-RPC tools/call {search_catalog|get_product} with meta.ucp-agent.profile
```

`meta.ucp-agent.profile` points at this app's own `/.well-known/ucp` (derived from the
request host when `AGENT_PROFILE_URL` is unset).

## Configuration

Container env vars. The two secrets resolve from **Key Vault references** in Azure (see
`../crumb-llc-infra`); locally they come from `.env` (gitignored — copy `.env.example`).

| Setting | Secret? | Notes |
|---|---|---|
| `SHOPIFY_UCP_CLIENT_ID` | ✓ | Dev Dashboard → Catalogs → "Get an API key" |
| `SHOPIFY_UCP_CLIENT_SECRET` | ✓ | same |
| `SHOPIFY_CATALOG_URL` | — | Dev Dashboard → Catalogs → "Copy URL" |
| `SHOPIFY_TOKEN_URL` | — | default `https://api.shopify.com/auth/access_token` |
| `UCP_VERSION` | — | default `2026-04-08` |
| `CRUMB_BROKER_KEY` | ✓ | optional; required as `x-broker-key` when set |
| `AGENT_PROFILE_URL` | — | optional; auto-derived from the request host if unset |

## Run locally

```sh
python3 -m venv .venv && . .venv/bin/activate     # Python 3.11+
pip install -r requirements.txt
cp .env.example .env                               # fill in real values
uvicorn server:app --reload --port 8000

# or in a container:
docker build -t crumb-agent . && docker run -p 8000:8000 --env-file .env crumb-agent
```

Without credentials, `/healthz` reports `configured: false` and the catalog routes return
`503 broker_not_configured` — the iOS app stays on its mock client until then.

## Test

```sh
python3 -m venv .venv && . .venv/bin/activate      # Python 3.11+
pip install -r requirements.txt pytest
python -m pytest          # 11 tests, no network (transport injected; FastAPI TestClient)
```

## Deploy

Built and deployed by `../crumb-llc-infra/deploy.sh`, which runs `az acr build` (cloud
build — no local Docker needed) to push the image to the existing `acrcrumbprod` registry,
then deploys the Container App via Bicep.

## Notes / to confirm against a live key

- The exact `SHOPIFY_CATALOG_URL` host comes from the Dev Dashboard.
- The `get_product` `selected` argument schema should be checked with
  `ucp catalog get_product --input-schema` once a real catalog exists; normalization in
  `crumb_agent/models.py` is deliberately tolerant of schema variation.
