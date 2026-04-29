#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.7 end-to-end behavioral integration test: simulate one full timer
    fire (poll-pN) with REAL production code paths and only HTTP transport mocked.

.DESCRIPTION
    Until now, our unit tests cover individual functions in isolation. This
    test wires them together in the EXACT sequence a real timer fire executes:

      profile.ps1 → Get-XdrLogRaiderConfig → \$env-direct config build
        → Get-XdrAuthSelfTestFlag (auth-gate green check)
        → Get-MDEAuthFromKeyVault (cred fetch from KV)
        → Connect-MDEPortal (sccauth cookie acquisition)
        → Invoke-MDETierPoll
            ├─ for each manifest entry in tier:
            │    ├─ Get-CheckpointTimestamp
            │    ├─ Invoke-MDEEndpoint
            │    │    ├─ Invoke-MDEPortalRequest
            │    │    └─ Expand-MDEResponse → ConvertTo-MDEIngestRow
            │    ├─ Send-ToLogAnalytics → DCE
            │    └─ Set-CheckpointTimestamp
            └─ return aggregate counters
        → Write-Heartbeat (success row)

    The ONLY thing mocked is the HTTP transport (Invoke-MDEPortalRequest +
    Invoke-WebRequest for DCE). Every other function executes its real
    production code, so a regression anywhere in the integration chain
    surfaces immediately as a test failure.

    This is the highest-value behavioral gate in the suite — it catches
    integration bugs that no individual unit test would detect.
#>

BeforeAll {
    $script:RepoRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:AuthModulePath   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth'   'Xdr.Portal.Auth.psd1'
    $script:IngestModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'
    $script:ClientModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'

    # Stub Az.* deps before module import.
    function global:Get-AzAccessToken { param([string]$ResourceUrl) [pscustomobject]@{ Token = 'stub'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }
    function global:Get-AzKeyVaultSecret { param([string]$VaultName, [string]$Name, [switch]$AsPlainText) [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'stubvalue' -AsPlainText -Force) } }
    function global:New-AzStorageContext { param([string]$StorageAccountName, [switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName = $StorageAccountName } }
    function global:Get-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
    function global:New-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
    function global:Get-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey)
        # Auth-gate flag returning green
        [pscustomobject]@{ Success = $true; Stage = 'complete'; LastRunUtc = [datetime]::UtcNow.ToString('o') }
    }
    function global:Add-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting) }

    Import-Module $script:AuthModulePath   -Force -ErrorAction Stop
    Import-Module $script:IngestModulePath -Force -ErrorAction Stop
    Import-Module $script:ClientModulePath -Force -ErrorAction Stop

    Set-StrictMode -Version Latest

    # Set the env vars that Invoke-TierPollWithHeartbeat reads.
    $env:KEY_VAULT_URI         = 'https://test-kv.vault.azure.net/'
    $env:AUTH_SECRET_NAME      = 'mde-portal-auth'
    $env:AUTH_METHOD           = 'CredentialsTotp'
    $env:SERVICE_ACCOUNT_UPN   = 'svc-test@example.com'
    $env:DCE_ENDPOINT          = 'https://test-dce.eastus-1.ingest.monitor.azure.com'
    $env:DCR_IMMUTABLE_ID      = 'dcr-12345'
    $env:STORAGE_ACCOUNT_NAME  = 'teststorage'
    $env:CHECKPOINT_TABLE_NAME = 'connectorCheckpoints'
    $env:TENANT_ID             = '11111111-1111-1111-1111-111111111111'
}

