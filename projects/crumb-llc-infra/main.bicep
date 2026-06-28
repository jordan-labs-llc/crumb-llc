// Crumb UCP broker — lean, stateless Azure footprint.
//
// Deploys into a resource group (create it first, see deploy.sh):
//   Function App (Linux Consumption, Python) + Storage + Key Vault + user-assigned
//   identity + App Insights/Log Analytics. No ACR, Postgres, or AI Search.
//
// Secrets are NOT in source. Pass them at deploy time; they are seeded into Key Vault and
// surfaced to the app as Key Vault references resolved via the managed identity.

targetScope = 'resourceGroup'

@description('Azure region')
param location string = resourceGroup().location

@description('Environment name (dev, prod, ...)')
param environmentName string = 'dev'

@description('Shopify UCP client id (Dev Dashboard → Catalogs → Get an API key). Seeded into Key Vault when provided.')
@secure()
param shopifyClientId string = ''

@description('Shopify UCP client secret. Seeded into Key Vault when provided.')
@secure()
param shopifyClientSecret string = ''

@description('Global Catalog MCP endpoint URL (Dev Dashboard → Catalogs → Copy URL)')
param shopifyCatalogUrl string = ''

@description('UCP protocol version advertised by the agent profile')
param ucpVersion string = '2026-04-08'

// ---------------------------------------------------------------------------- names

var suffix = uniqueString(resourceGroup().id)
var tags = {
  app: 'crumb-agent'
  env: environmentName
  managedBy: 'bicep'
}
var storageName = take('stcrumbagent${suffix}', 24)
var keyVaultName = take('kv-cagent-${suffix}', 24)
var functionAppName = 'func-crumb-agent-${take(suffix, 8)}'
var lawName = 'law-crumb-agent-${environmentName}'
var appInsightsName = 'appi-crumb-agent-${environmentName}'
var identityName = 'id-crumb-agent-${environmentName}'

var credsProvided = !empty(shopifyClientId) && !empty(shopifyClientSecret)

// -------------------------------------------------------------------------- identity

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

// --------------------------------------------------------------------------- storage

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

// ------------------------------------------------------------------------ monitoring

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// -------------------------------------------------------------------------- key vault

module keyVault 'modules/keyVault.bicep' = {
  name: 'keyvault'
  params: {
    name: keyVaultName
    location: location
    tags: tags
    enablePurgeProtection: environmentName == 'prod'
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: identity.properties.principalId
        permissions: {
          secrets: ['get', 'list']
        }
      }
    ]
  }
}

module kvClientId 'modules/keyVaultSecret.bicep' = if (credsProvided) {
  name: 'kv-shopify-client-id'
  params: {
    keyVaultName: keyVault.outputs.name
    secretName: 'shopify-ucp-client-id'
    secretValue: shopifyClientId
  }
}

module kvClientSecret 'modules/keyVaultSecret.bicep' = if (credsProvided) {
  name: 'kv-shopify-client-secret'
  params: {
    keyVaultName: keyVault.outputs.name
    secretName: 'shopify-ucp-client-secret'
    secretValue: shopifyClientSecret
  }
}

// ----------------------------------------------------------------------- app settings

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

var baseAppSettings = [
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'FUNCTIONS_WORKER_RUNTIME'
    value: 'python'
  }
  {
    name: 'AzureWebJobsStorage'
    value: storageConnectionString
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsights.properties.ConnectionString
  }
  {
    name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
    value: 'true'
  }
  {
    name: 'SHOPIFY_TOKEN_URL'
    value: 'https://api.shopify.com/auth/access_token'
  }
  {
    name: 'UCP_VERSION'
    value: ucpVersion
  }
  {
    name: 'SHOPIFY_CATALOG_URL'
    value: shopifyCatalogUrl
  }
]

// Key Vault references — only wired when the secrets were actually seeded, so an
// un-provisioned secret never surfaces as an unresolved reference.
var secretAppSettings = credsProvided ? [
  {
    name: 'SHOPIFY_UCP_CLIENT_ID'
    value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=shopify-ucp-client-id)'
  }
  {
    name: 'SHOPIFY_UCP_CLIENT_SECRET'
    value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=shopify-ucp-client-secret)'
  }
] : []

// ----------------------------------------------------------------------- function app

module functionApp 'modules/functionApp.bicep' = {
  name: 'functionapp'
  params: {
    name: functionAppName
    location: location
    tags: tags
    identityId: identity.id
    appSettings: concat(baseAppSettings, secretAppSettings)
  }
  dependsOn: [
    kvClientId
    kvClientSecret
  ]
}

// -------------------------------------------------------------------------- outputs

output functionAppName string = functionApp.outputs.name
output functionHostName string = functionApp.outputs.defaultHostName
output brokerBaseUrl string = 'https://${functionApp.outputs.defaultHostName}'
output agentProfileUrl string = 'https://${functionApp.outputs.defaultHostName}/.well-known/ucp'
output keyVaultName string = keyVault.outputs.name
output credentialsSeeded bool = credsProvided
