using '../main.bicep'

param environmentName = 'dev'
param location = 'eastus'

// Non-secret config. The Global Catalog MCP endpoint is a single fixed Shopify URL (not a
// per-store "Copy URL" — that only applies to the Storefront/single-merchant catalog).
// See https://shopify.dev/docs/agents/catalog/global-catalog. Leave empty for "idle" mode.
param shopifyCatalogUrl = 'https://catalog.shopify.com/api/ucp/mcp'
param ucpVersion = '2026-04-08'

// Secrets are NOT here and NOT passed to the deployment. Write them to Key Vault with
// ./set-secrets.sh, then flip these on (via deploy.sh: ENABLE_SHOPIFY=true ...).
param enableShopify = true
param enableBrokerKey = false
