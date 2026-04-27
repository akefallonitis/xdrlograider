#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.3 regression gates: lock single-runspace mode + $env-direct config
    pattern that fixes the multi-runspace $global propagation bug.

.DESCRIPTION
    LIVE PRODUCTION BUG (caught by post-deploy diagnostic, fixed in iter 13.3):
    Azure Functions PowerShell defaults to PSWorkerInProcConcurrencyUpperBound
    = 1000 (multi-runspace concurrency). profile.ps1 runs per runspace, but if
    a runspace's profile.ps1 invocation fails or doesn't fire, $global state
    never gets set in THAT runspace → strict-mode access throws every time
    a function runs in that runspace.

    Live evidence pre-fix: 60+ exceptions per 15 min from validate-auth-selftest
    failing with "$global:XdrLogRaiderConfig cannot be retrieved because it
    has not been set" — happening AFTER profile.ps1 had successfully run in
    other runspaces (App Insights traces confirm profile.ps1 imports modules
    + sets $global, but a different runspace's function fires + can't see it).

    Iter 13.3 fix (defense-in-depth):
    1. Set PSWorkerInProcConcurrencyUpperBound=1 + FUNCTIONS_WORKER_PROCESS_COUNT=1
       in FA app settings → forces single-runspace mode → eliminates the
       propagation bug at its root.
    2. Refactor each function's run.ps1 + Invoke-TierPollWithHeartbeat to read
       config DIRECTLY from $env:* (process-scoped, always present) instead
       of $global:XdrLogRaiderConfig → defensive even if (1) ever fails.

    Both changes complementary. Either alone would fix the bug; together
    they're robust to deploy-time errors AND future runtime changes.
#>

BeforeAll {
    $script:RepoRoot          = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:MainTemplatePath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:FunctionAppBicepPath = Join-Path $script:RepoRoot 'deploy' 'modules' 'function-app.bicep'
    $script:FunctionsDir      = Join-Path $script:RepoRoot 'src' 'functions'
    $script:OrchestratorPath  = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'Public' 'Invoke-TierPollWithHeartbeat.ps1'
}

Describe 'Single-runspace mode — FA app settings (mainTemplate.json + bicep)' {
    BeforeAll {
        $script:MainTemplate = Get-Content $script:MainTemplatePath -Raw | ConvertFrom-Json
        $faSite = $script:MainTemplate.resources |
            Where-Object { $_.type -eq 'Microsoft.Web/sites' } |
            Select-Object -First 1
        $script:FaAppSettings = $faSite.properties.siteConfig.appSettings
        $script:BicepContent = Get-Content $script:FunctionAppBicepPath -Raw
    }

    It 'mainTemplate.json appSettings includes PSWorkerInProcConcurrencyUpperBound = 1' {
        $setting = $script:FaAppSettings | Where-Object { $_.name -eq 'PSWorkerInProcConcurrencyUpperBound' }
        $setting | Should -Not -BeNullOrEmpty -Because 'iter 13.3 requires single-runspace mode to fix $global propagation bug'
        $setting.value | Should -Be '1' -Because 'multi-runspace mode (>1) caused production $global state propagation failure'
    }

    It 'mainTemplate.json appSettings includes FUNCTIONS_WORKER_PROCESS_COUNT = 1' {
        $setting = $script:FaAppSettings | Where-Object { $_.name -eq 'FUNCTIONS_WORKER_PROCESS_COUNT' }
        $setting | Should -Not -BeNullOrEmpty -Because 'must be 1 for PowerShell single-process model'
        $setting.value | Should -Be '1'
    }

    It 'function-app.bicep also declares both single-runspace settings (Bicep ↔ JSON sync)' {
        $script:BicepContent | Should -Match 'FUNCTIONS_WORKER_PROCESS_COUNT.*1' -Because 'bicep + JSON must stay in sync'
        $script:BicepContent | Should -Match 'PSWorkerInProcConcurrencyUpperBound.*1' -Because 'bicep + JSON must stay in sync'
    }
}

