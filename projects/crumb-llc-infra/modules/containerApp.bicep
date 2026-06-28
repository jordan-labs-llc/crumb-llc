// Container App (Consumption, scale-to-zero) for the broker.
// Pulls its image from a registry (possibly in another resource group) using a
// user-assigned managed identity — so `acrLoginServer` is passed as a string rather than
// referenced as a resource here.

@description('Container app name')
param name string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('Container Apps Environment resource ID')
param environmentId string

@description('Registry login server, e.g. acrcrumbprod.azurecr.io')
param acrLoginServer string

@description('Full container image reference')
param image string

@description('Target container port')
param targetPort int = 8000

@description('Min replicas (0 = scale to zero)')
param minReplicas int = 0

@description('Max replicas')
param maxReplicas int = 5

@description('User-assigned managed identity resource ID (ACR pull + Key Vault refs)')
param identityId string

@description('Environment variables ({name, value} or {name, secretRef})')
param env array = []

@description('Secrets ({name, keyVaultUrl, identity})')
param secrets array = []

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: acrLoginServer
          identity: identityId
        }
      ]
      secrets: secrets
    }
    template: {
      containers: [
        {
          name: 'broker'
          image: image
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: env
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
output name string = app.name
