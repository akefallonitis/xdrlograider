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

BeforeDiscovery {
    # BeforeDiscovery for inline -Skip clauses (Bicep is archived to
    # .internal/bicep-reference/ in v0.1.0-beta first publish).
    $script:DiscoveryRepoRoot          = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:DiscoveryFunctionAppBicep  = Join-Path $script:DiscoveryRepoRoot 'deploy' 'modules' 'function-app.bicep'
}

BeforeAll {
    $script:RepoRoot          = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:MainTemplatePath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:FunctionAppBicepPath = Join-Path $script:RepoRoot 'deploy' 'modules' 'function-app.bicep'
    $script:FunctionsDir      = Join-Path $script:RepoRoot 'src' 'functions'
    $script:OrchestratorPath  = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Public' 'Invoke-TierPollWithHeartbeat.ps1'
}

Describe 'Single-runspace mode — FA app settings (mainTemplate.json + bicep)' {
    BeforeAll {
        $script:MainTemplate = Get-Content $script:MainTemplatePath -Raw | ConvertFrom-Json
        $faSite = $script:MainTemplate.resources |
            Where-Object { $_.type -eq 'Microsoft.Web/sites' } |
            Select-Object -First 1
        $script:FaAppSettings = $faSite.properties.siteConfig.appSettings
        # Bicep is archived to .internal/bicep-reference/ in v0.1.0-beta — load
        # only when present (the Bicep parity gate skips cleanly if absent).
        $script:BicepContent = if (Test-Path -LiteralPath $script:FunctionAppBicepPath) {
            Get-Content $script:FunctionAppBicepPath -Raw
        } else { $null }
        # v0.1.0-beta first publish: appSettings switched from a flat array
        # of {name,value} entries to an ARM expression string that builds
        # the array via concat() of tier-driven variant variables. Either
        # shape is valid; this helper extracts the (name -> literal-value)
        # entries from whichever is present so the gate stays robust.
        $script:NamedAppSettings = @{}
        if ($script:FaAppSettings -is [System.Array]) {
            foreach ($kv in $script:FaAppSettings) {
                if ($null -ne $kv -and $kv.PSObject.Properties['name'] -and $kv.PSObject.Properties['value']) {
                    $script:NamedAppSettings[[string]$kv.name] = [string]$kv.value
                }
            }
        } else {
            # ARM expression string. Pull out createObject('name', '<n>', 'value', '<v>')
            # pairs — these are the inline literal entries (the dynamic ones use
            # references / variables and we don't need them for runspace gates).
            $expr = [string]$script:FaAppSettings
            $rx = [regex] "createObject\('name',\s*'([^']+)',\s*'value',\s*'([^']*)'\)"
            foreach ($m in $rx.Matches($expr)) {
                $script:NamedAppSettings[$m.Groups[1].Value] = $m.Groups[2].Value
            }
        }
    }

    It 'mainTemplate.json appSettings includes PSWorkerInProcConcurrencyUpperBound = 1' {
        $script:NamedAppSettings.ContainsKey('PSWorkerInProcConcurrencyUpperBound') | Should -BeTrue -Because 'iter 13.3 requires single-runspace mode to fix $global propagation bug'
        $script:NamedAppSettings['PSWorkerInProcConcurrencyUpperBound'] | Should -Be '1' -Because 'multi-runspace mode (>1) caused production $global state propagation failure'
    }

    It 'mainTemplate.json appSettings includes FUNCTIONS_WORKER_PROCESS_COUNT = 1' {
        $script:NamedAppSettings.ContainsKey('FUNCTIONS_WORKER_PROCESS_COUNT') | Should -BeTrue -Because 'must be 1 for PowerShell single-process model'
        $script:NamedAppSettings['FUNCTIONS_WORKER_PROCESS_COUNT'] | Should -Be '1'
    }

    It 'function-app.bicep also declares both single-runspace settings (Bicep ↔ JSON sync)' -Skip:(-not (Test-Path -LiteralPath $script:DiscoveryFunctionAppBicep)) {
        # Bicep is archived to .internal/bicep-reference/ in v0.1.0-beta first
        # publish — ARM is the single source of truth. The two `mainTemplate.json
        # appSettings includes ...` tests above already gate the runspace
        # settings on the deployed surface; this Bicep parity gate is a no-op
        # when Bicep is archived.
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
        $offenders | Should -BeNullOrEmpty -Because ('poll-* run.ps1 must NOT access $global state directly:' + [Environment]::NewLine + (($offenders | ForEach-Object { '    ' + $_ }) -join [Environment]::NewLine))
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

    It 'Invoke-TierPollWithHeartbeat (orchestrator) reads config from env vars (no global dependency)' {
        $content = Get-Content $script:OrchestratorPath -Raw
        # Strip both block comments (<# #>) and line comments (#)
        $stripped = [regex]::Replace($content, '<#[\s\S]*?#>', '')
        $codeOnly = ($stripped -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $codeOnly | Should -Not -Match '\$global:XdrLogRaiderConfig' -Because 'orchestrator reads env vars directly so all 5 poll-* timers benefit'
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
        $offenders | Should -BeNullOrEmpty -Because ('iter 13.3: all global reads replaced with env-direct reads. Offenders:' + [Environment]::NewLine + (($offenders | ForEach-Object { '    ' + $_ }) -join [Environment]::NewLine))
    }
}
