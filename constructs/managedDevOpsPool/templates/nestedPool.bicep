@description('Required. ')
param location string

@description('Required. Defines how many resources can there be created at any given time.')
@minValue(1)
@maxValue(10000)
param maximumConcurrency int

@description('Required. The name of the subnet the agents should be deployed into.')
param subnetName string

@description('Required. The resource Id of the Virtual Network the agents should be deployed into.')
param virtualNetworkResourceId string

@description('Required. The name of the Azure DevOps agent pool to create.')
param poolName string

@description('Required. The name of the Azure DevOps organization to register the agent pools in.')
param organizationName string

@description('Optional. The Azure DevOps projects to register the agent pools in. In none is provided, the pool is only registered in the organization.')
param projectNames string[]?

@description('Required. The name of the Dev Center to use for the DevOps Infrastructure Pool. Must be lower case and may contain hyphens.')
@minLength(3)
@maxLength(26)
param devCenterName string

@description('Required. The name of the Dev Center project to use for the DevOps Infrastructure Pool.')
@minLength(3)
@maxLength(63)
param devCenterProjectName string

@description('Optional. The Azure SKU name of the machines in the pool.')
param poolSize string = 'Standard_B1ms'

@description('Optional. Defines how the machine will be handled once it executed a job.')
param agentProfile agentProfileType = {
  kind: 'Stateless'
}

@description('Required. The object ID (principal id) of the \'DevOpsInfrastructure\' Enterprise Application in your tenant.')
param devOpsInfrastructureEnterpriseApplicationObjectId string

@description('Required. The name of the Azure Compute Gallery that hosts the image of the Managed DevOps Pool.')
param computeGalleryName string

@description('Required. The name of Image Definition of the Azure Compute Gallery that hosts the image of the Managed DevOps Pool.')
param computeGalleryImageDefinitionName string

@description('Optional. The version of the image to use in the Managed DevOps Pool.')
param imageVersion string = 'latest' // Note, 'latest' is not supported by resource type

@description('Optional. The managed identity definition for the Managed DevOps Pool.')
param poolManagedIdentities managedIdentitiesType?

var formattedUserAssignedIdentities = reduce(
  map((poolManagedIdentities.?userAssignedResourceIds ?? []), (id) => { '${id}': {} }),
  {},
  (cur, next) => union(cur, next)
) // Converts the flat array to an object like { '${id1}': {}, '${id2}': {} }

var poolIdentity = !empty(poolManagedIdentities)
  ? {
      type: !empty(poolManagedIdentities.?userAssignedResourceIds ?? {}) ? 'UserAssigned' : 'None'
      userAssignedIdentities: !empty(formattedUserAssignedIdentities) ? formattedUserAssignedIdentities : null
    }
  : null

resource computeGallery 'Microsoft.Compute/galleries@2022-03-03' existing = {
  name: computeGalleryName

  resource imageDefinition 'images@2022-03-03' existing = {
    name: computeGalleryImageDefinitionName

    resource version 'versions@2022-03-03' existing = {
      name: imageVersion
    }
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: last(split(virtualNetworkResourceId, '/'))

  resource subnet 'subnets@2024-01-01' existing = {
    name: subnetName
  }
}

resource imageVersionPermission 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    computeGallery::imageDefinition.id,
    devOpsInfrastructureEnterpriseApplicationObjectId,
    subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  )
  properties: {
    principalId: devOpsInfrastructureEnterpriseApplicationObjectId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    ) // Reader
    principalType: 'ServicePrincipal'
  }
  scope: computeGallery::imageDefinition // ::imageVersion Not using imageVersion as scope to enable to principal to find 'latest'. A role assignment on 'latest' is not possible
}

resource vnetPermission 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    vnet.id,
    devOpsInfrastructureEnterpriseApplicationObjectId,
    subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  )
  properties: {
    principalId: devOpsInfrastructureEnterpriseApplicationObjectId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4d97b98b-1d4f-4787-a291-c67834d212e7'
    ) // Network Contributor
    principalType: 'ServicePrincipal'
  }
  scope: vnet
}

resource devCenter 'Microsoft.DevCenter/devcenters@2024-02-01' = {
  name: devCenterName
  location: location
}

resource devCenterProject 'Microsoft.DevCenter/projects@2024-02-01' = {
  name: devCenterProjectName
  location: location
  properties: {
    devCenterId: devCenter.id
  }
}

