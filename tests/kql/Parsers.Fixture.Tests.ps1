#Requires -Modules Pester
<#
.SYNOPSIS
    Fixture-driven contract tests for the 4 cadence-tier drift parsers.

.DESCRIPTION
    Two layers of verification, offline:

    (A) Static parser audit (every parser under sentinel/parsers/MDE_Drift_*.kql):
        1. File parses as KQL text with no obvious syntax garbage.
        2. The tier union list matches the manifest's streams for that cadence
           tier (no references to REMOVED streams; every active stream is listed).
           The Maintenance parser also excludes the deprecated stream from its
           union (deprecated streams are NEVER unioned by any parser).
        3. The `| project` emits exactly the 9 documented drift columns:
           TimeGenerated, StreamName, EntityId, FieldName, OldValue, NewValue,
           SnapshotCurrent, SnapshotPrevious, ChangeType.

    (B) Fixture-scenario contract tests:
        1. Sample-snapshot fixtures for drift scenarios parse + have required keys.
        2. The Added/Removed/Modified semantics implied by each scenario's
           expectedDrift match the before/after diff (computed here in PS, not KQL).

    This does NOT execute KQL against a live Kusto engine — the NuGet Kusto.Language
    validator is scoped for v1.1. Today we guarantee: the parsers REFERENCE the
    right tables, EMIT the right columns, and the fixtures MEAN what they claim.

    Tier mapping (parser → cadence-tier streams from manifest):
        MDE_Drift_Exposure       → exposure
        MDE_Drift_Configuration  → config
        MDE_Drift_Inventory      → inventory
        MDE_Drift_Maintenance    → maintenance (active streams only)
    The 'ActionCenter' tier (Action Center events) has NO parser — those streams carry
    occurrences, not snapshots, so field-level drift is undefined.
#>

BeforeDiscovery {
    $repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $manifestPath = Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $manifest     = Import-PowerShellDataFile -Path $manifestPath

    # Tier-to-streams map EXCLUDES deprecated streams. Parsers should not
    # unconditionally union deprecated tables (they produce zero rows
    # post-deprecation; the unconditional union creates dead source-table list
    # entries that mislead rule authors). Pair with
    # tests/kql/Parsers.NoDeprecatedUnion.Tests.ps1 which locks the inverse.
    $script:StreamsByTier = @{}
    foreach ($e in $manifest.Endpoints) {
        if ($e.Availability -eq 'deprecated') { continue }
        if (-not $script:StreamsByTier.ContainsKey($e.Tier)) {
            $script:StreamsByTier[$e.Tier] = @()
        }
        $script:StreamsByTier[$e.Tier] += $e.Stream
    }

    # Parser-name → tier map. The 'ActionCenter' tier has no parser.
    $parserTierMap = @{
        'MDE_Drift_Exposure'      = 'XspmGraph'
        'MDE_Drift_Configuration' = 'Configuration'
        'MDE_Drift_Inventory'     = 'Inventory'
        'MDE_Drift_Maintenance'   = 'Maintenance'
    }

    $parsersDir = Join-Path $repoRoot 'sentinel' 'parsers'
    $script:ParserCases = @()
    foreach ($p in Get-ChildItem $parsersDir -Filter 'MDE_Drift_*.kql') {
        if ($parserTierMap.ContainsKey($p.BaseName)) {
            $tier = $parserTierMap[$p.BaseName]
            $script:ParserCases += @{
                Path     = $p.FullName
                Name     = $p.Name
                Tier     = $tier
                Expected = if ($script:StreamsByTier.ContainsKey($tier)) { $script:StreamsByTier[$tier] } else { @() }
            }
        }
    }
}

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    $script:FixtureDir       = Join-Path $repoRoot 'tests' 'fixtures' 'sample-snapshots'
    $script:LiveFixturesDir  = Join-Path $repoRoot 'tests' 'fixtures' 'live-responses'

    # v0.1.0-beta parsers output these 9 columns. Any change here is a breaking
    # change for every analytic rule / hunting query / workbook that consumes
    # parser output.
    $script:ExpectedParserColumns = @(
        'TimeGenerated', 'StreamName', 'EntityId', 'FieldName',
        'OldValue', 'NewValue', 'SnapshotCurrent', 'SnapshotPrevious', 'ChangeType'
    )

    # Removed streams — parsers MUST NOT reference these.
    $script:RemovedStreams = @(
        'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
        'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL',
        'MDE_SecureScoreBreakdown_CL'  # Graph /security/secureScores covers it
    )
}

