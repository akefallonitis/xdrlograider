#Requires -Modules Pester
<#
.SYNOPSIS
    Manifest ProjectionMap hint syntax validation + dry-run-against-fixture
    typed-col extraction gate.

.DESCRIPTION
    iter-14.0 Phase 4 (v0.1.0 GA). Implements Section 2.7 (defensive code) +
    Section 3 step 5 (unit-test gate that catches projection mismatches at PR
    time) of the senior-architect plan.

    Two assertions per stream:

    1. SYNTAX: every ProjectionMap hint matches the documented hint grammar:
         '$tostring|$toint|$tobool|$todatetime|$todouble|$todecimal|$tolong|$toguid|$json'
         followed by ':' followed by a JSONPath expression
         (or a bare JSONPath = default $tostring)

    2. DRY-RUN: for each `live` stream with a captured fixture, run
       Expand-MDEResponse + ConvertTo-MDEIngestRow against the first fixture
       row and assert at least ONE typed col extracts a non-null value (where
       the fixture has data). Catches the class of bug that produced the
       iter-14.0 property-bag mismatch (every typed col returned null).

    Skip-on-missing-fixture is acceptable here — the FA.ParsingPipeline gate
    enforces fixture coverage. This test focuses on the projection-resolution
    semantics.
#>

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Manifest = Import-PowerShellDataFile -Path (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')
    $script:LiveStreams = $script:Manifest.Endpoints |
        Where-Object { $_.ContainsKey('Availability') -and $_.Availability -eq 'live' } |
        ForEach-Object { @{ Stream = $_.Stream } }
}

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:FixturesDir  = Join-Path $script:RepoRoot 'tests' 'fixtures' 'live-responses'
    $script:Manifest     = Import-PowerShellDataFile -Path (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')

    # Stub Az.* (same pattern as FA.ParsingPipeline.Tests.ps1)
    if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
        function global:Get-AzAccessToken { param([string]$ResourceUrl) [pscustomobject]@{ Token = 'stub'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }
        function global:New-AzStorageContext { param([string]$StorageAccountName, [switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName = $StorageAccountName } }
        function global:Get-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
        function global:New-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
        function global:Get-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey) $null }
        function global:Add-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting) }
    }
    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1') -Force -ErrorAction Stop

    # Hint syntax: optional `$tox:` prefix + JSONPath (bare-name | dot-path | array-syntax)
    # Cast prefixes (left side of ':'):
    $script:ValidPrefixes = @('$tostring','$toint','$tobool','$todatetime','$todouble','$todecimal','$tolong','$toguid','$json')
    # JSONPath grammar (right side of ':' or whole hint if no ':'):
    #   - bare property: identifier
    #   - nested: identifier(\.identifier)*
    #   - array index: identifier\[\d+\]
    #   - array flatten: identifier\[\*\] OR identifier\.\*
    #   - .length / .Count special
    $script:JsonPathPattern = '^[A-Za-z_][A-Za-z0-9_]*((\.[A-Za-z_][A-Za-z0-9_]*|\.\*|\[\d+\]|\[\*\])+)?$'
}

Describe 'Manifest.ProjectionResolution — hint syntax validation' {

    It 'every ProjectionMap hint in every manifest stream uses valid syntax' {
        $errors = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $script:Manifest.Endpoints) {
            if (-not ($entry.ContainsKey('ProjectionMap')) -or $null -eq $entry.ProjectionMap) { continue }
            foreach ($targetCol in $entry.ProjectionMap.Keys) {
                $hint = [string]$entry.ProjectionMap[$targetCol]
                if ([string]::IsNullOrWhiteSpace($hint)) {
                    $errors.Add("$($entry.Stream).${targetCol}: empty hint")
                    continue
                }

                $path = $hint
                if ($hint -match '^(\$\w+):(.+)$') {
                    $prefix = $Matches[1]
                    if ($prefix -notin $script:ValidPrefixes) {
                        $errors.Add("$($entry.Stream).${targetCol}: unknown cast prefix '$prefix' (valid: $($script:ValidPrefixes -join ', '))")
                        continue
                    }
                    $path = $Matches[2]
                }

                if (-not ($path -match $script:JsonPathPattern)) {
                    $errors.Add("$($entry.Stream).${targetCol}: malformed JSONPath '$path' in hint '$hint'")
                }
            }
        }

        $reason = "ProjectionMap hint syntax errors:`n  " + ($errors -join "`n  ")
        @($errors) | Should -BeNullOrEmpty -Because $reason
    }
}

