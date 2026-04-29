#Requires -Modules Pester
<#
.SYNOPSIS
    Static audit of Sentinel workbooks under sentinel/workbooks/*.json.

.DESCRIPTION
    Walks each workbook JSON, enumerates every `items[].content.query` string,
    and applies the same invariants as analytic-rule / hunting-query tests:
      * workbook JSON parses
      * every query references only known streams / parsers
      * no reference to v1.0.2 REMOVED streams
      * balanced parens
#>

BeforeDiscovery {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $dir = Join-Path $repoRoot 'sentinel' 'workbooks'
    $script:WorkbookCases = @()
    foreach ($f in (Get-ChildItem $dir -Filter '*.json')) {
        $script:WorkbookCases += @{ Name = $f.Name; Path = $f.FullName }
    }
}

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $manifest = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')
    $script:KnownStreams = @($manifest.Endpoints | ForEach-Object { $_.Stream }) + @('MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL')
    $script:KnownParsers = @((Get-ChildItem (Join-Path $repoRoot 'sentinel' 'parsers') -Filter 'MDE_Drift_*.kql') | ForEach-Object { $_.BaseName })
    $script:RemovedStreams = @(
        'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
        'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL'
    )

    # Walk a workbook JSON tree and collect every `query` string property we find.
    function script:Get-WorkbookQueries {
        param($Node)
        $queries = @()
        if ($null -eq $Node) { return @() }
        if ($Node -is [array]) {
            foreach ($child in $Node) { $queries += script:Get-WorkbookQueries -Node $child }
            return $queries
        }
        if ($Node -is [pscustomobject]) {
            foreach ($prop in $Node.PSObject.Properties) {
                if ($prop.Name -eq 'query' -and $prop.Value -is [string] -and $prop.Value) {
                    $queries += $prop.Value
                } else {
                    $queries += script:Get-WorkbookQueries -Node $prop.Value
                }
            }
        }
        return $queries
    }
}

Describe 'Workbook <Name> — static audit' -ForEach $script:WorkbookCases {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:RemovedStreams = @(
            'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
            'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL'
        )
        $manifest = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')
        $script:KnownStreams = @($manifest.Endpoints | ForEach-Object { $_.Stream }) + @('MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL')
        $script:KnownParsers = @((Get-ChildItem (Join-Path $repoRoot 'sentinel' 'parsers') -Filter 'MDE_Drift_*.kql') | ForEach-Object { $_.BaseName })

        function script:Get-WorkbookQueries {
            param($Node)
            $queries = @()
            if ($null -eq $Node) { return @() }
            if ($Node -is [array]) {
                foreach ($child in $Node) { $queries += script:Get-WorkbookQueries -Node $child }
                return $queries
            }
            if ($Node -is [pscustomobject]) {
                foreach ($prop in $Node.PSObject.Properties) {
                    if ($prop.Name -eq 'query' -and $prop.Value -is [string] -and $prop.Value) {
                        $queries += $prop.Value
                    } else {
                        $queries += script:Get-WorkbookQueries -Node $prop.Value
                    }
                }
            }
            return $queries
        }

        $script:Wb = Get-Content $_.Path -Raw | ConvertFrom-Json
        $script:Queries = @(script:Get-WorkbookQueries -Node $script:Wb)
    }

    It 'workbook JSON parses' {
        $script:Wb | Should -Not -BeNullOrEmpty
    }

    It 'workbook has at least one query' {
        $script:Queries.Count | Should -BeGreaterThan 0
    }

    It 'no query references a v1.0.2 REMOVED stream' {
        foreach ($q in $script:Queries) {
            foreach ($r in $script:RemovedStreams) {
                $q | Should -Not -Match ([regex]::Escape($r)) -Because "workbook $($_.Name) query references removed stream $r"
            }
        }
    }

    It 'every MDE_*_CL stream in any query is in the manifest' {
        $allRefs = @()
        foreach ($q in $script:Queries) {
            $allRefs += [regex]::Matches($q, '\bMDE_[A-Za-z0-9]+_CL\b') | ForEach-Object { $_.Value }
        }
        $allRefs = $allRefs | Sort-Object -Unique
        foreach ($ref in $allRefs) {
            $script:KnownStreams | Should -Contain $ref -Because "workbook $($_.Name) references stream $ref which is not in the manifest"
        }
    }

    It 'every parser reference is a known parser' {
        $allRefs = @()
        foreach ($q in $script:Queries) {
            $allRefs += [regex]::Matches($q, '\bMDE_Drift_[A-Za-z0-9]+\b') | ForEach-Object { $_.Value }
        }
        $allRefs = $allRefs | Sort-Object -Unique
        foreach ($ref in $allRefs) {
            $script:KnownParsers | Should -Contain $ref -Because "workbook $($_.Name) references parser $ref which does not exist"
        }
    }

    It 'every query has balanced parens' {
        foreach ($q in $script:Queries) {
            $open  = ([regex]::Matches($q, '\(').Count)
            $close = ([regex]::Matches($q, '\)').Count)
            $open | Should -Be $close -Because "workbook $($_.Name) has unbalanced parens in a query"
        }
    }
}
