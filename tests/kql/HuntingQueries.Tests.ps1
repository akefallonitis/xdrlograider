#Requires -Modules Pester
<#
.SYNOPSIS
    Static audit of Sentinel hunting queries under sentinel/hunting-queries/*.yaml.

.DESCRIPTION
    Same invariants as AnalyticRules.Tests.ps1:
      * YAML parses
      * query references no v1.0.2 REMOVED streams
      * every MDE_*_CL reference is in the manifest
      * every parser reference is a known parser
      * balanced parens

    Hunting queries differ from analytic rules only in that they have no
    severity/triggerThreshold — pure investigation queries.
#>

BeforeDiscovery {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $dir = Join-Path $repoRoot 'sentinel' 'hunting-queries'
    $script:HuntCases = @()
    foreach ($f in (Get-ChildItem $dir -Filter '*.yaml')) {
        $script:HuntCases += @{ Name = $f.Name; Path = $f.FullName }
    }
}

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $manifest = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1')
    $script:KnownStreams = @($manifest.Endpoints | ForEach-Object { $_.Stream }) + @('MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL')
    $script:KnownParsers = @((Get-ChildItem (Join-Path $repoRoot 'sentinel' 'parsers') -Filter 'MDE_Drift_*.kql') | ForEach-Object { $_.BaseName })
    $script:RemovedStreams = @(
        'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
        'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL'
    )
}

Describe 'Hunting query <Name> — static audit' -ForEach $script:HuntCases {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:RemovedStreams = @(
            'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
            'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL'
        )
        $manifest = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1')
        $script:KnownStreams = @($manifest.Endpoints | ForEach-Object { $_.Stream }) + @('MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL')
        $script:KnownParsers = @((Get-ChildItem (Join-Path $repoRoot 'sentinel' 'parsers') -Filter 'MDE_Drift_*.kql') | ForEach-Object { $_.BaseName })

        # Extract the top-level `query:` block with a minimal line-mode parser.
        $text = Get-Content $_.Path -Raw
        $blockKey = $null; $blockLines = @(); $out = @{}
        foreach ($line in ($text -split "`r?`n")) {
            if ($null -ne $blockKey) {
                if ($line -match '^\s{2,}(.*)$') { $blockLines += $Matches[1]; continue }
                elseif ($line -match '^\s*$') { $blockLines += ''; continue }
                else { $out[$blockKey] = ($blockLines -join "`n").TrimEnd(); $blockKey = $null; $blockLines = @() }
            }
            if ($line -match '^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                $k = $Matches[1]; $v = $Matches[2]
                if ($v -eq '|') { $blockKey = $k; $blockLines = @() }
                elseif ($v -ne '') { $out[$k] = $v.Trim('"').Trim("'").Trim() }
                else { $out[$k] = '' }
            }
        }
        if ($null -ne $blockKey) { $out[$blockKey] = ($blockLines -join "`n").TrimEnd() }
        $script:Hunt = $out
    }

    It 'YAML parses with required fields (id, name, query)' {
        $script:Hunt.ContainsKey('id')    | Should -BeTrue
        $script:Hunt.ContainsKey('name')  | Should -BeTrue
        $script:Hunt.ContainsKey('query') | Should -BeTrue
    }

    It 'query references NO v1.0.2 REMOVED streams' {
        foreach ($r in $script:RemovedStreams) {
            $script:Hunt.query | Should -Not -Match ([regex]::Escape($r))
        }
    }

    It 'every MDE_*_CL stream in query is in the manifest' {
        $refs = [regex]::Matches($script:Hunt.query, '\bMDE_[A-Za-z0-9]+_CL\b') | ForEach-Object { $_.Value } | Sort-Object -Unique
        foreach ($ref in $refs) {
            $script:KnownStreams | Should -Contain $ref
        }
    }

    It 'every parser call is a known parser' {
        $refs = [regex]::Matches($script:Hunt.query, '\bMDE_Drift_[A-Za-z0-9]+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique
        foreach ($ref in $refs) {
            $script:KnownParsers | Should -Contain $ref
        }
    }

    It 'balanced parens in query' {
        $open  = ([regex]::Matches($script:Hunt.query, '\(').Count)
        $close = ([regex]::Matches($script:Hunt.query, '\)').Count)
        $open | Should -Be $close
    }
}
