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

Scope: catalog discovery plus constrained UCP checkout **preparation**. Checkout creates a
merchant-scoped session for an explicitly configured merchant and returns its handoff URL;
it never collects buyer/payment data, completes payment, or claims an order was placed.

The app's native multi-step checkout and demo order completion are a **device-local
sandbox** backed by deterministic fixtures. No sandbox buyer/address data or mock payment
instrument is sent to this broker. The live broker remains create-only: it exposes no
checkout get, update, cancel, or complete endpoint.

## Endpoints

| Method & path | Auth | Purpose |
|---|---|---|
| `GET /.well-known/ucp` | open | Hosted UCP agent profile (Shopify fetches this) |
| `GET /healthz` | open | Liveness + whether credentials are configured |
| `POST /catalog/search` | `x-broker-key`* | `{ "query": "...", "context"?: {...} }` → products |
| `POST /catalog/product` | `x-broker-key`* | `{ "productId": "gid://...", "selected"?: [...] }` |
| `POST /checkout/create` | `x-broker-key`* | `{ "merchantId", "items":[{"variantId","quantity"}], "idempotencyKey" }` |

\* Catalog routes require `x-broker-key` when `CRUMB_BROKER_KEY` is set. Checkout is
stricter: once a live merchant registry is configured, `CRUMB_BROKER_KEY` is mandatory;
the route fails closed with `checkout_auth_not_configured` if the deployment omitted it.

`/checkout/create` returns `prepared`, `unsupported`, `authentication_unsupported`, or
`preparation_failed`. The last result covers malformed/protocol-invalid merchant responses
and is retryable by the app. Unsupported merchants fall back to their catalog product/store
URL; they are never represented as UCP checkout success.

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
| `CRUMB_BROKER_KEY` | ✓ | required whenever live checkout merchants are configured; optional for catalog-only deployments |
| `AGENT_PROFILE_URL` | — | optional; auto-derived from the request host if unset |
| `UCP_CHECKOUT_MERCHANTS_JSON` | — | JSON object mapping stable merchant IDs to allowlisted HTTPS UCP origins; empty disables live checkout |

Example (quote as one environment value):

```json
{"merchant-id-from-catalog":"https://merchant.example"}
```

When this registry is non-empty, Crumb's hosted profile advertises
`dev.ucp.shopping.checkout` as a platform/consumer capability. It deliberately does not
publish a checkout service endpoint: each merchant remains the service provider and
Merchant of Record. It also never advertises a payment handler. The app's mock handler is
not a live UCP capability and must not appear in the hosted profile.

## Checkout preparation flow and boundaries

1. The app sends a stable merchant ID, variant IDs, quantities, and idempotency key.
2. The broker resolves the origin only from `UCP_CHECKOUT_MERCHANTS_JSON` and fetches
   `/.well-known/ucp` without redirects.
3. It intersects the merchant checkout capability with configured `UCP_VERSION`, resolves
   the advertised REST service endpoint, and posts to the normative `/checkout-sessions`
   path with `UCP-Agent`, `Request-Id`, and `Idempotency-Key` headers.
4. It validates the returned session/status and HTTPS handoff URL. The app then lets the
   buyer continue in the merchant's trusted checkout UI.

Because this broker is create-only and deliberately does not normalize order data, Create
responses are accepted only in `incomplete`, `requires_escalation`, or
`ready_for_complete`. `complete_in_progress`, `completed`, and `canceled` are rejected as
`preparation_failed` rather than surfaced as an unverified order/completion claim.

Both configured and advertised hosts receive a public-IP DNS preflight. Only HTTPS on the
default port is accepted, redirects are not followed, and requests use the bounded
`UCP_HTTP_TIMEOUT_SECONDS` timeout. Arbitrary origins from the device are never fetched.

Residual DNS risk: the HTTP/TLS library performs its own resolution after the preflight,
so an attacker controlling an allowlisted merchant's DNS could change answers between
those two operations. The allowlist makes that a trusted-onboarding risk rather than an
arbitrary-device-input risk, but it is not DNS pinning. Production should also enforce
network-layer egress denial for private, link-local, and cloud-metadata ranges (Azure
Firewall/NAT policy or equivalent) and monitor merchant registry changes.

Current deliberate limitations: exact protocol-version match only; unsigned/public
merchant checkout only; no merchant-specific OAuth, HTTP message signing, payment
instruments, checkout completion/cancel, buyer PII, AP2 mandates, or cross-merchant atomic
transaction. A merchant requiring authentication returns `authentication_unsupported`.

Production-native fulfillment updates and order completion require separate payment
provider/platform onboarding, merchant/PSP agreement, a provider-issued single-use
credential flow, privacy-policy/App Privacy changes for buyer PII, and authenticated UCP
update/complete support. Until those exist, live sessions continue through the merchant's
trusted HTTPS `continue_url`; the broker will not accept buyer or payment payloads.

## Make targets

```sh
make            # list targets
make install    # create .venv (Python 3.11+) and install deps
make test       # run unit tests (11; no network)
make run        # uvicorn --reload on :8000
make verify     # call Shopify directly via the broker's own UCPClient, using .env
make verify-kv  # same, but pull client id/secret from Key Vault (RG=rg-crumb-agent)
make smoke      # end-to-end against the DEPLOYED broker (BROKER=https://...)
make health     # curl the broker's /healthz (BROKER=https://...)
```

Two verification layers:

- **`make smoke BROKER=https://…`** — hits the deployed broker (`/healthz` then
  `/catalog/search`). The token, profile, and Shopify call all happen server-side, so this
  needs no local creds — the real "is it working?" check. Add `BROKER_KEY=…` if the broker
  requires the `x-broker-key` header.
- **`make verify`** (and `make verify-kv`) — runs the broker's `UCPClient` locally against
  Shopify using `.env` (or Key Vault) creds, for pre-deploy debugging with full output.
  Set `QUERY="..."` to change the search.

  > `verify` needs `AGENT_PROFILE_URL` to be a **public** URL Shopify can fetch (e.g. your
  > deployed broker's `/.well-known/ucp`) — a local/placeholder profile is rejected. This
  > is why the deployed-broker `smoke` is the simpler end-to-end check.

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

## Notes / confirmed against the live catalog (2026-04-08)

- **Real product shape.** A `search_catalog` product carries `media[]` (images),
  `variants[]` (each with `id`, `url`, `price`), `price_range.{min,max}`, and `{plain}`
  text objects — **not** the top-level `images`/`seller`/`buy_url`/`variant_id` we first
  guessed. `crumb_agent/models.py` now maps the real fields (image ← `media[0].url`,
  buy/handoff link ← `variants[0].url`, seller domain ← host of that URL) with the old
  names kept as tolerant fallbacks. See `tests/test_models.py` for the pinned shape.
- **`get_product` is not exposed by the GA Global Catalog.** Calling it returns
  `-32602 "Tool not found: get_product"`, so `POST /catalog/product` currently surfaces a
  502 `upstream_error`. This doesn't affect the app: `search_catalog` returns full
  product + variant data (including the buy URL), and the iOS client's `product(id:)` has
  no callers in the main flow. Revisit if/when a product-detail tool ships.
- The exact `SHOPIFY_CATALOG_URL` host comes from the Dev Dashboard.
