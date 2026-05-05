#Requires -Modules Pester
<#
.SYNOPSIS
    Bug-class gate: no streamDeclaration column or customTables schema column may
    use a Log Analytics SYSTEM-RESERVED column name. These columns are auto-typed
    by Azure Monitor and a user-defined column with the same name fails DCR
    validation with `Types of transform output columns do not match the ones
    defined by the output stream` (e.g. produced:'String', output:'Guid' for
    TenantId).

.DESCRIPTION
    Reserved list — sourced from Microsoft Learn Log Analytics standard columns.
    These are added/managed by Azure Monitor with FIXED types; declaring a
    user-defined column with the same name produces a hard ARM rejection at
    DCR PUT time. Caught us 2026-04-30 with three streams (MtoTenants /
    TenantContext / TenantWorkloadStatus) that declared `TenantId: string` —
    Azure auto-types it as `guid`, deploy died on dataFlows[5,7,8].

    Reserved columns:
      TenantId        guid     — workspace-tenant identifier
      _ResourceId     string   — origin resource identifier
      _SubscriptionId string   — origin subscription
      _ItemId         string   — per-row identifier
      _BilledSize     real     — ingestion-billing size
      _IsBillable     bool     — billable flag
      _TimeReceived   datetime — workspace ingest time (vs source TimeGenerated)
      Type            string   — table-name back-link (Log Analytics row-routing)

    Gate scope: walks every Microsoft.Insights/dataCollectionRules
    streamDeclarations.*.columns array AND every Microsoft.OperationalInsights/
    workspaces/tables schema.columns array in the customTables nested
    deployment. ANY collision is a FAIL.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    if (-not (Test-Path -LiteralPath $script:ArmPath)) {
        throw "Compiled ARM template not found at $($script:ArmPath). Run: az bicep build --file ./deploy/main.bicep --outfile ./deploy/compiled/mainTemplate.json"
    }
    $script:Arm = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50

    # Microsoft Learn — Log Analytics standard columns (system-reserved).
    # These names CANNOT be used for user-defined columns; Azure auto-injects them
    # with fixed types at row-write time and a same-name user column collides.
    $script:ReservedColumnNames = @(
        'TenantId',
        '_ResourceId',
        '_SubscriptionId',
        '_ItemId',
        '_BilledSize',
        '_IsBillable',
        '_TimeReceived',
        'Type'
    )
}

Describe 'SystemReservedColumnNames.StreamDeclarations' {

    It 'no DCR streamDeclaration column uses a system-reserved name' {
        $dcrs = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        $dcrs | Should -Not -BeNullOrEmpty -Because 'compiled ARM should declare DCR resources'

        $violations = @()
        foreach ($dcr in $dcrs) {
            if (-not $dcr.properties.streamDeclarations) { continue }
            foreach ($streamProp in $dcr.properties.streamDeclarations.PSObject.Properties) {
                $streamName = $streamProp.Name
                $cols = $streamProp.Value.columns
                if (-not $cols) { continue }
                foreach ($col in $cols) {
                    if ($script:ReservedColumnNames -contains $col.name) {
                        $violations += "DCR '$($dcr.name)' streamDeclarations['$streamName'] column '$($col.name)' is system-reserved (auto-typed by Azure; DCR validation will fail)"
                    }
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because ($violations -join "`n")
    }
}

Describe 'SystemReservedColumnNames.CustomTables' {

    It 'no customTables nested table schema column uses a system-reserved name' {
        # Find the cross-RG nested deployment whose name starts with `customTables-`.
        $nested = @($script:Arm.resources | Where-Object {
            $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'customTables'
        })
        $nested | Should -Not -BeNullOrEmpty -Because 'expected a customTables-* nested deployment'

        $violations = @()
        foreach ($n in $nested) {
            $innerResources = @($n.properties.template.resources)
            $tables = $innerResources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' }
            foreach ($tbl in $tables) {
                $tableName = $tbl.name
                $cols = $tbl.properties.schema.columns
                if (-not $cols) { continue }
                foreach ($col in $cols) {
                    if ($script:ReservedColumnNames -contains $col.name) {
                        $violations += "customTables nested deployment table '$tableName' column '$($col.name)' is system-reserved (Log Analytics auto-types it; DCR validation will fail when the matching streamDecl declares its own type)"
                    }
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because ($violations -join "`n")
    }
}

Describe 'SystemReservedColumnNames.ManifestProjectionMap' {
    # Defence in depth: also assert the manifest ProjectionMap keys do not name
    # a reserved column. The DCR/table schemas are derived from the manifest
    # at compile time, so a manifest-side gate catches the bug at PR review
    # rather than at compile-time-only.
    BeforeAll {
        $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
        $script:Manifest     = Import-PowerShellDataFile -Path $script:ManifestPath
    }

    It 'no manifest endpoint ProjectionMap key uses a system-reserved column name' {
        $violations = @()
        foreach ($endpoint in $script:Manifest.Endpoints) {
            $stream = $endpoint.Stream
            if (-not $endpoint.ContainsKey('ProjectionMap')) { continue }
            $pm = $endpoint.ProjectionMap
            if ($null -eq $pm) { continue }
            foreach ($key in $pm.Keys) {
                if ($script:ReservedColumnNames -contains $key) {
                    $violations += "manifest endpoint '$stream' ProjectionMap key '$key' is system-reserved (Log Analytics auto-types it; DCR validation will fail)"
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because ($violations -join "`n")
    }
}
