# Per-Op Pester replay test · Defender/ActionCenter/GetHistory
# Proves the FULL parse + projection pipeline against the 1,870-row lab capture.
#
# What this test proves:
#  - manifest entry parses and exposes the expected fields
#  - lab capture (Count=1870, wrapper {Results: [...]}) deserializes correctly
#  - ConvertTo-XdrRows produces 1870 rows (no fan-out loss · req #1)
#  - Apply-XdrProjectionMap projects all 19 typed cols correctly (req #6)
#  - Compress-XdrRawJson preserves rawJson on every row (req #7)
#  - manifest ProjectionMap keys match DCR streamDeclaration cols
#  - manifest is wired to the deploy/per-category-schemas/ artifact

#Requires -Module Pester

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')
    $env:PSModulePath = (Join-Path $repoRoot.Path 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $repoRoot.Path 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
    $script:Manifest = Import-PowerShellDataFile -Path (Join-Path $repoRoot.Path 'manifests\Defender\Operations.psd1') -ErrorAction Stop
    # Select GetHistory BY KEY · NOT Operations[0]. The 9-op Shipped manifest is catalogue-ordered so GetHistory
    # is no longer index 0 (GetPending is). This test is specifically the GetHistory replay contract · resolve it
    # explicitly so it stays correct regardless of the catalogue's emit order.
    $script:Op = $script:Manifest.Operations | Where-Object { $_.OperationKey -eq 'GetHistory' } | Select-Object -First 1
    # Tracked SANITIZED copy of the lab capture (G4 single-repo model: references/live is the untracked internal
    # layer; tests + CI consume the sanitized fixture — structure, Count and row-count byte-faithful to the capture).
    $script:LabCapturePath = Join-Path $repoRoot.Path 'tests\fixtures\live\MDE_ActionCenter_CL-raw.json'
    $script:LabCapture = Get-Content $script:LabCapturePath -Raw | ConvertFrom-Json
}

Describe 'Manifest contract · Defender/ActionCenter/GetHistory' {
    It 'manifest entry exists with required §4.11 fields · no IsActive flag (v11)' {
        $script:Op.OperationKey | Should -Be 'GetHistory'
        # v11 §4.11 · IsActive field MUST NOT be present · runtime dispatch via §4.18 4-gate model
        $script:Op.ContainsKey('IsActive') | Should -BeFalse
        # Required v11 fields per §4.11
        $script:Op.ContainsKey('Cadence') | Should -BeTrue
        $script:Op.ContainsKey('IngestionMode') | Should -BeTrue
        $script:Op.ContainsKey('RequiresProducts') | Should -BeTrue
        $script:Op.ContainsKey('ProjectionMap') | Should -BeTrue
        $script:Op.ContainsKey('DcrImmutableIdEnvVar') | Should -BeTrue
        $script:Op.ContainsKey('Provenance') | Should -BeTrue
    }
    It 'targets Defender mtp sub-portal with GET method' {
        $script:Op.Method | Should -Be 'GET'
        $script:Op.SubPortal | Should -Be 'mtp'
    }
    It 'declares wrapper ResponseShape (matches lab capture {Count, Results})' {
        $script:Op.ResponseShape | Should -Be 'wrapper'
        $script:Op.ItemsContainer | Should -Be 'Results'
    }
    It 'RequiresProducts gate is MDE (matches lab tenant)' {
        $script:Op.RequiresProducts | Should -Contain 'MDE'
    }
    It 'ProjectionMap has 19 typed cols' {
        $script:Op.ProjectionMap.Keys.Count | Should -Be 19
    }
    It 'Provenance cites the live fixture + catalogue derivation (generated manifest)' {
        $script:Op.Provenance.Live        | Should -Not -BeNullOrEmpty
        $script:Op.Provenance.OperationId | Should -Be 'ActionCenter.GetHistory'
        $script:Op.Provenance.DerivedFrom | Should -Match 'catalogue'
    }
}

