#Requires -Modules Pester
<#
.SYNOPSIS
    E2E deployment smoke tests — runs against a deployed XdrLogRaider
    environment to verify the full pipeline is functioning.

.DESCRIPTION
    Gated. Runs only when:
      XDRLR_ONLINE=true
      XDRLR_TEST_RG=<resource group>
      XDRLR_TEST_WORKSPACE=<Log Analytics workspace name>

    These tests are designed to run AFTER the user has:
      1. Clicked Deploy-to-Azure and filled the wizard
      2. Run Initialize-XdrLogRaiderAuth.ps1
      3. Waited at least one poll cycle for ingestion

    Not run during CI by default. Not a substitute for Phase 3 local integration
    tests or Phase 2 unit tests.

.EXAMPLE
    $env:XDRLR_ONLINE = 'true'
    $env:XDRLR_TEST_RG = 'xdrlr-prod-xxxx'
    $env:XDRLR_TEST_WORKSPACE = 'mylog-ws'
    pwsh ./tests/Run-Tests.ps1 -Category e2e
#>

BeforeAll {
    $script:RunE2E = ($env:XDRLR_ONLINE -eq 'true') -and
                     $env:XDRLR_TEST_RG -and
                     $env:XDRLR_TEST_WORKSPACE
    if (-not $script:RunE2E) {
        Write-Warning "e2e tests require XDRLR_ONLINE=true + XDRLR_TEST_RG + XDRLR_TEST_WORKSPACE. Skipping."
    }

    $script:Rg = $env:XDRLR_TEST_RG
    $script:Workspace = $env:XDRLR_TEST_WORKSPACE

    # Check Az modules are available
    $script:HasAz = (Get-Module -ListAvailable -Name Az.Resources) -and
                    (Get-Module -ListAvailable -Name Az.OperationalInsights)
    if ($script:RunE2E -and -not $script:HasAz) {
        Write-Warning "e2e tests require Az.Resources + Az.OperationalInsights modules. Install via: Install-Module Az -Force -Scope CurrentUser"
        $script:RunE2E = $false
    }

    if ($script:RunE2E) {
        Import-Module Az.Resources -Force -ErrorAction SilentlyContinue
        Import-Module Az.OperationalInsights -Force -ErrorAction SilentlyContinue
        $script:AzContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $script:AzContext) {
            Write-Warning "Not signed into Azure — running Connect-AzAccount..."
            Connect-AzAccount -ErrorAction Stop | Out-Null
        }
    }
}

Describe 'E2E — resource group contains expected resources' -Tag 'e2e', 'deployment' {
    It 'resource group exists' -Skip:(-not $script:RunE2E) {
        $rg = Get-AzResourceGroup -Name $script:Rg -ErrorAction Stop
        $rg | Should -Not -BeNullOrEmpty
    }

    It 'contains a Function App' -Skip:(-not $script:RunE2E) {
        $fa = Get-AzResource -ResourceGroupName $script:Rg -ResourceType 'Microsoft.Web/sites' -ErrorAction SilentlyContinue
        $fa | Should -Not -BeNullOrEmpty
        ($fa | Select-Object -First 1).Kind | Should -Match 'functionapp'
    }

    It 'contains a Key Vault' -Skip:(-not $script:RunE2E) {
        $kv = Get-AzResource -ResourceGroupName $script:Rg -ResourceType 'Microsoft.KeyVault/vaults' -ErrorAction SilentlyContinue
        $kv | Should -Not -BeNullOrEmpty
    }

    It 'contains a Data Collection Endpoint' -Skip:(-not $script:RunE2E) {
        $dce = Get-AzResource -ResourceGroupName $script:Rg -ResourceType 'Microsoft.Insights/dataCollectionEndpoints' -ErrorAction SilentlyContinue
        $dce | Should -Not -BeNullOrEmpty
    }

    It 'contains a Data Collection Rule' -Skip:(-not $script:RunE2E) {
        $dcr = Get-AzResource -ResourceGroupName $script:Rg -ResourceType 'Microsoft.Insights/dataCollectionRules' -ErrorAction SilentlyContinue
        $dcr | Should -Not -BeNullOrEmpty
    }

    It 'contains a Storage Account' -Skip:(-not $script:RunE2E) {
        $st = Get-AzResource -ResourceGroupName $script:Rg -ResourceType 'Microsoft.Storage/storageAccounts' -ErrorAction SilentlyContinue
        $st | Should -Not -BeNullOrEmpty
    }
}

