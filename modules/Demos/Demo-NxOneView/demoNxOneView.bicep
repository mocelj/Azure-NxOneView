// This template will orchestrate a sample Numerix OneView deployment on Azure

param environment string
param prefix string
param location string = resourceGroup().location
param tags object = {}

param rgSpoke string
param rgHub string
param vNetObject object

// KV

param deployPrivateAKV bool = true

// SQL Server

param administratorLogin string
@secure()
param administratorLoginPassword string

// Calc Nodes

param vmNodeSize string 

//--------------------------------------------------------------------------

// Global parameters

resource refVNetSpoke 'Microsoft.Network/virtualNetworks@2021-03-01' existing = {
  scope: resourceGroup(rgSpoke)
  name: vNetObject.vNetName
}

var privateEndpointSubnetId = '${refVNetSpoke.id}/subnets/${vNetObject.subnets[vNetObject.positionEndpointSubnet].subnetName}'

resource refDNSzoneMongoDB 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name:  'privatelink.mongo.cosmos.azure.com'
  scope: resourceGroup(rgHub)
}

resource refDNSzoneSQLServer 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink${az.environment().suffixes.sqlServerHostname}'
  scope: resourceGroup(rgHub)
}

// we are hitting the kv naming convention limit with with name. Be careful if you change it.
var kvName = 'kv-${prefix}-nxov'

var cosmosDBName = 'cosmos-${environment}-${prefix}-nx'

var sqlServerName = 'sql-${environment}-${prefix}-nx'

// Create a managed identity which will be added to the batch pool
//------------------------------------------------------------------------

var nxovManagedIdentityName = 'id-${environment}-${prefix}-nxov'

resource nxovManagedIdentity  'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: nxovManagedIdentityName
  location: location
  tags: tags
}

// Create a key vault to store secrets and connections strings
//------------------------------------------------------------------------

module deployNxOvKV '../../../modules/azureKeyVault/azureKeyVault.bicep' = {
  name: 'dpl-${uniqueString(deployment().name,location)}-nxovKeyVault'
  params: {
    keyVaultName: kvName
    privateEndpointSubnetId: privateEndpointSubnetId
    deployPrivateKeyVault: deployPrivateAKV
    enablePurgeProtection: true
    enableSoftDelete: true
    rgDNSZone: rgHub 
    tags: tags
  }
  dependsOn: [
    nxovManagedIdentity
  ]
}

// Add initial access policies for the managed identiy and Batch Service

var kvAccessPolicyMI = [
  {
    objectId: nxovManagedIdentity.properties.principalId
    permissions: {
      secrets: [
        'get'
        'list'
        'set'
        'delete'
        'recover'
      ]
    }
    tenantId: subscription().tenantId
  }
]

// Allow the MI to access the KV

module kvPolicyManagedIdentity '../../../modules/azureKeyVault/azureKeyVaultAddAccessPolicy.bicep' = {
  name: 'dpl-${uniqueString(deployment().name,location)}-nxovKV-Policy-MI-add'
  params: {
    accessPolicy: array(kvAccessPolicyMI)
    accessPolicyAction: 'add'
    kvName: kvName
  }
  dependsOn: [
    nxovManagedIdentity
    deployNxOvKV
  ]
}

// Create required storage accounts
//------------------------------------------------------------------------

var saDefinitions = [
  {
    storageAccountName: 'sa${environment}${prefix}nxov'
    privateLinkGroupIds: 'file'
    storageAccountAccessTier: 'Hot'
    storageAccountKind: 'FileStorage'
    largeFileSharesState: 'Enabled'
    storageAccountSku: 'Premium_LRS'
    supportsHttpsTrafficOnly: false
    isHnsEnabled: false
    isNfsV3Enabled: false
    fileShareEnabledProtocol: 'NFS'
    fileShareAccessTier: 'Premium'
    fileShareQuota: 100 
    allowSharedKeyAccess: true
  }
]

module deployNxOvStorageAccounts '../../../modules/Demos/Demo-Batch-Secured/demoAzureBatch-Secured-Storage.bicep' = {
  name: 'dpl-${uniqueString(deployment().name,location)}-nxovStorageAccounts'
  params: {
    saDefinitions: saDefinitions 
    privateEndpointSubnetId: privateEndpointSubnetId
    kvName: kvName
    rgHub: rgHub
    tags: tags
  }
  dependsOn: [
    deployNxOvKV
  ]
}

// Create the CosmosDB - Mongo API service
//------------------------------------------------------------------------

var cosmosPrivateEndpoints  = [
  {
    name: '${cosmosDBName}-pl' 
    subnetResourceId: privateEndpointSubnetId
    service: 'MongoDB'
    privateDnsZoneResourceIds: [ 
      refDNSzoneMongoDB.id
    ]
  }
]

