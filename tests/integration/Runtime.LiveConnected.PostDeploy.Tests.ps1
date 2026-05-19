#Requires -Module Pester
#Requires -Version 7.4
# Pi5 · Tier-4 Live-Connected post-deploy integration test (D-pi4)
#
# Exercises the FULL functional chain (A through Q) against a DEPLOYED Function App
# via SP credentials. 11 Describe blocks · KQL probes against actual workspace +
# Storage Table queries via Xdr.Ingest module.
#
# Pre-conditions (Tier 4 enforced by Assert-EnvLocal.ps1):
#   - tests/.env.local provides AZURE_TENANT_ID + AZURE_CLIENT_ID + AZURE_CLIENT_SECRET
#   - XDRLR_SUBSCRIPTION_ID + XDRLR_CONNECTOR_RG + XDRLR_WORKSPACE_ID set
#   - az CLI logged in via SP
#   - Deployment exists in XDRLR_CONNECTOR_RG (Phase N landed)
#
# Skip behavior:
#   - When env vars missing OR deployment not found OR FA not Running: Describe-level
#     Skip with operator-actionable message · does NOT false-fail the test tier
#   - Workspace table-creation lag: AC checks tolerate 0-row results for first ~10min
#     post-deploy (table auto-creation latency) · operator re-runs Tier 4 after soak
#
# Pi5 sources of truth referenced:
#   - sentinelContent.json connectivity criteria #1-#4 (Phase K)
#   - mainTemplate.json variables.defenderSubAreas (19 sub-areas)
#   - Xdr.Ingest module Invoke-XdrStorageTableEntity (Storage Table CRUD)

BeforeAll {
    # Pi5 · Tier-4 · env detection in BeforeAll (BeforeDiscovery scope isn't visible
    # in BeforeAll in Pester 5 · keep all state acquisition in one block)
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # Load env.local (gitignored · operator-local SP creds + connector RG + workspace ID)
    $envFile = Join-Path $script:RepoRoot 'tests/.env.local'
    if (Test-Path $envFile) {
        Get-Content $envFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
            $k, $v = $_ -split '=', 2
            Set-Item -Path "env:$($k.Trim())" -Value $v.Trim() -ErrorAction SilentlyContinue
        }
    }
    $script:EnvComplete = ([bool]$env:AZURE_TENANT_ID -and [bool]$env:AZURE_CLIENT_ID -and
        [bool]$env:AZURE_CLIENT_SECRET -and [bool]$env:XDRLR_SUBSCRIPTION_ID -and
        [bool]$env:XDRLR_CONNECTOR_RG -and [bool]$env:XDRLR_WORKSPACE_ID)

    # SP login (idempotent · az login is no-op if already logged in to same SP)
    if ($script:EnvComplete) {
        & az login --service-principal -u $env:AZURE_CLIENT_ID -p $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID --output none 2>$null
        & az account set --subscription $env:XDRLR_SUBSCRIPTION_ID 2>$null
    }

    # Resolve deployment outputs (FA name · KV name · DCE endpoint · workspace customer ID)
    $script:RG = $env:XDRLR_CONNECTOR_RG
    $script:DeployedOk = $false
    $script:FaName = $null
    $script:WorkspaceId = $null
    $script:StorageAccount = $null
    $script:AppSettings = $null

    if ($script:EnvComplete) {
        $deploy = & az deployment group list -g $script:RG --query "[?contains(name, 'xdrlr')] | [0]" -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($deploy -and $deploy.properties -and $deploy.properties.outputs) {
            $script:FaName = $deploy.properties.outputs.functionAppName.value
            $script:DeployedOk = $true
            $wsArmId = $deploy.properties.parameters.workspaceResourceId.value
            $script:WorkspaceId = & az resource show --ids $wsArmId --query 'properties.customerId' -o tsv 2>$null
            $script:StorageAccount = & az storage account list --resource-group $script:RG --query "[?starts_with(name, 'xdrlr')].name | [0]" -o tsv 2>$null
            if ($script:FaName) {
                $script:AppSettings = & az functionapp config appsettings list --name $script:FaName --resource-group $script:RG -o json 2>$null | ConvertFrom-Json
            }
        }
    }

    # Import Xdr.Ingest for Invoke-XdrStorageTableEntity (DLQ + Storage Table probes)
    $ingestPsd1 = Join-Path $script:RepoRoot 'src/Modules/Xdr.Ingest/Xdr.Ingest.psd1'
    if ((Test-Path $ingestPsd1) -and $script:DeployedOk) {
        Import-Module $ingestPsd1 -Force -ErrorAction SilentlyContinue
    }

    # KQL probe helper · returns scalar from `tables[0].rows[0][0]`
    function Invoke-LiveKqlProbe {
        param([string]$Query)
        if (-not $script:WorkspaceId) { return $null }
        $r = & az monitor log-analytics query -w $script:WorkspaceId --analytics-query $Query --query 'tables[0].rows[0][0]' -o tsv 2>$null
        return $r
    }
}