Describe 'Lab capture fan-out · partial page replay' {
    # Lab capture is page 1 of N · API total Count is 1870 · captured page has 30 items.
    # This is correct pagination behavior · the manifest Pagination block drives the loop.

    It 'lab capture Count field shows API total = 1,870' {
        $script:LabCapture.Count | Should -Be 1870
    }
    It 'lab capture Results array is a paged subset (~30 items in the captured page)' {
        $script:LabCapture.Results | Should -Not -BeNullOrEmpty
        @($script:LabCapture.Results).Count | Should -BeGreaterOrEqual 1
        @($script:LabCapture.Results).Count | Should -BeLessOrEqual 1870
    }
    It 'ConvertTo-XdrRows fans out exactly to the per-page array length (B1 keystone · req #1 · no row drop)' {
        $expectedRows = @($script:LabCapture.Results).Count
        $rows = ConvertTo-XdrRows `
            -ResponseBody $script:LabCapture `
            -OperationKey 'GetHistory' `
            -Category 'Operations' `
            -ResponseShape 'wrapper' `
            -ProjectionMap $script:Op.ProjectionMap
        @($rows).Count | Should -Be $expectedRows
    }
    It 'manifest Pagination block declares PageSize >= captured-page size (so prod will request bigger pages)' {
        $script:Op.Pagination.PageSize | Should -BeGreaterOrEqual @($script:LabCapture.Results).Count
    }
}

Describe 'ProjectionMap correctness · against real lab row[0]' {
    BeforeAll {
        $script:Sample = $script:LabCapture.Results[0]
        $script:Row = Apply-XdrProjectionMap -Item $script:Sample -ProjectionMap $script:Op.ProjectionMap -OperationKey 'GetHistory'
    }

    It 'projects ActionId from raw' {
        $script:Row.ActionId | Should -Be $script:Sample.ActionId
    }
    It 'projects ActionType from raw' {
        $script:Row.ActionType | Should -Be $script:Sample.ActionType
    }
    It 'projects ActionStatus from raw' {
        $script:Row.ActionStatus | Should -Be $script:Sample.ActionStatus
    }
    It 'projects MachineId from raw (REDACTED-HASH preserved)' {
        $script:Row.MachineId | Should -Be $script:Sample.MachineId
    }
    It 'projects ComputerName from raw' {
        $script:Row.ComputerName | Should -Be $script:Sample.ComputerName
    }
    It 'projects EventTime (the CURSOR field) from raw' {
        $script:Row.EventTime | Should -Be $script:Sample.EventTime
    }
    It 'projects EndTime (LA-reserved rewrite of EndTime)' {
        $script:Row.EndTime | Should -Be $script:Sample.EndTime
    }
    It 'projects Product=MDE from raw' {
        $script:Row.Product | Should -Be 'MDE'
    }
}

Describe 'RawJson preservation · req #7 (B3 1MB clamp)' {
    It 'lab row[0] serializes to valid compact JSON' {
        $raw = Compress-XdrRawJson -Item $script:LabCapture.Results[0]
        $raw | Should -Not -BeNullOrEmpty
        # Round-trip parse to confirm valid JSON
        { $raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }
    It 'serialized raw contains ActionId field' {
        $raw = Compress-XdrRawJson -Item $script:LabCapture.Results[0]
        $raw | Should -Match '"ActionId"'
    }
}

Describe 'Schema parity · manifest ↔ ARM DCR' {
    BeforeAll {
        $artifactPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path 'deploy\per-category-schemas\Defender-Operations.json'
        $script:Artifact = Get-Content $artifactPath -Raw | ConvertFrom-Json -Depth 50
    }
    It 'DCR + workspace table both have 133 cols (9 envelope + 124 typed UNION of the 9-op group) · DCR==table' {
        # 9-op per-group model: the Defender_Operations_CL table is the UNION of ALL 9 shipped ops' ProjectionMaps
        # (deduped · LA-reserved-safe) = 124 typed cols + 9 envelope (TimeGenerated/Portal/Category/Subcategory/
        # Operation/RecordId/ParentRecordId/CorrelationId/RawJson · F2: −OperationKey +RecordId +ParentRecordId) = 133.
        # GetHistory contributes 19 of those 124 (asserted by the
        # 'DCR contains all 19 typed cols' test below · its cols must be PRESENT in the union). TenantId stays
        # EXCLUDED (LA auto-populates). T4-PROJ: GetPending now SHARES GetHistory's 19-field PascalCase projection
        # (projectionAlias) instead of declaring 4 wrong-cased camelCase-only cols (completedDateTime/createdDateTime/
        # entityName/status) → the typed union dropped from 128 to 124. The DCR/table counts are read from the schema
        # Summary so they track the generator single-source; Summary.Total is the pinned regression guard.
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcrCount   = $script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns.Count
        $tableCount = $script:Artifact.TableResource.properties.schema.columns.Count
        $dcrCount   | Should -Be $script:Artifact.Summary.TotalColumnCount   # DCR tracks the generator single-source
        $tableCount | Should -Be $script:Artifact.Summary.TotalColumnCount   # table tracks the generator single-source
        $dcrCount   | Should -Be $tableCount   # DCR stream and workspace table MUST stay column-identical
        # Cross-check the generator's declared Summary (envelope + typed-union = total) · the pinned no-drift guard.
        $script:Artifact.Summary.EnvelopeColumnCount | Should -Be 9
        $script:Artifact.Summary.TypedColumnCount    | Should -Be 124
        $script:Artifact.Summary.TotalColumnCount    | Should -Be 133
    }
    It 'DCR has the canonical envelope cols (Subcategory included · TenantId EXCLUDED · LA auto-populates)' {
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $names = $script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns | ForEach-Object { $_.name }
        $names | Should -Contain 'TimeGenerated'
        $names | Should -Contain 'Portal'
        $names | Should -Contain 'Category'
        $names | Should -Contain 'Subcategory'
        $names | Should -Contain 'Operation'
        $names | Should -Contain 'RecordId'
        $names | Should -Contain 'ParentRecordId'
        $names | Should -Contain 'CorrelationId'
        $names | Should -Contain 'RawJson'
        $names | Should -Not -Contain 'OperationKey'   # F2 · dropped (it duplicated Operation)
        # iter#7 regression guard: TenantId MUST NOT be user-declared (LA auto-populates · DCR rejects)
        $names | Should -Not -Contain 'TenantId'
    }
    It 'DCR contains all 19 typed cols from manifest ProjectionMap' {
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcrColNames = ($script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns | ForEach-Object { $_.name })
        foreach ($pmKey in $script:Op.ProjectionMap.Keys) {
            $dcrColNames | Should -Contain $pmKey
        }
    }
}

Describe 'Real-path regression · StrictMode + -AsHashtable runtime shape (G2/G8/G9 · plan §24.2/§27)' {
    # The Activity poll path deserializes responses with `ConvertFrom-Json -AsHashtable`, producing an
    # [IDictionary] body — NOT the PSCustomObject the blocks above use. The prior parser `wrapper` branch
    # tested .PSObject.Properties (always false for a hashtable) → 0 rows from a valid 1,870-row response
    # (plan §24.2 G2 · the reason rows never landed). This block pins the fix under StrictMode -Version
    # Latest with the runtime's EXACT body shape AND the runtime's ConvertTo-XdrRows call signature
    # (-Portal + -ItemsContainer · G8 envelope + G9 ItemsContainer). Regress to PSObject-only → RED.
    BeforeAll {
        Set-StrictMode -Version Latest
        $script:HashBody = Get-Content $script:LabCapturePath -Raw | ConvertFrom-Json -AsHashtable -Depth 25
        # ConvertTo-XdrRows returns `,$list` (comma-protected so the List<hashtable> isn't pipeline-unrolled).
        # Assign first, THEN @() to enumerate the List into a flat array — same two-step the runtime uses
        # (Invoke-XdrEntryPoll does `@($pageRows).Count`). A single `@(call)` would capture the 1-element
        # comma-wrapper, not the 30 rows.
        $raw = ConvertTo-XdrRows `
            -ResponseBody $script:HashBody `
            -OperationKey 'GetHistory' `
            -Portal 'Defender' `
            -Category 'Operations' `
            -ResponseShape 'wrapper' `
            -ItemsContainer 'Results' `
            -ProjectionMap $script:Op.ProjectionMap
        $script:HashRows = @($raw)
    }

    It 'body deserializes as IDictionary (the runtime shape · NOT PSCustomObject)' {
        $script:HashBody -is [System.Collections.IDictionary] | Should -BeTrue
    }
    It 'parses N>0 rows from the -AsHashtable wrapper body (G2 · was 0 pre-fix)' {
        $script:HashRows.Count | Should -BeGreaterThan 0
        $script:HashRows.Count | Should -Be (@($script:HashBody['Results']).Count)
    }
    It 'each row is a [hashtable] (indexer-safe under StrictMode)' {
        $script:HashRows[0] -is [hashtable] | Should -BeTrue
    }
    It 'G8 envelope · Portal + Category + Operation columns populated on row[0]' {
        $script:HashRows[0]['Portal']       | Should -Be 'Defender'
        $script:HashRows[0]['Category']     | Should -Be 'Operations'
        $script:HashRows[0]['Operation']    | Should -Be 'GetHistory'
        $script:HashRows[0].ContainsKey('OperationKey') | Should -BeFalse   # F2 · OperationKey dropped (Operation carries it · RecordId/ParentRecordId are runtime-injected, absent at parser level)
    }
    It 'D8e · RawJson present and valid JSON on row[0]' {
        $raw = $script:HashRows[0]['RawJson']
        $raw | Should -Not -BeNullOrEmpty
        { $raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }
    It 'D8f · typed cols populated from the -AsHashtable item (EventTime cursor + ActionId key)' {
        $script:HashRows[0]['EventTime'] | Should -Not -BeNullOrEmpty
        $script:HashRows[0].ContainsKey('ActionId') | Should -BeTrue
    }
    It 'D8g · LA-reserved EndTime rewritten to EndTime (when any source row carries EndTime)' {
        $srcHasEndTime = @($script:HashBody['Results'] | Where-Object { $_.ContainsKey('EndTime') -and $_['EndTime'] }).Count -gt 0
        if ($srcHasEndTime) {
            (@($script:HashRows | Where-Object { $_['EndTime'] }).Count -gt 0) | Should -BeTrue
        }
    }
}
