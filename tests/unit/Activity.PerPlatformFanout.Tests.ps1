# Section R++++++ Architecture C (2026-05-07): PerPlatformFanout activity-loop test.
#
# Validates:
# 1. Manifest entry MDE_SecurityPolicies_CL declares PerPlatformFanout = 4 platforms
# 2. Invoke-MDEEndpoint accepts -BodyOverride parameter
# 3. BodyOverride merges into manifest body (caller wins on collision)
# 4. Activity (Xdr-PollStream) detects PerPlatformFanout field
#
# Architecture C is single-stream multi-platform iteration:
#   Same MDE_SecurityPolicies_CL stream, same Defender_EndpointConfiguration_CL
#   table — just multiple calls per cycle with different body['platform'] values
#   and Platform col stamped on each row.

#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:Manifest = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:Endpoints = $script:Manifest.Endpoints

    $script:InvokeMDEPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Public' 'Invoke-MDEEndpoint.ps1'
    $script:InvokeMDESrc = Get-Content $script:InvokeMDEPath -Raw

    $script:ActivityPath = Join-Path $script:RepoRoot 'src' 'functions' 'Xdr-PollStream' 'run.ps1'
    $script:ActivitySrc = Get-Content $script:ActivityPath -Raw
}

Describe 'Architecture C — PerPlatformFanout manifest declaration' {
    It 'MDE_SecurityPolicies_CL declares PerPlatformFanout with 4 standard MDE platforms' {
        $entry = $script:Endpoints | Where-Object { $_.Stream -eq 'MDE_SecurityPolicies_CL' } | Select-Object -First 1
        $entry | Should -Not -BeNullOrEmpty -Because 'MDE_SecurityPolicies_CL is the Phase 1 G7 stream'
        $entry.ContainsKey('PerPlatformFanout') | Should -BeTrue -Because 'Architecture C: PerPlatformFanout enables per-platform iteration'
        $platforms = @($entry.PerPlatformFanout)
        $platforms | Should -Contain 'Windows'
        $platforms | Should -Contain 'Linux'
        $platforms | Should -Contain 'macOS'
        $platforms | Should -Contain 'iOS'
        $platforms.Count | Should -Be 4 -Because 'MDE supports exactly 4 endpoint platforms'
    }

    It 'manifest body still defaults to Windows (so non-fanout callers get a working baseline)' {
        $entry = $script:Endpoints | Where-Object { $_.Stream -eq 'MDE_SecurityPolicies_CL' } | Select-Object -First 1
        $entry.Body | Should -Not -BeNullOrEmpty
        $entry.Body.platform | Should -Be 'Windows' -Because 'fallback platform if BodyOverride absent'
    }
}

Describe 'Architecture C — Invoke-MDEEndpoint -BodyOverride parameter' {
    It 'Invoke-MDEEndpoint declares -BodyOverride [hashtable] parameter' {
        $script:InvokeMDESrc | Should -Match '\[hashtable\]\s*\$BodyOverride' -Because 'Architecture C requires -BodyOverride for fanout loop'
    }

    It 'BodyOverride is merged into postBody (caller wins on collision)' {
        $script:InvokeMDESrc | Should -Match 'BodyOverride.Count\s*-gt\s*0' -Because 'merge logic guards against null/empty override'
        $script:InvokeMDESrc | Should -Match 'foreach.*\$BodyOverride\.Keys' -Because 'caller-key wins iteration must exist'
        $script:InvokeMDESrc | Should -Match '\$merged\[\$k\]\s*=\s*\$BodyOverride\[\$k\]' -Because 'caller value overrides manifest value'
    }

    It 'BodyOverride does NOT mutate the manifest body (clones first)' {
        # The merge code must copy the manifest body into a $merged hashtable,
        # not mutate $postBody in-place. Otherwise repeated calls to the same
        # stream would accumulate state across invocations.
        $script:InvokeMDESrc | Should -Match '\$merged\s*=\s*@\{\}' -Because 'merge must use a fresh hashtable to avoid manifest mutation'
        $script:InvokeMDESrc | Should -Match 'foreach\s*\(\s*\$k\s+in\s+\$postBody\.Keys\s*\)' -Because 'manifest body is COPIED into $merged before override merge'
    }
}

Describe 'Architecture C — Xdr-PollStream activity fanout loop' {
    It 'activity detects manifestEntry.PerPlatformFanout field' {
        $script:ActivitySrc | Should -Match 'PerPlatformFanout' -Because 'Architecture C activity must read this manifest field'
        $script:ActivitySrc | Should -Match 'manifestEntry\.ContainsKey\(.PerPlatformFanout.\)' -Because 'safe ContainsKey check before reading'
    }

    It 'activity iterates platforms and passes BodyOverride per iteration' {
        $script:ActivitySrc | Should -Match 'foreach\s*\(\s*\$platform\s+in\s+\$platforms\s*\)' -Because 'per-platform loop iterates declared platforms'
        $script:ActivitySrc | Should -Match 'BodyOverride.{0,30}@\{\s*platform\s*=\s*\$platform' -Because 'each iteration overrides body[platform] with current platform'
    }

    It 'activity stamps Platform col on each row' {
        $script:ActivitySrc | Should -Match 'Add-Member.{0,80}Platform' -Because 'rows must carry Platform col for operator filter/group'
        $script:ActivitySrc | Should -Match 'NotePropertyValue\s+\$platform' -Because 'Platform col value is the current loop iteration platform'
    }

    It 'standard streams (no PerPlatformFanout) take the single-call path (else branch)' {
        $script:ActivitySrc | Should -Match 'else\s*\{\s*\#\s*Standard single-call path' -Because 'streams without PerPlatformFanout must still use the original single-call code path'
    }
}

Describe 'Architecture C — Operator query pattern (no schema changes)' {
    It 'MDE_SecurityPolicies_CL workspace table is Defender_EndpointConfiguration_CL (single table for all platforms)' {
        $entry = $script:Endpoints | Where-Object { $_.Stream -eq 'MDE_SecurityPolicies_CL' } | Select-Object -First 1
        $entry.Category | Should -Be 'Endpoint Configuration' -Because 'PerPlatformFanout uses ONE table — Platform col distinguishes rows'
        $entry.CategoryId | Should -Be 2
    }

    It 'no separate per-platform stream identifiers exist (single MDE_SecurityPolicies_CL only)' {
        $perPlatformStreams = $script:Endpoints | Where-Object {
            $_.Stream -match 'MDE_SecurityPolicies_(Windows|Linux|macOS|iOS)_CL'
        }
        @($perPlatformStreams).Count | Should -Be 0 -Because 'Architecture C avoids stream-name explosion — single stream + Platform col'
    }
}