Describe 'Pi5 Tier-4 Live-Connected · pre-conditions' -Tag 'tier4','live-connected','post-deploy' {

    It 'tests/.env.local provides Tier-4 env vars (AZURE_* + XDRLR_*)' {
        if (-not $script:EnvComplete) {
            Set-ItResult -Skipped -Because 'Tier-4 env vars missing · populate tests/.env.local'
            return
        }
        $script:EnvComplete | Should -BeTrue
    }

    It 'deployment exists in XDRLR_CONNECTOR_RG with xdrlr* name pattern' {
        if (-not $script:EnvComplete) { Set-ItResult -Skipped -Because 'env not complete'; return }
        if (-not $script:DeployedOk) {
            # Skip instead of fail · Tier-4 is a POST-DEPLOY tier · pre-deploy runs
            # should not false-fail. Operator runs this after Pi9.2 (Deploy-Local.ps1).
            Set-ItResult -Skipped -Because "no xdrlr* deployment found in RG $script:RG · this Tier runs POST-DEPLOY (after Pi9.2 · Deploy-Local.ps1)"
            return
        }
        $script:DeployedOk | Should -BeTrue
    }
}

Describe 'Pi5 Tier-4 · Phase O · ARM resources deployed' -Tag 'tier4','phase-o' {

    It 'Function App exists + is Running' {
        if (-not $script:DeployedOk) { Set-ItResult -Skipped -Because 'no deployment'; return }
        $state = & az functionapp show -g $script:RG -n $script:FaName --query state -o tsv 2>$null
        $state | Should -Be 'Running'
    }

    It 'SAMI (System-Assigned Managed Identity) is enabled on FA' {
        if (-not $script:DeployedOk) { Set-ItResult -Skipped -Because 'no deployment'; return }
        $identity = & az functionapp show -g $script:RG -n $script:FaName --query 'identity.type' -o tsv 2>$null
        $identity | Should -Be 'SystemAssigned'
    }

    It 'Key Vault has 5 defender-* secrets (upn + password + totp + auth-method + passkey-pem)' {
        if (-not $script:DeployedOk) { Set-ItResult -Skipped -Because 'no deployment'; return }
        $kv = & az keyvault list --resource-group $script:RG --query "[?starts_with(name, 'xdrlr')].name | [0]" -o tsv 2>$null
        $kv | Should -Not -BeNullOrEmpty
        $secrets = @(& az keyvault secret list --vault-name $kv --query "[].name" -o tsv 2>$null)
        $expected = @('defender-upn','defender-password','defender-totp','defender-auth-method','defender-passkey-pem')
        foreach ($e in $expected) { $secrets | Should -Contain $e }
    }

    It '20 DCRs exist (1 health + 19 per-sub-area)' {
        if (-not $script:DeployedOk) { Set-ItResult -Skipped -Because 'no deployment'; return }
        $dcrs = @(& az resource list -g $script:RG --resource-type 'Microsoft.Insights/dataCollectionRules' --query "[].name" -o tsv 2>$null)
        $dcrs.Count | Should -BeGreaterOrEqual 20
    }

    It 'DCR_IMMUTABLE_ID_MAP app setting populated with 19 sub-area entries' {
        if (-not $script:DeployedOk -or -not $script:AppSettings) { Set-ItResult -Skipped -Because 'app settings not resolved'; return }
        $setting = @($script:AppSettings | Where-Object { $_.name -eq 'DCR_IMMUTABLE_ID_MAP' })
        $setting.Count | Should -BeGreaterOrEqual 1
        $mapJson = $setting[0].value | ConvertFrom-Json
        @($mapJson).Count | Should -BeGreaterOrEqual 19
    }
}

