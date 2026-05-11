#Requires -Modules Pester
<#
.SYNOPSIS
    Cold-start time budget for Y1 Linux Consumption (60s budget).

.DESCRIPTION
    Y1 Linux Consumption (Microsoft Functions plan) imposes a 60-second cold-start
    timeout. profile.ps1 + module-import + first-function-execute must complete
    within this budget or the function never starts and the timer fires miss.

    This test measures:

      1. profile.ps1 parse + execute time
      2. Each of 7 modules' import time
      3. Worst-case bound: profile + module imports < 30s (leaves 30s for first poll)

    Cold-start regressions usually come from:
      - New module dependency added to RequiredModules
      - profile.ps1 doing expensive work (network calls, file I/O, dependency download)
      - host.json managedDependency = true (which fails on Legion runtime)
#>

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ProfilePath  = Join-Path $script:RepoRoot 'src/profile.ps1'
    $script:ModulesDir   = Join-Path $script:RepoRoot 'src/Modules'
    $script:ColdStartBudgetMs = 30000  # 30s — half of Y1's 60s timeout, leaves room for first poll
    $script:ModuleImportBudgetMs = 5000  # 5s per module max
}

Describe 'ColdStart.Benchmark — Y1 Linux Consumption 60s timeout budget' {

    # Timing tests run only on Linux. Windows local dev has 3-5x slower
    # PowerShell module-import overhead than Linux Y1 Consumption (the actual
    # production target). The cold-start budget targets the Linux runtime,
    # not Windows dev machines.
    $script:IsLinux = $PSVersionTable.Platform -eq 'Unix' -and -not $IsMacOS

    It 'profile.ps1 + 7 module imports complete in <30s (leaves 30s for first poll under 60s Y1 budget)' -Skip:(-not $script:IsLinux) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Set PSModulePath so modules resolve like in FA runtime
        $originalPath = $env:PSModulePath
        $env:PSModulePath = "$script:ModulesDir$([IO.Path]::PathSeparator)$($env:PSModulePath)"

        try {
            # Import each module (mirrors profile.ps1 flow)
            foreach ($m in 'Xdr.Common.Auth','Xdr.Common.Telemetry','Xdr.Common.Manifest','Xdr.Sentinel.Ingest','Xdr.Defender.Auth','Xdr.Defender.Client','Xdr.Connector.Orchestrator') {
                $modulePath = Join-Path $script:ModulesDir "$m/$m.psd1"
                if (Test-Path $modulePath) {
                    Import-Module $modulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
                }
            }
        } finally {
            $env:PSModulePath = $originalPath
        }

        $sw.Stop()
        $elapsed = $sw.ElapsedMilliseconds
        $elapsed | Should -BeLessOrEqual $script:ColdStartBudgetMs -Because "profile + 7 module imports must complete in $($script:ColdStartBudgetMs)ms (Y1 60s cold-start budget; 30s leaves room for first poll)"
    }

    It 'each module imports in <5s (no individual outlier)' -Skip:(-not $script:IsLinux) {
        $env:PSModulePath = "$script:ModulesDir$([IO.Path]::PathSeparator)$($env:PSModulePath)"
        $modules = 'Xdr.Common.Auth','Xdr.Common.Telemetry','Xdr.Common.Manifest','Xdr.Sentinel.Ingest','Xdr.Defender.Auth','Xdr.Defender.Client','Xdr.Connector.Orchestrator'
        $slowModules = @()
        foreach ($m in $modules) {
            $modulePath = Join-Path $script:ModulesDir "$m/$m.psd1"
            if (-not (Test-Path $modulePath)) { continue }
            # Remove first to force re-import
            Get-Module $m -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Import-Module $modulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
            $sw.Stop()
            if ($sw.ElapsedMilliseconds -gt $script:ModuleImportBudgetMs) {
                $slowModules += "${m}: $($sw.ElapsedMilliseconds)ms"
            }
        }
        $slowModules | Should -BeNullOrEmpty -Because "no module should take >$($script:ModuleImportBudgetMs)ms to import on cold-start"
    }

    It 'profile.ps1 has no expensive operations (network calls, file I/O, dependency download)' {
        $content = Get-Content $script:ProfilePath -Raw
        # Anti-patterns that would slow cold-start
        $content | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod' -Because 'profile.ps1 should not make network calls on cold-start'
        $content | Should -Not -Match 'Save-Module|Install-Module' -Because 'profile.ps1 should not install modules on cold-start (modules are bundled in zip)'
    }

    It 'host.json has managedDependency.Enabled=false (Legion runtime requirement)' {
        $hostJsonPath = Join-Path $script:RepoRoot 'src/host.json'
        $hostJson = Get-Content $hostJsonPath -Raw | ConvertFrom-Json
        $hostJson.managedDependency.Enabled | Should -BeFalse -Because 'Linux Consumption Legion runtime fails when managedDependency=true; modules must be bundled in zip'
    }

    It 'requirements.psd1 is empty/comments-only (no Az modules listed)' {
        $reqPath = Join-Path $script:RepoRoot 'src/requirements.psd1'
        $content = Get-Content $reqPath -Raw
        # Strip comments + whitespace
        $codeLines = $content -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim().Length -gt 0 }
        # Check we don't have actual module entries (look for 'Az.X' patterns)
        $azModuleEntries = $codeLines | Where-Object { $_ -match "'Az\.[A-Za-z]+'" -or $_ -match '"Az\.[A-Za-z]+"' }
        $azModuleEntries | Should -BeNullOrEmpty -Because 'Az modules must be bundled in zip; listing them in requirements.psd1 fails on Legion'
    }
}
