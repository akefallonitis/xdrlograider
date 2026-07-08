#Requires -Version 7.4
# P0 gate (plan v12 §7 · P0): the catalogue engine, run from references ONLY, must reproduce the
# LIVE-PROVEN ActionCenter/GetHistory manifest's data-plane decisions. The ONLY permitted differences
# are the two intended v12 changes (3-level taxonomy · per-group table) and Finding F1 (EndTime_x drift,
# auto-corrected to canonical EndTime by the single-source Get-XdrSafeColumnName).

Describe 'P0 · Catalogue Operations group · derived == live-proven baseline' {
    BeforeAll {
        $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        # Validate the COMMITTED catalogue.json (the tracked data source of truth). The builder lives in
        # gitignored dev-tools/ and is run at design time; CI validates the committed artifact, not a fresh build.
        $script:catalogue = Get-Content "$repo\references\inventory\nodoc-defender-xdr\catalogue.json" -Raw | ConvertFrom-Json
        $script:gh  = $catalogue.Operations | Where-Object { $_.OperationId -eq 'ActionCenter.GetHistory' }
        # Select GetHistory BY KEY · the 9-op Shipped manifest is catalogue-ordered so Operations[0] is now
        # GetPending, not GetHistory. This P0 gate compares the DERIVED catalogue GetHistory against the
        # LIVE-PROVEN manifest GetHistory entry · resolve it explicitly so it is order-independent.
        $script:man = (Import-PowerShellDataFile "$repo\manifests\Defender\Operations.psd1").Operations |
            Where-Object { $_.OperationKey -eq 'GetHistory' } | Select-Object -First 1
    }

    It 'derives the 3-level taxonomy (Operations / Action Center / GetHistory)' {
        $gh.Category    | Should -Be 'Operations'
        $gh.Subcategory | Should -Be 'Action Center'
        $gh.Operation   | Should -Be 'GetHistory'
    }

    It 'reproduces the live manifest data-plane decisions' {
        $gh.SubPortal      | Should -Be $man.SubPortal
        $gh.Path           | Should -Be $man.Path
        $gh.Method         | Should -Be $man.Method
        $gh.ResponseShape  | Should -Be $man.ResponseShape
        $gh.ItemsContainer | Should -Be $man.ItemsContainer
        $gh.IngestionMode  | Should -Be $man.IngestionMode
        $gh.CursorField    | Should -Be $man.CursorField
        @($gh.NaturalKey)  | Should -Be @($man.NaturalKey)
        $gh.Cadence        | Should -Be $man.Cadence
        @($gh.RequiresProducts) | Should -Be @($man.RequiresProducts)
        $gh.TimeFilter.Mode | Should -Be $man.TimeFilter.Mode
    }

    It 'reproduces pagination incl. PageIndexStart=1 (from live-evidence · spec wrongly says 0)' {
        $gh.Pagination.Mode                 | Should -Be $man.Pagination.Mode
        $gh.Pagination.PageSize             | Should -Be $man.Pagination.PageSize
        $gh.Pagination.PageIndexStart       | Should -Be $man.Pagination.PageIndexStart
        $gh.Pagination.PageIndexStart       | Should -Be 1
        $gh.Pagination.SortByField          | Should -Be $man.Pagination.SortByField
        $gh.Pagination.SortOrder            | Should -Be $man.Pagination.SortOrder
        $gh.Pagination.StopWhenCursorPassed | Should -Be $man.Pagination.StopWhenCursorPassed
        $gh.Pagination.TotalCountPath       | Should -Be $man.Pagination.TotalCountPath
    }

    It 'reproduces the ProjectionMap (19 cols · modulo F1 EndTime drift)' {
        $catPm = @{}; $gh.ProjectionMap.PSObject.Properties | ForEach-Object { $catPm[$_.Name] = $_.Value }
        $catPm.Count | Should -Be $man.ProjectionMap.Count
        foreach ($k in $man.ProjectionMap.Keys) {
            if ($k -eq 'EndTime_x') {
                # F1: canonical single-source Get-XdrSafeColumnName does NOT reserve EndTime; manifest drifted to EndTime_x.
                $catPm.ContainsKey('EndTime') | Should -BeTrue
                $catPm['EndTime'] | Should -Be '$.EndTime'
                continue
            }
            $catPm[$k] | Should -Be $man.ProjectionMap[$k] -Because "PM col $k"
        }
    }

    It 'applies the per-group table model (intended P3 migration delta)' {
        $gh.WorkspaceTable | Should -Be 'Defender_Operations_CL'
        $gh.DcrStreamName  | Should -Be 'Custom-Defender_Operations_CL'
        $man.WorkspaceTable | Should -Be 'Defender_Operations_CL'   # the per-tag baseline being migrated
    }

    It 'catalogues the full Operations group (29 ops · 0 Validated offline · 16 LiveCaptured · 13 OpenApiDerived · HONESTY LOCK §4.D)' {
        # catalogue.json is now the FULL portal catalogue (all groups · v13); filter to the Operations group.
        # HONESTY LOCK §4.D: Status=Validated is RESERVED for ops live-proven (exactly-once) in production via the
        # $XdrLiveProven registry — EMPTY offline, so NOTHING is Validated here. The captured ops (incl. GetHistory)
        # are LiveCaptured: a real response proves SCHEMA + the real behavioral SHAPE, NOT the live exactly-once chain.
        $opsGroup = @($catalogue.Operations | Where-Object { $_.Category -eq 'Operations' })
        $opsGroup.Count | Should -Be 29
        @($opsGroup | Where-Object { $_.Status -eq 'Validated' }).Count      | Should -Be 0
        @($opsGroup | Where-Object { $_.Status -eq 'LiveCaptured' }).Count   | Should -Be 16
        @($opsGroup | Where-Object { $_.Status -eq 'OpenApiDerived' }).Count | Should -Be 13
        @($opsGroup | Where-Object { $_.Status -eq 'StructuralOnly' }).Count | Should -Be 0
        @($opsGroup | Where-Object { $_.Status -eq 'Excluded' }).Count       | Should -Be 0

        # HONEST GATING (value-based Shipped model · §21.7 BehavioralTier · HONESTY LOCK).
        # LiveCaptured proves SCHEMA (ProjectionMap/ResponseShape from a captured body) — NOT ingestion behavior.
        # The honesty invariant is preserved AND STRENGTHENED, split by whether the op was promoted to SHIP:
        #
        #  (a) NON-Shipped LiveCaptured ops — untouched by the ship-gate — MUST stay fully null/empty on every
        #      behavioral field (IngestionMode/CursorField/Cadence/TimeFilter/NaturalKey). No fabrication, period.
        #  (b) Shipped ops on the DERIVED-CONSERVATIVE tier (no captured ingestion mode) carry CONSERVATIVE,
        #      HONESTLY-TAGGED defaults (§21.7): BehavioralTier='derived-conservative', IngestionMode=SNAPSHOT
        #      (NEVER a fabricated CURSOR), and NO fabricated CursorField/NaturalKey (an unproven op gets NO dedup
        #      identity). GetHistory is the ONE op with CURSOR + NaturalKey=ActionId, and those are EVIDENCE-BACKED
        #      from its live capture (LiveCaptured · not yet Validated · §4.D) — real, not fabricated.
        #  ProjectionTier reflects the TRUE projection source (T4-PROJ · the $capTier honesty fix). A LiveCaptured op
        #  with a NON-EMPTY real capture is 'live'; an EMPTY-capture op honestly records its fallback (openapi/postman
        #  /none) or 'live-sibling' when it inherits a schema-sibling's live projection (GetPending<-GetHistory). The
        #  prior "ALL LiveCaptured = live" assertion was the LIE that hid the empty-capture spec-fallback class (the
        #  camelCase-nulls-at-ingest bug · e.g. GetPending camelCase, GetPendingSummary mislabeled live).
        foreach ($op in @($opsGroup | Where-Object { $_.Status -eq 'LiveCaptured' })) {
            $op.ProjectionTier | Should -BeIn @('live','live-sibling','openapi','postman','none') -Because "LiveCaptured $($op.OperationId) must record its TRUE projection source"
            if (@($op.ProjectionMap.PSObject.Properties).Count -gt 0) { $op.ProjectionTier | Should -Not -Be 'none' -Because "$($op.OperationId) has typed columns → a real (non-none) projection tier" }
            if (-not $op.Shipped) {
                $op.IngestionMode       | Should -BeNullOrEmpty -Because "NON-Shipped LiveCaptured $($op.OperationId) must not fabricate IngestionMode"
                $op.CursorField         | Should -BeNullOrEmpty -Because "NON-Shipped LiveCaptured $($op.OperationId) must not fabricate CursorField"
                $op.Cadence             | Should -BeNullOrEmpty -Because "NON-Shipped LiveCaptured $($op.OperationId) must not fabricate Cadence"
                $op.TimeFilter          | Should -BeNullOrEmpty -Because "NON-Shipped LiveCaptured $($op.OperationId) must not fabricate TimeFilter"
                @($op.NaturalKey).Count | Should -Be 0          -Because "NON-Shipped LiveCaptured $($op.OperationId) must not fabricate NaturalKey"
            }
        }
        # (b) · Shipped DERIVED-CONSERVATIVE-tier ops — conservative SNAPSHOT · NO fabricated cursor; a NaturalKey is
        #       PERMITTED ONLY when live-PROVEN in live-evidence.json (the authoritative live>spec override · §4.D).
        #       BehavioralTier ('derived-conservative' = no captured INGESTION MODE → SNAPSHOT default) and the
        #       ROW-IDENTITY key are ORTHOGONAL axes: a SNAPSHOT op may carry a live-proven NaturalKey (RecordId +
        #       within-cycle dedup) WITHOUT a CursorField — e.g. MultiTenant.GetTenantContext=OrgId, the SAME proven
        #       pattern as ExposureManagement.GetPostureOversightTenants=orgId. The invariant is key⟺live-evidence
        #       (NEVER a fabricated/curated key), and when present it MUST equal the live-evidence proof.
        $derivedOps = @($opsGroup | Where-Object { $_.Shipped -and $_.BehavioralTier -eq 'derived-conservative' })
        $derivedOps.Count | Should -BeGreaterThan 0 -Because 'the conservative tier must still have ops · else the gate is vacuous'
        $liveEvOps = (Get-Content "$repo\references\inventory\nodoc-defender-xdr\live-evidence.json" -Raw | ConvertFrom-Json).operations
        foreach ($op in $derivedOps) {
            $op.Status              | Should -Not -Be 'Validated'        -Because "derived-conservative $($op.OperationId) is not live-proven (Validated is reserved for the live exactly-once X-phase)"
            $op.IngestionMode       | Should -Be 'SNAPSHOT'             -Because "derived-conservative $($op.OperationId) must use the safe SNAPSHOT default · NEVER a fabricated CURSOR"
            $op.CursorField         | Should -BeNullOrEmpty             -Because "derived-conservative $($op.OperationId) must not fabricate a CursorField (no live cursor proof)"
            $evNk = @(); $evp = $liveEvOps.PSObject.Properties | Where-Object { $_.Name -eq $op.OperationId }
            if ($evp -and $evp.Value.NaturalKey) { $evNk = @($evp.Value.NaturalKey) }
            if ($evNk.Count -gt 0) {
                @($op.NaturalKey) | Should -Be $evNk -Because "derived-conservative $($op.OperationId) NaturalKey MUST equal its live-evidence proof (live>spec · not fabricated)"
            } else {
                @($op.NaturalKey).Count | Should -Be 0 -Because "derived-conservative $($op.OperationId) must not fabricate a NaturalKey (no live-evidence proof)"
            }
        }
        # (c) · GetHistory · LiveCaptured (NOT yet Validated · §4.D) with EVIDENCE-BACKED CURSOR semantics from its
        # live capture — CURSOR/EventTime/ActionId are real (captured), NOT fabricated. ONLY op with CURSOR + a
        # NaturalKey; NOT on the derived-conservative tier. Promoted to Validated after the X-phase live exactly-once
        # proof (add ActionCenter.GetHistory to $XdrLiveProven · regen).
        $ghCat = @($opsGroup | Where-Object { $_.OperationId -eq 'ActionCenter.GetHistory' })[0]
        $ghCat.Status         | Should -Be 'LiveCaptured'
        $ghCat.BehavioralTier | Should -BeNullOrEmpty -Because 'GetHistory carries REAL captured behavior · not a derived-conservative default'
        $ghCat.IngestionMode  | Should -Be 'CURSOR'
        $ghCat.CursorField    | Should -Be 'EventTime'
        @($ghCat.NaturalKey)  | Should -Be @('ActionId')
    }
}