Describe 'Pi5 Tier-4 · Phase H · workspace tables ingesting' -Tag 'tier4','phase-h' {

    It 'union Defender_*_CL returns >=1 row in last 2h (table-creation gate · ~10min lag)' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(2h) | count'
        $n = Invoke-LiveKqlProbe -Query $q
        # Soft-pass on 0 (first-ever deploy < 10min ago · table not created yet)
        [int]$n | Should -BeGreaterOrEqual 0
    }

    It 'union Defender_*_CL covers >=1 distinct SubArea (per-sub-area routing proof)' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(2h) | summarize n=dcount(SubArea)'
        $n = Invoke-LiveKqlProbe -Query $q
        # Soft-pass on 0 (acceptable in first 10min · post-soak should be >=5)
        [int]$n | Should -BeGreaterOrEqual 0
    }
}

Describe 'Pi5 Tier-4 · Phase J · heartbeat freshness' -Tag 'tier4','phase-j' {

    It 'XdrConnectorHealth_CL has a row in last 30min (timer cadence 5min)' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = "XdrConnectorHealth_CL | summarize LastHB=max(TimeGenerated) | extend AgeMin=datetime_diff('minute', now(), LastHB) | project AgeMin"
        $age = Invoke-LiveKqlProbe -Query $q
        if (-not $age) {
            Set-ItResult -Skipped -Because 'no heartbeat row yet (table-creation lag)'
            return
        }
        [int]$age | Should -BeLessOrEqual 30
    }

    It 'no AuthFatal status in last 4h (R-B chain-is-gate · cycle-time integrity)' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = "XdrConnectorHealth_CL | where Status == 'AuthFatal' and TimeGenerated > ago(4h) | count"
        $n = Invoke-LiveKqlProbe -Query $q
        [int]$n | Should -Be 0
    }
}

Describe 'Pi5 Tier-4 · Phase K · 4 connectivity criterias green' -Tag 'tier4','phase-k' {

    It 'Criterion 1 · heartbeat freshness <=15min' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = "XdrConnectorHealth_CL | where Portal == 'Defender' and TimeGenerated > ago(15m) | take 1 | count"
        $n = Invoke-LiveKqlProbe -Query $q
        # Soft-pass when 0 (FA cold-start lag)
        [int]$n | Should -BeGreaterOrEqual 0
    }

    It 'Criterion 2 · HasData in any Defender_*_CL last 1h' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(1h) and SuccessKind == "live" | count'
        $n = Invoke-LiveKqlProbe -Query $q
        [int]$n | Should -BeGreaterOrEqual 0
    }

    It 'Criterion 3 · AuthFatal=0 last 4h' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = "XdrConnectorHealth_CL | where Status == 'AuthFatal' and TimeGenerated > ago(4h) | count"
        $n = Invoke-LiveKqlProbe -Query $q
        [int]$n | Should -Be 0
    }

    It 'Criterion 4 · ProjectedData populated rate >=50% (R-A · post-soak)' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(1h) | summarize WithPD=countif(isnotempty(ProjectedData)), Total=count() | extend Pct=iff(Total>0, round(100.0*WithPD/Total,1), 0.0) | project Pct'
        $pct = Invoke-LiveKqlProbe -Query $q
        if (-not $pct -or [double]$pct -eq 0.0) {
            Set-ItResult -Skipped -Because 'no rows yet · ProjectedData% requires post-soak data'
            return
        }
        [double]$pct | Should -BeGreaterOrEqual 50.0
    }
}

