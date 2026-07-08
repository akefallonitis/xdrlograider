#Requires -Version 7.4
# SelfTest for tools/Assert-ShippedManifestParity.ps1 — the INVERSE manifest invariant (gauntlet Axis 37 ·
# VulnerabilityManagement-class drift guard). The catalogue ship-gate marks ops Shipped=true WITHOUT any manifest
# term; the manifest is a downstream artifact. Validate-Manifests only sees manifests that EXIST, so a category
# Shipped=true with NO manifest is invisible to it. This test RED-proves the inverse: it drives the REAL validator
# (NOT a re-implementation) against synthetic temp repos and asserts it FAILS+names a Shipped category lacking a
# manifest, PASSES when every Shipped category has one, and does NOT require a manifest for a category whose ops are
# all un-shipped (the exact post-un-ship VulnerabilityManagement shape). Same temp-repo + src-junction harness as
# tests/unit/Process/ManifestShipGates.Tests.ps1 (the validator imports Xdr.Common.Parser off its OWN script dir, so
# only references/inventory + manifests/ need to live in the synthetic root — but the src link keeps it identical to
# the established pattern and robust if the import path ever changes).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:tool = Join-Path $script:repo 'tools/Assert-ShippedManifestParity.ps1'
    $script:temps = @()

    # A minimal portals.json carrying ONLY the Defender entry — the validator resolves -Portal Defender -> portalKey
    # nodoc-defender-xdr through this file EXACTLY as Generate-Manifest does.
    $script:portalsJson = (@{ portals = @(@{ PortalKey = 'nodoc-defender-xdr'; PortalShort = 'defender-xdr' }) } | ConvertTo-Json -Depth 5)

    # Build a synthetic catalogue.json with the given (Category, Shipped) ops, plus a synthetic manifests/Defender
    # directory containing exactly $ManifestTokens.psd1 files. Returns the temp repo root.
    function New-ParityRepo {
        param(
            [object[]] $Ops,            # @(@{ Category='X'; Shipped=$true }, ...)
            [string[]] $ManifestTokens  # tokens (file base names) to create under manifests/Defender (e.g. 'EndpointManagement')
        )
        $t = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-parity-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $t 'references/inventory/nodoc-defender-xdr') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $t 'manifests/Defender') -Force | Out-Null
        # src/ reachable for the validator's Parser import (CROSS-PLATFORM · parity with ManifestShipGates.Tests.ps1:
        # Junction on Windows · SymbolicLink on the ubuntu ci runner).
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path (Join-Path $t 'src') -Target (Join-Path $script:repo 'src') | Out-Null

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $t 'references/inventory/portals.json'), $script:portalsJson, $utf8)
        $catalogue = @{ Portal = 'Defender'; PortalKey = 'nodoc-defender-xdr'; Operations = @($Ops | ForEach-Object { @{ Category = $_.Category; Shipped = [bool]$_.Shipped } }) }
        [IO.File]::WriteAllText((Join-Path $t 'references/inventory/nodoc-defender-xdr/catalogue.json'), ($catalogue | ConvertTo-Json -Depth 8), $utf8)
        foreach ($tok in $ManifestTokens) {
            # A non-empty placeholder · the inverse-invariant axis asserts EXISTENCE (Validate-Manifests/Axis 28 own
            # manifest CONTENT). Existence is exactly what the VulnerabilityManagement drift lacked.
            [IO.File]::WriteAllText((Join-Path $t "manifests/Defender/$tok.psd1"), "@{ Portal = 'Defender'; Category = '$tok'; Operations = @() }`n", $utf8)
        }
        $script:temps += $t
        $t
    }

    function Invoke-Parity {
        param([string] $RepoRoot)
        $json = & pwsh -NoProfile -File $script:tool -Portal Defender -RepoRoot $RepoRoot -Json 2>&1 | Out-String
        $obj = try { $json | ConvertFrom-Json } catch { $null }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Json = $json; Obj = $obj }
    }
}
AfterAll {
    foreach ($t in $script:temps) {
        if (Test-Path $t) {
            # Remove the src LINK first (delete the link · never the target) so -Recurse can't traverse the real src
            # on a platform that follows symlinks. (Same teardown as ManifestShipGates.Tests.ps1.)
            $srcLink = Join-Path $t 'src'
            if (Test-Path $srcLink) { try { (Get-Item $srcLink -Force).Delete() } catch { } }
            Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Axis 37 SelfTest · tool parses + loads' {
    It 'parses with zero errors' {
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
}

Describe 'Axis 37 SelfTest · INVERSE manifest invariant · a Shipped category WITHOUT a manifest FAILS and is named' {
    It 'FAILS (exit 1) and NAMES the Shipped category that has no manifest (the VulnerabilityManagement-class drift)' {
        # "Endpoint Management" is Shipped but ONLY "Operations" has a manifest → EndpointManagement.psd1 is missing.
        $repo = New-ParityRepo -Ops @(
            @{ Category = 'Operations';          Shipped = $true }
            @{ Category = 'Endpoint Management'; Shipped = $true }
        ) -ManifestTokens @('Operations')
        $r = Invoke-Parity $repo
        $r.ExitCode      | Should -Be 1
        $r.Obj.verdict   | Should -Be 'FAIL'
        # the offending category IS listed (by name) AND its expected token-mapped manifest path
        ($r.Obj.missing.category)         | Should -Contain 'Endpoint Management'
        ($r.Obj.missing.expectedManifest) | Should -Contain 'manifests/Defender/EndpointManagement.psd1'
        # a category that DOES have its manifest is NOT mis-reported as missing
        ($r.Obj.missing.category)         | Should -Not -Contain 'Operations'
    }

    It 'names EVERY missing Shipped category when more than one lacks a manifest' {
        $repo = New-ParityRepo -Ops @(
            @{ Category = 'Cloud Apps';        Shipped = $true }
            @{ Category = 'Analytics & Data';  Shipped = $true }
        ) -ManifestTokens @()   # neither manifest present
        $r = Invoke-Parity $repo
        $r.ExitCode | Should -Be 1
        @($r.Obj.missing).Count | Should -Be 2
        ($r.Obj.missing.expectedManifest) | Should -Contain 'manifests/Defender/CloudApps.psd1'
        ($r.Obj.missing.expectedManifest) | Should -Contain 'manifests/Defender/AnalyticsData.psd1'
    }
}

Describe 'Axis 37 SelfTest · every Shipped category HAS a manifest → PASSES' {
    It 'PASSES (exit 0) when each distinct Shipped category maps to an existing token manifest (spaced/& names included)' {
        # The space/& category names exercise the SHARED Get-XdrCategoryToken mapping the generator uses
        # ("Endpoint Management"->EndpointManagement · "Analytics & Data"->AnalyticsData).
        $repo = New-ParityRepo -Ops @(
            @{ Category = 'Operations';          Shipped = $true }
            @{ Category = 'Endpoint Management'; Shipped = $true }
            @{ Category = 'Analytics & Data';    Shipped = $true }
        ) -ManifestTokens @('Operations', 'EndpointManagement', 'AnalyticsData')
        $r = Invoke-Parity $repo
        $r.ExitCode | Should -Be 0
        $r.Obj.verdict | Should -Be 'PASS'
        @($r.Obj.missing).Count | Should -Be 0
        $r.Obj.shippedCategoryCount | Should -Be 3
    }
}

Describe 'Axis 37 SelfTest · the predicate is >=1 Shipped · an all-un-shipped category needs NO manifest' {
    It 'does NOT require a manifest for a category whose ops are ALL Shipped=false (the post-un-ship VulnerabilityManagement shape)' {
        # Vulnerability Management present with ops but 0 Shipped → must NOT be required to have a manifest (the fix
        # that resolved the drift was to UN-SHIP · this asserts the axis agrees un-shipping is a valid resolution).
        $repo = New-ParityRepo -Ops @(
            @{ Category = 'Operations';               Shipped = $true }
            @{ Category = 'Vulnerability Management'; Shipped = $false }
            @{ Category = 'Vulnerability Management'; Shipped = $false }
        ) -ManifestTokens @('Operations')   # NO VulnerabilityManagement.psd1
        $r = Invoke-Parity $repo
        $r.ExitCode | Should -Be 0
        $r.Obj.verdict | Should -Be 'PASS'
        $r.Obj.shippedCategoryCount | Should -Be 1
        ($r.Obj.missing.category) | Should -Not -Contain 'Vulnerability Management'
    }
}
