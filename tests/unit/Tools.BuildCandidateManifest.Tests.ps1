#Requires -Module Pester
# Locks tools/Build-CandidateManifest.ps1 + manifests/_subarea-mappings.psd1 (cherry-picked from v3 · F-1+F-6).
# Validates:
#   - Tool script exists and dot-sources cleanly
#   - _subarea-mappings.psd1 schema (per-portal contract)
#   - Memory Rule 2 wholesale drops (AdvancedHunting + AlertsIncidents + LiveResponse for Defender)
#   - DropPathRegex catches graph-proxy paths
#   - PascalCase auto-mapping for unknown tags
#   - EntryKey + Slug builders (deterministic + URL-safe)
#
# Live YAML probe is operator-managed at Phase 0h · uses Get-PortalYmlFiles against references/_external/nodoc/.
# These offline tests use the minimal YAML fixture under tests/fixtures/build-candidate-manifest/.

BeforeAll {
    $script:repoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:toolPath      = Join-Path $script:repoRoot 'tools\Build-CandidateManifest.ps1'
    $script:mappingsPath  = Join-Path $script:repoRoot 'manifests\_subarea-mappings.psd1'
    $script:fixtureRoot   = Join-Path $script:repoRoot 'tests\fixtures\build-candidate-manifest'
}

Describe 'Build-CandidateManifest · script artefacts present (F-1 + F-6 cherry-pick)' -Tag 'build-candidate-manifest' {

    It 'tools/Build-CandidateManifest.ps1 on disk' {
        Test-Path $script:toolPath | Should -BeTrue
    }

    It 'manifests/_subarea-mappings.psd1 on disk' {
        Test-Path $script:mappingsPath | Should -BeTrue
    }

    It 'tests/fixtures/build-candidate-manifest/minimal-defender.yml on disk' {
        Test-Path (Join-Path $script:fixtureRoot 'minimal-defender.yml') | Should -BeTrue
    }
}

Describe 'manifests/_subarea-mappings.psd1 · per-portal contract' -Tag 'build-candidate-manifest' {

    BeforeAll {
        $script:mappings = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script:mappingsPath)))
    }

    It 'has all 5 portals (Defender/Purview/Entra/Intune/SecurityCopilot)' {
        $script:mappings.Keys | Should -Contain 'Defender'
        $script:mappings.Keys | Should -Contain 'Purview'
        $script:mappings.Keys | Should -Contain 'Entra'
        $script:mappings.Keys | Should -Contain 'Intune'
        $script:mappings.Keys | Should -Contain 'SecurityCopilot'
    }

    It 'Defender · Memory Rule 2 wholesale-drops AdvancedHunting + AlertsIncidents + LiveResponse (LOCKED · 2026-05-17)' {
        $defender = $script:mappings['Defender']
        $defender.DropSubAreas | Should -Contain 'AdvancedHunting'
        $defender.DropSubAreas | Should -Contain 'AlertsIncidents'
        $defender.DropSubAreas | Should -Contain 'LiveResponse'
        @($defender.DropSubAreas).Count | Should -Be 3 -Because "ONLY these 3 sub-areas wholesale-excluded · ASR/CR/DT IN-SCOPE via endpoint_configuration/configuration/endpoint_devices"
    }

    It 'Defender · /apiproxy/ prefix declared (Gate O)' {
        $script:mappings['Defender'].PathPrefix | Should -Be '/apiproxy'
    }

    It 'Purview · /apiproxy/ prefix declared · DropPathRegex covers Graph proxy' {
        $script:mappings['Purview'].PathPrefix     | Should -Be '/apiproxy'
        $script:mappings['Purview'].DropPathRegex | Should -Match 'msgraph|GraphProxy'
    }

    It 'Entra · IsMultiSpec=$true with 5 sub-portals (IAM/PIM/IDGov/IGA/B2C)' {
        $entra = $script:mappings['Entra']
        $entra.IsMultiSpec      | Should -BeTrue
        $entra.SpecGroup.Keys   | Should -Contain 'IAM'
        $entra.SpecGroup.Keys   | Should -Contain 'PIM'
        $entra.SpecGroup.Keys   | Should -Contain 'IDGov'
        $entra.SpecGroup.Keys   | Should -Contain 'IGA'
        $entra.SpecGroup.Keys   | Should -Contain 'B2C'
    }

    It 'Intune · IsMultiSpec=$true with Portal + Autopatch sub-portals' {
        $intune = $script:mappings['Intune']
        $intune.IsMultiSpec     | Should -BeTrue
        $intune.SpecGroup.Keys  | Should -Contain 'Portal'
        $intune.SpecGroup.Keys  | Should -Contain 'Autopatch'
    }

    It 'every portal declares AuthScheme matching the bearer/cookie split' {
        foreach ($portal in @('Defender','Purview')) {
            $script:mappings[$portal].AuthScheme | Should -Match '^cookie-' -Because "$portal uses cookie chain"
        }
        foreach ($portal in @('Entra','Intune','SecurityCopilot')) {
            $script:mappings[$portal].AuthScheme | Should -Match '^bearer-' -Because "$portal uses bearer chain"
        }
    }

    It 'Defender SubAreaCapability annotates capability flags per D-34' {
        $defender = $script:mappings['Defender']
        $defender.SubAreaCapability.Keys | Should -Contain 'CloudApps'
        $defender.SubAreaCapability['CloudApps'] | Should -Be 'IsMcasActive'
        $defender.SubAreaCapability['Identity']  | Should -Be 'IsMdiActive'
    }
}

