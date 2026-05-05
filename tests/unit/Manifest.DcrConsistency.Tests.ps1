#Requires -Modules Pester

# Cross-layer drift guard. Every MDE data stream MUST be declared in three places
# that must agree:
#
#   1. src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1  (46 entries)
#   2. DCR streamDeclarations                                   (46 data + 1 system = 47)
#   3. Custom-tables list in the workspace deployment           (46 data + 1 system = 47)
#
# Preferred source of declarations 2 and 3 is the compiled ARM
# (deploy/compiled/mainTemplate.json) — it's what actually gets deployed. Bicep
# sources are used as fallback if the JSON ever drifts out of existence.

BeforeDiscovery {
    $repoRoot           = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    $script:ManifestPath     = Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:MainTemplatePath = Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:CustomTablesBicep = Join-Path $repoRoot 'deploy' 'modules' 'custom-tables.bicep'
    $script:DceDcrBicep       = Join-Path $repoRoot 'deploy' 'modules' 'dce-dcr.bicep'

    # System tables declared ONLY in DCR + custom-tables; NOT in endpoints manifest.
    $script:SystemStreams = @('XdrConnectorHealth_CL')
}

BeforeAll {
    $repoRoot           = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ManifestPath     = Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:MainTemplatePath = Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:CustomTablesBicep = Join-Path $repoRoot 'deploy' 'modules' 'custom-tables.bicep'
    $script:DceDcrBicep       = Join-Path $repoRoot 'deploy' 'modules' 'dce-dcr.bicep'

    # Pester 5 — BeforeDiscovery script vars do NOT carry into the Run phase;
    # re-declare the system stream list here.
    $script:SystemStreams = @('XdrConnectorHealth_CL')

    # -------- Manifest -------------------------------------------------------
    $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:ManifestStreams = @($manifest.Endpoints | ForEach-Object { $_.Stream } | Sort-Object -Unique)

    # -------- DCR streams (from compiled mainTemplate.json) -----------------
    $script:DcrStreams = @()
    $script:CustomTables = @()

    if (Test-Path $script:MainTemplatePath) {
        $arm = Get-Content -Raw -Path $script:MainTemplatePath | ConvertFrom-Json

        # 47 streams partitioned across 5 DCRs sharing one DCE (canonical
        # Microsoft pattern: 1 dataFlow per stream with explicit outputStream
        # + transformKql='source', capped at 10 dataFlows per DCR). Walk all
        # DCR resources and union their streamDeclarations.
        $dcrs = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
        $allDcrStreams = @()
        foreach ($dcr in $dcrs) {
            if ($dcr -and $dcr.properties.streamDeclarations) {
                $allDcrStreams += @($dcr.properties.streamDeclarations.PSObject.Properties.Name)
            }
        }
        if ($allDcrStreams) {
            $script:DcrStreams = $allDcrStreams |
                ForEach-Object { $_ -replace '^Custom-', '' } |
                Sort-Object -Unique
        }

        # Custom tables live inside a nested deployment. Walk the resources tree.
        # StrictMode-safe: use PSObject.Properties.Name checks throughout because
        # some nested deployments use `templateLink` (no inline template at all).
        # Three patterns supported:
        #   (a) nested-template variable `tableNames` holding an array of names (copy-loop)
        #   (b) nested-template resource with literal name "ws/MDE_Xyz_CL"
        #   (c) nested-template resource with ARM expression name like
        #       "[concat(parameters('workspaceName'), '/MDE_Xyz_CL')]" — extract via regex
        $nestedDeployments = $arm.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' }
        foreach ($nd in $nestedDeployments) {
            if (-not ($nd.PSObject.Properties.Name -contains 'properties')) { continue }
            if (-not ($nd.properties.PSObject.Properties.Name -contains 'template')) { continue }
            # Pattern (a) — Bicep-output ARM declared a `tableNames` variable +
            # copy-loop. Hand-authored ARM (single source of truth in v0.1.0-beta)
            # does NOT use this pattern; tables are direct resources. Check for
            # the variable and harvest if present, but DO NOT early-skip the
            # resource walk on its absence.
            if (($nd.properties.template.PSObject.Properties.Name -contains 'variables') -and
                ($nd.properties.template.variables.PSObject.Properties.Name -contains 'tableNames')) {
                $script:CustomTables += @($nd.properties.template.variables.tableNames)
            }
            # Also support the pattern where the nested template declares tables as
            # individual resources (type=Microsoft.OperationalInsights/workspaces/tables).
            if ($nd.properties.template.PSObject.Properties.Name -contains 'resources') {
                foreach ($r in $nd.properties.template.resources) {
                    if ($r.PSObject.Properties.Name -contains 'type' -and
                        $r.type -eq 'Microsoft.OperationalInsights/workspaces/tables' -and
                        $r.PSObject.Properties.Name -contains 'name') {
                        # Case (b): plain "workspace/TableName"
                        $tblName = ($r.name -split '/')[-1]
                        # Phase J.C.2-5 (2026-05-04): 47 per-stream MDE_*_CL tables
                        # consolidated to 10 per-category Defender_<Category>_CL.
                        # XdrConnectorHealth_CL is the operational table (transcends portals).
                        # Pattern accepts: Defender_<PascalCategory>_CL OR XdrConnectorHealth_CL.
                        if ($tblName -match '^(Defender_\w+_CL|XdrConnectorHealth_CL)$') {
                            $script:CustomTables += $tblName
                            continue
                        }
                        # Case (c): ARM expression — extract "/Defender_X_CL" or "/XdrConnectorHealth_CL" substring
                        if ($r.name -match "'/(Defender_\w+_CL|XdrConnectorHealth_CL)'") {
                            $script:CustomTables += $matches[1]
                            continue
                        }
                        # Case (c-alt): look inside properties.schema.name (literal)
                        if ($r.PSObject.Properties.Name -contains 'properties' -and
                            $r.properties.PSObject.Properties.Name -contains 'schema' -and
                            $r.properties.schema.PSObject.Properties.Name -contains 'name') {
                            $schemaName = $r.properties.schema.name
                            if ($schemaName -is [string] -and $schemaName -match '^(Defender_\w+_CL|XdrConnectorHealth_CL)$') {
                                $script:CustomTables += $schemaName
                            }
                        }
                    }
                }
            }
        }
        $script:CustomTables = @($script:CustomTables | Sort-Object -Unique)
    }

    # -------- Fallback: parse Bicep as text if JSON missing / incomplete ----
    if (-not $script:DcrStreams -and (Test-Path $script:DceDcrBicep)) {
        $bicep = Get-Content -Raw -Path $script:DceDcrBicep
        $script:DcrStreams = @([regex]::Matches($bicep, "'(MDE_\w+_CL)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique)
    }
    if (-not $script:CustomTables -and (Test-Path $script:CustomTablesBicep)) {
        $bicep = Get-Content -Raw -Path $script:CustomTablesBicep
        $script:CustomTables = @([regex]::Matches($bicep, "'(MDE_\w+_CL)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique)
    }

    # -------- Phase J.C.2-5 architecture: per-stream → category-table mapping ----
    # Manifest declares 46 streams → DCR streamDeclarations 47 (46 data + 1 ops).
    # Workspace tables 11 (10 Defender_<Category>_CL + 1 XdrConnectorHealth_CL).
    # Each stream maps to a CategoryTable derived from CategoryId.
    $script:CategoryMap = @{
        1='EndpointDeviceManagement'; 2='EndpointConfiguration'; 3='VulnerabilityManagement';
        4='IdentityProtection';       5='ConfigurationAndSettings'; 6='ExposureManagement';
        7='ThreatAnalytics';          8='ActionCenter'; 9='MultiTenantOperations'; 10='StreamingApi'
    }
    $script:StreamToCatTable = @{}
    foreach ($entry in $manifest.Endpoints) {
        if ($entry.ContainsKey('CategoryId') -and $entry.CategoryId -and $script:CategoryMap.ContainsKey([int]$entry.CategoryId)) {
            $script:StreamToCatTable[$entry.Stream] = "Defender_$($script:CategoryMap[[int]$entry.CategoryId])_CL"
        }
    }
}

Describe 'Manifest / DCR / custom-tables consistency (Phase J.C.2-5: 47→10 consolidation)' {

    It 'manifest contains exactly 59 streams (46 baseline + 13 Tier A new in v0.1.0 GA Phase 2)' {
        $script:ManifestStreams.Count | Should -Be 59
    }

    It 'DCR declares 59 source streams + 1 ops (XdrConnectorHealth_CL) = 60 total streamDeclarations' {
        $script:DcrStreams.Count | Should -Be 60 -Because 'DCR keeps Custom-MDE_*_CL incoming streamDeclarations + 1 XdrConnectorHealth_CL ops'
    }

    It 'custom-tables declares 10 per-category Defender_*_CL + 1 XdrConnectorHealth_CL = 11 total' {
        $script:CustomTables.Count | Should -Be 11 -Because 'Phase J.C.2-5: 47 per-stream tables consolidated to 10 per-category + 1 ops'
    }

    It 'DCR contains the XdrConnectorHealth_CL ops stream' {
        $script:DcrStreams | Should -Contain 'XdrConnectorHealth_CL'
        $script:DcrStreams | Should -Not -Contain 'MDE_AuthTestResult_CL' -Because 'auth chain diagnostics moved to App Insights customEvents in v0.1.0 GA first publish'
    }

    It 'custom-tables contains the XdrConnectorHealth_CL ops table' {
        $script:CustomTables | Should -Contain 'XdrConnectorHealth_CL'
        $script:CustomTables | Should -Not -Contain 'MDE_AuthTestResult_CL'
    }

    It 'custom-tables contains all 10 Defender_<Category>_CL tables' {
        foreach ($cat in $script:CategoryMap.Values) {
            $expected = "Defender_${cat}_CL"
            $script:CustomTables | Should -Contain $expected -Because "Phase J.C.2-5: each nodoc category has a Defender_<Category>_CL table"
        }
    }
}

Describe 'Per-stream DCR coverage (Phase J.C.2-5)' -ForEach @(
    # One It per manifest stream, so failure picks out the bad row precisely.
    # BeforeDiscovery doesn't run the Import, so we re-read the manifest here.
    (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')).Endpoints |
        ForEach-Object { @{ StreamName = $_.Stream; Tier = $_.Tier } }
) {

    It "stream <StreamName> (<Tier>) has a DCR streamDeclaration" {
        $script:DcrStreams | Should -Contain $StreamName
    }

    It "stream <StreamName> (<Tier>) maps to a Defender_<Category>_CL table" {
        # Phase J.C.2-5: each stream maps to a category table via CategoryTable derivation.
        $catTable = $script:StreamToCatTable[$StreamName]
        $catTable | Should -Not -BeNullOrEmpty -Because "stream <StreamName> must have CategoryId in manifest"
        $script:CustomTables | Should -Contain $catTable -Because "stream <StreamName> maps to category table $catTable which must exist in workspace"
    }
}
