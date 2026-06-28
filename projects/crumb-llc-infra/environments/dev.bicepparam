using '../main.bicep'

param environmentName = 'dev'
param location = 'eastus'

// Non-secret config. Paste the Global Catalog MCP URL from the Dev Dashboard once you
// have it (leave empty to deploy the broker in "not configured" mode for now).
param shopifyCatalogUrl = ''
param ucpVersion = '2026-04-08'

// SECRETS ARE NOT STORED HERE. Pass them at deploy time, e.g.:
//   az deployment group create -g rg-crumb-agent -f main.bicep -p environments/dev.bicepparam \
//     -p shopifyClientId=$SHOPIFY_CLIENT_ID -p shopifyClientSecret=$SHOPIFY_CLIENT_SECRET