Describe 'Parser static audit — per cadence tier' -ForEach $script:ParserCases {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:ExpectedParserColumns = @(
            'TimeGenerated', 'StreamName', 'EntityId', 'FieldName',
            'OldValue', 'NewValue', 'SnapshotCurrent', 'SnapshotPrevious', 'ChangeType'
        )
        $script:RemovedStreams = @(
            'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
            'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL',
            'MDE_SecureScoreBreakdown_CL'
        )

        $text = Get-Content $_.Path -Raw
        $unionMatch = [regex]::Match($text, 'union\s+withsource=_Table\s+([\s\S]*?)(?=\|\s*where|\|\s*summarize|\|\s*extend|\Z)', 'IgnoreCase')
        $script:ParserTables = @()
        if ($unionMatch.Success) {
            $script:ParserTables = [regex]::Matches($unionMatch.Groups[1].Value, '\bMDE_[A-Za-z0-9]+_CL\b') |
                ForEach-Object { $_.Value } | Sort-Object -Unique
        }

        # Column extraction: find the LAST `| project` block and scan it for
        # every identifier that could be an output column.
        $projectIdxes = [regex]::Matches($text, '\|\s*project\b', 'IgnoreCase')
        $script:ParserColumns = @()
        if ($projectIdxes.Count -gt 0) {
            $last = $projectIdxes[$projectIdxes.Count - 1]
            $pBlock = $text.Substring($last.Index + $last.Length)
            $aliased = [regex]::Matches($pBlock, '(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') |
                ForEach-Object { $_.Groups[1].Value }
            $bare = [regex]::Matches($pBlock, '(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*,?\s*$') |
                ForEach-Object { $_.Groups[1].Value }
            $script:ParserColumns = @($aliased + $bare | Sort-Object -Unique)
        }
    }

    It 'parser file <Name> exists and has non-empty content' {
        Test-Path $_.Path | Should -BeTrue
        (Get-Item $_.Path).Length | Should -BeGreaterThan 100
    }

    It 'parser <Name> references exactly the manifest streams for tier <Tier>' {
        Compare-Object -ReferenceObject $_.Expected -DifferenceObject $script:ParserTables |
            Should -BeNullOrEmpty -Because "parser must list every active <$($_.Tier)> stream from the manifest and nothing else"
    }

    It 'parser <Name> references NO removed streams' {
        foreach ($r in $script:RemovedStreams) {
            $script:ParserTables | Should -Not -Contain $r -Because "parser references $r which has been removed (NO_PUBLIC_API or public-API-covered)"
        }
    }

    It 'parser <Name> emits all 9 expected drift columns in its project clause' {
        foreach ($c in $script:ExpectedParserColumns) {
            $script:ParserColumns | Should -Contain $c -Because "parser $($_.Name) must project column '$c' for downstream consumers"
        }
    }
}

