#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker - Sentinel Connector card dataTypes[].name +
    connectivityCriteria query MUST reference workspace tables that actually
    receive ingested rows.

.DESCRIPTION
    LIVE FORENSIC 2026-05-06: deploy/compiled/mainTemplate.json shipped with:
      1. dataTypes[].name = MDE_*_CL - these are DCR streamDeclaration names
         only; they NEVER materialize as workspace tables (transformKql routes
         rows to Defender_<Category>_CL). Sentinel UI showed Disconnected
         because every freshness query returned empty.
      2. The criteria key was misspelled connectivityCriterias (plural) -
         Sentinel UI parser only reads the singular connectivityCriteria,
         so the IsConnectedQuery was silently ignored.

    Both bugs slipped past 1778 tests because no test reads the compiled
    mainTemplate.json connector block + cross-references with the actual
    workspace table set the DCRs ingest into.

    This test loads deploy/compiled/mainTemplate.json + asserts:
      - dataTypes[].name is one of the 10 Defender_<Category>_CL tables
        OR XdrConnectorHealth_CL
      - The criteria key is connectivityCriteria (singular) NOT
        connectivityCriterias
      - The IsConnectedQuery references XdrConnectorHealth_CL with a
        StreamsSucceeded > 0 guard
#>

BeforeAll {
    $script:RepoRoot          = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:MainTemplatePath  = Join-Path $script:RepoRoot 'deploy/compiled/mainTemplate.json'

    # Canonical workspace destination tables (per consolidated 10-category
    # DCR schema + 1 ops table). Update this list when adding new categories.
    $script:LiveTables = @(
        'Defender_EndpointDeviceManagement_CL',
        'Defender_EndpointConfiguration_CL',
        'Defender_VulnerabilityManagement_CL',
        'Defender_IdentityProtection_CL',
        'Defender_ConfigurationAndSettings_CL',
        'Defender_ExposureManagement_CL',
        'Defender_ThreatAnalytics_CL',
        'Defender_ActionCenter_CL',
        'Defender_MultiTenantOperations_CL',
        'Defender_StreamingApi_CL',
        'XdrConnectorHealth_CL'
    )

    # Walk an ARM template tree to locate the connector block.
    # Strict-mode safe: every property access is gated by PSObject.Properties.Name -contains
    # check (PS 7.4+ on Linux CI runs StrictMode v3 which throws on missing properties).
    $script:FindConnectorBlock = {
        param($node)
        if (-not $node) { return $null }
        $hasProp = { param($obj, $name) ($null -ne $obj) -and ($obj.PSObject.Properties.Name -contains $name) }
        if ((& $hasProp $node 'properties') -and (& $hasProp $node.properties 'connectorUiConfig')) {
            $cui = $node.properties.connectorUiConfig
            if (& $hasProp $cui 'dataTypes') {
                return $cui
            }
        }
        if (& $hasProp $node 'resources') {
            foreach ($child in $node.resources) {
                $found = & $script:FindConnectorBlock $child
                if ($found) { return $found }
            }
        }
        if ((& $hasProp $node 'properties') -and (& $hasProp $node.properties 'template') -and (& $hasProp $node.properties.template 'resources')) {
            foreach ($child in $node.properties.template.resources) {
                $found = & $script:FindConnectorBlock $child
                if ($found) { return $found }
            }
        }
        return $null
    }

    $script:Tpl = Get-Content -Raw $script:MainTemplatePath | ConvertFrom-Json
    $script:ConnectorBlock = $null
    foreach ($res in $script:Tpl.resources) {
        $script:ConnectorBlock = & $script:FindConnectorBlock $res
        if ($script:ConnectorBlock) { break }
    }
}

Describe 'Connector.DataTypeWorkspaceParity - connector card references LIVE workspace tables' {

    It 'mainTemplate.json connector resource block parses as JSON (no syntax errors)' {
        Test-Path $script:MainTemplatePath | Should -BeTrue -Because 'mainTemplate.json must exist'
        { Get-Content -Raw $script:MainTemplatePath | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'connector resource block is present in mainTemplate.json' {
        $script:ConnectorBlock | Should -Not -BeNullOrEmpty -Because 'recursive walk failed to find a connector block in any nesting depth'
    }

    It 'every dataTypes[].name is one of the live workspace tables' {
        $script:ConnectorBlock | Should -Not -BeNullOrEmpty
        foreach ($dt in $script:ConnectorBlock.dataTypes) {
            $dt.name | Should -BeIn $script:LiveTables -Because (
                "Sentinel UI freshness indicator queries '$($dt.name)' - if no DCR writes there, the indicator stays Stale and the operator thinks the connector is broken. MDE_*_CL stream identifiers are DCR streamDecl names only; they NEVER appear as workspace tables. Use Defender_<Category>_CL instead."
            )
        }
    }

    It 'every dataTypes[].lastDataReceivedQuery starts with the same workspace table name' {
        $script:ConnectorBlock | Should -Not -BeNullOrEmpty
        foreach ($dt in $script:ConnectorBlock.dataTypes) {
            $dt.lastDataReceivedQuery | Should -Match ('^' + [regex]::Escape($dt.name) + '\s') -Because (
                "lastDataReceivedQuery for '$($dt.name)' should query that exact table; mismatch means the freshness indicator queries a different table than its label."
            )
        }
    }

    It 'uses singular connectivityCriteria (NOT misspelled connectivityCriterias)' {
        $script:ConnectorBlock | Should -Not -BeNullOrEmpty
        $hasSingular = $script:ConnectorBlock.PSObject.Properties.Name -contains 'connectivityCriteria'
        $hasPlural   = $script:ConnectorBlock.PSObject.Properties.Name -contains 'connectivityCriterias'
        $hasSingular | Should -BeTrue -Because 'Sentinel UI schema requires singular connectivityCriteria. Misspelled plural is silently ignored - card stays Disconnected.'
        $hasPlural   | Should -BeFalse -Because 'The plural connectivityCriterias was a 2026-05-06 LIVE bug - Sentinel UI ignored it silently.'
    }

    It 'IsConnectedQuery targets XdrConnectorHealth_CL with a real liveness guard' {
        $script:ConnectorBlock | Should -Not -BeNullOrEmpty
        $criteria = $script:ConnectorBlock.connectivityCriteria | Where-Object { $_.type -eq 'IsConnectedQuery' }
        $criteria | Should -Not -BeNullOrEmpty -Because 'IsConnectedQuery is the gate that flips the card to Connected'
        foreach ($c in $criteria) {
            foreach ($q in $c.value) {
                $q | Should -Match 'XdrConnectorHealth_CL' -Because 'IsConnectedQuery must query the consolidated health table'
                $q | Should -Match 'StreamsSucceeded\s*>\s*0' -Because 'Liveness gate is StreamsSucceeded > 0 (means at least one tier completed an activity successfully)'
            }
        }
    }
}
