#Requires -Modules Pester
<#
.SYNOPSIS
    Validates that the source tree under src/ produces a CANONICAL flat
    function-app.zip structure when packaged by .github/workflows/release.yml.

.DESCRIPTION
    The Azure Functions PowerShell runtime (PowerShell 7.4 worker) requires
    function directories at the ROOT of the deployment zip — NOT nested under
    a `functions/` parent. Packaging that preserves the `src/functions/` parent
    directory results in:
      - Function App enters "Runtime: Error" state at cold start
      - 0 functions enumerated in the Functions tab
      - 0 rows in MDE_Heartbeat_CL
      - Connector card hidden in Sentinel Data Connectors blade
        (connectivityCriteria gates blade visibility on heartbeat presence)

    v0.1.0-beta first deploy attempts shipped exactly this bug. This Pester
    test offline-simulates the zip-build step in release.yml so the bug is
    caught at PR time, not at tag-push time (when the bad zip is already
    published as a release asset).

    Verifies:
      - All 9 timer function directories at the ROOT of the staged tree
        (heartbeat-5m, poll-p0-compliance-1h, poll-p1-pipeline-30m, ...)
      - No `functions/` wrapper directory
      - No `local.settings.json*` development artefact
      - Required root files: host.json, profile.ps1, requirements.psd1
      - Modules/ at root for shared PowerShell modules
#>

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SrcDir     = Join-Path $script:RepoRoot 'src'
    $script:ReleaseYml = Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml'

    # The 9 timer functions that ship with v0.1.0-beta — must all appear at
    # the zip root (NOT under `functions/`) per Azure Functions runtime spec.
    $script:ExpectedFunctions = @(
        'heartbeat-5m'
        'poll-p0-compliance-1h'
        'poll-p1-pipeline-30m'
        'poll-p2-governance-1d'
        'poll-p3-exposure-1h'
        'poll-p5-identity-1d'
        'poll-p6-audit-10m'
        'poll-p7-metadata-1d'
        'validate-auth-selftest'
    )

    # Simulate the release.yml staging step — flatten src/functions/* to root.
    $script:StageDir = Join-Path ([System.IO.Path]::GetTempPath()) "func-app-zip-test-$([Guid]::NewGuid().Guid.Substring(0,8))"
    if (Test-Path $script:StageDir) { Remove-Item $script:StageDir -Recurse -Force }
    New-Item -ItemType Directory -Path $script:StageDir -Force | Out-Null

    # Root-level config files
    foreach ($f in 'host.json', 'profile.ps1', 'requirements.psd1') {
        $sp = Join-Path $script:SrcDir $f
        if (Test-Path $sp) { Copy-Item $sp -Destination $script:StageDir }
    }

    # Modules/ at root
    $modSrc = Join-Path $script:SrcDir 'Modules'
    if (Test-Path $modSrc) {
        Copy-Item $modSrc -Destination (Join-Path $script:StageDir 'Modules') -Recurse
    }

    # FLATTEN: src/functions/<name>/ → $stage/<name>/
    $funcSrcDir = Join-Path $script:SrcDir 'functions'
    if (Test-Path $funcSrcDir) {
        Get-ChildItem -Path $funcSrcDir -Directory | ForEach-Object {
            Copy-Item $_.FullName -Destination (Join-Path $script:StageDir $_.Name) -Recurse
        }
    }

    # Now actually compress to a temp zip — same as release.yml — and re-read
    # the entries via System.IO.Compression to assert the canonical shape.
    $script:ZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "func-app-test-$([Guid]::NewGuid().Guid.Substring(0,8)).zip"
    Push-Location $script:StageDir
    try {
        $relItems = Get-ChildItem -Exclude 'local.settings.json*' | Select-Object -ExpandProperty Name
        Compress-Archive -Path $relItems -DestinationPath $script:ZipPath -Force
    } finally {
        Pop-Location
    }
    $script:ZipEntries = [System.IO.Compression.ZipFile]::OpenRead($script:ZipPath).Entries.FullName
}

AfterAll {
    if ($script:StageDir -and (Test-Path $script:StageDir)) { Remove-Item $script:StageDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:ZipPath -and (Test-Path $script:ZipPath))   { Remove-Item $script:ZipPath -Force -ErrorAction SilentlyContinue }
}

Describe 'Function App zip — canonical flat structure (Azure runtime requirement)' {

    It 'src/ exists and contains a functions/ subdirectory' {
        Test-Path $script:SrcDir                              | Should -BeTrue
        Test-Path (Join-Path $script:SrcDir 'functions')      | Should -BeTrue
    }

    It 'src/functions/ contains all 9 expected timer function directories' {
        $funcSrcDir = Join-Path $script:SrcDir 'functions'
        $actualDirs = @(Get-ChildItem -Path $funcSrcDir -Directory | Select-Object -ExpandProperty Name)
        foreach ($expected in $script:ExpectedFunctions) {
            $actualDirs | Should -Contain $expected -Because "v0.1.0-beta ships 9 timer functions; '$expected' is missing"
        }
    }

    It 'every function directory in src/functions/ has function.json + run.ps1' {
        $funcSrcDir = Join-Path $script:SrcDir 'functions'
        Get-ChildItem -Path $funcSrcDir -Directory | ForEach-Object {
            (Join-Path $_.FullName 'function.json') | Should -Exist -Because "Azure Functions requires function.json in every function dir"
            (Join-Path $_.FullName 'run.ps1')       | Should -Exist -Because "PowerShell-language functions require run.ps1"
        }
    }
}