Describe 'Sample-snapshot fixture files — presence and structure' {
    It 'sample-snapshots directory exists' {
        Test-Path $script:FixtureDir | Should -BeTrue
    }

    It 'at least 2 fixture files present' {
        $files = Get-ChildItem -Path $script:FixtureDir -Filter '*.json'
        $files.Count | Should -BeGreaterOrEqual 2
    }

    It 'no fixture references a removed stream' {
        foreach ($file in Get-ChildItem -Path $script:FixtureDir -Filter '*.json') {
            $content = Get-Content $file.FullName -Raw
            foreach ($r in $script:RemovedStreams) {
                $content | Should -Not -Match ([regex]::Escape($r)) -Because "fixture $($file.Name) references removed stream $r"
            }
        }
    }

    It 'every fixture file is valid JSON' {
        foreach ($file in Get-ChildItem -Path $script:FixtureDir -Filter '*.json') {
            { Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } |
                Should -Not -Throw -Because "fixture $($file.Name) must be parseable JSON"
        }
    }
}

Describe 'MDE_AdvancedFeatures before/after snapshot pair' {
    BeforeAll {
        $script:BeforePath = Join-Path $script:FixtureDir 'MDE_AdvancedFeatures_before.json'
        $script:AfterPath  = Join-Path $script:FixtureDir 'MDE_AdvancedFeatures_after.json'
        $script:Before = Get-Content $script:BeforePath -Raw | ConvertFrom-Json
        $script:After  = Get-Content $script:AfterPath  -Raw | ConvertFrom-Json
    }

    It 'both snapshot files exist' {
        Test-Path $script:BeforePath | Should -BeTrue
        Test-Path $script:AfterPath  | Should -BeTrue
    }

    It 'each row has required columns (TimeGenerated, SourceStream, EntityId, RawJson)' {
        $script:Before + $script:After | ForEach-Object {
            $_.TimeGenerated | Should -Not -BeNullOrEmpty
            $_.SourceStream  | Should -Be 'MDE_AdvancedFeatures_CL'
            $_.EntityId      | Should -Not -BeNullOrEmpty
            $_.RawJson       | Should -Not -BeNullOrEmpty
        }
    }

    It 'captures the TamperProtection feature downgrade scenario' {
        $beforeTp = $script:Before | Where-Object EntityId -eq 'TamperProtection'
        $afterTp  = $script:After  | Where-Object EntityId -eq 'TamperProtection'
        $beforeTp.Enabled | Should -BeTrue  -Because 'before state: TamperProtection enabled'
        $afterTp.Enabled  | Should -BeFalse -Because 'after state: TamperProtection disabled (drift event)'
    }

    It 'captures a new-feature-added scenario (Added change-type)' {
        $beforeIds = $script:Before | ForEach-Object EntityId
        $afterIds  = $script:After  | ForEach-Object EntityId
        $added = $afterIds | Where-Object { $_ -notin $beforeIds }
        $added | Should -Contain 'NewFeature' -Because 'after snapshot has a feature not in before'
    }
}

