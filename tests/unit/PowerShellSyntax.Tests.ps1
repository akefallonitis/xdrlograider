#Requires -Modules Pester
<#
.SYNOPSIS
    Offline parse-time + module-export regression gates for the Function App
    runtime code. Catches the EXACT class of bugs that escaped to production
    in iter-13 deployment:

      Bug A: validate-auth-selftest/run.ps1 had 5 parse errors from "$fn:"
             pattern (PowerShell parses `$fn:` as scope qualifier; needs
             `${fn}:` to delimit). Manifested as "Variable reference is not
             valid. ':' was not followed by a valid variable name character."
             every time the function loaded → 45 exceptions/30min in
             App Insights, 0 rows in MDE_AuthTestResult_CL.

      Bug B: XdrLogRaider.Client.psm1 Export-ModuleMember array was missing
             'Invoke-TierPollWithHeartbeat' even though .psd1
             FunctionsToExport listed it. PowerShell uses the INTERSECTION
             of psm1+psd1 export lists → function silently filtered out.
             Manifested as "The term 'Invoke-TierPollWithHeartbeat' is not
             recognized as a name of a cmdlet" every poll-* tick →
             24 exceptions/30min in App Insights, 0 data ingestion.

    Both bugs would have been caught at PR time by these gates. They were
    missed because:
      - PSScriptAnalyzer doesn't parse-check function-app run.ps1 files in
        a way that reproduces the runtime error
      - Existing Pester tests imported modules in PSModulePath-extended
        sessions that auto-loaded all dot-sourced functions, masking the
        Export-ModuleMember filter bug

    These gates use the SAME parser the Functions runtime uses + verify the
    PSD1/PSM1 export contracts match.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SrcDir   = Join-Path $script:RepoRoot 'src'
}

