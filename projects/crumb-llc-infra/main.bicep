// Crumb UCP broker — lean, stateless footprint on Azure Container Apps.
//
// Container Apps (not Functions) because this subscription has zero App Service VM quota;
// ACA Consumption is available (prod uses it), scales to zero, and is just as cheap.
//
// SECRET HANDLING: this template never receives secret values. It creates the Key Vault +
// managed identity and wires the Container App to *reference* secrets by name. The secret
// VALUES are written to Key Vault out-of-band (see set-secrets.sh) and resolved at runtime
// via the managed identity. So the deployment carries no secrets.
//
// Flow: deploy (idle) → set-secrets.sh → redeploy with enableShopify=true.

targetScope = 'resourceGroup'

@description('Azure region')
param location string = resourceGroup().location

@description('Environment name (dev, prod, ...)')
param environmentName string = 'dev'

@description('Global Catalog MCP endpoint URL (Dev Dashboard → Catalogs → Copy URL). Not a secret.')
param shopifyCatalogUrl string = ''

@description('UCP protocol version advertised by the agent profile')
param ucpVersion string = '2026-04-08'

@description('Wire the Shopify Key Vault references. Set true AFTER the secrets exist in Key Vault (see set-secrets.sh).')
param enableShopify bool = false

@description('Wire the broker-key Key Vault reference (require the x-broker-key header). Set true after seeding crumb-broker-key.')
param enableBrokerKey bool = false

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

// Created empty. Secret VALUES are written by set-secrets.sh, not by this template.
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

// Container App secret references — point at Key Vault secrets that set-secrets.sh writes.
var appSecrets = concat(
  enableShopify ? [
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
  enableBrokerKey ? [
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
  enableShopify ? [
    {
      name: 'SHOPIFY_UCP_CLIENT_ID'
      secretRef: 'shopify-ucp-client-id'
    }
    {
      name: 'SHOPIFY_UCP_CLIENT_SECRET'
      secretRef: 'shopify-ucp-client-secret'
    }
  ] : [],
  enableBrokerKey ? [
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
  ]
}

// -------------------------------------------------------------------------- outputs

output containerAppName string = containerApp.outputs.name
output brokerBaseUrl string = 'https://${containerApp.outputs.fqdn}'
output agentProfileUrl string = 'https://${containerApp.outputs.fqdn}/.well-known/ucp'
output keyVaultName string = keyVault.outputs.name
output shopifyEnabled bool = enableShopify
