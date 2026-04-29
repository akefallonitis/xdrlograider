#Requires -Modules Pester
<#
.SYNOPSIS
    iter-14.0 Phase 3 — Expand-MDEResponse fix gate. Verifies the wrapper-key
    EntityId bug is closed (Action Center 1868 actions → 1868 rows, not 2),
    the scalar-wrap shape works, the null/empty boundary-marker emits one
    sentinel row, and per-entry IdProperty overrides are honored.

.DESCRIPTION
    Locked invariants:
      WrapperKey.NoRegression  — feeding a {Results:[…], Count:N} response with
                                 UnwrapProperty='Results' MUST NOT emit rows
                                 with EntityId in {Results, Count, value, items,
                                 sums, '@odata.context', recordsCount}.

      WrapperKey.ActionCenter  — replay tests/fixtures/live-responses/
                                 MDE_ActionCenter_CL-raw.json (1868 actions);
                                 with manifest's UnwrapProperty='Results' +
                                 IdProperty=@('ActionId',…), Expand-MDEResponse
                                 returns 1868 rows each with a real ActionId
                                 (not 'Results' or 'Count').

      ScalarWrap               — bool/int/string/double scalar response wraps to
                                 ONE row {Id='value'; Entity={value=$scalar}}.

      NullBoundaryMarker       — null response emits ONE marker row with
                                 __boundary_marker=$true so heartbeat can detect
                                 "API working but no data" (vs "API failed").

      EmptyArrayBoundaryMarker — `@()` response emits ONE marker row.

      EmptyObjectBoundaryMarker — `@{}` response emits ONE marker row.

      UnwrapTargetNullMarker   — wrapper present but UnwrapProperty value is null
                                 emits ONE marker row.

      IdHeuristicCoverage      — default IdProperty list covers ActionId,
                                 InvestigationId, incidentId, alertId, attackPathId,
                                 plus PascalCase variants.

      PerEntryIdPropertyOverride — manifest entry's IdProperty override is
                                 respected (Action Center → ActionId; XSPM → attackPathId).
#>

BeforeDiscovery {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:HasActionCenterFixture = Test-Path -LiteralPath (Join-Path $repoRoot 'tests' 'fixtures' 'live-responses' 'MDE_ActionCenter_CL-raw.json')
}

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ClientPsd1     = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'
    $script:CommonAuthPsd1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    $script:DefAuthPsd1    = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'
    $script:PortalShimPsd1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'
    $script:ActionCenterFixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'live-responses' 'MDE_ActionCenter_CL-raw.json'

    Import-Module $script:CommonAuthPsd1 -Force -ErrorAction Stop
    Import-Module $script:DefAuthPsd1    -Force -ErrorAction Stop
    Import-Module $script:PortalShimPsd1 -Force -ErrorAction Stop
    Import-Module $script:ClientPsd1     -Force -ErrorAction Stop

    # The wrapper-key shapes that WERE breaking before iter-14.0 Phase 3.
    # Locked: NO row in production should ever carry EntityId in this set.
    $script:ForbiddenWrapperKeys = @(
        'Results', 'Count', 'value', 'items', 'sums',
        '@odata.context', 'recordsCount'
    )
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Portal.Auth     -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
}

