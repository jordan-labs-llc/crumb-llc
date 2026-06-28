using '../main.bicep'

param environmentName = 'dev'
param location = 'eastus'

// Non-secret config. Paste the Global Catalog MCP URL from the Dev Dashboard once you
// have it (Catalogs → Copy URL). Leave empty to deploy the broker in "idle" mode.
param shopifyCatalogUrl = ''
param ucpVersion = '2026-04-08'

// Secrets are NOT here and NOT passed to the deployment. Write them to Key Vault with
// ./set-secrets.sh, then flip these on (via deploy.sh: ENABLE_SHOPIFY=true ...).
param enableShopify = false
param enableBrokerKey = false
