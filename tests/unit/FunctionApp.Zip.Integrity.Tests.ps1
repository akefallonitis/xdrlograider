#Requires -Module Pester
# Pi8b · T1 FA zip integrity · build the function-app.zip · extract to temp ·
# verify Modules/ layout · Test-ModuleManifest on each from-zip-path module ·
# verify Xdr-Poll function presence · verify all 5 portal manifests bundled.
#
# Catches packaging bugs that complement FunctionApp.Zip.Layout.Tests:
#   - Module psd1 fails Test-ModuleManifest from inside-zip-extracted path
#   - profile.ps1 module-discovery glob mismatches actual layout
#   - manifest filename mismatches (defender.psd1 missing · etc.)
#   - Az module Save-Module bundling issues (-BundleAz path)
#
# G-D3 (Import-Module from /home/site/wwwroot/Modules/) mitigation via local
# zip-extract-and-re-test simulation.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:BuildScript = Join-Path $script:RepoRoot 'tools/Build-FunctionAppZip.ps1'
    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-faz-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $script:ZipPath = Join-Path $script:TempDir 'function-app.zip'
    $script:ExtractDir = Join-Path $script:TempDir 'extracted'

    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
    # Build the zip · skip ARM auto-sync to keep test isolated
    & $script:BuildScript -OutputPath $script:ZipPath -SyncArmDefenderSubAreas:$false *>$null

    if (Test-Path $script:ZipPath) {
        Expand-Archive -Path $script:ZipPath -DestinationPath $script:ExtractDir -Force
    }
}

AfterAll {
    if (Test-Path $script:TempDir) {
        Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
    }
}

Describe 'Pi8b · FA zip integrity · build + extract + verify' -Tag 'fa-zip','integrity' {

    It 'zip built successfully' {
        Test-Path $script:ZipPath | Should -BeTrue
        (Get-Item $script:ZipPath).Length | Should -BeGreaterThan 1KB
    }

    It 'zip size under FA WEBSITE_RUN_FROM_PACKAGE soft cap (25 MB)' {
        $sizeMB = [math]::Round((Get-Item $script:ZipPath).Length / 1MB, 2)
        $sizeMB | Should -BeLessOrEqual 25
    }

    It 'zip extracted successfully' {
        Test-Path $script:ExtractDir | Should -BeTrue
    }

    It 'root-level host.json present in extracted zip' {
        Test-Path (Join-Path $script:ExtractDir 'host.json') | Should -BeTrue
    }

    It 'root-level profile.ps1 present in extracted zip' {
        Test-Path (Join-Path $script:ExtractDir 'profile.ps1') | Should -BeTrue
    }

    It 'root-level requirements.psd1 present in extracted zip' {
        Test-Path (Join-Path $script:ExtractDir 'requirements.psd1') | Should -BeTrue
    }

    It 'Xdr-Poll function dir present with function.json + run.ps1' {
        Test-Path (Join-Path $script:ExtractDir 'Xdr-Poll/function.json') | Should -BeTrue
        Test-Path (Join-Path $script:ExtractDir 'Xdr-Poll/run.ps1') | Should -BeTrue
    }

    It 'Modules/ dir contains all 5 Xdr.* modules with psd1 + psm1' {
        $modulesDir = Join-Path $script:ExtractDir 'Modules'
        Test-Path $modulesDir | Should -BeTrue
        foreach ($mod in 'Xdr.Auth','Xdr.Common.Telemetry','Xdr.Ingest','Xdr.Parser','Xdr.Poll') {
            $modDir = Join-Path $modulesDir $mod
            Test-Path $modDir | Should -BeTrue -Because "Modules/$mod dir must exist"
            Test-Path (Join-Path $modDir "$mod.psd1") | Should -BeTrue -Because "Modules/$mod/$mod.psd1 must exist"
            Test-Path (Join-Path $modDir "$mod.psm1") | Should -BeTrue -Because "Modules/$mod/$mod.psm1 must exist"
        }
    }

    It 'each module psd1 passes Test-ModuleManifest from-zip-path' {
        $modulesDir = Join-Path $script:ExtractDir 'Modules'
        foreach ($mod in 'Xdr.Auth','Xdr.Common.Telemetry','Xdr.Ingest','Xdr.Parser','Xdr.Poll') {
            $psd1 = Join-Path $modulesDir "$mod/$mod.psd1"
            { Test-ModuleManifest -Path $psd1 -ErrorAction Stop } | Should -Not -Throw -Because "Test-ModuleManifest must succeed against $mod from FA-extracted layout"
        }
    }

    It 'all 5 portal manifests bundled in manifests/' {
        $manifestsDir = Join-Path $script:ExtractDir 'manifests'
        Test-Path $manifestsDir | Should -BeTrue
        foreach ($portal in 'defender','entra','intune','purview','securitycopilot') {
            Test-Path (Join-Path $manifestsDir "$portal.psd1") | Should -BeTrue -Because "manifests/$portal.psd1 must be bundled"
        }
    }

    It 'defender.psd1 parses as PowerShell data file (not corrupted in zip)' {
        $defPath = Join-Path $script:ExtractDir 'manifests/defender.psd1'
        # Use scriptblock evaluator (handles dynamic $true · Import-PowerShellDataFile rejects)
        { & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $defPath))) } | Should -Not -Throw
    }

    It 'defender.psd1 has Entries array with expected SubArea count' {
        $defPath = Join-Path $script:ExtractDir 'manifests/defender.psd1'
        $manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $defPath)))
        $entries = @($manifest.Entries)
        $entries.Count | Should -BeGreaterOrEqual 500 -Because "manifest must have ~519 endpoints"
        $subAreas = @($entries | ForEach-Object SubArea | Sort-Object -Unique)
        $subAreas.Count | Should -Be 19 -Because "19 distinct sub-areas expected"
    }

    It 'profile.ps1 module-discovery glob matches actual Modules/ layout' {
        $profileText = Get-Content -Raw (Join-Path $script:ExtractDir 'profile.ps1')
        # Verify profile.ps1 reads from Modules/ root (matches what zip provides)
        $profileText | Should -Match "(?m)\bModules\b" -Because "profile.ps1 must reference 'Modules' dir name"
        # Verify it iterates the 5 module names we ship
        foreach ($mod in 'Xdr.Common.Telemetry','Xdr.Auth','Xdr.Poll','Xdr.Ingest','Xdr.Parser') {
            $profileText | Should -Match ([regex]::Escape($mod)) -Because "profile.ps1 must import $mod"
        }
    }

    It 'run.ps1 references MANIFEST_PATH = /home/site/wwwroot/manifests/defender.psd1 (or fallback)' {
        $runPath = Join-Path $script:ExtractDir 'Xdr-Poll/run.ps1'
        $runText = Get-Content -Raw $runPath
        # run.ps1 reads $env:MANIFEST_PATH set by ARM; fallback uses $PSScriptRoot relative
        $runText | Should -Match 'MANIFEST_PATH' -Because "run.ps1 must read MANIFEST_PATH env var (ARM-injected)"
    }
}