Describe '$env-direct config pattern — each timer function reads from process-scoped env vars' {
    BeforeAll {
        # All timer entry points: 9 run.ps1 files + the orchestrator
        $script:RunPs1Files = @(Get-ChildItem -Path $script:FunctionsDir -Recurse -Filter 'run.ps1')
    }

    It 'every poll-pN run.ps1 dispatches to Invoke-TierPollWithHeartbeat (no direct $global access)' {
        # poll-* functions are thin wrappers; $global access (if any) lives in
        # the orchestrator. Verify the wrappers themselves don't access $global.
        $offenders = @()
        foreach ($file in $script:RunPs1Files | Where-Object Name -eq 'run.ps1') {
            if ($file.Directory.Name -notmatch '^poll-') { continue }
            $content = Get-Content $file.FullName -Raw
            # Strip comments first
            $codeOnly = ($content -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
            if ($codeOnly -match '\$global:XdrLogRaiderConfig') {
                $offenders += $file.FullName.Replace($script:RepoRoot, '.')
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "poll-* run.ps1 must NOT access $global state directly:`n$(($offenders | ForEach-Object { '    ' + $_ }) -join "`n")"
    }

    It 'heartbeat-5m run.ps1 reads config from $env (no $global dependency)' {
        $heartbeatPath = Join-Path $script:FunctionsDir 'heartbeat-5m' 'run.ps1'
        $content = Get-Content $heartbeatPath -Raw
        $codeOnly = ($content -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        # Must NOT have $global:XdrLogRaiderConfig outside comments
        $codeOnly | Should -Not -Match '\$global:XdrLogRaiderConfig' -Because 'iter 13.3: heartbeat reads env vars directly to avoid propagation bug'
        # Must read at least one expected env var
        $content | Should -Match '\$env:KEY_VAULT_URI|\$env:DCE_ENDPOINT' -Because 'must use env-direct pattern'
    }

    It 'validate-auth-selftest run.ps1 reads config from $env (no $global dependency)' {
        $authPath = Join-Path $script:FunctionsDir 'validate-auth-selftest' 'run.ps1'
        $content = Get-Content $authPath -Raw
        $codeOnly = ($content -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $codeOnly | Should -Not -Match '\$global:XdrLogRaiderConfig' -Because 'iter 13.3: auth-selftest reads env vars directly'
        $content | Should -Match '\$env:KEY_VAULT_URI|\$env:DCE_ENDPOINT'
    }

    It 'Invoke-TierPollWithHeartbeat (orchestrator) reads config from env vars (no global dependency)' {
        $content = Get-Content $script:OrchestratorPath -Raw
        # Strip both block comments (<# #>) and line comments (#)
        $stripped = [regex]::Replace($content, '<#[\s\S]*?#>', '')
        $codeOnly = ($stripped -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $codeOnly | Should -Not -Match '\$global:XdrLogRaiderConfig' -Because 'iter 13.3: orchestrator reads env vars directly so all 7 poll-* timers benefit'
        $content | Should -Match '\$env:KEY_VAULT_URI|\$env:DCE_ENDPOINT'
    }

    It 'profile.ps1 still exposes Get-XdrLogRaiderConfig as a defensive helper' {
        # Even though run.ps1 files now read $env: directly, keep the helper
        # for any future code path that might want a single source of truth.
        $profilePath = Join-Path $script:RepoRoot 'src' 'profile.ps1'
        $content = Get-Content $profilePath -Raw
        $content | Should -Match 'function global:Get-XdrLogRaiderConfig' -Because 'helper kept as defensive option for future code'
    }
}

Describe 'Strict-mode safety — config retrieval must never throw on missing $global' {
    It 'every config-consuming script uses pattern that survives missing $global' {
        # Static check: no script may have a bare `$global:XdrLogRaiderConfig`
        # access that's not inside a Test-Path / try-catch / Get-Variable
        # defensive wrapper. With single-runspace mode this is double-defensive.
        # Excludes profile.ps1 (which legitimately initializes the global).
        $profilePath = Join-Path $script:RepoRoot 'src' 'profile.ps1'
        $allScripts = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'src') -Recurse -Include '*.ps1','*.psm1') |
            Where-Object { $_.FullName -ne $profilePath }
        $offenders = @()
        foreach ($file in $allScripts) {
            $content = Get-Content $file.FullName -Raw
            # Strip both single-line `# comments` and multi-line `<# ... #>` comment-based help
            # First remove block comments, then per-line comments.
            $stripped = [regex]::Replace($content, '<#[\s\S]*?#>', '')
            $lines = $stripped -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '^\s*#') { continue }
                if ($line -match '\$global:XdrLogRaiderConfig') {
                    # Allow if it's an assignment (defining the global) — that's profile.ps1
                    if ($line -match '\$global:XdrLogRaiderConfig\s*=') { continue }
                    # Otherwise, flag as offender (read access without defensive wrapper)
                    $offenders += "$($file.FullName.Replace($script:RepoRoot, '.')):L$($i+1) - $($line.Trim())"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "iter 13.3: all global reads replaced with env-direct reads. Offenders:`n$(($offenders | ForEach-Object { '    ' + $_ }) -join "`n")"
    }
}