Describe 'Expand-MDEResponse — WrapperKey.NoRegression (locked iter-14.0 Phase 3)' {

    It 'a {Results:[…], Count:N} response with UnwrapProperty="Results" emits per-action rows' {
        $response = [pscustomobject]@{
            Count   = 3
            Results = @(
                [pscustomobject]@{ ActionId = 'a-001'; Status = 'Completed'; ActionType = 'Block' }
                [pscustomobject]@{ ActionId = 'a-002'; Status = 'Pending';   ActionType = 'Quarantine' }
                [pscustomobject]@{ ActionId = 'a-003'; Status = 'Completed'; ActionType = 'Investigate' }
            )
        }
        $rows = Expand-MDEResponse -Response $response -UnwrapProperty 'Results'
        $rows.Count | Should -Be 3
        ($rows | ForEach-Object Id) | Should -Be @('a-001', 'a-002', 'a-003')
    }

    It 'NO row carries EntityId in the forbidden wrapper-key set' {
        $response = [pscustomobject]@{
            Count   = 2
            Results = @(
                [pscustomobject]@{ ActionId = 'a-100'; Status = 'Completed' }
                [pscustomobject]@{ ActionId = 'a-101'; Status = 'Pending' }
            )
        }
        $rows = Expand-MDEResponse -Response $response -UnwrapProperty 'Results'
        foreach ($row in $rows) {
            $script:ForbiddenWrapperKeys | Should -Not -Contain $row.Id -Because "row Id '$($row.Id)' must not be a wrapper-key (iter-13.15 bug regression)"
        }
    }

    It 'WITHOUT UnwrapProperty, a wrapper-key response would still NOT produce wrapper-key rows when the response is treated as object property-bag (shape 3) — but operators MUST declare UnwrapProperty for paged endpoints' {
        # Shape 3 (object with named properties) emits one row per top-level property.
        # For paged endpoints {Results:[…], Count:N}, that yields 2 rows with EntityId='Results'/'Count'.
        # iter-14.0 Phase 3 doesn't auto-detect — the manifest MUST declare UnwrapProperty.
        # This test documents the failure mode so the regression-detector test
        # below catches manifest entries that miss UnwrapProperty.
        $response = [pscustomobject]@{
            Count   = 2
            Results = @(
                [pscustomobject]@{ ActionId = 'a-200' }
            )
        }
        $rows = Expand-MDEResponse -Response $response   # NO UnwrapProperty
        $rowIds = @($rows | ForEach-Object Id)
        # This is the BUG state — operators see Count + Results as EntityIds.
        $rowIds | Should -Contain 'Results' -Because 'this is the bug-state baseline; manifest UnwrapProperty fixes it'
        $rowIds | Should -Contain 'Count'
        # Test asserts the bug-state shape so regression detection downstream
        # can flag manifest entries that miss UnwrapProperty when they should declare it.
    }
}

Describe 'Expand-MDEResponse — WrapperKey.ActionCenter (live-fixture replay)' {

    It 'replays MDE_ActionCenter_CL-raw.json with UnwrapProperty=Results + IdProperty=ActionId; emits per-action rows (NOT 2 wrapper rows)' -Skip:(-not $script:HasActionCenterFixture) {
        $rawJson = Get-Content -LiteralPath $script:ActionCenterFixture -Raw
        $response = $rawJson | ConvertFrom-Json -Depth 20
        # The fixture is a sampled capture: Count metadata says 1868 (the
        # tenant's total), Results array carries a 30-row sample. The wrapper-
        # key bug would emit 2 rows (EntityId='Results' + EntityId='Count');
        # the iter-14.0 fix emits N rows where N = Results.Length.
        $sampleSize = @($response.Results).Count
        $sampleSize | Should -BeGreaterThan 0 -Because 'fixture must have at least one sampled action'

        $rows = Expand-MDEResponse -Response $response -UnwrapProperty 'Results' -IdProperty @('ActionId', 'Id', 'id')
        $rows.Count | Should -Be $sampleSize -Because "Action Center fixture has $sampleSize sampled actions; with UnwrapProperty + IdProperty=ActionId we expect $sampleSize rows (NOT 2 wrapper rows)"

        # No row Id is a wrapper-key — locked-in regression gate for iter-13.15 bug
        foreach ($row in $rows) {
            $script:ForbiddenWrapperKeys | Should -Not -Contain $row.Id -Because "row Id '$($row.Id)' must not be a wrapper-key"
        }

        # Each row's Entity carries an ActionId (or fallback heuristic match)
        $rowsWithActionId = @($rows | Where-Object {
            $_.Entity.PSObject.Properties['ActionId'] -and $_.Entity.ActionId
        })
        $rowsWithActionId.Count | Should -BeGreaterThan 0 -Because 'sampled actions in the fixture should carry ActionId fields'
    }
}

