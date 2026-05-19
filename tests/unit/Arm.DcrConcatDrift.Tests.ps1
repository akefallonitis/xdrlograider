#Requires -Module Pester
# Pi8a-alt · T1 drift detection · ARM template DCR_IMMUTABLE_ID_MAP concat MUST
# contain every distinct SubArea in manifests/defender.psd1. Catches future
# additions/removals/renames at test time (e.g. v0.2.0+ adds AppGovernance or
# operator splits CloudApps · this test fails until operator regenerates the
# concat).
#
# Why this test (rather than auto-sync via Build-FunctionAppZip):
# Auto-sync requires precise ARM-expression escape handling for embedded JSON
# (literal `\"X\"` syntax inside concat() string args). A safe drift-detection
# test catches the issue at commit-time without risking auto-modifying the
# brittle ARM expression (which is hand-validated against ARM engine).

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath      = Join-Path $script:RepoRoot 'deploy/mainTemplate.json'
    $script:ManifestPath = Join-Path $script:RepoRoot 'manifests/defender.psd1'

    $script:ArmText  = Get-Content -Raw -LiteralPath $script:ArmPath
    $manifest        = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script:ManifestPath)))
    $script:SubAreas = @($manifest.Entries | ForEach-Object SubArea | Sort-Object -Unique)
}

Describe 'Pi8a-alt · ARM DCR_IMMUTABLE_ID_MAP concat drift detection' -Tag 'arm-hardening','drift' {

    It 'manifest has >= 1 SubArea (precondition)' {
        $script:SubAreas.Count | Should -BeGreaterOrEqual 1
    }

    It 'ARM template has DCR_IMMUTABLE_ID_MAP app setting' {
        $script:ArmText | Should -Match '"name":\s*"DCR_IMMUTABLE_ID_MAP"'
    }

    It 'ARM concat references every manifest SubArea by name (no drift)' {
        $missing = @()
        foreach ($sub in $script:SubAreas) {
            # Each SubArea must appear in 2 places in the concat:
            # 1. JSON field literal: "subArea":"<Name>"  (in ARM file: \"subArea\":\"<Name>\")
            # 2. Stream name: Custom-Defender_<Name>_CL
            $subAreaPattern   = 'subArea\\":\\"' + [regex]::Escape($sub) + '\\"'
            $streamNamePattern = 'Custom-Defender_' + [regex]::Escape($sub) + '_CL'
            if (-not ($script:ArmText -match $subAreaPattern) -or -not ($script:ArmText -match $streamNamePattern)) {
                $missing += $sub
            }
        }
        $missingCount = @($missing).Count
        $missingList = @($missing) -join ', '
        $missingCount | Should -Be 0 -Because "ARM concat missing SubAreas: $missingList"
    }

    It 'ARM concat references every manifest SubArea via lowercase prefix (DCR resource name)' {
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($sub in $script:SubAreas) {
            $lower = $sub.ToLowerInvariant()
            $prefixPattern = "concat\(variables\('dcrDefenderPrefix'\),\s*'" + [regex]::Escape($lower) + "'\)"
            if ($script:ArmText -notmatch $prefixPattern) {
                $missing.Add($sub) | Out-Null
            }
        }
        $missing.Count | Should -Be 0 -Because "ARM concat is missing the lowercase DCR reference for: $($missing -join ', '). Required by stream router runtime."
    }

    It 'ARM concat has exactly the same SubArea count as manifest (no orphan entries)' {
        # Count unique SubAreas referenced in the concat via JSON field pattern
        $matchesArr = @([regex]::Matches($script:ArmText, '"subArea\\":\\"([A-Za-z]+)\\"'))
        $subAreasInArm = @($matchesArr | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $subAreasInArm.Count | Should -Be $script:SubAreas.Count -Because "ARM concat has $($subAreasInArm.Count) distinct SubAreas but manifest has $($script:SubAreas.Count). Difference: $($subAreasInArm | Compare-Object $script:SubAreas | ForEach-Object { '$($_.SideIndicator) $($_.InputObject)' } | Join-String -Separator ', ')"
    }
}
