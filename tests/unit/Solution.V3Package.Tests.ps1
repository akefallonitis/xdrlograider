#Requires -Module Pester
# φ.H · Sentinel Solution V3 package · marketplace-submittable scaffold
# Locks: Package/manifest.json + SolutionMetadata.json shape · Build-SolutionPackage tool
# emits valid V3 zip · contentSchemaVersion=3.0.0 · gate ζ.SolutionV3 closed.

BeforeAll {
    $script:RepoRoot          = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:PackageManifest   = Join-Path $script:RepoRoot 'Package\manifest.json'
    $script:PackageMetadata   = Join-Path $script:RepoRoot 'Package\SolutionMetadata.json'
    $script:BuildScript       = Join-Path $script:RepoRoot 'tools\Build-SolutionPackage.ps1'
}

Describe 'φ.H · Package/manifest.json · Sentinel Solution V3 schema' -Tag 'solution-v3' {

    It 'Package/manifest.json exists' {
        Test-Path $script:PackageManifest | Should -BeTrue
    }

    It 'is valid JSON with all required V3 fields' {
        $pmf = Get-Content -Raw -LiteralPath $script:PackageManifest | ConvertFrom-Json
        foreach ($r in 'Name','Author','Version','TemplateSpec','Is1PConnector','StaticDataConnectorIds','DataConnectors','ContentSchemaVersion') {
            $pmf.PSObject.Properties.Name | Should -Contain $r -Because "V3 schema requires '$r' field"
        }
    }

    It 'ContentSchemaVersion is 3.0.0 (V3 marketplace)' {
        $pmf = Get-Content -Raw -LiteralPath $script:PackageManifest | ConvertFrom-Json
        $pmf.ContentSchemaVersion | Should -Be '3.0.0'
    }

    It 'StaticDataConnectorIds contains XdrLogRaiderInternal (matches sentinelContent.json id)' {
        $pmf = Get-Content -Raw -LiteralPath $script:PackageManifest | ConvertFrom-Json
        @($pmf.StaticDataConnectorIds) | Should -Contain 'XdrLogRaiderInternal'
    }

    It 'DataConnectors array points to deploy/sentinelContent.json' {
        $pmf = Get-Content -Raw -LiteralPath $script:PackageManifest | ConvertFrom-Json
        @($pmf.DataConnectors) | Should -Contain 'deploy/sentinelContent.json'
    }

    It 'Empty content slots (v0.1.0 connector-only · v0.2.0 fills · per D-2026-05-18g)' {
        $pmf = Get-Content -Raw -LiteralPath $script:PackageManifest | ConvertFrom-Json
        foreach ($k in 'AnalyticalRules','HuntingQueries','Parsers','Workbooks','Playbooks') {
            @($pmf.$k).Count | Should -Be 0 -Because "v0.1.0 ships connector-only · $k deferred to v0.2.0"
        }
    }
}

Describe 'φ.H · Package/SolutionMetadata.json · publisher + support' -Tag 'solution-v3' {

    It 'SolutionMetadata.json exists with publisherId + offerId + categories + support' {
        Test-Path $script:PackageMetadata | Should -BeTrue
        $meta = Get-Content -Raw -LiteralPath $script:PackageMetadata | ConvertFrom-Json
        $meta.publisherId | Should -Not -BeNullOrEmpty
        $meta.offerId     | Should -Not -BeNullOrEmpty
        $meta.categories.domains | Should -Not -BeNullOrEmpty
        $meta.support.email | Should -Match '@'
    }
}

Describe 'φ.H · Build-SolutionPackage tool · emits valid V3 zip' -Tag 'solution-v3' {

    It 'Build-SolutionPackage.ps1 exists + parses cleanly' {
        Test-Path $script:BuildScript | Should -BeTrue
        { [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $script:BuildScript), [ref]$null) } | Should -Not -Throw
    }

    It 'Build-SolutionPackage emits a valid V3 zip · structure matches Azure-Sentinel/Solutions/(Name)/Package/' {
        $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-solv3-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            $zipPath = & $script:BuildScript -OutputDir $tmpOut 2>&1 | Select-Object -Last 1
            $zipPath | Should -Match '\.zip$'
            Test-Path $zipPath | Should -BeTrue

            # Inspect zip structure
            $tmpExtract = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-solv3-extract-" + [guid]::NewGuid().ToString('N').Substring(0,8))
            Expand-Archive -LiteralPath $zipPath -DestinationPath $tmpExtract -Force
            try {
                # Expected · <PackageName>/Package/manifest.json · <PackageName>/Data Connectors/XdrLogRaiderInternal.json
                $solRoot = Get-ChildItem -Path $tmpExtract -Directory | Select-Object -First 1
                $solRoot | Should -Not -BeNullOrEmpty
                Test-Path (Join-Path $solRoot.FullName 'Package\manifest.json')                  | Should -BeTrue
                Test-Path (Join-Path $solRoot.FullName 'Package\SolutionMetadata.json')           | Should -BeTrue
                Test-Path (Join-Path $solRoot.FullName 'Package\mainTemplate.json')              | Should -BeTrue
                Test-Path (Join-Path $solRoot.FullName 'Package\createUiDefinition.json')        | Should -BeTrue
                Test-Path (Join-Path $solRoot.FullName 'Data Connectors\XdrLogRaiderInternal.json') | Should -BeTrue
            } finally {
                if (Test-Path $tmpExtract) { Remove-Item -Recurse -Force $tmpExtract -ErrorAction SilentlyContinue }
            }
        } finally {
            if (Test-Path $tmpOut) { Remove-Item -Recurse -Force $tmpOut -ErrorAction SilentlyContinue }
        }
    }
}
