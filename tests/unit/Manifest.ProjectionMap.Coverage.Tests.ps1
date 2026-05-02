#Requires -Modules Pester
<#
.SYNOPSIS
    iter-14.0 Phase 4B — manifest ProjectionMap coverage gate. Asserts every
    non-deprecated entry has a populated ProjectionMap (>=3 typed columns) with
    valid type-cast-hint syntax + LA-table-safe column names.

.DESCRIPTION
    Phase 4B populates each manifest entry's ProjectionMap with a per-stream
    typed-column projection drawn from per-Category conventions + per-stream
    fixture data. The contract:

      Manifest.ProjectionMap.Populated     every non-deprecated entry has >=3
                                           ProjectionMap entries (so operators
                                           get real typed columns, not just
                                           RawJson).
      Manifest.ProjectionMap.HintSyntax    every value is either a plain field
                                           name or a $tostring/$toint/$tobool/
                                           $todatetime/$todouble/$todecimal/
                                           $tolong/$toguid/$json:Path hint.
      Manifest.ProjectionMap.ColumnNames   every TargetColumn is a valid LA
                                           custom-column name (alphanumeric +
                                           underscore, starts with letter, no
                                           spaces / dashes / special chars).
      Manifest.ProjectionMap.Deprecated    deprecated streams may have an
                                           empty ProjectionMap (canonical
                                           surface is elsewhere).

    Phase 4C wires Invoke-MDEEndpoint to pass each entry's ProjectionMap into
    ConvertTo-MDEIngestRow at dispatch time. The map's syntax + columns are
    validated here; runtime resolution is the next phase.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:ClientPsd1   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'
    $script:CommonAuthPsd1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    $script:DefAuthPsd1    = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'

    Import-Module $script:CommonAuthPsd1 -Force -ErrorAction Stop
    Import-Module $script:DefAuthPsd1    -Force -ErrorAction Stop
    Import-Module $script:ClientPsd1     -Force -ErrorAction Stop

    $script:Manifest = Get-MDEEndpointManifest -Force

    # Valid type-cast hints (left side of ':' in the hint string). Match
    # _ProjectionHelpers.ps1 regex: tostring|toint|tobool|todatetime|todouble|
    # todecimal|tolong|toguid|json.
    $script:ValidCastPrefixes = @(
        '$tostring', '$toint', '$tobool', '$todatetime',
        '$todouble', '$todecimal', '$tolong', '$toguid', '$json'
    )

    # LA custom-column-name regex: must start with letter, then alphanumeric
    # or underscore. No spaces, dashes, dots, or special chars.
    $script:LAColumnNameRegex = '^[A-Za-z][A-Za-z0-9_]*$'
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
}

Describe 'Manifest.ProjectionMap.Populated' {

    It 'every non-deprecated entry has ProjectionMap with >=3 entries' {
        foreach ($stream in $script:Manifest.Keys) {
            $entry = $script:Manifest[$stream]
            if ($entry.Availability -eq 'deprecated') { continue }
            $entry.ContainsKey('ProjectionMap') | Should -BeTrue -Because "$stream must declare ProjectionMap"
            $map = $entry.ProjectionMap
            $map | Should -Not -BeNullOrEmpty -Because "$stream must have a populated ProjectionMap (Phase 4B)"
            @($map.Keys).Count | Should -BeGreaterOrEqual 3 -Because "$stream ProjectionMap must declare >=3 typed columns (operators query typed columns directly, not just RawJson)"
        }
    }

    It 'deprecated streams may have empty ProjectionMap' {
        foreach ($stream in $script:Manifest.Keys) {
            $entry = $script:Manifest[$stream]
            if ($entry.Availability -ne 'deprecated') { continue }
            # No assertion on size — empty is OK for deprecated streams.
            $entry.ContainsKey('ProjectionMap') | Should -BeTrue -Because "$stream must still declare ProjectionMap field (default empty applied by loader)"
        }
    }

    It 'all 45 non-deprecated streams have populated ProjectionMap' {
        $populated = 0
        foreach ($stream in $script:Manifest.Keys) {
            $entry = $script:Manifest[$stream]
            if ($entry.Availability -eq 'deprecated') { continue }
            if ($entry.ProjectionMap -and @($entry.ProjectionMap.Keys).Count -ge 3) { $populated++ }
        }
        $populated | Should -Be 45 -Because 'every non-deprecated stream populates ProjectionMap for typed-column ingest (46 - 1 deprecated)'
    }
}

Describe 'Manifest.ProjectionMap.HintSyntax' {

    It 'every ProjectionMap value is a valid type-cast hint OR plain field name' {
        $validCastRegex = ($script:ValidCastPrefixes | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $hintRegex = "^(?:$validCastRegex):(.+)$"
        # Plain field name regex: any non-empty path expression — supports
        # nested.dot, [N] index, [*] flatten, and 'length'/'Count' suffix.
        # Specifically: must NOT start with '$' unless it matches the cast
        # prefix list; must be non-empty.
        foreach ($stream in $script:Manifest.Keys) {
            $entry = $script:Manifest[$stream]
            if ($null -eq $entry.ProjectionMap) { continue }
            foreach ($col in $entry.ProjectionMap.Keys) {
                $hint = [string]$entry.ProjectionMap[$col]
                $hint | Should -Not -BeNullOrEmpty -Because "$stream.$col hint must not be empty"
                if ($hint.StartsWith('$')) {
                    # Must match a known cast prefix
                    $matched = $hint -match $hintRegex
                    $reason = ('{0}.{1} hint ''{2}'' must use a valid cast prefix from the list: {3}' -f `
                        $stream, $col, $hint, ($script:ValidCastPrefixes -join ', '))
                    $matched | Should -BeTrue -Because $reason
                } else {
                    # Plain field name — must be non-empty (no further constraint;
                    # Resolve-EntityPath handles arbitrary path syntax).
                    $hint.Length | Should -BeGreaterThan 0 -Because ('{0}.{1} plain-field hint must be non-empty' -f $stream, $col)
                }
            }
        }
    }
}

Describe 'Manifest.ProjectionMap.ColumnNames' {

    It 'every TargetColumn is a valid LA-table column name' {
        foreach ($stream in $script:Manifest.Keys) {
            $entry = $script:Manifest[$stream]
            if ($null -eq $entry.ProjectionMap) { continue }
            foreach ($col in $entry.ProjectionMap.Keys) {
                ([string]$col) | Should -Match $script:LAColumnNameRegex -Because "$stream ProjectionMap key '$col' must be a valid LA custom-column name (alphanumeric + underscore, starts with letter, no spaces/dashes)"
            }
        }
    }

    It 'no TargetColumn collides with the 4 base columns (TimeGenerated/SourceStream/EntityId/RawJson)' {
        $reserved = @('TimeGenerated','SourceStream','EntityId','RawJson')
        foreach ($stream in $script:Manifest.Keys) {
            $entry = $script:Manifest[$stream]
            if ($null -eq $entry.ProjectionMap) { continue }
            foreach ($col in $entry.ProjectionMap.Keys) {
                $reserved | Should -Not -Contain $col -Because "$stream ProjectionMap key '$col' collides with a base ingest column (Extras-style override is not the right tool for typed columns)"
            }
        }
    }
}
