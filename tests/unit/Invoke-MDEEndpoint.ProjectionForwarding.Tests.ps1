#Requires -Modules Pester
<#
.SYNOPSIS
    Regression gate: Invoke-MDEEndpoint MUST forward the manifest's
    ProjectionMap to ConvertTo-MDEIngestRow.

.DESCRIPTION
    LIVE EVIDENCE (iter-14.0, 2026-05-03 — workspace 3f75ec26-...):
        Every MDE_*_CL row's typed cols were NULL across ALL 47 streams since
        v0.1.0-beta because Invoke-MDEEndpoint constructed the
        ConvertTo-MDEIngestRow call without -ProjectionMap. The dispatcher
        emitted rows with only the 4 base columns + RawJson; every typed
        column in every operator-facing query came back as null.

    Sample evidence (post-fix verification):
        MDE_AdvancedFeatures_CL EntityId='LowFidelityEnrichmentEnabled'
            FeatureName=NULL EnableWdavAntiTampering=NULL
            AatpIntegrationEnabled=NULL  RawJson length=5
        MDE_TenantContext_CL  MdeTenantId=NULL TenantName=NULL Region=NULL
        MDE_PUAConfig_CL      AutomatedIrPuaAsSuspicious=NULL ...

    The bug was silent because:
      - ConvertTo-MDEIngestRow's -ProjectionMap parameter is OPTIONAL (defaults
        to $null), so callers that omit it just skip projection.
      - Invoke-MDEEndpoint's call site set every other parameter explicitly
        (-Stream / -EntityId / -Raw / -Extras) but not -ProjectionMap.
      - DCR.SchemaConsistency.Tests.ps1 drove ConvertTo-MDEIngestRow directly
        with -ProjectionMap explicitly set, so it validated the projector but
        not its caller.

    This test fires Invoke-MDEEndpoint with a representative real-shape
    response and asserts the emitted row has the typed cols populated, not
    just the base 4 + RawJson. Catches any future regression where
    -ProjectionMap forwarding breaks.
#>

BeforeAll {
    $script:RepoRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ClientModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'
    $script:IngestModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'

    function global:Get-AzAccessToken { param([string]$ResourceUrl) [pscustomobject]@{ Token = 'stub'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }

    Import-Module $script:IngestModulePath -Force -ErrorAction Stop
    $script:CommonAuthPath_   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth'    'Xdr.Common.Auth.psd1'
    $script:DefenderAuthPath_ = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'
    Import-Module $script:CommonAuthPath_   -Force -ErrorAction Stop
    Import-Module $script:DefenderAuthPath_ -Force -ErrorAction Stop
    Import-Module $script:ClientModulePath  -Force -ErrorAction Stop

    Set-StrictMode -Version Latest
    $script:Session = [pscustomobject]@{
        PortalHost = 'security.microsoft.com'
        TenantId   = '11111111-1111-1111-1111-111111111111'
        Cookies    = @{}
    }
}

Describe 'Invoke-MDEEndpoint forwards manifest ProjectionMap to ConvertTo-MDEIngestRow' {

    It 'emits rows with populated typed columns (not just base 4 + RawJson) for MDE_ExposureRecommendations_CL' {
        # Real-shape exposure recommendation captured from the live tenant 2026-05-03.
        # The manifest's ProjectionMap for this stream maps:
        #   RecommendationId = $tostring:id  → 'RoleOverlap'
        #   Title            = $tostring:title → 'Use least privileged...'
        #   Severity         = $tostring:severity → 'low'
        #   Source           = $tostring:source → 'Microsoft'
        #   Category         = $tostring:category → 'identity'
        #   IsDisabled       = $tobool:isDisabled → $false
        $mockShape = [pscustomobject]@{
            results = @(
                [pscustomobject]@{
                    id                  = 'RoleOverlap'
                    title               = 'Use least privileged administrative roles'
                    severity            = 'low'
                    currentState        = 'NotStarted'
                    source              = 'Microsoft'
                    product             = 'AzureAD'
                    category            = 'identity'
                    implementationCost  = 'low'
                    userImpact          = 'low'
                    isDisabled          = $false
                    score               = 0.0
                    maxScore            = 10.0
                    lastSynced          = '2026-05-02T01:00:00Z'
                }
            )
            recordsCount = 1
        }

        InModuleScope Xdr.Defender.Client -Parameters @{ MockShape = $mockShape; Session = $script:Session } {
            param($MockShape, $Session)

            Mock Invoke-DefenderPortalRequest -ModuleName Xdr.Defender.Client { $MockShape } -ParameterFilter { $true }

            $rows = Invoke-MDEEndpoint -Session $Session -Stream 'MDE_ExposureRecommendations_CL'
            $rows = @($rows)

            $rows.Count | Should -Be 1 -Because 'UnwrapProperty=results unwraps the {results:[1]} shape into 1 per-entity row'

            $row = $rows[0]
            $row.EntityId | Should -Be 'RoleOverlap'

            # The single failure mode this gate exists to catch: ProjectionMap
            # NOT forwarded → typed cols all null while RawJson is populated.
            $row.PSObject.Properties['RecommendationId'] | Should -Not -BeNullOrEmpty -Because 'ProjectionMap declared RecommendationId; row must have the column'
            $row.RecommendationId | Should -Be 'RoleOverlap' -Because 'RecommendationId hint = $tostring:id; entity.id = RoleOverlap'
            $row.Title            | Should -Be 'Use least privileged administrative roles'
            $row.Severity         | Should -Be 'low'
            $row.Source           | Should -Be 'Microsoft'
            $row.Category         | Should -Be 'identity'
            $row.Status           | Should -Be 'NotStarted' -Because 'Status hint = $tostring:currentState'
            $row.IsDisabled       | Should -BeFalse -Because 'IsDisabled hint = $tobool:isDisabled'
        }
    }

    It 'emits typed cols for property-bag streams (e.g. MDE_AdvancedFeatures_CL)' {
        # Property-bag streams (Shape 3) — each top-level property becomes
        # one row with EntityId=propertyName, Entity=propertyValue. The
        # manifest's ProjectionMap projects EntityId itself + RawJson.
        # Per Get-MDEEndpointManifest Defaults block ProjectionMap is always at
        # least @{} so the forwarding path is exercised.
        $mockShape = [pscustomobject]@{
            EnableWdavAntiTampering       = $true
            AatpIntegrationEnabled        = $true
            EnableMcasIntegration         = $false
            AutoResolveInvestigatedAlerts = $true
        }

        InModuleScope Xdr.Defender.Client -Parameters @{ MockShape = $mockShape; Session = $script:Session } {
            param($MockShape, $Session)

            Mock Invoke-DefenderPortalRequest -ModuleName Xdr.Defender.Client { $MockShape } -ParameterFilter { $true }

            $rows = Invoke-MDEEndpoint -Session $Session -Stream 'MDE_AdvancedFeatures_CL'
            $rows = @($rows)
            $rows.Count | Should -BeGreaterOrEqual 1 -Because 'property-bag flattens into one row per property'

            # The first row should have EntityId='EnableWdavAntiTampering' (or
            # whichever the iteration order surfaces first). The manifest's
            # ProjectionMap maps FeatureName='$tostring:EntityId' so:
            $row = $rows[0]
            $row.PSObject.Properties['FeatureName'] | Should -Not -BeNullOrEmpty -Because 'AdvancedFeatures ProjectionMap declares FeatureName'
            [string]::IsNullOrEmpty([string]$row.FeatureName) | Should -BeFalse -Because 'FeatureName projects from EntityId; ProjectionMap was forwarded'
        }
    }
}