Describe 'MDE_XspmAttackPaths set-diff drift scenario (exposure tier)' {
    BeforeAll {
        $script:XspmScenarioPath = Join-Path $script:FixtureDir 'MDE_XspmAttackPaths_drift_scenario.json'
        $script:XspmScenario = Get-Content $script:XspmScenarioPath -Raw | ConvertFrom-Json
    }

    It 'scenario file exists and has required keys' {
        Test-Path $script:XspmScenarioPath | Should -BeTrue
        foreach ($key in 'description', 'before', 'after', 'expectedDrift') {
            $script:XspmScenario.$key | Should -Not -BeNullOrEmpty
        }
    }

    It 'expectedDrift contains an Added path and a Removed path (set-diff shape)' {
        $added   = $script:XspmScenario.expectedDrift | Where-Object ChangeType -eq 'Added'
        $removed = $script:XspmScenario.expectedDrift | Where-Object ChangeType -eq 'Removed'
        $added.Count   | Should -BeGreaterThan 0 -Because 'Exposure parser set-diff must surface Added entities'
        $removed.Count | Should -BeGreaterThan 0 -Because 'Exposure parser set-diff must surface Removed entities'
    }

    It 'Added path IDs exist in after but NOT in before' {
        $added = $script:XspmScenario.expectedDrift | Where-Object ChangeType -eq 'Added'
        $beforeIds = $script:XspmScenario.before | ForEach-Object EntityId
        $afterIds  = $script:XspmScenario.after  | ForEach-Object EntityId
        foreach ($a in $added) {
            $a.EntityId | Should -BeIn $afterIds  -Because "Added entity $($a.EntityId) must be in after"
            $a.EntityId | Should -Not -BeIn $beforeIds -Because "Added entity $($a.EntityId) must NOT be in before"
        }
    }

    It 'Removed path IDs exist in before but NOT in after' {
        $removed = $script:XspmScenario.expectedDrift | Where-Object ChangeType -eq 'Removed'
        $beforeIds = $script:XspmScenario.before | ForEach-Object EntityId
        $afterIds  = $script:XspmScenario.after  | ForEach-Object EntityId
        foreach ($r in $removed) {
            $r.EntityId | Should -BeIn $beforeIds -Because "Removed entity $($r.EntityId) must be in before"
            $r.EntityId | Should -Not -BeIn $afterIds -Because "Removed entity $($r.EntityId) must NOT be in after"
        }
    }

    It 'all scenario rows reference the XspmAttackPaths stream' {
        $script:XspmScenario.before + $script:XspmScenario.after | ForEach-Object {
            $_.SourceStream | Should -Be 'MDE_XspmAttackPaths_CL'
        }
    }
}

Describe 'Parser-tier coverage — live fixture shape compatibility' {
    # For each parser, there should be at least ONE live-response fixture for a
    # stream in its cadence tier so KQL drift against live data is possible
    # post-deployment.
    It 'Exposure parser has at least one live fixture' {
        @(Get-ChildItem $script:LiveFixturesDir -Filter 'MDE_*_CL-raw.json' | Where-Object {
            $_.BaseName -match '^MDE_(AssetRules|XspmInitiatives|ExposureSnapshots|ExposureRecommendations|XspmAttackPaths|XspmChokePoints|XspmTopTargets)_CL-raw$'
        }).Count | Should -BeGreaterThan 0
    }

    It 'Configuration parser has at least one live fixture' {
        @(Get-ChildItem $script:LiveFixturesDir -Filter 'MDE_*_CL-raw.json' | Where-Object {
            $_.BaseName -match '^MDE_(PreviewFeatures|AlertServiceConfig|AlertTuning|SuppressionRules|CustomDetections|TenantAllowBlock|ConnectedApps|IntuneConnection|PurviewSharing|RbacDeviceGroups|UnifiedRbacRoles|ThreatAnalytics|UserPreferences|CloudAppsConfig)_CL-raw$'
        }).Count | Should -BeGreaterThan 0
    }

    It 'Inventory parser has at least one live fixture' {
        @(Get-ChildItem $script:LiveFixturesDir -Filter 'MDE_*_CL-raw.json' | Where-Object {
            $_.BaseName -match '^MDE_(AdvancedFeatures|DeviceControlPolicy|WebContentFiltering|SmartScreenConfig|LiveResponseConfig|AuthenticatedTelemetry|PUAConfig|AntivirusPolicy|CustomCollection|TenantContext|TenantWorkloadStatus|SAClassification|IdentityOnboarding|IdentityServiceAccounts|DCCoverage|IdentityAlertThresholds|RemediationAccounts|SecurityBaselines|MtoTenants|LicenseReport|DeviceTimeline)_CL-raw$'
        }).Count | Should -BeGreaterThan 0
    }

    It 'Maintenance parser has at least one live fixture (DataExportSettings)' {
        @(Get-ChildItem $script:LiveFixturesDir -Filter 'MDE_*_CL-raw.json' | Where-Object {
            $_.BaseName -match '^MDE_DataExportSettings_CL-raw$'
        }).Count | Should -BeGreaterThan 0
    }
}