Describe 'Function App zip — simulated release.yml package shape' {

    It 'simulated zip has NO functions/ wrapper directory' {
        # The critical assertion. v0.1.0-beta first deploy attempt failed
        # because release.yml's `Push-Location ./src; Compress-Archive (Get-ChildItem)`
        # preserved the `functions/` parent → Azure Functions runtime walked
        # the zip looking for function dirs at root and found none → "Runtime: Error".
        $functionsWrapperEntries = @($script:ZipEntries | Where-Object { $_ -like 'functions/*' })
        $functionsWrapperEntries.Count | Should -Be 0 -Because "Azure Functions runtime requires function dirs at zip ROOT, not under functions/. v0.1.0-beta first deploy hit this exact bug."
    }

    It 'simulated zip has all 9 function directories at the ROOT' {
        foreach ($func in $script:ExpectedFunctions) {
            $rootFuncJson = "$func/function.json"
            $script:ZipEntries | Should -Contain $rootFuncJson -Because "Azure Functions PowerShell runtime walks zip ROOT for function.json files; '$func' must be at root, not under functions/"
            $rootRun = "$func/run.ps1"
            $script:ZipEntries | Should -Contain $rootRun -Because "PowerShell function '$func' must have run.ps1 at root"
        }
    }

    It 'simulated zip has required root config files (host.json, profile.ps1, requirements.psd1)' {
        foreach ($required in 'host.json', 'profile.ps1', 'requirements.psd1') {
            $script:ZipEntries | Should -Contain $required -Because "Azure Functions runtime requires '$required' at zip root"
        }
    }

    It 'simulated zip has Modules/ at the ROOT (shared PowerShell modules)' {
        $modulesEntries = @($script:ZipEntries | Where-Object { $_ -like 'Modules/*' })
        $modulesEntries.Count | Should -BeGreaterThan 0 -Because "Modules/ contains shared cmdlets imported by every timer function"
    }

    It 'simulated zip has NO local.settings.json* development artefacts' {
        # local.settings.json holds dev secrets and is excluded from the zip
        # via Get-ChildItem -Exclude. local.settings.json.example is a stowaway
        # that snuck into v0.1.0-beta's first release and shouldn't ship publicly.
        $stowaways = @($script:ZipEntries | Where-Object { $_ -like 'local.settings.json*' })
        $stowaways.Count | Should -Be 0 -Because "local.settings.json* are dev artefacts and must not ship to customers"
    }

    It 'simulated zip total file count is reasonable (>= 30 files, < 1000)' {
        # Count only FILE entries (exclude directory markers — different
        # platforms handle them differently: Windows .NET Compress-Archive
        # emits dir entries, Linux .NET skips them, so total entry count
        # varies by ±1 across runners; counting files only is platform-agnostic).
        # Lower bound: 9 funcs × 2 files (function.json + run.ps1) = 18
        # + 3 root config files (host.json, profile.ps1, requirements.psd1) = 3
        # + Modules/ contents (~12+ .ps1 / .psm1 / .psd1) ≈ ~12
        # Total floor ≈ 33; using 30 as the conservative threshold.
        # 1000 is a hard upper bound — anything beyond suggests we're shipping
        # node_modules / .git / other unintended trees.
        $fileEntries = @($script:ZipEntries | Where-Object { $_ -notmatch '/$' })
        $fileEntries.Count | Should -BeGreaterOrEqual 30 -Because "expected at minimum 9 funcs × 2 files + 3 root config + Modules/ contents"
        $fileEntries.Count | Should -BeLessThan 1000     -Because "zip with > 1000 files suggests unintended trees (node_modules, .git, etc) leaked into staging"
    }
}

Describe 'release.yml — zip-build step validation gates' {
    # Gate the workflow itself — if someone reverts the temp-dir staging in
    # release.yml, this test catches it before merge.

    BeforeAll {
        $script:ReleaseYmlContent = Get-Content $script:ReleaseYml -Raw
    }

    It 'release.yml uses a temp-dir staging pattern (NOT direct Push-Location ./src)' {
        # The bad pattern: Push-Location ./src; Compress-Archive (Get-ChildItem)
        # preserves the functions/ parent → broken zip. The good pattern stages
        # to RUNNER_TEMP and copies src/functions/* directories to the stage root.
        $script:ReleaseYmlContent | Should -Match 'RUNNER_TEMP'   -Because 'release.yml must stage to a temp dir before zipping'
        $script:ReleaseYmlContent | Should -Match 'src/functions' -Because 'release.yml must explicitly enumerate src/functions/* and copy each dir'
    }

    It 'release.yml asserts NO functions/ wrapper exists in the produced zip' {
        # Iter 11 release.yml had a backwards check — `if (-not ...functions/...) throw`
        # which actually REQUIRED the broken shape. Iter 12 inverts to assert
        # the broken shape is ABSENT.
        $script:ReleaseYmlContent | Should -Match "functions/' wrapper" -Because 'release.yml must reject zips with functions/ wrapper'
    }

    It 'release.yml asserts all 9 expected function dirs at zip root' {
        foreach ($func in $script:ExpectedFunctions) {
            $script:ReleaseYmlContent | Should -Match ([regex]::Escape($func)) -Because "release.yml validation must check '$func' is at zip root"
        }
    }

    It 'release.yml excludes local.settings.json* development artefacts' {
        $script:ReleaseYmlContent | Should -Match "local\.settings\.json\*" -Because 'release.yml must exclude dev artefacts to prevent secret leak / customer confusion'
    }
}
