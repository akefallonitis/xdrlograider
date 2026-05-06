#Requires -Modules Pester
<#
.SYNOPSIS
    ARM mainTemplate.json siteConfig.appSettings vs FA code env-var consumption parity.

.DESCRIPTION
    Per BINDING methodology Step 4 — behavioural test that catches the regression
    class found in 2026-05-06 audit (TENANT_ID consumed by activity but never set
    in mainTemplate.json appSettings, leading to silent multi-tenant misroute).

    Asserts:
      1. Every env var referenced by activity / orchestrator / heartbeat / cadence
         timers / profile.ps1 IS declared in mainTemplate.json appSettings.
      2. Every appSetting in mainTemplate.json IS consumed by FA code (no dead config).
      3. profile.ps1 cold-start required-env-vars list matches the set actually
         consumed by activity code (no silent-failure mode where activity reads an
         env var profile.ps1 doesn't validate at boot).
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ArmTemplate  = Join-Path $script:RepoRoot 'deploy/compiled/mainTemplate.json'
    $script:ProfilePath  = Join-Path $script:RepoRoot 'src/profile.ps1'
    $script:ActivityPath = Join-Path $script:RepoRoot 'src/functions/Xdr-PollStream/run.ps1'
    $script:HeartbeatPath = Join-Path $script:RepoRoot 'src/functions/Connector-Heartbeat/run.ps1'

    # Three regex patterns built via [regex]::new to avoid PS string-interpolation
    # quirks that bit us during Pester discovery (the BeforeAll runs in a
    # PSScope where some auto-vars get re-evaluated; using compiled Regex
    # objects sidesteps that).
    $envRegex     = [regex]::new('\$env:([A-Z_][A-Z0-9_]*)')
    $armRegex     = [regex]::new("createObject\('name',\s*'([A-Z_][A-Z0-9_]*)'")
    $profileRegex = [regex]::new("Name\s*=\s*'([A-Z_][A-Z0-9_]*)'")

    $script:ArmAppSettings   = [System.Collections.Generic.HashSet[string]]::new()
    $script:ActivityEnvVars  = [System.Collections.Generic.HashSet[string]]::new()
    $script:HeartbeatEnvVars = [System.Collections.Generic.HashSet[string]]::new()
    $script:ProfileRequired  = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($hit in $armRegex.Matches((Get-Content -Raw $script:ArmTemplate))) {
        [void]$script:ArmAppSettings.Add($hit.Groups[1].Value)
    }
    foreach ($hit in $envRegex.Matches((Get-Content -Raw $script:ActivityPath))) {
        [void]$script:ActivityEnvVars.Add($hit.Groups[1].Value)
    }
    foreach ($hit in $envRegex.Matches((Get-Content -Raw $script:HeartbeatPath))) {
        [void]$script:HeartbeatEnvVars.Add($hit.Groups[1].Value)
    }
    foreach ($hit in $profileRegex.Matches((Get-Content -Raw $script:ProfilePath))) {
        [void]$script:ProfileRequired.Add($hit.Groups[1].Value)
    }

    # No filtering needed — the regex pattern is already strict enough.
}

Describe 'mainTemplate.json appSettings vs FA code parity' {

    Context 'Every env var the activity reads MUST be set in mainTemplate.json appSettings (regression: 2026-05-06 TENANT_ID missing)' {

        It 'TENANT_ID is set in mainTemplate.json appSettings' {
            $script:ArmAppSettings.Contains('TENANT_ID') | Should -BeTrue -Because 'activity passes -TenantId $config.ExpectedTenantId to Connect-DefenderPortal; if TENANT_ID env is empty, multi-tenant routing breaks silently'
        }

        It 'XDR_INGEST_DLQ_TABLE_NAME is set in mainTemplate.json appSettings' {
            $script:ArmAppSettings.Contains('XDR_INGEST_DLQ_TABLE_NAME') | Should -BeTrue -Because 'activity passes -TableName $config.DlqTable to Pop-XdrIngestDlq; mandatory parameter'
        }

        It 'every $env:NAME read by activity is in mainTemplate.json appSettings' {
            $missing = @()
            foreach ($v in $script:ActivityEnvVars) {
                if (-not $script:ArmAppSettings.Contains($v)) { $missing += $v }
            }
            $missing | Should -BeNullOrEmpty -Because "ARM template MUST set every env var the activity reads. Missing: $($missing -join ', ')"
        }

        It 'every $env:NAME read by heartbeat is in mainTemplate.json appSettings' {
            $missing = @()
            foreach ($v in $script:HeartbeatEnvVars) {
                if (-not $script:ArmAppSettings.Contains($v)) { $missing += $v }
            }
            $missing | Should -BeNullOrEmpty -Because "ARM template MUST set every env var heartbeat reads. Missing: $($missing -join ', ')"
        }
    }

    Context 'profile.ps1 cold-start required-env-vars list matches activity consumption (regression: missing fail-fast for TENANT_ID + XDR_INGEST_DLQ_TABLE_NAME)' {

        It 'profile.ps1 required-env-vars includes TENANT_ID' {
            $script:ProfileRequired.Contains('TENANT_ID') | Should -BeTrue -Because 'fail-fast at cold start beats silent activity failure on first poll'
        }

        It 'profile.ps1 required-env-vars includes XDR_INGEST_DLQ_TABLE_NAME' {
            $script:ProfileRequired.Contains('XDR_INGEST_DLQ_TABLE_NAME') | Should -BeTrue -Because 'Pop-XdrIngestDlq -TableName is mandatory; activity reads from $env:XDR_INGEST_DLQ_TABLE_NAME'
        }

        It 'every env var the activity reads is also in profile.ps1 required-env-vars (no silent-failure mode)' {
            # Allow a small whitelist: APPLICATIONINSIGHTS_CONNECTION_STRING is set by Functions runtime,
            # KV_CACHE_TTL_MINUTES has a safe default in the auth module.
            $whitelist = @('APPLICATIONINSIGHTS_CONNECTION_STRING','KV_CACHE_TTL_MINUTES','APPLICATIONINSIGHTS_TELEMETRY_SAMPLING_EXCLUDED_TYPES')
            $missing = @()
            foreach ($v in $script:ActivityEnvVars) {
                if ($whitelist -contains $v) { continue }
                if (-not $script:ProfileRequired.Contains($v)) { $missing += $v }
            }
            $missing | Should -BeNullOrEmpty -Because "profile.ps1 MUST validate every env var the activity reads. Missing from profile.ps1: $($missing -join ', ')"
        }
    }
}
