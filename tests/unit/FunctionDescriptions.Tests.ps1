#Requires -Modules Pester
<#
.SYNOPSIS
    Locks function.json description fields against the manifest source-of-truth.

.DESCRIPTION
    Each poll-* timer's function.json description tells operators (in the
    Azure Portal "Function details" pane) which cadence-tier it polls and
    which streams it covers. The descriptions are hand-written and prone to
    drift; this gate auto-extracts the claimed stream count + names and
    compares against the manifest's per-tier breakdown.

    Tier mapping (poll-* function → manifest Tier value):
      Defender-ActionCenter-Refresh         → fast        (2 active streams)
      Defender-XspmGraph-Refresh      → exposure    (7 active streams)
      Defender-Configuration-Refresh        → config      (14 active streams)
      Defender-Inventory-Refresh     → inventory   (21 active streams)
      Defender-Maintenance-Refresh   → maintenance (1 active + 1 deprecated; description states "1 active stream")
#>

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:FunctionsDir = Join-Path $script:RepoRoot 'src' 'functions'

    $script:Manifest = Import-PowerShellDataFile $script:ManifestPath
    # Build tier → expected stream list map. EXCLUDES deprecated streams from
    # the count check because timer descriptions count active polls only —
    # deprecated streams are not actually fetched.
    $script:TierStreams = @{}
    foreach ($entry in $script:Manifest.Endpoints) {
        if ($entry.Availability -eq 'deprecated') { continue }
        if (-not $script:TierStreams.ContainsKey($entry.Tier)) {
            $script:TierStreams[$entry.Tier] = @()
        }
        $script:TierStreams[$entry.Tier] += $entry.Stream
    }

    # Map each poll-* function dir to its cadence tier.
    $script:PollFunctions = @{
        'Defender-ActionCenter-Refresh'        = 'ActionCenter'
        'Defender-XspmGraph-Refresh'     = 'XspmGraph'
        'Defender-Configuration-Refresh'       = 'Configuration'
        'Defender-Inventory-Refresh'    = 'Inventory'
        'Defender-Maintenance-Refresh'  = 'Maintenance'
    }
}

Describe 'function.json descriptions match manifest source-of-truth' {

    It 'every poll-* function.json has a description field' {
        foreach ($funcName in $script:PollFunctions.Keys) {
            $funcJsonPath = Join-Path $script:FunctionsDir $funcName 'function.json'
            $funcJson = Get-Content $funcJsonPath -Raw | ConvertFrom-Json
            $funcJson.PSObject.Properties.Name | Should -Contain 'description' -Because "$funcName must have an operator-friendly description"
            $funcJson.description | Should -Not -BeNullOrEmpty
        }
    }

    It 'every poll-* description states the correct active-stream count for its tier' {
        $offenders = @()
        foreach ($funcName in $script:PollFunctions.Keys) {
            $tier = $script:PollFunctions[$funcName]
            $expectedCount = $script:TierStreams[$tier].Count
            $funcJsonPath = Join-Path $script:FunctionsDir $funcName 'function.json'
            $funcJson = Get-Content $funcJsonPath -Raw | ConvertFrom-Json
            $description = $funcJson.description

            # Extract claimed count from patterns like "Polls 7 streams" or
            # "polling 14 streams" or "1 active stream".
            $claimedCount = $null
            if ($description -match '(\d+)\s+(?:active\s+)?streams?\b') {
                $claimedCount = [int]$Matches[1]
            }
            if ($null -eq $claimedCount) {
                $offenders += "$funcName - description does not state a stream count"
            } elseif ($claimedCount -ne $expectedCount) {
                $offenders += "$funcName (Tier $tier) - description claims $claimedCount streams but manifest has $expectedCount active"
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "function.json description stream counts must match manifest tier counts:`n$(($offenders | ForEach-Object { '    ' + $_ }) -join "`n")"
    }

    It 'every poll-* description that lists individual stream names matches the manifest tier list' {
        # Some descriptions list streams as "MDE_X_CL, MDE_Y_CL, ...". If listed,
        # those names MUST appear in the manifest tier — otherwise the
        # description misleads operators. The deprecated MDE_StreamingApiConfig_CL
        # is allowed in the maintenance description because it's explicitly
        # called out as excluded-from-poll.
        $allActiveStreams = $script:TierStreams.Values | ForEach-Object { $_ } | Sort-Object -Unique
        $allowDeprecatedMention = @{ 'Maintenance' = @('MDE_StreamingApiConfig_CL') }

        $offenders = @()
        foreach ($funcName in $script:PollFunctions.Keys) {
            $tier = $script:PollFunctions[$funcName]
            $expectedStreams = $script:TierStreams[$tier]
            $allowExtra = if ($allowDeprecatedMention.ContainsKey($tier)) { $allowDeprecatedMention[$tier] } else { @() }
            $funcJsonPath = Join-Path $script:FunctionsDir $funcName 'function.json'
            $funcJson = Get-Content $funcJsonPath -Raw | ConvertFrom-Json
            $description = $funcJson.description

            $mentionedStreams = [regex]::Matches($description, 'MDE_\w+_CL') | ForEach-Object { $_.Value } | Sort-Object -Unique

            foreach ($mentioned in $mentionedStreams) {
                if (($mentioned -notin $expectedStreams) -and ($mentioned -notin $allowExtra)) {
                    $offenders += "$funcName (Tier $tier) - description mentions '$mentioned' but that stream is NOT in tier $tier per manifest"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "Stream names mentioned in function.json description must match the manifest tier:`n$(($offenders | ForEach-Object { '    ' + $_ }) -join "`n")"
    }
}
