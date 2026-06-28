// Crumb UCP broker — lean, stateless footprint on Azure Container Apps.
//
// Container Apps (not Functions) because this subscription has zero App Service VM quota;
// ACA Consumption is available (prod uses it), scales to zero, and is just as cheap.
//
// Deploys into a resource group (create it first — see deploy.sh):
//   Container Apps Environment + Container App (scale-to-zero) + Key Vault + user-assigned
//   identity. The image is pulled from the existing `acrcrumbprod` registry (in
//   rg-crumb-prod) via an AcrPull role on the managed identity. No new ACR/Postgres/Search.
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

@description('Optional broker access key — required as the x-broker-key header when set. Seeded into Key Vault when provided.')
@secure()
param brokerKey string = ''

@description('Existing container registry name')
param acrName string = 'acrcrumbprod'

@description('Resource group of the existing container registry')
param acrResourceGroup string = 'rg-crumb-prod'

@description('Registry login server')
param acrLoginServer string = 'acrcrumbprod.azurecr.io'

@description('Image tag to deploy')
param imageTag string = 'latest'

// ---------------------------------------------------------------------------- names

var suffix = uniqueString(resourceGroup().id)
var tags = {
  app: 'crumb-agent'
  env: environmentName
  managedBy: 'bicep'
}
var keyVaultName = take('kv-cagent-${suffix}', 24)
var identityName = 'id-crumb-agent-${environmentName}'
var envName = 'cae-crumb-agent-${environmentName}'
var appName = 'ca-crumb-agent-${environmentName}'
var image = '${acrLoginServer}/crumb-agent:${imageTag}'

var credsProvided = !empty(shopifyClientId) && !empty(shopifyClientSecret)
var brokerKeyProvided = !empty(brokerKey)

// -------------------------------------------------------------------------- identity

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

// ----------------------------------------------------------------------- acr pull role

// Scoped to the registry's resource group so the assignment can target the ACR resource.
module acrPull 'modules/acrPullRole.bicep' = {
  name: 'acr-pull-role'
  scope: resourceGroup(acrResourceGroup)
  params: {
    acrName: acrName
    principalId: identity.properties.principalId
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

module kvBrokerKey 'modules/keyVaultSecret.bicep' = if (brokerKeyProvided) {
  name: 'kv-broker-key'
  params: {
    keyVaultName: keyVault.outputs.name
    secretName: 'crumb-broker-key'
    secretValue: brokerKey
  }
}

// ---------------------------------------------------------------- container apps env

module containerEnv 'modules/containerAppsEnv.bicep' = {
  name: 'container-env'
  params: {
    name: envName
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------- app settings

var kvUri = keyVault.outputs.vaultUri

var appSecrets = concat(
  credsProvided ? [
    {
      name: 'shopify-ucp-client-id'
      keyVaultUrl: '${kvUri}secrets/shopify-ucp-client-id'
      identity: identity.id
    }
    {
      name: 'shopify-ucp-client-secret'
      keyVaultUrl: '${kvUri}secrets/shopify-ucp-client-secret'
      identity: identity.id
    }
  ] : [],
  brokerKeyProvided ? [
    {
      name: 'crumb-broker-key'
      keyVaultUrl: '${kvUri}secrets/crumb-broker-key'
      identity: identity.id
    }
  ] : []
)

var baseEnv = [
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

var secretEnv = concat(
  credsProvided ? [
    {
      name: 'SHOPIFY_UCP_CLIENT_ID'
      secretRef: 'shopify-ucp-client-id'
    }
    {
      name: 'SHOPIFY_UCP_CLIENT_SECRET'
      secretRef: 'shopify-ucp-client-secret'
    }
  ] : [],
  brokerKeyProvided ? [
    {
      name: 'CRUMB_BROKER_KEY'
      secretRef: 'crumb-broker-key'
    }
  ] : []
)

// ----------------------------------------------------------------------- container app

module containerApp 'modules/containerApp.bicep' = {
  name: 'container-app'
  params: {
    name: appName
    location: location
    tags: tags
    environmentId: containerEnv.outputs.id
    acrLoginServer: acrLoginServer
    image: image
    identityId: identity.id
    env: concat(baseEnv, secretEnv)
    secrets: appSecrets
  }
  dependsOn: [
    acrPull
    kvClientId
    kvClientSecret
    kvBrokerKey
  ]
}

// -------------------------------------------------------------------------- outputs

output containerAppName string = containerApp.outputs.name
output brokerBaseUrl string = 'https://${containerApp.outputs.fqdn}'
output agentProfileUrl string = 'https://${containerApp.outputs.fqdn}/.well-known/ucp'
output keyVaultName string = keyVault.outputs.name
output credentialsSeeded bool = credsProvided