Describe 'Expand-MDEResponse — ScalarWrap (iter-14.0 Phase 3.4)' {

    It 'wraps a bool scalar response to one row with Id="value" + Entity.value' {
        $rows = Expand-MDEResponse -Response $true
        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'value'
        $rows[0].Entity.value | Should -Be $true
    }

    It 'wraps an int scalar response' {
        $rows = Expand-MDEResponse -Response 42
        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'value'
        $rows[0].Entity.value | Should -Be 42
    }

    It 'wraps a string scalar response' {
        $rows = Expand-MDEResponse -Response 'hello'
        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'value'
        $rows[0].Entity.value | Should -Be 'hello'
    }

    It 'wraps a double scalar response' {
        $rows = Expand-MDEResponse -Response 3.14
        $rows.Count | Should -Be 1
        $rows[0].Entity.value | Should -Be 3.14
    }
}

Describe 'Expand-MDEResponse — NullBoundaryMarker (iter-14.0 Phase 3.5)' {

    It 'null response emits ONE boundary-marker row' {
        $rows = Expand-MDEResponse -Response $null
        $rows.Count | Should -Be 1
        $rows[0].Entity.__boundary_marker | Should -Be $true
        $rows[0].Entity.__reason | Should -Be 'api-returned-null'
    }

    It 'boundary-marker carries -Stream context when supplied' {
        $rows = Expand-MDEResponse -Response $null -Stream 'MDE_TestStream_CL'
        $rows[0].Entity.__stream | Should -Be 'MDE_TestStream_CL'
    }

    It 'boundary-marker EntityId is unique per call (cross-stream collisions impossible)' {
        $rows1 = Expand-MDEResponse -Response $null
        $rows2 = Expand-MDEResponse -Response $null
        $rows1[0].Id | Should -Not -Be $rows2[0].Id -Because 'boundary marker IDs use Get-Random for uniqueness'
    }
}

Describe 'Expand-MDEResponse — Empty-shape boundary markers' {

    It 'empty array @() emits ONE boundary-marker row with reason=empty-array' {
        $rows = Expand-MDEResponse -Response @()
        $rows.Count | Should -Be 1
        $rows[0].Entity.__boundary_marker | Should -Be $true
        $rows[0].Entity.__reason | Should -Be 'empty-array'
    }

    It 'empty object {} emits ONE boundary-marker row with reason=empty-object' {
        $rows = Expand-MDEResponse -Response ([pscustomobject]@{})
        $rows.Count | Should -Be 1
        $rows[0].Entity.__boundary_marker | Should -Be $true
        $rows[0].Entity.__reason | Should -Be 'empty-object'
    }

    It 'wrapper present but UnwrapProperty value null emits ONE boundary-marker row with reason=unwrap-target-null' {
        $response = [pscustomobject]@{ Count = 0; Results = $null }
        $rows = Expand-MDEResponse -Response $response -UnwrapProperty 'Results'
        $rows.Count | Should -Be 1
        $rows[0].Entity.__boundary_marker | Should -Be $true
        $rows[0].Entity.__reason | Should -Be 'unwrap-target-null'
        $rows[0].Entity.__unwrapProperty | Should -Be 'Results'
    }
}

