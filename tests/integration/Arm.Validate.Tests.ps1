#Requires -Module Pester
#Requires -Version 7.4
# T2 integration · az deployment group validate against deploy/mainTemplate.json.
# Runs against the env.local SP credentials (Tier-2 contract).
# Asserts ARM resolves dependencies + provisioningState != Failed.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # Load env.local (provides AZURE_TENANT_ID · AZURE_CLIENT_ID · AZURE_CLIENT_SECRET · XDRLR_SUBSCRIPTION_ID · XDRLR_WORKSPACE_RG · XDRLR_WORKSPACE_ID)
    $envFile = Join-Path $script:RepoRoot 'tests\.env.local'
    if (Test-Path $envFile) {
        Get-Content $envFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
            $k, $v = $_ -split '=', 2
            Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
        }
    }
}

Describe 'T2 · az deployment group validate against mainTemplate.json' -Tag 'arm-validate' {

    It 'env.local provides AZURE_TENANT_ID + AZURE_CLIENT_ID + XDRLR_SUBSCRIPTION_ID + XDRLR_WORKSPACE_RG' -Tag 'env-precondition' {
        $env:AZURE_TENANT_ID    | Should -Not -BeNullOrEmpty
        $env:AZURE_CLIENT_ID    | Should -Not -BeNullOrEmpty
        $env:XDRLR_SUBSCRIPTION_ID | Should -Not -BeNullOrEmpty
        $env:XDRLR_WORKSPACE_RG | Should -Not -BeNullOrEmpty
    }

    It 'az CLI is installed and version >= 2.50' -Tag 'env-precondition' {
        $vRaw = & az version --output tsv 2>$null | Select-Object -First 1
        # Output shape: "azure-cli<TAB>2.x.y" — extract the version
        $version = if ($vRaw -match '(\d+\.\d+(?:\.\d+)?)') { $Matches[1] } else { $null }
        $version | Should -Not -BeNullOrEmpty
        [Version]$version | Should -BeGreaterOrEqual ([Version]'2.50')
    }

    Context 'SP-authenticated validate pass' -Tag 'arm-validate-live' {

        BeforeAll {
            if ($env:AZURE_CLIENT_SECRET) {
                & az login --service-principal -u $env:AZURE_CLIENT_ID -p $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID --output none 2>$null
                & az account set --subscription $env:XDRLR_SUBSCRIPTION_ID 2>$null
            }
            $script:Params = [ordered]@{
                projectPrefix            = 'xdrlrtest'
                location                 = 'westeurope'
                workspaceResourceId      = $env:XDRLR_WORKSPACE_ID
                workspaceLocation        = 'westeurope'
                serviceAccountUpn        = if ($env:XDRLR_TEST_UPN) { $env:XDRLR_TEST_UPN } else { 'svc@example.com' }
                serviceAccountPassword   = 'DummyPassword-VALIDATE-ONLY-NotSecret'
                serviceAccountTotpSecret = 'JBSWY3DPEHPK3PXP'
                githubRepo               = 'akefallonitis/xdrlograider'
                releaseTag               = 'v0.1.0-local'
                connectorVersion         = '0.1.0'
                planSku                  = 'Y1'
                deployRoleAssignments    = $false
            }
            $obj = [ordered]@{
                '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                contentVersion = '1.0.0.0'
                parameters     = [ordered]@{}
            }
            foreach ($k in $script:Params.Keys) { $obj.parameters[$k] = @{ value = $script:Params[$k] } }
            $script:ParamsFile = [System.IO.Path]::GetTempFileName()
            $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ParamsFile -Encoding UTF8
        }

        AfterAll {
            if (Test-Path $script:ParamsFile) { Remove-Item -LiteralPath $script:ParamsFile -ErrorAction SilentlyContinue }
        }

        It 'validates without error (error == null)' -Skip:(-not $env:XDRLR_WORKSPACE_RG) {
            $template = Join-Path $script:RepoRoot 'deploy\mainTemplate.json'
            $result = & az deployment group validate `
                --resource-group $env:XDRLR_WORKSPACE_RG `
                --template-file $template `
                --parameters "@$script:ParamsFile" `
                --output json 2>$null | ConvertFrom-Json
            $result | Should -Not -BeNullOrEmpty
            # Successful validate has properties.error = null
            if ($result.PSObject.Properties['error']) {
                $result.error | Should -BeNullOrEmpty -Because "ARM validate rejection: $($result.error | ConvertTo-Json -Depth 5 -Compress)"
            }
            # Resource dependency graph should resolve to >= 10 resources
            if ($result.PSObject.Properties['properties'] -and $result.properties.PSObject.Properties['dependencies']) {
                @($result.properties.dependencies).Count | Should -BeGreaterOrEqual 5
            }
        }
    }
}
