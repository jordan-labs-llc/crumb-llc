// Grants AcrPull to a principal on an existing ACR.
// Deployed scoped to the ACR's resource group (the registry lives in rg-crumb-prod),
// so role assignments can use the ACR resource as their scope.

@description('Name of the existing container registry')
param acrName string

@description('Principal ID (managed identity) to grant AcrPull')
param principalId string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// Built-in AcrPull role.
var acrPullRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, principalId, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
