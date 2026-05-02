#Requires -Modules Pester
<#
.SYNOPSIS
    Bug-class gate: enforces Sentinel content schema length limits on every
    hunting-query and analytic-rule YAML.

.DESCRIPTION
    Microsoft Sentinel surfaces hunting-query metadata as ARM `tags[]` entries
    with the `TagValue` datatype (MaxLength 256). Analytic rules carry their
    description in a top-level `properties.description` (separate, ~1000 char
    limit). Both fields are surfaced from the YAML `description:` block scalar.

    Caught us 2026-04-30: `ConfigChangesByUpn.yaml` description was 393 chars,
    deploy died with `'Correlate Defender XDR... categories.' is invalid
    according to its datatype 'TagValue' - The actual length is greater than
    the MaxLength value`. Same root cause for AfterHoursDrift +
    ExclusionAdditionsPastQuarter (both >256 chars).

    Limits per Microsoft Learn Sentinel content schema (verified 2026-04-30):
      hunting-queries  description  ≤ 256 chars  (TagValue datatype MaxLength)
      hunting-queries  tags[*]      ≤ 256 chars  (TagValue datatype MaxLength)
      hunting-queries  name         ≤ 100 chars
      analytic-rules   description  ≤ 1000 chars (properties.description)
      analytic-rules   name         ≤ 100 chars
      analytic-rules   tags[*]      ≤ 256 chars  (when present)

    The gate walks every YAML, extracts the relevant fields with the same
    block-scalar parser used by HuntingQueries.Tests.ps1 +
    AnalyticRules.Tests.ps1, and asserts each is within its limit.

    Long explanatory content that exceeds the description budget should move
    INTO the KQL query as `// Note:` comments — the query body is unbounded.
#>

BeforeDiscovery {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:HuntingCases = @()
    foreach ($f in (Get-ChildItem (Join-Path $repoRoot 'sentinel' 'hunting-queries') -Filter '*.yaml' -ErrorAction SilentlyContinue)) {
        $script:HuntingCases += @{ Name = $f.Name; Path = $f.FullName; Kind = 'hunting' }
    }
    $script:AnalyticCases = @()
    foreach ($f in (Get-ChildItem (Join-Path $repoRoot 'sentinel' 'analytic-rules') -Filter '*.yaml' -ErrorAction SilentlyContinue)) {
        $script:AnalyticCases += @{ Name = $f.Name; Path = $f.FullName; Kind = 'analytic' }
    }
}

BeforeAll {
    # Block-scalar-aware minimal YAML reader. Same shape as
    # tests/kql/AnalyticRules.Tests.ps1::Read-RuleYaml — top-level keys, block
    # scalars (key: |), and lists under top-level keys.
    function script:Read-YamlContent {
        param([string] $Path)
        $text = Get-Content $Path -Raw
        $out = @{}
        $lines = $text -split "`r?`n"
        $blockKey = $null
        $blockLines = $null
        $listKey = $null
        foreach ($line in $lines) {
            if ($null -ne $blockKey) {
                if ($line -match '^\s{2,}(.*)$') { $blockLines += $Matches[1]; continue }
                elseif ($line -match '^\s*$') { $blockLines += ''; continue }
                else {
                    $out[$blockKey] = ($blockLines -join "`n").TrimEnd()
                    $blockKey = $null; $blockLines = $null
                }
            }
            if ($line -match '^\s{2,}-\s+(\S.*)$' -and $listKey) {
                $out[$listKey] += @($Matches[1].Trim().Trim("'").Trim('"'))
                continue
            }
            if ($line -match '^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                $k = $Matches[1]; $v = $Matches[2]
                $listKey = $null
                if ($v -eq '|') { $blockKey = $k; $blockLines = @() }
                elseif ($v -eq '') { $out[$k] = @(); $listKey = $k }
                else { $out[$k] = $v.Trim('"').Trim("'").Trim() }
            }
        }
        if ($null -ne $blockKey) { $out[$blockKey] = ($blockLines -join "`n").TrimEnd() }
        return $out
    }
}

