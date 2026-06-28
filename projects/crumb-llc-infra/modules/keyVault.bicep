// Key Vault for the broker's Shopify credentials.
// Uses access policies (immediate effect, no RBAC propagation wait).

@description('Key Vault name (3-24 chars, alphanumeric + hyphens)')
param name string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('Tenant ID')
param tenantId string = subscription().tenantId

@description('Access policies granting secret read to managed identities')
param accessPolicies array = []

@description('Enable purge protection (recommended for prod)')
param enablePurgeProtection bool = false

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: enablePurgeProtection ? true : null
    accessPolicies: accessPolicies
  }
}

output id string = keyVault.id
output name string = keyVault.name
output vaultUri string = keyVault.properties.vaultUri
