#Requires -Module Pester
# Builds the function-app.zip via Build-FunctionAppZip.ps1 (no Az bundling for speed)
# and asserts the layout matches what the FA runtime expects. Locks the FLAT layout
# regression class (bundled-into-functions/ wrapper was a recurring prior-fork bug).

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:BuildTool  = Join-Path $script:RepoRoot 'tools\Build-FunctionAppZip.ps1'
    $script:ZipPath    = Join-Path $TestDrive 'function-app.zip'
    & $script:BuildTool -OutputPath $script:ZipPath -MaxSizeMB 50 | Out-Null

    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    $script:Archive = [System.IO.Compression.ZipFile]::OpenRead($script:ZipPath)
    $script:Entries = @($script:Archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
}

AfterAll {
    if ($script:Archive) { $script:Archive.Dispose() }
}

Describe 'function-app.zip layout' -Tag 'fa-zip' {

    It 'builds successfully and is under 25 MB without Az bundling' {
        $sizeMB = (Get-Item $script:ZipPath).Length / 1MB
        $sizeMB | Should -BeLessThan 25
    }

    It 'has host.json at the ROOT (FLAT layout — no functions/ wrapper)' {
        $script:Entries | Should -Contain 'host.json'
    }

    It 'has profile.ps1 + requirements.psd1 at root' {
        $script:Entries | Should -Contain 'profile.ps1'
        $script:Entries | Should -Contain 'requirements.psd1'
    }

    It 'has Xdr-Poll/function.json + run.ps1 (function directory at root, not under functions/)' {
        $script:Entries | Should -Contain 'Xdr-Poll/function.json'
        $script:Entries | Should -Contain 'Xdr-Poll/run.ps1'
        # Anti-bloat regression: no nested 'functions/Xdr-Poll/' wrapper
        ($script:Entries | Where-Object { $_ -like 'functions/*' }) | Should -BeNullOrEmpty
    }

    It 'has all 5 Xdr.* modules under Modules name name.psm1 path (Common.Telemetry + Auth + Poll + Ingest + Parser)' {
        foreach ($m in 'Xdr.Common.Telemetry','Xdr.Auth','Xdr.Poll','Xdr.Ingest','Xdr.Parser') {
            $script:Entries | Should -Contain "Modules/$m/$m.psm1"
            $script:Entries | Should -Contain "Modules/$m/$m.psd1"
        }
    }

    It 'has manifests/defender.psd1 (loaded by Xdr-Poll via MANIFEST_PATH env var)' {
        $script:Entries | Should -Contain 'manifests/defender.psd1'
    }

    It 'φ.I · bundles ALL 5 portal manifests (defender + purview + entra + intune + securitycopilot)' {
        # v0.1.0 Defender ACTIVE · 4 portals AUTH-SCAFFOLDED for v0.3.0 polling
        $script:Entries | Should -Contain 'manifests/defender.psd1'
        $script:Entries | Should -Contain 'manifests/purview.psd1'
        $script:Entries | Should -Contain 'manifests/entra.psd1'
        $script:Entries | Should -Contain 'manifests/intune.psd1'
        $script:Entries | Should -Contain 'manifests/securitycopilot.psd1'
    }

    It 'has NO __MACOSX / .DS_Store / .git noise' {
        $script:Entries | Where-Object { $_ -like '__MACOSX/*' -or $_ -like '*/.DS_Store' -or $_ -like '.git/*' } | Should -BeNullOrEmpty
    }

    It 'has NO tests/ or tools/ or deploy/ leakage' {
        $script:Entries | Where-Object { $_ -like 'tests/*' -or $_ -like 'tools/*' -or $_ -like 'deploy/*' } | Should -BeNullOrEmpty
    }
}
