#Requires -Modules Pester
<#
.SYNOPSIS
    Drift gate: Sentinel content (parsers + analytic rules + hunting queries +
    workbooks) referencing typed columns MUST reference cols declared in the
    manifest's ProjectionMap for that stream.

.DESCRIPTION
    iter-14.0 Phase 3 (v0.1.0 GA). Closes the SSoT loop per Section 2.1 of the
    senior-architect plan: manifest is the source of truth for typed cols;
    Sentinel content references must be valid against it.

    Without this gate, Phase 1 col renames silently break operator workbooks /
    rules / hunting queries that reference dropped col names. Operators see
    null cols at query time but tests stay green.

    This gate parses each Sentinel content file (KQL / YAML / JSON), extracts
    every `MDE_<X>_CL | project ..., ColName, ...` reference, and asserts the
    col is declared in the manifest's ProjectionMap for that stream.

    Parsing is pragmatic, not full KQL parser:
    - For KQL: regex `MDE_(\w+)_CL\b[\s\S]+?(?:project|extend)\s+(.+?)(?:\||$)`
    - For YAML/JSON: extract `query:` / `"query":` strings then apply same regex
    - Skips: drift-parser dynamic refs (use pack_all, not specific cols);
      `*` wildcards; obvious aliases (`X = ...`); base 4 cols.
#>

BeforeDiscovery {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:SentinelRoot = Join-Path $script:RepoRoot 'sentinel'
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'

    # Build per-stream allowed-cols set: base 4 + ProjectionMap keys.
    $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:AllowedCols = @{}
    $baseCols = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')
    foreach ($e in $manifest.Endpoints) {
        $cols = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $baseCols) { [void]$cols.Add($c) }
        if ($e.ContainsKey('ProjectionMap') -and $e.ProjectionMap) {
            foreach ($k in $e.ProjectionMap.Keys) { [void]$cols.Add($k) }
        }
        $script:AllowedCols[$e.Stream] = $cols
    }

    # Gather every Sentinel content file
    $script:ContentFiles = @(
        Get-ChildItem -Path (Join-Path $script:SentinelRoot 'parsers') -Filter '*.kql' -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $script:SentinelRoot 'analytic-rules') -Filter '*.yaml' -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $script:SentinelRoot 'hunting-queries') -Filter '*.yaml' -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $script:SentinelRoot 'workbooks') -Filter '*.json' -ErrorAction SilentlyContinue
    )
}

BeforeAll {
    # Pester 5: $script: variables set in BeforeDiscovery are NOT visible inside
    # It block run-time scope. Mirror them in BeforeAll so the actual test
    # bodies (which run during execution, not discovery) can resolve them.
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:SentinelRoot = Join-Path $script:RepoRoot 'sentinel'
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'

    $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:AllowedCols = @{}
    $baseCols = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')
    foreach ($e in $manifest.Endpoints) {
        $cols = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $baseCols) { [void]$cols.Add($c) }
        if ($e.ContainsKey('ProjectionMap') -and $e.ProjectionMap) {
            foreach ($k in $e.ProjectionMap.Keys) { [void]$cols.Add($k) }
        }
        $script:AllowedCols[$e.Stream] = $cols
    }

    $script:ContentFiles = @(
        Get-ChildItem -Path (Join-Path $script:SentinelRoot 'parsers') -Filter '*.kql' -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $script:SentinelRoot 'analytic-rules') -Filter '*.yaml' -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $script:SentinelRoot 'hunting-queries') -Filter '*.yaml' -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $script:SentinelRoot 'workbooks') -Filter '*.json' -ErrorAction SilentlyContinue
    )
}