Describe 'PowerShell parse-time correctness for Function App runtime files' {
    # Parses every .ps1 / .psm1 file under src/ with the SAME parser the Azure
    # Functions PowerShell runtime uses. Catches the iter-13 Bug A class of
    # syntax error that PSScriptAnalyzer warnings don't reliably surface.

    BeforeAll {
        $script:RuntimeFiles = @(
            Get-ChildItem -Path (Join-Path $script:SrcDir 'profile.ps1') -ErrorAction SilentlyContinue
        ) + @(
            Get-ChildItem -Path (Join-Path $script:SrcDir 'functions') -Recurse -Filter 'run.ps1' -ErrorAction SilentlyContinue
        ) + @(
            Get-ChildItem -Path (Join-Path $script:SrcDir 'Modules') -Recurse -Include '*.ps1','*.psm1' -ErrorAction SilentlyContinue
        )
    }

    It 'enumerates expected runtime files (profile.ps1 + 9 run.ps1 + module ps1/psm1)' {
        @($script:RuntimeFiles).Count | Should -BeGreaterThan 20 -Because "profile.ps1 + 9 timer run.ps1 + ~20 module files"
    }

    It 'every src/ runtime file parses cleanly via [Parser]::ParseFile() (no syntax errors)' {
        # This is the EXACT parser the Azure Functions PowerShell worker uses
        # at function-load time. Any error here = guaranteed runtime failure.
        $allErrors = @()
        foreach ($file in $script:RuntimeFiles) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
            if ($errors -and $errors.Count -gt 0) {
                foreach ($err in $errors) {
                    $allErrors += [pscustomobject]@{
                        File    = $file.FullName.Replace($script:RepoRoot, '.')
                        Line    = $err.Extent.StartLineNumber
                        Column  = $err.Extent.StartColumnNumber
                        Message = $err.Message
                    }
                }
            }
        }
        $errReport = if ($allErrors.Count -gt 0) { ($allErrors | ForEach-Object { "    $($_.File):L$($_.Line):C$($_.Column) - $($_.Message)" }) -join "`n" } else { '' }
        $allErrors.Count | Should -Be 0 -Because "parse errors will fail the function at load time. Errors found:`n$errReport"
    }

    It 'NO function script uses bare "`$variable:" pattern (must use `${variable}: instead)' {
        # Specific gate for Bug A: catch "$fnName:" / "$config:" patterns
        # that the parser interprets as scope-qualified variable references.
        # The fix is to use ${fnName}: to delimit the variable name.
        $offenders = @()
        foreach ($file in $script:RuntimeFiles) {
            $content = Get-Content $file.FullName -Raw
            # Match "$Foo:<space-or-letter>" (where <letter> is not a valid
            # variable name char in scope context — i.e., not preceded by ${).
            # Acceptable: $env:NAME, $script:foo, $global:foo (lowercase scopes).
            # Bad: $myVar:something (custom variable with colon — parser confused).
            $matches = [regex]::Matches($content, '(?<!\${)\$([A-Z][a-zA-Z0-9_]*)(?<!env|env|script|global|local|private|using|configuration|workflow|variable|function|process)\:[a-zA-Z]')
            foreach ($m in $matches) {
                # Filter out known scope qualifiers
                $varName = $m.Groups[1].Value
                if ($varName -notin @('env','script','global','local','private','using','configuration','workflow','variable','function','process','Env','Script','Global','Local','Private','Using','Configuration','Workflow','Variable','Function','Process')) {
                    $offenders += "$($file.FullName.Replace($script:RepoRoot, '.')): " + '$' + "${varName}:"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "Pattern `"`$Var:text`" causes parser error 'Variable reference is not valid'. Use `${Var}: instead. Offenders:`n$(($offenders | ForEach-Object { "    $_" }) -join "`n")"
    }
}

Describe 'Module export contract — psd1 FunctionsToExport must match psm1 Export-ModuleMember' {
    # Catches the iter-13 Bug B class: psm1 Export-ModuleMember filters out a
    # function that the psd1 FunctionsToExport claims to export. PowerShell
    # uses the INTERSECTION → function silently unavailable to callers.

    BeforeAll {
        # Only true MODULE manifests — those colocated with a .psm1 of the same
        # base name. Excludes data files (endpoints.manifest.psd1, etc.) that
        # also use psd1 extension but aren't module manifests.
        $allPsd1 = Get-ChildItem -Path (Join-Path $script:SrcDir 'Modules') -Recurse -Filter '*.psd1' -ErrorAction SilentlyContinue
        $script:ModuleManifests = @($allPsd1 | Where-Object {
            $psm1Path = Join-Path $_.Directory.FullName ($_.BaseName + '.psm1')
            Test-Path $psm1Path
        })
    }

    It 'enumerates expected module manifests (5 custom modules in v0.1.0-beta first publish)' {
        # Five-module architecture: Xdr.Common.Auth, Xdr.Sentinel.Ingest,
        # Xdr.Defender.Auth, Xdr.Defender.Client, Xdr.Connector.Orchestrator.
        @($script:ModuleManifests).Count | Should -Be 5 -Because "v0.1.0-beta first publish has exactly 5 modules and no shims"
    }

    It 'every psd1 FunctionsToExport entry is also in the corresponding psm1 Export-ModuleMember' {
        $offenders = @()
        foreach ($manifest in $script:ModuleManifests) {
            $manifestData = Import-PowerShellDataFile $manifest.FullName
            $declaredExports = @($manifestData.FunctionsToExport)
            $rootModulePath = Join-Path $manifest.Directory.FullName $manifestData.RootModule
            if (-not (Test-Path $rootModulePath)) {
                $offenders += "$($manifest.Name): RootModule '$($manifestData.RootModule)' not found at $rootModulePath"
                continue
            }
            $rootModuleContent = Get-Content $rootModulePath -Raw

            # Find the Export-ModuleMember call in the .psm1
            if ($rootModuleContent -match 'Export-ModuleMember\s+-Function\s+@\(([^)]+)\)') {
                $psm1ExportsBlock = $Matches[1]
                $psm1Exports = [regex]::Matches($psm1ExportsBlock, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }

                foreach ($declared in $declaredExports) {
                    if ($declared -notin $psm1Exports) {
                        $offenders += "$($manifest.Name) FunctionsToExport lists '$declared' but $($manifestData.RootModule) Export-ModuleMember does NOT — PowerShell will use the intersection and silently drop this function."
                    }
                }
                # Also flag the reverse: psm1 exports a function the psd1 doesn't claim
                foreach ($exported in $psm1Exports) {
                    if ($exported -notin $declaredExports) {
                        $offenders += "$($manifest.RootModule) Export-ModuleMember includes '$exported' but $($manifest.Name) FunctionsToExport does NOT — function won't be visible to module consumers."
                    }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "psd1.FunctionsToExport ↔ psm1.Export-ModuleMember mismatch silently filters functions:`n$(($offenders | ForEach-Object { "    $_" }) -join "`n")"
    }

    It 'live import simulation — every psd1 successfully imports + exports its claimed functions' {
        $offenders = @()
        $modulesDir = Join-Path $script:SrcDir 'Modules'
        # Simulate Functions runtime by extending PSModulePath
        $originalPSModulePath = $env:PSModulePath
        $env:PSModulePath = "$modulesDir$([IO.Path]::PathSeparator)$originalPSModulePath"
        try {
            # Import in dependency order
            foreach ($manifest in $script:ModuleManifests | Sort-Object { if ($_.Name -match 'Xdr\.Portal\.Auth') { 1 } elseif ($_.Name -match 'Ingest') { 2 } else { 3 } }) {
                $manifestData = Import-PowerShellDataFile $manifest.FullName
                $moduleName = [IO.Path]::GetFileNameWithoutExtension($manifest.Name)
                try {
                    Import-Module $manifest.FullName -Force -ErrorAction Stop
                    $loadedModule = Get-Module $moduleName -ErrorAction SilentlyContinue
                    if (-not $loadedModule) {
                        $offenders += "$($manifest.Name): imported but Get-Module returned null"
                        continue
                    }
                    $exportedFns = @($loadedModule.ExportedFunctions.Keys)
                    foreach ($declared in @($manifestData.FunctionsToExport)) {
                        if ($declared -notin $exportedFns) {
                            $offenders += "$($manifest.Name): claims to export '$declared' but Get-Module after import shows it NOT exported (psm1 Export-ModuleMember filter active)"
                        }
                    }
                } catch {
                    $offenders += "$($manifest.Name): Import-Module FAILED — $($_.Exception.Message)"
                }
            }
        } finally {
            $env:PSModulePath = $originalPSModulePath
            # Cleanup: unload the modules so other Pester tests get a fresh state
            foreach ($manifest in $script:ModuleManifests) {
                $moduleName = [IO.Path]::GetFileNameWithoutExtension($manifest.Name)
                Get-Module $moduleName -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "live import simulation surfaces hidden export gaps:`n$(($offenders | ForEach-Object { "    $_" }) -join "`n")"
    }
}
