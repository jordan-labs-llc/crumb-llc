// Linux Consumption Function App (Python) + its plan.

@description('Function App name (globally unique)')
param name string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('User-assigned managed identity resource ID (for Key Vault references)')
param identityId string

@description('Python version, e.g. 3.11')
param pythonVersion string = '3.11'

@description('App settings array ({name, value} pairs)')
param appSettings array

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${name}-plan'
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    // Linux
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: name
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // Resolve @Microsoft.KeyVault(...) references using the user-assigned identity.
    keyVaultReferenceIdentity: identityId
    siteConfig: {
      linuxFxVersion: 'Python|${pythonVersion}'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: appSettings
    }
  }
}

output name string = site.name
output defaultHostName string = site.properties.defaultHostName
