// Seeds a single secret into an existing Key Vault.

@description('Existing Key Vault name')
param keyVaultName string

@description('Secret name')
param secretName string

@description('Secret value')
@secure()
param secretValue string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: secretName
  properties: {
    value: secretValue
  }
}

output name string = secret.name
