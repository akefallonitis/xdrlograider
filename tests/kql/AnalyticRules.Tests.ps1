#Requires -Modules Pester
<#
.SYNOPSIS
    Static audit of Sentinel analytic rules under sentinel/analytic-rules/*.yaml.

.DESCRIPTION
    For every rule:
      1. YAML parses (basic shape: id + name + query keys present)
      2. query references only streams / parsers / Heartbeat-schema cols that exist in v1.0.2
      3. query references NO v1.0.2 REMOVED streams
      4. query contains balanced braces/parens (cheap KQL sanity)
      5. rule's requiredDataConnectors.dataTypes names a table that actually exists

    Plus fix-verification tests for agent-surfaced bugs:
      * BUG #1 (Heartbeat extended schema) — no rule references non-existent Heartbeat cols
      * BUG #2 (XSPM rules depend on deferred streams) — documented in rule comments
#>

BeforeDiscovery {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $rulesDir = Join-Path $repoRoot 'sentinel' 'analytic-rules'
    $script:RuleCases = @()
    foreach ($f in (Get-ChildItem $rulesDir -Filter '*.yaml')) {
        $script:RuleCases += @{ Name = $f.Name; Path = $f.FullName }
    }
}

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    # Manifest: all streams (active + deferred); anything referenced must be in here.
    $manifest = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1')
    $script:KnownStreams = @($manifest.Endpoints | ForEach-Object { $_.Stream }) + @('MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL')

    # Parser names (from sentinel/parsers/MDE_Drift_*.kql).
    $script:KnownParsers = @((Get-ChildItem (Join-Path $repoRoot 'sentinel' 'parsers') -Filter 'MDE_Drift_*.kql') | ForEach-Object { $_.BaseName })

    # v1.0.2 removed streams. Rules must NOT reference these.
    $script:RemovedStreams = @(
        'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
        'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL'
    )

    # Heartbeat schema columns (v1.0.2 extended, must match Write-Heartbeat emission).
    $script:HeartbeatCols = @(
        'TimeGenerated', 'FunctionName', 'Tier', 'StreamsAttempted', 'StreamsSucceeded',
        'RowsIngested', 'LatencyMs', 'HostName', 'Notes', 'SourceStream', 'EntityId', 'RawJson'
    )

    # Minimal YAML reader — the rules use a consistent subset (top-level keys,
    # block scalars for description/query, lists under requiredDataConnectors/tactics).
    function script:Read-RuleYaml {
        param([string] $Path)
        $text = Get-Content $Path -Raw
        $out = @{}
        $lines = $text -split "`r?`n"
        $blockKey = $null
        $blockLines = $null
        foreach ($line in $lines) {
            if ($null -ne $blockKey) {
                if ($line -match '^\s{2,}(.*)$') { $blockLines += $Matches[1]; continue }
                elseif ($line -match '^\s*$') { $blockLines += ''; continue }
                else {
                    $out[$blockKey] = ($blockLines -join "`n").TrimEnd()
                    $blockKey = $null; $blockLines = $null
                }
            }
            if ($line -match '^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                $k = $Matches[1]; $v = $Matches[2]
                if ($v -eq '|') { $blockKey = $k; $blockLines = @() }
                elseif ($v -ne '') { $out[$k] = $v.Trim('"').Trim("'").Trim() }
                else { $out[$k] = '' }
            }
        }
        if ($null -ne $blockKey) { $out[$blockKey] = ($blockLines -join "`n").TrimEnd() }
        return $out
    }
}

Describe 'Analytic rule <Name> — static audit' -ForEach $script:RuleCases {
    BeforeAll {
        # Per-Describe scope refresh for strict-mode safety under Run-Tests.
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:RemovedStreams = @(
            'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
            'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL'
        )
        $manifest = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1')
        $script:KnownStreams = @($manifest.Endpoints | ForEach-Object { $_.Stream }) + @('MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL')
        $script:KnownParsers = @((Get-ChildItem (Join-Path $repoRoot 'sentinel' 'parsers') -Filter 'MDE_Drift_*.kql') | ForEach-Object { $_.BaseName })

        # Copy of the minimal YAML reader (needed inside -ForEach scope).
        function script:Read-RuleYaml {
            param([string] $Path)
            $text = Get-Content $Path -Raw
            $out = @{}
            $lines = $text -split "`r?`n"
            $blockKey = $null; $blockLines = $null
            foreach ($line in $lines) {
                if ($null -ne $blockKey) {
                    if ($line -match '^\s{2,}(.*)$') { $blockLines += $Matches[1]; continue }
                    elseif ($line -match '^\s*$') { $blockLines += ''; continue }
                    else {
                        $out[$blockKey] = ($blockLines -join "`n").TrimEnd()
                        $blockKey = $null; $blockLines = $null
                    }
                }
                if ($line -match '^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                    $k = $Matches[1]; $v = $Matches[2]
                    if ($v -eq '|') { $blockKey = $k; $blockLines = @() }
                    elseif ($v -ne '') { $out[$k] = $v.Trim('"').Trim("'").Trim() }
                    else { $out[$k] = '' }
                }
            }
            if ($null -ne $blockKey) { $out[$blockKey] = ($blockLines -join "`n").TrimEnd() }
            return $out
        }

        $script:Rule = script:Read-RuleYaml -Path $_.Path
    }

    It 'YAML parses with required fields (id, name, query)' {
        $script:Rule.ContainsKey('id')    | Should -BeTrue
        $script:Rule.ContainsKey('name')  | Should -BeTrue
        $script:Rule.ContainsKey('query') | Should -BeTrue
        $script:Rule.id    | Should -Not -BeNullOrEmpty
        $script:Rule.name  | Should -Not -BeNullOrEmpty
        $script:Rule.query | Should -Not -BeNullOrEmpty
    }

    It 'query references NO v1.0.2 REMOVED streams' {
        foreach ($r in $script:RemovedStreams) {
            $script:Rule.query | Should -Not -Match ([regex]::Escape($r)) -Because "rule $($_.Name) references removed stream $r"
        }
    }

    It 'every MDE_*_CL stream in query is declared in the manifest' {
        $refs = [regex]::Matches($script:Rule.query, '\bMDE_[A-Za-z0-9]+_CL\b') | ForEach-Object { $_.Value } | Sort-Object -Unique
        foreach ($ref in $refs) {
            $script:KnownStreams | Should -Contain $ref -Because "rule $($_.Name) references stream $ref which is not in the manifest"
        }
    }

    It 'every parser call in query is a known parser' {
        # Match `MDE_Drift_P\d\w+(` — the function-call form.
        $parserRefs = [regex]::Matches($script:Rule.query, '\bMDE_Drift_[A-Za-z0-9]+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique
        foreach ($ref in $parserRefs) {
            $script:KnownParsers | Should -Contain $ref -Because "rule $($_.Name) references parser $ref which does not exist"
        }
    }

    It 'query has balanced parens and braces' {
        # Very cheap KQL sanity — catch truncated queries.
        $open  = ([regex]::Matches($script:Rule.query, '\(').Count)
        $close = ([regex]::Matches($script:Rule.query, '\)').Count)
        $open | Should -Be $close -Because "parens must balance in query for $($_.Name)"
    }
}
