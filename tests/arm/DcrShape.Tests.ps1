#Requires -Modules Pester
<#
.SYNOPSIS
    DCR shape gates for v0.1.0 GA architecture.

.DESCRIPTION
    Phase J.C.2-5 (2026-05-04): 47 per-stream MDE_*_CL workspace tables
    consolidated to 10 per-category Defender_<Category>_CL tables. DCR
    architecture changed:
      - streamDeclarations stay Custom-MDE_<Stream>_CL (incoming format from FA)
      - dataFlows: streams=[Custom-MDE_<Stream>_CL] (1 source)
                   outputStream=Custom-Defender_<Category>_CL (target)
                   transformKql='source | extend SourceName=''<Stream>'''
      - 5 cadence-tier DCRs (Microsoft 10-flow-per-DCR cap)
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:Arm = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50
}

Describe 'DcrShape.PerDcrFlowCap' {
    It 'every DCR has at most 10 dataFlows (Microsoft service limit)' {
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        $dcrs | Should -Not -BeNullOrEmpty
        foreach ($d in $dcrs) {
            $d.properties.dataFlows.Count | Should -BeLessOrEqual 10 -Because "DCR '$($d.name)' has $($d.properties.dataFlows.Count) flows; Azure caps at 10"
        }
    }
}

Describe 'DcrShape.PerFlowSingleStream' {
    It 'every dataFlow has exactly 1 stream (canonical Microsoft pattern for distinct-schema custom tables)' {
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        foreach ($d in $dcrs) {
            for ($i = 0; $i -lt $d.properties.dataFlows.Count; $i++) {
                $df = $d.properties.dataFlows[$i]
                $df.streams.Count | Should -Be 1 -Because "DCR '$($d.name)' dataFlows[$i] has $($df.streams.Count) streams; canonical pattern is 1 (multi-stream needs shared schema)"
            }
        }
    }
}

Describe 'DcrShape.OutputStreamSet (Phase J.C.2-5: streams project to category tables)' {
    It 'every dataFlow declares an outputStream' {
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        foreach ($d in $dcrs) {
            for ($i = 0; $i -lt $d.properties.dataFlows.Count; $i++) {
                $df = $d.properties.dataFlows[$i]
                $df.PSObject.Properties.Name -contains 'outputStream' | Should -BeTrue -Because "DCR '$($d.name)' dataFlows[$i] missing outputStream"
                $df.outputStream | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'data dataFlows have outputStream = Custom-Defender_<Category>_CL (Phase J.C.2-5 consolidation)' {
        # Phase J.C.2-5: 47 per-stream MDE_*_CL streams now project to 10
        # Defender_<Category>_CL tables. The OPS stream Custom-XdrConnectorHealth_CL
        # remains 1:1 (its outputStream matches its source).
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        foreach ($d in $dcrs) {
            for ($i = 0; $i -lt $d.properties.dataFlows.Count; $i++) {
                $df = $d.properties.dataFlows[$i]
                $sourceStream = $df.streams[0]
                if ($sourceStream -eq 'Custom-XdrConnectorHealth_CL') {
                    # Ops stream stays 1:1
                    $df.outputStream | Should -Be 'Custom-XdrConnectorHealth_CL' -Because 'XdrConnectorHealth_CL ops table is 1:1'
                } else {
                    # Data stream projects to category table
                    $df.outputStream | Should -Match '^Custom-Defender_\w+_CL$' -Because "stream '$sourceStream' must project to a Defender_<Category>_CL table"
                }
            }
        }
    }
}

Describe 'DcrShape.TransformKqlSourceName (Phase J.C.2-5: SourceName injected via transformKql)' {
    It 'data dataFlows have transformKql injecting SourceName from source stream' {
        # Phase J.C.2-5: transformKql = "source | extend SourceName = '<Stream>'"
        # so Defender_<Category>_CL rows carry the source stream identity.
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        foreach ($d in $dcrs) {
            for ($i = 0; $i -lt $d.properties.dataFlows.Count; $i++) {
                $df = $d.properties.dataFlows[$i]
                $df.PSObject.Properties.Name -contains 'transformKql' | Should -BeTrue
                $sourceStream = $df.streams[0]
                if ($sourceStream -eq 'Custom-XdrConnectorHealth_CL') {
                    # Ops stream: identity transform OK
                    $df.transformKql | Should -BeIn @('source', "source | extend SourceName = 'XdrConnectorHealth_CL'")
                } else {
                    # Data stream: must inject SourceName
                    $df.transformKql | Should -Match "source\s*\|\s*extend\s+SourceName\s*=\s*'" -Because "data dataFlow for '$sourceStream' must inject SourceName via transformKql"
                }
            }
        }
    }
}

Describe 'DcrShape.AllStreamsCovered' {
    It 'union of streams across all DCRs equals 60 (59 data + 1 ops)' {
        # v0.1.0 GA Phase 2: 46 baseline + 13 Tier A new streams + 1 ops = 60
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        $allStreams = @()
        foreach ($d in $dcrs) {
            foreach ($df in $d.properties.dataFlows) {
                $allStreams += $df.streams
            }
        }
        ($allStreams | Sort-Object -Unique).Count | Should -Be 60
    }
}
