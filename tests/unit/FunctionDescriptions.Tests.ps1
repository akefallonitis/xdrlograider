#Requires -Modules Pester
<#
.SYNOPSIS
    Locks function.json description fields against the manifest source-of-truth.

.DESCRIPTION
    Iter 13 added operator-friendly descriptions to each function.json so the
    Azure Portal "Function details" pane shows what each timer does. But 4 of
    7 poll-* descriptions had wrong stream counts AND listed wrong streams
    (e.g., poll-p5 listed MDE_AssetRules_CL which is actually P2). Confused
    operators reading the Portal.

    This gate auto-extracts the claimed stream count from each description
    and compares against the manifest tier count. Locks the invariant.
#>

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:FunctionsDir = Join-Path $script:RepoRoot 'src' 'functions'

    $script:Manifest = Import-PowerShellDataFile $script:ManifestPath
    # Build tier → expected stream list map
    $script:TierStreams = @{}
    foreach ($entry in $script:Manifest.Endpoints) {
        if (-not $script:TierStreams.ContainsKey($entry.Tier)) {
            $script:TierStreams[$entry.Tier] = @()
        }
        $script:TierStreams[$entry.Tier] += $entry.Stream
    }

    # Map each poll-pN-* function dir to its tier
    $script:PollFunctions = @{
        'poll-p0-compliance-1h'  = 'P0'
        'poll-p1-pipeline-30m'   = 'P1'
        'poll-p2-governance-1d'  = 'P2'
        'poll-p3-exposure-1h'    = 'P3'
        'poll-p5-identity-1d'    = 'P5'
        'poll-p6-audit-10m'      = 'P6'
        'poll-p7-metadata-1d'    = 'P7'
    }
}

Describe 'function.json descriptions match manifest source-of-truth' {

    It 'every poll-pN-* function.json has a description field' {
        foreach ($funcName in $script:PollFunctions.Keys) {
            $funcJsonPath = Join-Path $script:FunctionsDir $funcName 'function.json'
            $funcJson = Get-Content $funcJsonPath -Raw | ConvertFrom-Json
            $funcJson.PSObject.Properties.Name | Should -Contain 'description' -Because "$funcName must have an operator-friendly description"
            $funcJson.description | Should -Not -BeNullOrEmpty
        }
    }

    It 'every poll-pN-* description states the correct stream count for its tier' {
        $offenders = @()
        foreach ($funcName in $script:PollFunctions.Keys) {
            $tier = $script:PollFunctions[$funcName]
            $expectedCount = $script:TierStreams[$tier].Count
            $funcJsonPath = Join-Path $script:FunctionsDir $funcName 'function.json'
            $funcJson = Get-Content $funcJsonPath -Raw | ConvertFrom-Json
            $description = $funcJson.description

            # Extract claimed count from patterns like "/ 4 streams)" or "(7 streams)"
            $claimedCount = $null
            if ($description -match '(\d+)\s+streams') {
                $claimedCount = [int]$Matches[1]
            }
            if ($null -eq $claimedCount) {
                $offenders += "$funcName — description does not state a stream count"
            } elseif ($claimedCount -ne $expectedCount) {
                $offenders += "$funcName (Tier $tier) — description claims $claimedCount streams but manifest has $expectedCount"
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "function.json description stream counts must match manifest tier counts:`n$(($offenders | ForEach-Object { '    ' + $_ }) -join "`n")"
    }

    It 'every poll-pN-* description that lists individual stream names matches the manifest tier list' {
        # Some descriptions list streams as "MDE_X_CL, MDE_Y_CL, ...". If listed,
        # those names MUST appear in the manifest tier — otherwise the
        # description misleads operators.
        $offenders = @()
        foreach ($funcName in $script:PollFunctions.Keys) {
            $tier = $script:PollFunctions[$funcName]
            $expectedStreams = $script:TierStreams[$tier]
            $funcJsonPath = Join-Path $script:FunctionsDir $funcName 'function.json'
            $funcJson = Get-Content $funcJsonPath -Raw | ConvertFrom-Json
            $description = $funcJson.description

            # Find all MDE_*_CL tokens in description
            $mentionedStreams = [regex]::Matches($description, 'MDE_\w+_CL') | ForEach-Object { $_.Value } | Sort-Object -Unique

            foreach ($mentioned in $mentionedStreams) {
                if ($mentioned -notin $expectedStreams) {
                    $offenders += "$funcName (Tier $tier) — description mentions '$mentioned' but that stream is NOT in tier $tier per manifest"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "Stream names mentioned in function.json description must match the manifest tier:`n$(($offenders | ForEach-Object { '    ' + $_ }) -join "`n")"
    }
}