// Toy collection to test the creation of the Mongo DB service
var mongodbDatabases = [
  {
    name: 'sxx-az-mdb-x-001'
    collections: [
        {
            name: 'car_collection'
            indexes: [
                {
                    key: {
                        keys: [
                            '_id'
                        ]
                    }
                }
                {
                    key: {
                        keys: [
                            '$**'
                        ]
                    }
                }
                {
                    key: {
                        keys: [
                            'car_id'
                            'car_model'
                        ]
                    }
                    options: {
                        unique: true
                    }
                }
                {
                    key: {
                        keys: [
                            '_ts'
                        ]
                    }
                    options: {
                        expireAfterSeconds: 2629746
                    }
                }
            ]
            shardKey: {
                car_id: 'Hash'
            }
        }
      ]
    }
]

var locations = [
  {
    locationName: 'West Europe'
    failoverPriority: 0
    isZoneRedundant: false
  }
]

module cosmosDB '../../../modules/cosmosDB/deploy.bicep' = {
  name: 'dpl-${uniqueString(deployment().name,location)}-nxovCosmosDB'
  params: {
    locations: locations
    name: cosmosDBName
    automaticFailover: false
    multipleWritelocations: false
    publicNetworkAccess: 'Disabled'
    networkAclByPass: 'AzureServices'
    mongodbDatabases: mongodbDatabases
    throughput: 400
    privateEndpoints: cosmosPrivateEndpoints
    tags: tags
  }
  dependsOn: []
}

// Create the Aure SQL Server
//------------------------------------------------------------------------

var sqlDatabases = [
  {
    
      name: 'sqldb-nxov-test'
      collation: 'SQL_Latin1_General_CP1_CI_AS'
      tier: 'GeneralPurpose'
      skuName: 'GP_Gen5_2'
      maxSizeBytes: 34359738368
      licenseType: 'LicenseIncluded'  
  }
]

var sqlPrivateEndpoints  = [
  {
    name: '${sqlServerName}-pl' 
    subnetResourceId: privateEndpointSubnetId
    service: 'sqlServer'
    privateDnsZoneResourceIds: [ 
      refDNSzoneSQLServer.id
    ]
  }
]


module sqlServer '../../../modules/sqlServer/servers/deploy.bicep' = {
  name: 'dpl-${uniqueString(deployment().name,location)}-nxovSqlServer'
  params: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    name: sqlServerName
    databases: sqlDatabases
    publicNetworkAccess: 'Disabled'
    privateEndpoints: sqlPrivateEndpoints
    tags: tags
  }
}

// Create the Head Compute Node
//------------------------------------------------------------------------

var linuxVmInitScript = loadFileAsBase64('../../../modules/virtualMachines/cloud-init-jumpbox.txt')

var vmObjectHeadNode  = {
  nicName: 'nic-head-linux-'
  vmName: 'vm-head-linux-'
  vmSize: vmNodeSize
  osProfile: {
    computerName: 'NxOvHeadNode'
    adminUserName: administratorLogin
    adminPassword: administratorLoginPassword
    customData: linuxVmInitScript
  }
  imageReference: {
    publisher: 'canonical'
    offer: '0001-com-ubuntu-server-focal'
    sku: '20_04-lts-gen2'
    version: 'latest'
  }
}

module vmHeadNode '../../../modules/virtualMachines/vmSimple.bicep' = { 
  name: 'dpl-${uniqueString(deployment().name,location)}-nxovHeadNode'
  params: {
    subnetId: '${refVNetSpoke.id}/subnets/${vNetObject.subnets[vNetObject.positionHeadNode].subnetName}'
    vmObject: vmObjectHeadNode
    tags: tags
  }
  dependsOn: [
    deployNxOvStorageAccounts
  ]
}


// Create the Worker Nodes
//------------------------------------------------------------------------

var vmObjectWorkerNode  = {
  nicName: 'nic-worker-linux-'
  vmName: 'vm-worker-linux-'
  vmSize:  vmNodeSize
  osProfile: {
    computerName: 'NxOvWorkerNode-'
    adminUserName: administratorLogin
    adminPassword: administratorLoginPassword
    customData: linuxVmInitScript
  }
  imageReference: {
    publisher: 'canonical'
    offer: '0001-com-ubuntu-server-focal'
    sku: '20_04-lts-gen2'
    version: 'latest'
  }
}

module vmWorkerNodes '../../../modules/virtualMachines/vmSimple.bicep' = { 
  name: 'dpl-${uniqueString(deployment().name,location)}-nxovWorkerNode'
  params: {
    subnetId: '${refVNetSpoke.id}/subnets/${vNetObject.subnets[vNetObject.positionWorkerNodes].subnetName}'
    vmObject: vmObjectWorkerNode
    vmCount: 2
    tags: tags
  }
  dependsOn: [
    deployNxOvStorageAccounts
  ]
}