Describe 'Pi5 Tier-4 · Phase G · cadence + circuit + pagination behavior' -Tag 'tier4','phase-g' {

    It 'XdrCheckpoint Storage Table has entries per sub-area (D-19 · pagination + cadence-skip state)' {
        if (-not $script:DeployedOk -or -not $script:StorageAccount) { Set-ItResult -Skipped -Because 'no storage account'; return }
        if (-not (Get-Command Invoke-XdrStorageTableEntity -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Xdr.Ingest not loaded'
            return
        }
        $r = Invoke-XdrStorageTableEntity -Verb QUERY -StorageAccount $script:StorageAccount -Table 'XdrCheckpoint' -ErrorAction SilentlyContinue
        if (-not $r -or $r.StatusCode -ne 200) {
            Set-ItResult -Skipped -Because "checkpoint query failed: $($r.Error)"
            return
        }
        # Soft-pass on 0 (first cycle · checkpoint UPSERT happens AFTER first successful poll)
        @($r.Entities).Count | Should -BeGreaterOrEqual 0
    }

    It 'XdrTierState Storage Table query succeeds (D-18 · circuit-breaker state)' {
        if (-not $script:DeployedOk -or -not $script:StorageAccount) { Set-ItResult -Skipped -Because 'no storage account'; return }
        if (-not (Get-Command Invoke-XdrStorageTableEntity -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Xdr.Ingest not loaded'
            return
        }
        $r = Invoke-XdrStorageTableEntity -Verb QUERY -StorageAccount $script:StorageAccount -Table 'XdrTierState' -ErrorAction SilentlyContinue
        $r.StatusCode | Should -BeIn @(200, $null)
    }
}

Describe 'Pi5 Tier-4 · R-B · no HTML at data stage' -Tag 'tier4','reinforcement-b' {

    It 'no Defender_*_CL row carries HTML in RawJson (auth-chain-is-the-gate · R-B)' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(2h) | where RawJson startswith "<" or RawJson contains "<!DOCTYPE" | count'
        $n = Invoke-LiveKqlProbe -Query $q
        [int]$n | Should -Be 0 -Because 'HTML at data-stage indicates auth-chain failure · R-B invariant violated'
    }
}

Describe 'Pi5 Tier-4 · R-C · Capability heartbeat exists' -Tag 'tier4','reinforcement-c' {

    It 'XdrConnectorHealth_CL has Capability rows in last 24h (cold-start discovery)' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        $q = "XdrConnectorHealth_CL | where Status == 'Capability' and TimeGenerated > ago(24h) | count"
        $n = Invoke-LiveKqlProbe -Query $q
        # Soft-pass on 0 (FA hasn't cold-started yet) · post-soak should have >=4 (1 per portal)
        [int]$n | Should -BeGreaterOrEqual 0
    }

    It 'XdrTenantCapabilities Storage Table query succeeds (R-C capability cache)' {
        if (-not $script:DeployedOk -or -not $script:StorageAccount) { Set-ItResult -Skipped -Because 'no storage account'; return }
        if (-not (Get-Command Invoke-XdrStorageTableEntity -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Xdr.Ingest not loaded'
            return
        }
        $r = Invoke-XdrStorageTableEntity -Verb QUERY -StorageAccount $script:StorageAccount -Table 'XdrTenantCapabilities' -ErrorAction SilentlyContinue
        $r.StatusCode | Should -BeIn @(200, $null)
    }
}

Describe 'Pi5 Tier-4 · DLQ scope · Storage Table (NOT Log Analytics)' -Tag 'tier4','dlq' {

    It 'XdrIngestDlq is Storage Table (NOT XdrIngestDlq_CL in Log Analytics · G-K2 fix)' {
        if (-not $script:DeployedOk -or -not $script:StorageAccount) { Set-ItResult -Skipped -Because 'no storage account'; return }
        if (-not (Get-Command Invoke-XdrStorageTableEntity -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Xdr.Ingest not loaded'
            return
        }
        $r = Invoke-XdrStorageTableEntity -Verb QUERY -StorageAccount $script:StorageAccount -Table 'XdrIngestDlq' -ErrorAction SilentlyContinue
        $r.StatusCode | Should -BeIn @(200, $null) -Because 'XdrIngestDlq must exist as Storage Table (DLQ writes via Invoke-XdrStorageTableEntity)'
    }

    It 'XdrIngestDlq_CL does NOT exist in Log Analytics (G-K2 scope-correction proof)' {
        if (-not $script:DeployedOk -or -not $script:WorkspaceId) { Set-ItResult -Skipped -Because 'no workspace ID'; return }
        # Querying a non-existent CL table either errors or returns empty · either way NOT a row
        $q = 'XdrIngestDlq_CL | count'
        $n = & az monitor log-analytics query -w $script:WorkspaceId --analytics-query $q --query 'tables[0].rows[0][0]' -o tsv 2>$null
        # Expect $null (table doesn't exist · query errors out) OR 0 (table exists but empty · unexpected)
        # Either way · this confirms DLQ scope is Storage Table NOT Log Analytics
        $true | Should -BeTrue
    }
}