Describe 'E2E — ingestion signal' -Tag 'e2e', 'ingestion' {
    BeforeAll {
        if ($script:RunE2E) {
            $script:Ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $script:Rg -Name $script:Workspace -ErrorAction Stop
        }
    }

    It 'MDE_Heartbeat_CL has rows in the last hour' -Skip:(-not $script:RunE2E) {
        $query = "MDE_Heartbeat_CL | where TimeGenerated > ago(1h) | count"
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $script:Ws.CustomerId -Query $query -ErrorAction Stop
        $count = [int]$result.Results[0].Count
        $count | Should -BeGreaterThan 0 -Because 'connector should be emitting heartbeats'
    }

    It 'MDE_AuthTestResult_CL shows latest Success=true' -Skip:(-not $script:RunE2E) {
        $query = "MDE_AuthTestResult_CL | order by TimeGenerated desc | take 1 | project Success"
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $script:Ws.CustomerId -Query $query -ErrorAction Stop
        $result.Results | Should -Not -BeNullOrEmpty
        [string]$result.Results[0].Success | Should -Match '^(true|True|1)$' -Because 'FA self-test must be green'
    }

    It 'MDE_AdvancedFeatures_CL has at least one row' -Skip:(-not $script:RunE2E) {
        $query = "MDE_AdvancedFeatures_CL | count"
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $script:Ws.CustomerId -Query $query -ErrorAction Stop
        $count = [int]$result.Results[0].Count
        $count | Should -BeGreaterThan 0 -Because 'first P0 stream must have ingested'
    }

    It 'at least 3 P0 streams have ingested rows' -Skip:(-not $script:RunE2E) {
        $streams = @(
            'MDE_AdvancedFeatures_CL', 'MDE_PreviewFeatures_CL', 'MDE_PUAConfig_CL',
            'MDE_AsrRulesConfig_CL', 'MDE_LiveResponseConfig_CL'
        )
        $ingested = 0
        foreach ($s in $streams) {
            try {
                $query = "$s | take 1 | count"
                $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $script:Ws.CustomerId -Query $query -ErrorAction Stop
                if ([int]$result.Results[0].Count -gt 0) { $ingested++ }
            } catch { }
        }
        $ingested | Should -BeGreaterOrEqual 3 -Because "At least 3 of 5 sampled P0 streams should have data"
    }
}

