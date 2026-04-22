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

    It 'creates core resource types' {
        $types = $script:MainTemplate.resources | ForEach-Object { $_.type } | Sort-Object -Unique
        $types | Should -Contain 'Microsoft.Storage/storageAccounts'
        $types | Should -Contain 'Microsoft.KeyVault/vaults'
        $types | Should -Contain 'Microsoft.Web/sites'
        $types | Should -Contain 'Microsoft.Web/serverfarms'
        $types | Should -Contain 'Microsoft.Insights/components'
        $types | Should -Contain 'Microsoft.Insights/dataCollectionEndpoints'
    }

    It 'Function App has SystemAssigned managed identity' {
        $funcApp = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $funcApp.identity.type | Should -Be 'SystemAssigned'
    }

    It 'outputs keyVaultName and dceEndpoint' {
        $script:MainTemplate.outputs.keyVaultName  | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.dceEndpoint   | Should -Not -BeNullOrEmpty
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
        foreach ($requiredOutput in 'projectPrefix', 'serviceAccountUpn', 'authMethod') {
            $outputs | Should -Contain $requiredOutput
        }
    }
}

Describe 'Bicep source — files present' {
    It 'main.bicep is non-empty' {
        (Get-Content $script:BicepMainPath -Raw).Length | Should -BeGreaterThan 500
    }

    It 'has modular submodules' {
        $modulesDir = Join-Path $script:DeployDir 'modules'
        $modules = Get-ChildItem -Path $modulesDir -Filter '*.bicep'
        $modules.Count | Should -BeGreaterOrEqual 6  # log-analytics, storage, key-vault, app-insights, function-app, dce-dcr, custom-tables, role-assignments, data-connector
    }
}

Describe 'DCR streams — completeness' {
    It 'DCR includes 52 MDE_*_CL stream declarations + 2 operational tables' {
        # 52 = 19 P0 + 7 P1 + 7 P2 + 8 P3 + 5 P5 + 2 P6 + 4 P7
        # (P4 DeviceTimeline + AirDecisions + InvestigationPackage dropped from v1.0 scope.)
        $dceDcrBicep = Get-Content (Join-Path $script:DeployDir 'modules' 'dce-dcr.bicep') -Raw
        $streams = [regex]::Matches($dceDcrBicep, "'(MDE_\w+_CL)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $streams.Count | Should -BeGreaterOrEqual 54  # 52 endpoint streams + Heartbeat + AuthTestResult
    }

    It 'DCR has NO dropped streams (MDE_AirDecisions, MDE_InvestigationPackage, MDE_DeviceTimeline)' {
        $dceDcrBicep = Get-Content (Join-Path $script:DeployDir 'modules' 'dce-dcr.bicep') -Raw
        $dceDcrBicep | Should -Not -Match 'MDE_AirDecisions'
        $dceDcrBicep | Should -Not -Match 'MDE_InvestigationPackage'
        $dceDcrBicep | Should -Not -Match 'MDE_DeviceTimeline'
    }
}