// Requires: https://github.com/Azure/bicep-registry-modules/pull/3401
// module pool 'br/public:avm/res/dev-ops-infrastructure/pool:0.1.0' = {
//   name:
//   params: {
//     name: poolName
//     agentProfile: agentProfile
//     concurrency: maximumConcurrency
//     devCenterProjectResourceId: devCenterProject.id
//     fabricProfileSkuName: devOpsInfrastructurePoolSize
//     images:  [
//       {
//          resourceId: computeGallery::imageDefinition::imageVersion.id
//       }
//     ]
//     organizationProfile: {
//       kind: 'AzureDevOps'
//       organizations: [
//         {
//           url: 'https://dev.azure.com/${organizationName}'
//           projects: projectNames
//         }
//       ]
//     }
//   }
// }

resource name 'Microsoft.DevOpsInfrastructure/pools@2024-04-04-preview' = {
  name: poolName
  location: location
  identity: poolIdentity
  properties: {
    maximumConcurrency: maximumConcurrency
    agentProfile: agentProfile
    organizationProfile: {
      kind: 'AzureDevOps'
      organizations: [
        {
          url: 'https://dev.azure.com/${organizationName}'
          projects: projectNames
        }
      ]
    }
    devCenterProjectResourceId: devCenterProject.id
    fabricProfile: {
      sku: {
        name: poolSize
      }
      kind: 'Vmss'
      images: [
        {
          resourceId: computeGallery::imageDefinition::version.id
        }
      ]
      networkProfile: {
        subnetId: vnet::subnet.id
      }
    }
  }
  dependsOn: [
    imageVersionPermission
    vnetPermission
  ]
}

/////////////////////
//   Definitions   //
/////////////////////

@export()
@discriminator('kind')
type agentProfileType = agentStatefulType | agentStatelessType

type agentStatefulType = {
  @description('Required. Stateful profile meaning that the machines will be returned to the pool after running a job.')
  kind: 'Stateful'

  @description('Required. How long should stateful machines be kept around. The maximum is one week.')
  maxAgentLifetime: string

  @description('Required. How long should the machine be kept around after it ran a workload when there are no stand-by agents. The maximum is one week.')
  gracePeriodTimeSpan: string

  @description('Optional. Defines pool buffer/stand-by agents.')
  resourcePredictions: object?

  @discriminator('kind')
  @description('Optional. Determines how the stand-by scheme should be provided.')
  resourcePredictionsProfile: (resourcePredictionsProfileAutomaticType | resourcePredictionsProfileManualType)?
}

type agentStatelessType = {
  @description('Required. Stateless profile meaning that the machines will be cleaned up after running a job.')
  kind: 'Stateless'

  @description('Optional. Defines pool buffer/stand-by agents.')
  resourcePredictions: {
    @description('Required. The time zone in which the daysData is provided. To see the list of available time zones, see: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/default-time-zones?view=windows-11#time-zones or via PowerShell command `(Get-TimeZone -ListAvailable).StandardName`.')
    timeZone: string

    @description('Optional. The number of agents needed at a specific time.')
    @metadata({
      example: '''
      [
        {} // Sunday
        {  // Monday
          '09:00:00': 1
          '17:00:00': 0
        }
        { // Tuesday
          '09:00:00': 1
          '17:00:00': 0
        }
        { // Wednesday
          '09:00:00': 1
          '17:00:00': 0
        }
        { // Thursday
          '09:00:00': 1
          '17:00:00': 0
        }
        { // Friday
          '09:00:00': 1
          '17:00:00': 0
        }
        {} // Saturday
      ]
      '''
    })
    daysData: object[]?
  }?

  @discriminator('kind')
  @description('Optional. Determines how the stand-by scheme should be provided.')
  resourcePredictionsProfile: (resourcePredictionsProfileAutomaticType | resourcePredictionsProfileManualType)?
}

type resourcePredictionsProfileAutomaticType = {
  @description('Required. The stand-by agent scheme is determined based on historical demand.')
  kind: 'Automatic'

  @description('Required. Determines the balance between cost and performance.')
  predictionPreference: 'Balanced' | 'MostCostEffective' | 'MoreCostEffective' | 'MorePerformance' | 'BestPerformance'
}

type resourcePredictionsProfileManualType = {
  @description('Required. Customer provides the stand-by agent scheme.')
  kind: 'Manual'
}

@export()
type managedIdentitiesType = {
  @description('Optional. The resource ID(s) to assign to the resource. Required if a user assigned identity is used for encryption.')
  userAssignedResourceIds: string[]?
}
