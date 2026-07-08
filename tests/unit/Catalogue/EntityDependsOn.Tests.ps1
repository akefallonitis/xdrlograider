#Requires -Version 7.4
# U3b · DEPEND-stage proof (plan §16 U3b · §4.H entity edges · G-P). Validates the COMMITTED Defender catalogue.json
# (the tracked source of truth · same artifact the P0 test reads · NOT a fresh build) carries the entity DependsOn
# edges derived by Build-Catalogue's Depend stage. Proves the edges are:
#   - DERIVED for a known entity op (a non-{TenantId} {param} matched to a parent list/get-all op carrying that id),
#   - ABSENT for ActionCenter.GetHistory (no entity {param} → EntityResolution='NotEntity' · DependsOn=null · the
#     runtime routes it to the normal poll path · byte-identical),
#   - ADDITIVE + HONEST: every entity op is either Resolved (full edge) or Unresolved (no fabricated edge · the runtime
#     skips its fan-out gracefully) · {TenantId}-only ops are NOT entity ops (ParamSource='TenantContext' · R3 auto-fills).

Describe 'U3b · catalogue DependsOn edges · derived for entity ops · absent for GetHistory' {
    BeforeAll {
        $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:catalogue = Get-Content "$repo\references\inventory\nodoc-defender-xdr\catalogue.json" -Raw | ConvertFrom-Json
        $script:ops = $script:catalogue.Operations
        $script:entityOps = @($script:ops | Where-Object { $_.ParamSource -eq 'ParentOp' })
    }

    It 'GetHistory (no entity {param}) has NO DependsOn edge · EntityResolution=NotEntity (normal path · byte-identical)' {
        $gh = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetHistory' }
        $gh | Should -Not -BeNullOrEmpty
        $gh.ParamSource       | Should -Be 'None'
        $gh.DependsOn         | Should -BeNullOrEmpty
        $gh.EntityResolution  | Should -Be 'NotEntity'
        @($gh.PathParams).Count | Should -Be 0
    }

    It 'every NON-entity op carries EntityResolution=NotEntity and a null DependsOn (additive · never fanned out)' {
        $nonEntity = @($script:ops | Where-Object { $_.ParamSource -ne 'ParentOp' })
        $nonEntity.Count | Should -BeGreaterThan 0
        foreach ($o in $nonEntity) {
            $o.EntityResolution | Should -Be 'NotEntity' -Because "non-entity $($o.OperationId)"
            $o.DependsOn        | Should -BeNullOrEmpty   -Because "non-entity $($o.OperationId) must not carry an edge"
        }
    }

    It 'a {TenantId}-only op is NOT an entity op (ParamSource=TenantContext · R3 auto-fills · not fanned out)' {
        # e.g. /automation/internal/automation/{TenantId}/automationRules
        $tenantOps = @($script:ops | Where-Object { $_.ParamSource -eq 'TenantContext' })
        $tenantOps.Count | Should -BeGreaterThan 0
        foreach ($o in $tenantOps) {
            $o.EntityResolution | Should -Be 'NotEntity'
            $o.DependsOn        | Should -BeNullOrEmpty
            @($o.PathParams)    | Should -Contain 'TenantId'
        }
    }

    It 'every entity op is classified Resolved or Unresolved (no Pending leaks · honest gating)' {
        $script:entityOps.Count | Should -BeGreaterThan 0
        foreach ($o in $script:entityOps) {
            $o.EntityResolution | Should -BeIn @('Resolved','Unresolved') -Because "entity $($o.OperationId)"
        }
        @($script:entityOps | Where-Object { $_.EntityResolution -eq 'Pending' }).Count | Should -Be 0
    }

    It 'a RESOLVED entity op has a COMPLETE DependsOn edge (ParentOperationKey + EntityIdField + ParamName + MatchKind)' {
        $resolved = @($script:entityOps | Where-Object { $_.EntityResolution -eq 'Resolved' })
        $resolved.Count | Should -BeGreaterThan 0 -Because 'the Depend stage must resolve at least one entity edge'
        foreach ($o in $resolved) {
            $o.DependsOn                    | Should -Not -BeNullOrEmpty -Because "resolved $($o.OperationId)"
            $o.DependsOn.ParentOperationKey | Should -Not -BeNullOrEmpty
            $o.DependsOn.EntityIdField      | Should -Not -BeNullOrEmpty
            $o.DependsOn.ParamName          | Should -Not -BeNullOrEmpty
            $o.DependsOn.MatchKind          | Should -BeIn @('ExactName','StemName','PathChildId','CurationOverride')   # CurationOverride = the sanctioned curation entityParent edge (ROUND-7b · validated by the shipped-parent guard below)
            # The edge's ParamName is one of the op's OWN non-TenantId path params (the entity it scopes over).
            @($o.PathParams | Where-Object { $_ -ne 'TenantId' }) | Should -Contain $o.DependsOn.ParamName
        }
    }

    It 'a known entity op (Incidents.GetAutoIrIncident · {IncidentId}) resolves to a parent carrying an incidentId field' {
        $inc = $script:ops | Where-Object { $_.OperationId -eq 'Incidents.GetAutoIrIncident' }
        $inc | Should -Not -BeNullOrEmpty
        @($inc.PathParams) | Should -Contain 'IncidentId'
        $inc.EntityResolution | Should -Be 'Resolved'
        $inc.DependsOn.ParamName     | Should -Be 'IncidentId'
        $inc.DependsOn.EntityIdField | Should -Match '(?i)incidentId'
        $inc.DependsOn.MatchKind     | Should -Be 'ExactName'
        # The parent must be a DIFFERENT op in the SAME category.
        $inc.DependsOn.ParentOperationId | Should -Not -Be 'Incidents.GetAutoIrIncident'
    }

    It 'an UNRESOLVED entity op carries NO fabricated edge (DependsOn null · ActionCenter.GetCase · no parent lists CaseId)' {
        # {CaseId} at /CaseManagement/be/cases/{CaseId} — there is no parent list op whose item carries a CaseId field,
        # so the Depend stage honestly leaves it Unresolved (the runtime will skip its fan-out with a warning).
        $gc = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetCase' }
        $gc | Should -Not -BeNullOrEmpty
        $gc.EntityResolution | Should -Be 'Unresolved'
        $gc.DependsOn        | Should -BeNullOrEmpty
    }

    It 'the DependsOn parent is always a real op in the SAME category as the child (edge integrity)' {
        $resolved = @($script:entityOps | Where-Object { $_.EntityResolution -eq 'Resolved' })
        foreach ($o in $resolved) {
            $parent = $script:ops | Where-Object { $_.OperationId -eq $o.DependsOn.ParentOperationId } | Select-Object -First 1
            $parent | Should -Not -BeNullOrEmpty -Because "parent $($o.DependsOn.ParentOperationId) of $($o.OperationId) must exist"
            $parent.Category | Should -Be $o.Category -Because "parent of $($o.OperationId) must be in the same category"
            # The parent must NOT itself be an entity op (it's a list/get-all id source).
            $parent.ParamSource | Should -Not -Be 'ParentOp'
        }
    }

    It 'a CurationOverride edge binds a SHIPPED parent that exposes the EntityIdField (ROUND-7b fan-out-starvation guard)' {
        # ROUND-7b live-caught: the {MachineId} fan-out had bound EndpointDevices.List — a stale-projection sibling whose
        # machineId col is null live (PascalCase /ndr/machines) → parent cache NEVER seeded → 0 children after ~20 cycles.
        # A curation entityParent override re-binds it to the canonical GetMachinesWdatp.id. This gate ensures every
        # override parent (a) SHIPS (in the manifest · polls every cycle · actually feeds the id-cache) and (b) really
        # projects the EntityIdField — so an override can never silently re-introduce the empty-cache bug.
        $overrides = @($script:entityOps | Where-Object { $_.DependsOn -and $_.DependsOn.MatchKind -eq 'CurationOverride' })
        foreach ($o in $overrides) {
            $parent = $script:ops | Where-Object { $_.OperationId -eq $o.DependsOn.ParentOperationId } | Select-Object -First 1
            $parent         | Should -Not -BeNullOrEmpty -Because "override parent $($o.DependsOn.ParentOperationId) must exist"
            $parent.Shipped | Should -BeTrue -Because "override parent $($o.DependsOn.ParentOperationId) of $($o.OperationId) MUST ship (else it never polls → fan-out cache stays empty → 0 children · the ROUND-7b bug)"
            @($parent.ProjectionMap.PSObject.Properties.Name) | Should -Contain $o.DependsOn.EntityIdField -Because "override EntityIdField '$($o.DependsOn.EntityIdField)' must be a real projected field of $($o.DependsOn.ParentOperationId)"
        }
    }

    # ── G-H REGRESSION GUARD · the Shipped-vs-EntityResolution ordering bug ──────────────────────────────────
    # Build-PortalCatalogue once decided Shipped INSIDE the build loop, while every entity op was still 'Pending'
    # (:754 · pre-DEPEND), so the $entityPollable gate was always false → Resolved entity telemetry GETs were
    # silently un-shipped, leaving the catalogue self-inconsistent (EntityResolution='Resolved' yet Shipped=$false).
    # The fix re-decides Shipped over the SAME generic ship-formula AFTER Set-XdrDependsOnEdges. These tests are
    # RED on the pre-fix catalogue (the 6 ops below were Shipped=$false at HEAD 6319079) and GREEN after.
    # §22-pollable (query) addition (2026-06-15): the ship-formula ALSO holds an op with an unsatisfied required QUERY
    # param (RequiredQueryParams · a sparse field), exactly as it holds Unresolved entities and ShipHeldReason ops. So
    # "ship-eligible" here must exclude those too — a Resolved entity GET that still needs e.g. isManagedByMde is NOT
    # pollable-now (it onboards via curation querySupplied). That exclusion is the new clause in the filter below.
    It 'G-H · every ship-eligible Resolved entity GET SHIPS (ship-gate reads FINAL EntityResolution, not pre-DEPEND Pending)' {
        $shipEligibleResolved = @($script:entityOps | Where-Object {
            $_.EntityResolution -eq 'Resolved' -and
            $_.Method -eq 'GET' -and
            $_.ScopeDecision -ne 'Exclude' -and
            $_.EffectiveValueClass -in @('CoreTelemetry','ConfigState') -and
            [string]::IsNullOrEmpty([string]$_.ShipHeldReason) -and
            (-not $_.PSObject.Properties['RequiredQueryParams'])   # §22-pollable (query) · an unsatisfied required query param holds the op
        })
        $shipEligibleResolved.Count | Should -BeGreaterThan 0 -Because 'the corpus has Resolved entity telemetry GETs'
        foreach ($o in $shipEligibleResolved) {
            $o.Shipped | Should -BeTrue -Because "Resolved entity GET $($o.OperationId) meets every ship criterion · the post-DEPEND ship-gate must ship it (else Resolved-yet-unshipped self-inconsistency)"
            [string]::IsNullOrEmpty([string]$o.IngestionMode) | Should -BeFalse -Because "a shipped op must carry an IngestionMode ($($o.OperationId))"
        }
    }

    It 'G-H · a Resolved entity GET with no time window + no required query param ships with the conservative SNAPSHOT default' {
        # GetMachineTimelineEvents is now WINDOW (G-C/G-D · fromDate/toDate pair) and ListDevicePolicies is now HELD by the
        # query-param gate (required isManagedByMde · see next test); GetMachineMarkedEvents was the prior exemplar but is
        # now HELD (ROUND-7c · live-proven 400 'Machine id must be provided' even with a real machineId in the path → needs
        # the id in query/body · the query/body-fanout engine gap · curation shipHold). EndpointDevices.GetDataSensitivity
        # (per-machine data-sensitivity labels · Resolved entity GET · no time window · no required query param · live-proven
        # Succeeds=15) is the stable conservative-SNAPSHOT exemplar.
        $op = $script:ops | Where-Object { $_.OperationId -eq 'EndpointDevices.GetDataSensitivity' }
        $op | Should -Not -BeNullOrEmpty
        $op.EntityResolution | Should -Be 'Resolved'
        $op.Shipped          | Should -BeTrue -Because 'a Resolved entity telemetry GET (no unsatisfied query param) must ship after the post-DEPEND ship-gate'
        $op.IngestionMode    | Should -Be 'SNAPSHOT' -Because 'F4 conservative default (no live-proven mode · no fromDate/toDate window param)'
    }

    It 'G-H · the query-param pollability gate COMPOSES with entity resolution (ListDevicePolicies · Resolved yet HELD by required isManagedByMde)' {
        # The §22-pollable (query) gate is orthogonal to entity resolution: even a fully-Resolved entity GET is HELD when it
        # carries a required query param the autonomous runtime cannot supply (isManagedByMde · in:query·required:true). It
        # onboards when Endpoint Management is added (curation querySupplied declares the value / fan-out). NOT a self-
        # inconsistency — Resolved + un-pollable-query is a legitimate non-ship, recorded transparently via RequiredQueryParams.
        $op = $script:ops | Where-Object { $_.OperationId -eq 'EndpointConfiguration.ListDevicePolicies' }
        $op | Should -Not -BeNullOrEmpty
        $op.EntityResolution       | Should -Be 'Resolved'
        @($op.RequiredQueryParams) | Should -Contain 'isManagedByMde'
        $op.Shipped                | Should -BeFalse -Because 'a required query param the runtime cannot supply holds the op even when its entity is Resolved'
    }
}