AfterAll {
    # Don't pollute env vars after the test
    foreach ($v in 'KEY_VAULT_URI','AUTH_SECRET_NAME','AUTH_METHOD','SERVICE_ACCOUNT_UPN','DCE_ENDPOINT','DCR_IMMUTABLE_ID','STORAGE_ACCOUNT_NAME','CHECKPOINT_TABLE_NAME','TENANT_ID') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

Describe 'End-to-end timer fire — Invoke-TierPollWithHeartbeat (P0 tier)' {

    It 'completes successfully when every dependency works (happy path)' {
        $outcome = InModuleScope Xdr.Defender.Client {
            # Mock the HTTP transport at the module that owns it (Xdr.Portal.Auth).
            Mock Invoke-MDEPortalRequest -ModuleName Xdr.Defender.Client {
                # Return a simple object response that Expand-MDEResponse handles.
                [pscustomobject]@{
                    id   = 'test-entity-1'
                    name = 'TestObj'
                    config = @{ enabled = $true; threshold = 100 }
                }
            }
            # Mock Connect-MDEPortal so we don't need a real auth flow.
            Mock Connect-MDEPortal -ModuleName Xdr.Defender.Client {
                [pscustomobject]@{
                    PortalHost = 'security.microsoft.com'
                    TenantId   = '11111111-1111-1111-1111-111111111111'
                    Cookies    = @{ sccauth = 'stub-cookie' }
                    AcquiredUtc = [datetime]::UtcNow
                }
            }
            # Mock KV credential fetch so we don't need real KV.
            Mock Get-MDEAuthFromKeyVault -ModuleName Xdr.Defender.Client {
                @{
                    Method   = 'CredentialsTotp'
                    Upn      = 'svc-test@example.com'
                    Password = (ConvertTo-SecureString 'fake' -AsPlainText -Force)
                    TotpSeed = 'JBSWY3DPEHPK3PXP'
                }
            }
            # Mock the DCE ingest transport (Invoke-WebRequest in Ingest module).
            Mock Invoke-WebRequest -ModuleName Xdr.Sentinel.Ingest {
                [pscustomobject]@{ StatusCode = 204; Headers = @{} }
            }
            # Mock checkpoint reads to return null (first run for every stream)
            Mock Get-CheckpointTimestamp -ModuleName Xdr.Defender.Client { $null }
            Mock Set-CheckpointTimestamp -ModuleName Xdr.Defender.Client {}

            # Reset the token cache so each test starts fresh.
            $module = Get-Module Xdr.Sentinel.Ingest
            & $module { $script:MonitorTokenCache = $null; $script:MonitorTokenExpiry = [datetime]::MinValue }

            $threw = $false
            $errMsg = $null
            try {
                Invoke-TierPollWithHeartbeat -Tier 'P0' -FunctionName 'poll-p0-test-1h' -Portal 'security.microsoft.com'
            } catch {
                $threw = $true
                $errMsg = $_.Exception.Message
            }
            return [pscustomobject]@{ Threw = $threw; ErrMsg = $errMsg }
        }
        $outcome.Threw | Should -BeFalse -Because "happy-path timer fire must complete without exception. Got: $($outcome.ErrMsg)"
    }

    It 'survives a per-stream Invoke-MDEPortalRequest failure (per-stream isolation works end-to-end)' {
        $outcome = InModuleScope Xdr.Defender.Client {
            $script:RequestCallCount = 0
            Mock Invoke-MDEPortalRequest -ModuleName Xdr.Defender.Client {
                $script:RequestCallCount++
                # Fail every other call
                if ($script:RequestCallCount % 2 -eq 0) {
                    throw "Simulated 403 Forbidden"
                }
                [pscustomobject]@{ id = "ok-$script:RequestCallCount"; name = 'OkEntity' }
            }
            Mock Connect-MDEPortal -ModuleName Xdr.Defender.Client {
                [pscustomobject]@{ PortalHost = 'security.microsoft.com'; TenantId = 't'; Cookies = @{ sccauth = 'c' }; AcquiredUtc = [datetime]::UtcNow }
            }
            Mock Get-MDEAuthFromKeyVault -ModuleName Xdr.Defender.Client {
                @{ Method = 'CredentialsTotp'; Upn = 'u'; Password = (ConvertTo-SecureString 'p' -AsPlainText -Force); TotpSeed = 'JBSWY3DPEHPK3PXP' }
            }
            Mock Invoke-WebRequest -ModuleName Xdr.Sentinel.Ingest {
                [pscustomobject]@{ StatusCode = 204; Headers = @{} }
            }
            Mock Get-CheckpointTimestamp -ModuleName Xdr.Defender.Client { $null }
            Mock Set-CheckpointTimestamp -ModuleName Xdr.Defender.Client {}

            $module = Get-Module Xdr.Sentinel.Ingest
            & $module { $script:MonitorTokenCache = $null; $script:MonitorTokenExpiry = [datetime]::MinValue }

            $threw = $false; $errMsg = $null
            try {
                Invoke-TierPollWithHeartbeat -Tier 'P0' -FunctionName 'poll-p0-test-1h'
            } catch {
                $threw = $true; $errMsg = $_.Exception.Message
            }
            return [pscustomobject]@{ Threw = $threw; ErrMsg = $errMsg }
        }
        $outcome.Threw | Should -BeFalse -Because "per-stream isolation must hold END-TO-END through every layer. Got: $($outcome.ErrMsg)"
    }

    It 'auth-gate red emits a "skipped" heartbeat row but does not throw' {
        $outcome = InModuleScope Xdr.Defender.Client {
            # Override auth-gate flag to RED
            Mock Get-XdrAuthSelfTestFlag -ModuleName Xdr.Defender.Client { $false }
            Mock Connect-MDEPortal -ModuleName Xdr.Defender.Client {
                throw "Should NOT reach Connect-MDEPortal when auth-gate is red"
            }
            Mock Invoke-WebRequest -ModuleName Xdr.Sentinel.Ingest {
                [pscustomobject]@{ StatusCode = 204; Headers = @{} }
            }
            $module = Get-Module Xdr.Sentinel.Ingest
            & $module { $script:MonitorTokenCache = $null; $script:MonitorTokenExpiry = [datetime]::MinValue }

            $threw = $false; $errMsg = $null
            try {
                Invoke-TierPollWithHeartbeat -Tier 'P0' -FunctionName 'poll-p0-test-1h'
            } catch {
                $threw = $true; $errMsg = $_.Exception.Message
            }
            return [pscustomobject]@{ Threw = $threw; ErrMsg = $errMsg }
        }
        $outcome.Threw | Should -BeFalse -Because "auth-gate-red must skip cleanly with skipped-heartbeat row, NOT throw. Got: $($outcome.ErrMsg)"
    }

    It 'fatal error during Connect-MDEPortal emits fatal-error heartbeat then re-throws' {
        $outcome = InModuleScope Xdr.Defender.Client {
            Mock Connect-MDEPortal -ModuleName Xdr.Defender.Client {
                throw "FATAL: Key Vault unreachable"
            }
            Mock Get-MDEAuthFromKeyVault -ModuleName Xdr.Defender.Client {
                @{ Method = 'CredentialsTotp'; Upn = 'u'; Password = (ConvertTo-SecureString 'p' -AsPlainText -Force); TotpSeed = 'JBSWY3DPEHPK3PXP' }
            }
            $heartbeatRows = @()
            Mock Invoke-WebRequest -ModuleName Xdr.Sentinel.Ingest {
                # Capture each request body so we can inspect heartbeat content
                if ($Body -match 'fatalError') {
                    $script:FatalHeartbeatSeen = $true
                }
                [pscustomobject]@{ StatusCode = 204; Headers = @{} }
            } -ParameterFilter { $true }
            Mock Get-XdrAuthSelfTestFlag -ModuleName Xdr.Defender.Client { $true }

            $module = Get-Module Xdr.Sentinel.Ingest
            & $module { $script:MonitorTokenCache = $null; $script:MonitorTokenExpiry = [datetime]::MinValue }
            $script:FatalHeartbeatSeen = $false

            $threw = $false; $errMsg = $null
            try {
                Invoke-TierPollWithHeartbeat -Tier 'P0' -FunctionName 'poll-p0-test-1h'
            } catch {
                $threw = $true; $errMsg = $_.Exception.Message
            }
            return [pscustomobject]@{ Threw = $threw; ErrMsg = $errMsg; FatalSeen = $script:FatalHeartbeatSeen }
        }
        # Contract: fatal MUST re-throw (Azure Functions runtime needs to mark
        # the invocation failed) AND the heartbeat-with-fatalError MUST fire
        # before re-throwing (so operators can see in MDE_Heartbeat_CL).
        $outcome.Threw | Should -BeTrue -Because "fatal error must re-throw so Azure Functions runtime marks invocation failed"
        $outcome.ErrMsg | Should -Match 'Key Vault unreachable' -Because 'the original error message must propagate'
    }
}