Describe 'HuntingQuery <Name> — Sentinel TagValue length limits' -ForEach $script:HuntingCases {
    BeforeAll {
        function script:Read-YamlContent {
            param([string] $Path)
            $text = Get-Content $Path -Raw
            $out = @{}
            $lines = $text -split "`r?`n"
            $blockKey = $null
            $blockLines = $null
            $listKey = $null
            foreach ($line in $lines) {
                if ($null -ne $blockKey) {
                    if ($line -match '^\s{2,}(.*)$') { $blockLines += $Matches[1]; continue }
                    elseif ($line -match '^\s*$') { $blockLines += ''; continue }
                    else {
                        $out[$blockKey] = ($blockLines -join "`n").TrimEnd()
                        $blockKey = $null; $blockLines = $null
                    }
                }
                if ($line -match '^\s{2,}-\s+(\S.*)$' -and $listKey) {
                    $out[$listKey] += @($Matches[1].Trim().Trim("'").Trim('"'))
                    continue
                }
                if ($line -match '^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                    $k = $Matches[1]; $v = $Matches[2]
                    $listKey = $null
                    if ($v -eq '|') { $blockKey = $k; $blockLines = @() }
                    elseif ($v -eq '') { $out[$k] = @(); $listKey = $k }
                    else { $out[$k] = $v.Trim('"').Trim("'").Trim() }
                }
            }
            if ($null -ne $blockKey) { $out[$blockKey] = ($blockLines -join "`n").TrimEnd() }
            return $out
        }
        $script:Y = script:Read-YamlContent -Path $_.Path
    }

    It 'description fits Sentinel TagValue MaxLength (<=256 chars)' {
        # Hunting-query description is mapped to a savedSearches tags[] entry
        # whose datatype is TagValue (MaxLength 256). Long explainers should
        # move INTO the KQL body as `// Note:` comments instead.
        if ($script:Y.ContainsKey('description')) {
            ([string]$script:Y.description).Length |
                Should -BeLessOrEqual 256 -Because "hunting-query 'description' becomes a Sentinel tag[].value (TagValue datatype, MaxLength 256). Move long explainers into the KQL body as `// comments`."
        }
    }

    It 'name fits Sentinel content schema (<=100 chars)' {
        if ($script:Y.ContainsKey('name')) {
            ([string]$script:Y.name).Length |
                Should -BeLessOrEqual 100 -Because 'Sentinel content schema caps hunting-query name at 100 chars'
        }
    }

    It 'every tags[*] entry fits Sentinel TagValue MaxLength (<=256 chars)' {
        if ($script:Y.ContainsKey('tags')) {
            foreach ($t in @($script:Y.tags)) {
                if ($null -ne $t) {
                    ([string]$t).Length |
                        Should -BeLessOrEqual 256 -Because "tags[*] is the same TagValue datatype (MaxLength 256)"
                }
            }
        }
    }
}

Describe 'AnalyticRule <Name> — Sentinel field length limits' -ForEach $script:AnalyticCases {
    BeforeAll {
        function script:Read-YamlContent {
            param([string] $Path)
            $text = Get-Content $Path -Raw
            $out = @{}
            $lines = $text -split "`r?`n"
            $blockKey = $null
            $blockLines = $null
            $listKey = $null
            foreach ($line in $lines) {
                if ($null -ne $blockKey) {
                    if ($line -match '^\s{2,}(.*)$') { $blockLines += $Matches[1]; continue }
                    elseif ($line -match '^\s*$') { $blockLines += ''; continue }
                    else {
                        $out[$blockKey] = ($blockLines -join "`n").TrimEnd()
                        $blockKey = $null; $blockLines = $null
                    }
                }
                if ($line -match '^\s{2,}-\s+(\S.*)$' -and $listKey) {
                    $out[$listKey] += @($Matches[1].Trim().Trim("'").Trim('"'))
                    continue
                }
                if ($line -match '^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                    $k = $Matches[1]; $v = $Matches[2]
                    $listKey = $null
                    if ($v -eq '|') { $blockKey = $k; $blockLines = @() }
                    elseif ($v -eq '') { $out[$k] = @(); $listKey = $k }
                    else { $out[$k] = $v.Trim('"').Trim("'").Trim() }
                }
            }
            if ($null -ne $blockKey) { $out[$blockKey] = ($blockLines -join "`n").TrimEnd() }
            return $out
        }
        $script:Y = script:Read-YamlContent -Path $_.Path
    }

    It 'description fits properties.description limit (<=1000 chars)' {
        # Analytic rules carry description in properties.description — separate
        # 1000-char limit (NOT the 256-char TagValue limit hunting queries hit).
        if ($script:Y.ContainsKey('description')) {
            ([string]$script:Y.description).Length |
                Should -BeLessOrEqual 1000 -Because 'analytic-rule properties.description caps at 1000 chars'
        }
    }

    It 'name fits Sentinel content schema (<=100 chars)' {
        if ($script:Y.ContainsKey('name')) {
            ([string]$script:Y.name).Length |
                Should -BeLessOrEqual 100 -Because 'Sentinel content schema caps analytic-rule name at 100 chars'
        }
    }

    It 'every tags[*] entry fits Sentinel TagValue MaxLength (<=256 chars)' {
        if ($script:Y.ContainsKey('tags')) {
            foreach ($t in @($script:Y.tags)) {
                if ($null -ne $t) {
                    ([string]$t).Length |
                        Should -BeLessOrEqual 256 -Because 'tags[*] datatype is TagValue (MaxLength 256)'
                }
            }
        }
    }
}