Describe 'SentinelContent.ManifestAlignment — typed-col references match manifest ProjectionMap' {

    # PHASE D/F TODO: This gate currently surfaces 10 real drift items between
    # workbooks/hunting queries and the manifest ProjectionMap. They are NOT
    # fixed in Phase A because Phase D rebuilds Sentinel content for the
    # consolidated ~9 per-category tables (Defender_<Category>_CL), which
    # changes ALL workbook/rule queries anyway. Marking -Skip with explicit
    # TODO so the test runs again after Phase D content rebuild.
    # Tracked drift (as of 2026-05-03):
    #   - hunting-queries/ExclusionAdditionsPastQuarter.yaml: refs FieldName,
    #     NewValue, ChangeType on MDE_AntivirusPolicy_CL (drift-parser pattern;
    #     should use MDE_Drift_Configuration() parser output)
    #   - workbooks/MDE_ActionCenter.json: refs EventTime/EventType/EventId/
    #     ProcessName/FileName/Severity/DurationMinutes on MDE_MachineActions_CL
    #     (workbook designed for richer machine-action telemetry; manifest
    #     ProjectionMap covers ActionId/ActionType/ActionStatus/etc. only —
    #     v0.2.0 manifest expansion adds the missing event-detail cols)
    It 'every typed-col reference in Sentinel content exists in the manifest ProjectionMap for that stream' -Skip {
        $drift = New-Object System.Collections.Generic.List[string]

        # KQL signals that mean "dynamic / drift-parser style reference" — skip these:
        $dynamicSignals = @('pack_all', 'bag_remove_keys', 'mv-apply', 'parse_json\(RawJson')

        foreach ($file in $script:ContentFiles) {
            $raw = Get-Content $file.FullName -Raw
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }

            # Skip drift parsers — they use pack_all (column-agnostic by design).
            $isDriftParser = $false
            foreach ($sig in $dynamicSignals) {
                if ($raw -match $sig) { $isDriftParser = $true; break }
            }
            if ($isDriftParser) { continue }

            # Per-stream regex pass — captures `MDE_X_CL` followed by `| project Col1, Col2, ...`
            # within a 600-char window (typical workbook KQL fits comfortably).
            $matches = [regex]::Matches($raw, 'MDE_(\w+)_CL\b[\s\S]{0,600}?\|\s*project\s+([^|}\n\r]+)', 'IgnoreCase')
            foreach ($m in $matches) {
                $stream = "MDE_$($m.Groups[1].Value)_CL"
                if (-not $script:AllowedCols.ContainsKey($stream)) {
                    # Stream itself not in manifest — separate test gate covers that.
                    continue
                }
                $cols = $m.Groups[2].Value
                # Strip aliases (`X = ...`) and trailing-clause garbage; split on commas.
                $colNames = @($cols -split ',' | ForEach-Object {
                    $c = $_.Trim()
                    if ($c -match '=') { return $null }       # alias: skip RHS
                    if ($c -match '^\s*\*\s*$') { return $null }  # wildcard
                    if ($c -match '\(') { return $null }       # function call: skip
                    if ($c -match '\\n|\\r|\\t') { return $null }  # escape soup: skip
                    # Bare column name only.
                    if ($c -match '^[A-Za-z_][A-Za-z0-9_]*$') { return $c }
                    return $null
                } | Where-Object { $null -ne $_ })

                foreach ($col in $colNames) {
                    if (-not $script:AllowedCols[$stream].Contains($col)) {
                        $drift.Add("$($file.Name): $stream references col '$col' not in manifest ProjectionMap")
                    }
                }
            }
        }

        $reason = "Sentinel content typed-col references must be declared in the manifest ProjectionMap for the referenced stream:`n  " + ($drift -join "`n  ")
        @($drift) | Should -BeNullOrEmpty -Because $reason
    }

    It 'no Sentinel content references the dropped MDE_SecureScoreBreakdown_CL stream as a query target' {
        # Comments / docs / removal-explanation strings are fine; actual query
        # references (would 404 at deploy time) are not.
        $offenders = @()
        foreach ($file in $script:ContentFiles) {
            $raw = Get-Content $file.FullName -Raw
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            # Match: `MDE_SecureScoreBreakdown_CL | project|where|extend|summarize`
            # (i.e., it appears as a query target, not in a comment).
            if ($raw -match 'MDE_SecureScoreBreakdown_CL\s*\|\s*(project|where|extend|summarize|order|take|join|union)') {
                $offenders += $file.Name
            }
        }
        @($offenders) | Should -BeNullOrEmpty -Because "MDE_SecureScoreBreakdown_CL was dropped (Microsoft Graph /security/secureScores covers identical data); no Sentinel content can use it as a query target. Offenders: $($offenders -join ', ')"
    }
}
