#Requires -Modules Pester
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
                $df.streams.Count | Should -Be 1 -Because "DCR '$($d.name)' dataFlows[$i] has $($df.streams.Count) streams; canonical pattern is 1 (multi-stream needs shared schema, which we don't have)"
            }
        }
    }
}
Describe 'DcrShape.OutputStreamSet' {
    It 'every dataFlow has outputStream matching its single stream' {
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        foreach ($d in $dcrs) {
            for ($i = 0; $i -lt $d.properties.dataFlows.Count; $i++) {
                $df = $d.properties.dataFlows[$i]
                $df.PSObject.Properties.Name -contains 'outputStream' | Should -BeTrue -Because "DCR '$($d.name)' dataFlows[$i] missing outputStream — Azure rejects with InvalidTransformOutput"
                $df.outputStream | Should -Be $df.streams[0] -Because "outputStream must match the single stream"
            }
        }
    }
}
Describe 'DcrShape.TransformKqlSource' {
    It 'every dataFlow has transformKql=source (identity transform per Microsoft canonical sample)' {
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        foreach ($d in $dcrs) {
            for ($i = 0; $i -lt $d.properties.dataFlows.Count; $i++) {
                $df = $d.properties.dataFlows[$i]
                $df.PSObject.Properties.Name -contains 'transformKql' | Should -BeTrue
                $df.transformKql | Should -Be 'source'
            }
        }
    }
}
Describe 'DcrShape.AllStreamsCovered' {
    It 'union of streams across all DCRs equals 47 (46 data + 1 heartbeat)' {
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        $allStreams = @()
        foreach ($d in $dcrs) {
            foreach ($df in $d.properties.dataFlows) {
                $allStreams += $df.streams
            }
        }
        ($allStreams | Sort-Object -Unique).Count | Should -Be 47
    }
}