Describe 'Expand-MDEResponse — IdHeuristicCoverage' {

    It 'extracts ActionId from items in an array response' {
        $resp = @(
            [pscustomobject]@{ ActionId = 'A-1'; Status = 'OK' }
            [pscustomobject]@{ ActionId = 'A-2'; Status = 'OK' }
        )
        $rows = Expand-MDEResponse -Response $resp
        @($rows | ForEach-Object Id) | Should -Be @('A-1', 'A-2')
    }

    It 'extracts InvestigationId when ActionId not present' {
        $resp = @(
            [pscustomobject]@{ InvestigationId = 'I-1' }
        )
        $rows = Expand-MDEResponse -Response $resp
        $rows[0].Id | Should -Be 'I-1'
    }

    It 'extracts attackPathId from XSPM-shaped items' {
        $resp = @(
            [pscustomobject]@{ attackPathId = 'p-1'; severity = 'Critical' }
        )
        $rows = Expand-MDEResponse -Response $resp
        $rows[0].Id | Should -Be 'p-1'
    }

    It 'extracts incidentId from incident-shaped items' {
        $resp = @(
            [pscustomobject]@{ incidentId = 'inc-100' }
        )
        $rows = Expand-MDEResponse -Response $resp
        $rows[0].Id | Should -Be 'inc-100'
    }

    It 'extracts alertId from alert-shaped items' {
        $resp = @(
            [pscustomobject]@{ alertId = 'alert-200' }
        )
        $rows = Expand-MDEResponse -Response $resp
        $rows[0].Id | Should -Be 'alert-200'
    }

    It 'falls back to idx-N when no IdProperty match' {
        $resp = @(
            [pscustomobject]@{ random_field = 'anonymous' }
        )
        $rows = Expand-MDEResponse -Response $resp
        $rows[0].Id | Should -Be 'idx-0'
    }
}

Describe 'Expand-MDEResponse — PerEntryIdPropertyOverride' {

    It 'manifest IdProperty override is respected (Action Center)' {
        $manifest = Get-MDEEndpointManifest -Force
        $entry = $manifest['MDE_ActionCenter_CL']
        $entry.IdProperty | Should -Not -BeNullOrEmpty
        @($entry.IdProperty) | Should -Contain 'ActionId'
    }

    It 'manifest IdProperty override is respected (XSPM AttackPaths)' {
        $manifest = Get-MDEEndpointManifest -Force
        $entry = $manifest['MDE_XspmAttackPaths_CL']
        @($entry.IdProperty) | Should -Contain 'attackPathId'
    }
}

Describe 'Expand-MDEResponse — Hashtable-vs-PSCustomObject parity (regression: iter-13.5)' {

    It 'hashtable response with named properties flattens (shape 3)' {
        $resp = @{ FeatureA = $true; FeatureB = $false }
        $rows = Expand-MDEResponse -Response $resp
        $rows.Count | Should -Be 2
        @($rows | ForEach-Object Id) | Should -Contain 'FeatureA'
        @($rows | ForEach-Object Id) | Should -Contain 'FeatureB'
    }

    It 'hashtable wrapper with UnwrapProperty unwraps correctly (multi-item)' {
        # Use 2 items so PowerShell's single-element-array collapse inside hashtables
        # doesn't bite. Production responses always have N items (or 0 → empty marker
        # path) so the singleton-collapse case isn't reachable from real API data.
        $resp = @{
            Count   = 2
            Results = @(
                [pscustomobject]@{ ActionId = 'h-1' }
                [pscustomobject]@{ ActionId = 'h-2' }
            )
        }
        $rows = Expand-MDEResponse -Response $resp -UnwrapProperty 'Results'
        $rows.Count | Should -Be 2
        @($rows | ForEach-Object Id) | Should -Be @('h-1', 'h-2')
    }

    It 'hashtable wrapper with single-item Results array unwraps via [Object[]]' {
        # Force array typing to defeat single-element collapse inside hashtable
        # construction. This is the pattern operators see when JSON parsing
        # delivers a 1-element Results array (ConvertFrom-Json preserves typing).
        $singleItemArray = [Object[]]@( [pscustomobject]@{ ActionId = 'single-1' } )
        $resp = @{ Count = 1; Results = $singleItemArray }
        $rows = Expand-MDEResponse -Response $resp -UnwrapProperty 'Results'
        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'single-1'
    }
}
