# Per-Op Pester replay test · Defender/EndpointManagement/GetMagellanFeatures
# GENERATED scaffold (tools/Onboard-NextCategory.ps1 -Generate). Offline contract + schema-parity assertions
# are live now; the live-fixture fan-out + ProjectionMap block is -Skip-gated until the operator captures the
# lab fixture and fills Provenance.Live (plan §11.1 #7). Remove the -Skip once the fixture exists.

#Requires -Module Pester

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $env:PSModulePath = (Join-Path $script:RepoRoot 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $script:RepoRoot 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
    $script:Manifest = Import-PowerShellDataFile -Path (Join-Path $script:RepoRoot 'manifests\Defender\EndpointManagement.psd1') -ErrorAction Stop
    $script:Op = @($script:Manifest.Operations | Where-Object { $_.OperationKey -eq 'GetMagellanFeatures' })[0]
}

Describe 'Manifest contract · Defender/EndpointManagement/GetMagellanFeatures' {
    It 'manifest entry exists for GetMagellanFeatures · no IsActive flag (v11 §4.11)' {
        $script:Op | Should -Not -BeNullOrEmpty
        $script:Op.OperationKey | Should -Be 'GetMagellanFeatures'
        $script:Op.ContainsKey('IsActive') | Should -BeFalse
    }
    It 'carries the required §4.11 fields' {
        foreach ($f in @('Method','SubPortal','Path','ResponseShape','IngestionMode','Cadence','RequiresProducts','ProjectionMap','DcrStreamName','WorkspaceTable','DcrImmutableIdEnvVar','Provenance')) {
            $script:Op.ContainsKey($f) | Should -BeTrue -Because "missing $f"
        }
    }
    It 'canonical table + stream naming' {
        $script:Op.WorkspaceTable | Should -Be 'Defender_EndpointManagement_CL'
        $script:Op.DcrStreamName  | Should -Be 'Custom-Defender_EndpointManagement_CL'
    }
}

Describe 'Schema parity · manifest to ARM artifact (per-category-schema)' {
    BeforeAll {
        $script:Artifact = Get-Content (Join-Path $script:RepoRoot 'deploy\per-category-schemas\Defender-EndpointManagement.json') -Raw | ConvertFrom-Json -Depth 50
    }
    It 'DCR stream cols == table cols (set-equal · axis 14)' {
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcr   = @($script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns | ForEach-Object { "$($_.name):$($_.type)" }) | Sort-Object
        $table = @($script:Artifact.TableResource.properties.schema.columns | ForEach-Object { "$($_.name):$($_.type)" }) | Sort-Object
        Compare-Object $dcr $table | Should -BeNullOrEmpty
    }
    It 'every manifest ProjectionMap key is present as a DCR column' {
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcrNames = @($script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns | ForEach-Object { $_.name })
        foreach ($k in $script:Op.ProjectionMap.Keys) { $dcrNames | Should -Contain $k }
    }
    It 'TenantId is NOT user-declared (LA auto-populates · DCR rejects)' {
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcrNames = @($script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns | ForEach-Object { $_.name })
        $dcrNames | Should -Not -Contain 'TenantId'
    }
}

Describe 'Live fan-out + ProjectionMap · GetMagellanFeatures' -Skip {
    # TODO(operator · §11.1 #7): capture the live fixture, set Provenance.Live, then REMOVE the -Skip above.
    # Mirror tests/replay/Defender/Operations/GetHistory.Tests.ps1: ConvertTo-XdrRows fan-out (B1 · no row drop),
    # Apply-XdrProjectionMap typed-col correctness against real row[0], and Compress-XdrRawJson RawJson presence.
    It 'fixture replay proves N>0 rows + typed projection (fill in after fixture capture)' {
        $true | Should -BeTrue
    }
}