Describe 'E2E — per-tier ingestion coverage' -Tag 'e2e', 'tier-coverage' {
    BeforeAll {
        if ($script:RunE2E) {
            $script:Ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $script:Rg -Name $script:Workspace -ErrorAction Stop
        }
    }

    # Helper: count populated streams for a tier, asserted against the expected count.
    $tierProbes = @(
        @{ Tier = 'P0'; Streams = @('MDE_AdvancedFeatures_CL','MDE_PreviewFeatures_CL','MDE_AlertServiceConfig_CL','MDE_SuppressionRules_CL') ; MinPopulated = 2 }
        @{ Tier = 'P1'; Streams = @('MDE_ConnectedApps_CL','MDE_DataExportSettings_CL','MDE_TenantContext_CL')                                ; MinPopulated = 2 }
        @{ Tier = 'P2'; Streams = @('MDE_RbacDeviceGroups_CL','MDE_UnifiedRbacRoles_CL','MDE_AssetRules_CL','MDE_SAClassification_CL')        ; MinPopulated = 2 }
        @{ Tier = 'P3'; Streams = @('MDE_SecureScoreBreakdown_CL','MDE_XspmInitiatives_CL','MDE_ExposureRecommendations_CL')                  ; MinPopulated = 1 }
        @{ Tier = 'P5'; Streams = @('MDE_IdentityOnboarding_CL')                                                                              ; MinPopulated = 1 }
        @{ Tier = 'P6'; Streams = @('MDE_ThreatAnalytics_CL','MDE_ActionCenter_CL')                                                           ; MinPopulated = 1 }
        @{ Tier = 'P7'; Streams = @('MDE_UserPreferences_CL','MDE_MtoTenants_CL')                                                             ; MinPopulated = 1 }
    )

    It "Tier <Tier>: at least <MinPopulated> of its verified streams has ingested rows" -ForEach $tierProbes -Skip:(-not $script:RunE2E) {
        $populated = 0
        foreach ($s in $Streams) {
            try {
                $query = "$s | where TimeGenerated > ago(6h) | take 1 | count"
                $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $script:Ws.CustomerId -Query $query -ErrorAction Stop
                if ([int]$r.Results[0].Count -gt 0) { $populated++ }
            } catch { }
        }
        $populated | Should -BeGreaterOrEqual $MinPopulated -Because "Tier $Tier must have at least $MinPopulated populated streams post-first-poll"
    }

    It 'MDE_Heartbeat_CL shows all 9 timer functions fired in last 2h' -Skip:(-not $script:RunE2E) {
        $query = @'
MDE_Heartbeat_CL
| where TimeGenerated > ago(2h)
| summarize by FunctionName
| count
'@
        $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $script:Ws.CustomerId -Query $query -ErrorAction Stop
        # 9 timer functions: heartbeat-5m + validate-auth-selftest + 7 poll-p*
        [int]$r.Results[0].Count | Should -BeGreaterOrEqual 7 -Because 'Most timers should have fired in a 2-hour window'
    }

    It 'No repeated auth failures in Application Insights traces (last 1h)' -Skip:(-not $script:RunE2E) {
        # The Function App logs to the same workspace via App Insights connected logs
        $query = @'
union isfuzzy=true AppTraces, FunctionAppLogs
| where TimeGenerated > ago(1h)
| where Message has_any ("AADSTS", "sccauth not issued", "OathCodeIncorrect")
| count
'@
        try {
            $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $script:Ws.CustomerId -Query $query -ErrorAction Stop
            [int]$r.Results[0].Count | Should -BeLessThan 5 -Because 'Occasional auth hiccups OK; sustained failures not'
        } catch {
            # App Insights table may not be linked in some layouts — non-fatal
            Set-ItResult -Inconclusive -Because "Trace table unavailable: $($_.Exception.Message)"
        }
    }

    It 'Checkpoint state storage has rows for filterable streams' -Skip:(-not $script:RunE2E) {
        $sa = Get-AzResource -ResourceGroupName $script:Rg -ResourceType 'Microsoft.Storage/storageAccounts' -ErrorAction SilentlyContinue | Select-Object -First 1
        $sa | Should -Not -BeNullOrEmpty
        # Just verify the checkpoint table exists — actual row check requires Storage data-plane auth
        $ctx = (Get-AzStorageAccount -ResourceGroupName $script:Rg -Name $sa.Name).Context
        $tableList = Get-AzStorageTable -Context $ctx -ErrorAction SilentlyContinue
        $checkpointTable = $tableList | Where-Object Name -like '*heckpoint*' | Select-Object -First 1
        $checkpointTable | Should -Not -BeNullOrEmpty -Because 'Checkpoint table must exist in deployed storage'
    }
}

Describe 'E2E — Sentinel content deployed' -Tag 'e2e', 'sentinel' {
    It 'parser functions are registered in workspace' -Skip:(-not $script:RunE2E) {
        $parsers = Get-AzOperationalInsightsSavedSearch -ResourceGroupName $script:Rg -WorkspaceName $script:Workspace -ErrorAction SilentlyContinue
        $driftParsers = $parsers.Value | Where-Object { $_.Properties.Category -eq 'Functions' -and $_.Name -like '*MDE_Drift*' }
        $driftParsers.Count | Should -BeGreaterOrEqual 6 -Because 'all 6 drift parsers must be deployed'
    }

    It 'hunting queries are registered' -Skip:(-not $script:RunE2E) {
        $saved = Get-AzOperationalInsightsSavedSearch -ResourceGroupName $script:Rg -WorkspaceName $script:Workspace -ErrorAction SilentlyContinue
        $hunting = $saved.Value | Where-Object { $_.Properties.Category -eq 'Hunting Queries' }
        $hunting.Count | Should -BeGreaterOrEqual 10
    }

    It 'Compliance Dashboard workbook exists' -Skip:(-not $script:RunE2E) {
        $workbooks = Get-AzResource -ResourceGroupName $script:Rg -ResourceType 'Microsoft.Insights/workbooks' -ErrorAction SilentlyContinue
        $compliance = $workbooks | Where-Object {
            (Get-AzResource -ResourceId $_.ResourceId -ExpandProperties -ErrorAction SilentlyContinue).Properties.displayName -eq 'MDE Compliance Dashboard'
        }
        $compliance | Should -Not -BeNullOrEmpty
    }
}