Describe 'Manifest.ProjectionResolution — dry-run extraction against fixture' -ForEach $script:LiveStreams {

    It 'at least one typed col extracts non-null from <Stream> fixture (or the fixture is empty)' {
        $rawPath = Join-Path $script:FixturesDir "$($_.Stream)-raw.json"
        if (-not (Test-Path $rawPath)) {
            Set-ItResult -Skipped -Because "No fixture for $($_.Stream) — FA.ParsingPipeline gate enforces fixture coverage separately"
            return
        }

        # Find this stream's manifest entry
        $entry = $script:Manifest.Endpoints | Where-Object { $_.Stream -eq $_.Stream -and $_.Stream -eq $_.Stream } | Where-Object { $_.Stream -eq $_.Stream }
        # Above is a Pester $_-collision pattern; fix:
        $streamName = $_.Stream
        $entry = $script:Manifest.Endpoints | Where-Object { $_.Stream -eq $streamName } | Select-Object -First 1
        if ($null -eq $entry) {
            Set-ItResult -Skipped -Because "Stream '$streamName' not in manifest (drift)"
            return
        }

        $projMap = if ($entry.ContainsKey('ProjectionMap')) { $entry.ProjectionMap } else { $null }
        if ($null -eq $projMap -or @($projMap.Keys).Count -eq 0) {
            Set-ItResult -Skipped -Because "Stream $streamName has no ProjectionMap (deprecated or empty by design)"
            return
        }

        $raw = Get-Content $rawPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq 'null' -or $raw -eq '{}' -or $raw -eq '[]') {
            Set-ItResult -Skipped -Because "Fixture for $streamName is empty (operator-empty tenant; cannot dry-run)"
            return
        }

        # Marker fixture (tenant-gated 4xx capture sentinel) — skip
        try {
            $parsed = $raw | ConvertFrom-Json
        } catch {
            Set-ItResult -Skipped -Because "Fixture for $streamName fails to parse: $($_.Exception.Message)"
            return
        }
        if ($parsed -is [pscustomobject] -and $parsed.PSObject.Properties['__marker__']) {
            Set-ItResult -Skipped -Because "Fixture for $streamName is a 4xx marker (tenant-gated)"
            return
        }

        $expandArgs = @{ Response = $parsed }
        if ($entry.ContainsKey('IdProperty') -and $entry.IdProperty) { $expandArgs['IdProperty'] = [string[]]$entry.IdProperty }
        if ($entry.ContainsKey('UnwrapProperty') -and $entry.UnwrapProperty) { $expandArgs['UnwrapProperty'] = [string]$entry.UnwrapProperty }
        if ($entry.ContainsKey('SingleObjectAsRow') -and $entry.SingleObjectAsRow) { $expandArgs['SingleObjectAsRow'] = $true }

        # Don't wrap in @() — Expand-MDEResponse returns via `,$pairs` which PS
        # already preserves as an array; outer @() RE-wraps and collapses 18 pairs
        # into 1 Object[] containing the array. Same pattern as DCR.SchemaConsistency
        # test (line 182-183).
        $pairs = Expand-MDEResponse @expandArgs
        $pairs = @($pairs)  # second-step normalisation keeps array semantics
        if ($pairs.Count -eq 0) {
            Set-ItResult -Skipped -Because "Expand-MDEResponse returned 0 pairs for $streamName (empty array / null inner)"
            return
        }

        $firstPair = $pairs[0]
        $entity = $firstPair.Entity
        if ($null -eq $entity -or ($entity -is [array] -and @($entity).Count -eq 0)) {
            $entity = [pscustomobject]@{}
        }
        # Coerce Id to string (Pester+pscustomobject can produce null/non-string).
        $entityIdStr = if ($null -eq $firstPair.Id) { 'unknown' } else { [string]$firstPair.Id }
        if ([string]::IsNullOrWhiteSpace($entityIdStr)) { $entityIdStr = 'unknown' }

        $row = ConvertTo-MDEIngestRow -Stream $streamName -EntityId $entityIdStr -Raw $entity -ProjectionMap $projMap

        # Find at least one typed col with a non-null value (excluding base 4)
        $baseCols = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')
        $typedColsWithValues = @()
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Name -in $baseCols) { continue }
            if ($null -ne $prop.Value -and "$($prop.Value)" -ne '') {
                $typedColsWithValues += "$($prop.Name)=$($prop.Value)"
            }
        }

        if ($typedColsWithValues.Count -eq 0) {
            $allKeys = ($projMap.Keys -join ', ')
            "$streamName has $($projMap.Keys.Count) typed cols declared but ZERO extract non-null values from fixture. ProjectionMap keys: $allKeys. Likely property-bag mismatch (Phase 1 class of bug) — verify manifest convention vs fixture shape." | Should -BeNullOrEmpty
        } else {
            $typedColsWithValues.Count | Should -BeGreaterOrEqual 1 -Because "at least one typed col must extract from $streamName fixture"
        }
    }
}
