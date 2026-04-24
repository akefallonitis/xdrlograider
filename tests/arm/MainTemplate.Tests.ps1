#Requires -Modules Pester

BeforeAll {
    $script:DeployDir = Join-Path $PSScriptRoot '..' '..' 'deploy'
    $script:MainTemplatePath  = Join-Path $script:DeployDir 'compiled' 'mainTemplate.json'
    $script:UiDefinitionPath  = Join-Path $script:DeployDir 'compiled' 'createUiDefinition.json'
    $script:BicepMainPath     = Join-Path $script:DeployDir 'main.bicep'
}

Describe 'ARM template files — presence' {
    It 'mainTemplate.json exists' {
        Test-Path $script:MainTemplatePath | Should -BeTrue
    }

    It 'createUiDefinition.json exists' {
        Test-Path $script:UiDefinitionPath | Should -BeTrue
    }

    It 'main.bicep source exists' {
        Test-Path $script:BicepMainPath | Should -BeTrue
    }
}

Describe 'mainTemplate.json — schema + structure' {
    BeforeAll {
        $script:MainTemplate = Get-Content $script:MainTemplatePath -Raw | ConvertFrom-Json
    }

    It 'has a valid ARM $schema' {
        $script:MainTemplate.'$schema' | Should -Match 'schema\.management\.azure\.com.*deploymentTemplate'
    }

    It 'has required top-level keys' {
        foreach ($key in 'contentVersion', 'parameters', 'variables', 'resources', 'outputs') {
            $script:MainTemplate.PSObject.Properties[$key] | Should -Not -BeNullOrEmpty
        }
    }

    It 'declares projectPrefix parameter with valid constraints' {
        $p = $script:MainTemplate.parameters.projectPrefix
        $p | Should -Not -BeNullOrEmpty
        $p.type | Should -Be 'string'
        $p.minLength | Should -Be 3
        $p.maxLength | Should -Be 12
    }

    It 'declares authMethod parameter with validation' {
        $p = $script:MainTemplate.parameters.authMethod
        $p | Should -Not -BeNullOrEmpty
        $p.allowedValues | Should -Contain 'passkey'
        $p.allowedValues | Should -Contain 'credentials_totp'
    }

    It 'declares serviceAccountUpn parameter' {
        $script:MainTemplate.parameters.serviceAccountUpn | Should -Not -BeNullOrEmpty
    }

    It 'existingWorkspaceId is REQUIRED (no default value)' {
        $p = $script:MainTemplate.parameters.existingWorkspaceId
        $p | Should -Not -BeNullOrEmpty
        $p.PSObject.Properties['defaultValue'] | Should -BeNullOrEmpty
        $p.minLength | Should -Be 1
    }

    It 'workspaceLocation is REQUIRED' {
        $p = $script:MainTemplate.parameters.workspaceLocation
        $p | Should -Not -BeNullOrEmpty
        $p.minLength | Should -Be 1
    }

    It 'has NO workspace-creation resource (workspace must pre-exist)' {
        $types = $script:MainTemplate.resources | ForEach-Object { $_.type }
        $types | Should -Not -Contain 'Microsoft.OperationalInsights/workspaces'
    }

    It 'creates core connector resource types' {
        $types = $script:MainTemplate.resources | ForEach-Object { $_.type } | Sort-Object -Unique
        $types | Should -Contain 'Microsoft.Storage/storageAccounts'
        $types | Should -Contain 'Microsoft.KeyVault/vaults'
        $types | Should -Contain 'Microsoft.Web/sites'
        $types | Should -Contain 'Microsoft.Web/serverfarms'
        $types | Should -Contain 'Microsoft.Insights/components'
        $types | Should -Contain 'Microsoft.Insights/dataCollectionEndpoints'
        $types | Should -Contain 'Microsoft.Insights/dataCollectionRules'
        $types | Should -Contain 'Microsoft.Authorization/roleAssignments'
        $types | Should -Contain 'Microsoft.Resources/deployments'
    }

    It 'Function App has SystemAssigned managed identity' {
        $funcApp = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $funcApp.identity.type | Should -Be 'SystemAssigned'
    }

    It 'creates exactly 3 role assignments for the MI (KV Secrets User, Storage Table Contributor, Monitoring Metrics Publisher)' {
        $roleAssignments = @($script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' })
        $roleAssignments.Count | Should -Be 3
    }

    It 'has a nested deployment for cross-RG custom tables (54)' {
        $nestedDeployments = @($script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' })
        $nestedDeployments.Count | Should -BeGreaterOrEqual 2  # customTables + sentinelContent
        $customTablesDeploy = $nestedDeployments | Where-Object { $_.name -match 'customTables' }
        $customTablesDeploy | Should -Not -BeNullOrEmpty
        $customTablesDeploy.subscriptionId | Should -Not -BeNullOrEmpty  # cross-subscription capable
        $customTablesDeploy.resourceGroup  | Should -Not -BeNullOrEmpty  # cross-RG
    }

    It 'has a nested deployment for cross-RG Sentinel content' {
        $sentinelDeploy = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'sentinelContent' }
        $sentinelDeploy | Should -Not -BeNullOrEmpty
        $sentinelDeploy.properties.templateLink.uri | Should -Match 'sentinelContent\.json'
    }

    It 'DCE + DCR use workspaceLocation (not connectorLocation)' {
        $dce = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionEndpoints' } | Select-Object -First 1
        $dcr = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules'    } | Select-Object -First 1
        $dce.location | Should -Be "[parameters('workspaceLocation')]"
        $dcr.location | Should -Be "[parameters('workspaceLocation')]"
    }

    It 'DCE does NOT have a `kind` property (the AMA-era label)' {
        $dce = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionEndpoints' } | Select-Object -First 1
        $dce.PSObject.Properties['kind'] | Should -BeNullOrEmpty
    }

    It 'outputs keyVaultName, dceEndpoint, dcrImmutableId, workspace context' {
        $script:MainTemplate.outputs.keyVaultName      | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.dceEndpoint       | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.dcrImmutableId    | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.workspaceId       | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.workspaceRg       | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.workspaceLocation | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.postDeployCommand | Should -Not -BeNullOrEmpty
    }
}

Describe 'createUiDefinition.json — schema + structure' {
    BeforeAll {
        $script:UiDef = Get-Content $script:UiDefinitionPath -Raw | ConvertFrom-Json
    }

    It 'has correct handler' {
        $script:UiDef.handler | Should -Be 'Microsoft.Azure.CreateUIDef'
    }

    It 'has schema property' {
        $script:UiDef.'$schema' | Should -Match 'schema\.management\.azure\.com.*CreateUIDefinition'
    }

    It 'declares basics elements' {
        $script:UiDef.parameters.basics | Should -Not -BeNullOrEmpty
    }

    It 'has authentication step' {
        $authStep = $script:UiDef.parameters.steps | Where-Object name -eq 'authSettings'
        $authStep | Should -Not -BeNullOrEmpty
    }

    It 'outputs match mainTemplate parameters' {
        $outputs = $script:UiDef.parameters.outputs.PSObject.Properties.Name
        foreach ($requiredOutput in 'projectPrefix', 'serviceAccountUpn', 'authMethod', 'existingWorkspaceId', 'workspaceLocation') {
            $outputs | Should -Contain $requiredOutput
        }
    }

    It 'has workspaceSettings step requiring existingWorkspaceId + workspaceLocation' {
        $wsStep = $script:UiDef.parameters.steps | Where-Object name -eq 'workspaceSettings'
        $wsStep | Should -Not -BeNullOrEmpty
        $wsIdElement  = $wsStep.elements | Where-Object name -eq 'existingWorkspaceId'
        $wsLocElement = $wsStep.elements | Where-Object name -eq 'workspaceLocation'
        $wsIdElement.constraints.required  | Should -BeTrue
        $wsLocElement.constraints.required | Should -BeTrue
    }
}

Describe 'Bicep source — files present' {
    It 'main.bicep is non-empty' {
        (Get-Content $script:BicepMainPath -Raw).Length | Should -BeGreaterThan 500
    }

    It 'has modular submodules (no log-analytics.bicep — workspace is external)' {
        $modulesDir = Join-Path $script:DeployDir 'modules'
        $modules = Get-ChildItem -Path $modulesDir -Filter '*.bicep'
        $modules.Count | Should -BeGreaterOrEqual 6  # storage, key-vault, app-insights, function-app, dce-dcr, custom-tables, role-assignments, data-connector
        $moduleNames = $modules | ForEach-Object { $_.BaseName }
        $moduleNames | Should -Not -Contain 'log-analytics'  # deleted in v1.0
    }

    It 'main.bicep requires existingWorkspaceId + workspaceLocation (no defaults)' {
        $bicep = Get-Content $script:BicepMainPath -Raw
        $bicep | Should -Match "param existingWorkspaceId string\b"
        $bicep | Should -Match "param workspaceLocation string\b"
        $bicep | Should -Match "@minLength\(1\)"   # Both required params carry minLength(1)
    }

    It 'main.bicep uses cross-RG scope for custom-tables module' {
        $bicep = Get-Content $script:BicepMainPath -Raw
        $bicep | Should -Match "scope:\s*resourceGroup\(workspaceSubscriptionId,\s*workspaceResourceGroup\)"
    }
}

Describe 'DCR streams — completeness' {
    It 'DCR includes 45 MDE_*_CL data stream declarations + 2 operational tables (v0.1.0-beta.1)' {
        # v0.1.0-beta.1: 45 = 15 P0 + 7 P1 + 4 P2 + 8 P3 + 5 P5 + 2 P6 + 4 P7
        # v0.1.0-beta.1 removals (2 WRITE endpoints per XDRInternals):
        #   MDE_CriticalAssets_CL, MDE_DeviceCriticality_CL.
        # Earlier v1.0.2 removals (NO_PUBLIC_API):
        #   MDE_AsrRulesConfig_CL, MDE_AntiRansomwareConfig_CL,
        #   MDE_ControlledFolderAccess_CL, MDE_NetworkProtectionConfig_CL,
        #   MDE_ApprovalAssignments_CL.
        $dceDcrBicep = Get-Content (Join-Path $script:DeployDir 'modules' 'dce-dcr.bicep') -Raw
        $streams = [regex]::Matches($dceDcrBicep, "'(MDE_\w+_CL)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $streams.Count | Should -BeGreaterOrEqual 47  # 45 data streams + Heartbeat + AuthTestResult
    }

    It 'DCR has NO dropped streams (v1.0.0 P4 + v1.0.2 + v0.1.0-beta.1 removals)' {
        $dceDcrBicep = Get-Content (Join-Path $script:DeployDir 'modules' 'dce-dcr.bicep') -Raw
        # v1.0.0 early drops
        $dceDcrBicep | Should -Not -Match 'MDE_AirDecisions'
        $dceDcrBicep | Should -Not -Match 'MDE_InvestigationPackage'
        $dceDcrBicep | Should -Not -Match 'MDE_DeviceTimeline'
        # v1.0.2 NO_PUBLIC_API removals
        $dceDcrBicep | Should -Not -Match 'MDE_AsrRulesConfig_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_AntiRansomwareConfig_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_ControlledFolderAccess_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_NetworkProtectionConfig_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_ApprovalAssignments_CL'
        # v0.1.0-beta.1 write-endpoint removals
        $dceDcrBicep | Should -Not -Match 'MDE_CriticalAssets_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_DeviceCriticality_CL'
    }
}