Describe 'Build-CandidateManifest · live YAML parse via minimal fixture' -Tag 'build-candidate-manifest' {

    It 'dot-sources Get-NodocOperations + parses 3-operation fixture · drops AdvancedHunting + GraphProxy' {
        # Dot-source the tool to bring helper functions into scope (avoid running main block).
        # Main block runs on script load; capture its noise + ignore exit.
        $fixtureYml = Join-Path $script:fixtureRoot 'minimal-defender.yml'
        Test-Path $fixtureYml | Should -BeTrue

        # Parse YAML via the tool's Get-NodocOperations function
        # Tool runs Main at script load · we capture output silently
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-bcm-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $tempRoot 'manifests') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempRoot 'tools')     -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempRoot 'references/_external/nodoc/specifications/nodoc-defender-xdr/specification') -Force | Out-Null

        try {
            # Copy minimal fixture to expected spec path
            Copy-Item $fixtureYml (Join-Path $tempRoot 'references/_external/nodoc/specifications/nodoc-defender-xdr/specification/portal_services.yml')
            # Copy mappings + tool to temp repo
            Copy-Item $script:mappingsPath (Join-Path $tempRoot 'manifests/_subarea-mappings.psd1')
            Copy-Item $script:toolPath     (Join-Path $tempRoot 'tools/Build-CandidateManifest.ps1')

            # Run tool against temp repo (Defender portal only)
            $stdout = & pwsh -NoProfile -File (Join-Path $tempRoot 'tools/Build-CandidateManifest.ps1') `
                -RepoRoot $tempRoot -Portal Defender -NoEvidence 2>&1

            # Manifest should exist · contain TenantContext entry only (AdvancedHunting + GraphProxy dropped)
            $manifest = Join-Path $tempRoot 'manifests/defender.psd1'
            Test-Path $manifest | Should -BeTrue

            $content = Get-Content -Raw $manifest
            $content | Should -Match 'TenantContext'
            $content | Should -Not -Match 'AdvancedHunting.Run'
            $content | Should -Not -Match 'GraphProxy.Alerts'

            # Audit JSON should record both drops
            $audit = Get-Content -Raw (Join-Path $tempRoot 'manifests/_step5-audit.json') | ConvertFrom-Json
            @($audit.Drops.ByReason).Count | Should -BeGreaterOrEqual 1
            ($audit.Drops.ByReason | ForEach-Object { $_.Reason }) | Should -Contain 'memory-rule-2-wholesale'
        } finally {
            Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
        }
    }
}
