#Requires -Modules Pester

# Cross-layer drift guard. Every MDE data stream MUST be declared in three places
# that must agree:
#
#   1. src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1  (45 entries, v0.1.0-beta.1)
#   2. DCR streamDeclarations                                   (45 data + 2 system = 47)
#   3. Custom-tables list in the workspace deployment           (45 data + 2 system = 47)
#
# Preferred source of declarations 2 and 3 is the compiled ARM
# (deploy/compiled/mainTemplate.json) — it's what actually gets deployed. Bicep
# sources are used as fallback if the JSON ever drifts out of existence.

BeforeDiscovery {
    $repoRoot           = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    $script:ManifestPath     = Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1'
    $script:MainTemplatePath = Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:CustomTablesBicep = Join-Path $repoRoot 'deploy' 'modules' 'custom-tables.bicep'
    $script:DceDcrBicep       = Join-Path $repoRoot 'deploy' 'modules' 'dce-dcr.bicep'

    # System tables declared ONLY in DCR + custom-tables; NOT in endpoints manifest.
    $script:SystemStreams = @('MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL')
}

BeforeAll {
    $repoRoot           = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ManifestPath     = Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1'
    $script:MainTemplatePath = Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:CustomTablesBicep = Join-Path $repoRoot 'deploy' 'modules' 'custom-tables.bicep'
    $script:DceDcrBicep       = Join-Path $repoRoot 'deploy' 'modules' 'dce-dcr.bicep'

    # Pester 5 — BeforeDiscovery script vars do NOT carry into the Run phase;
    # re-declare the system stream list here.
    $script:SystemStreams = @('MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL')

    # -------- Manifest -------------------------------------------------------
    $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:ManifestStreams = @($manifest.Endpoints | ForEach-Object { $_.Stream } | Sort-Object -Unique)

    # -------- DCR streams (from compiled mainTemplate.json) -----------------
    $script:DcrStreams = @()
    $script:CustomTables = @()

    if (Test-Path $script:MainTemplatePath) {
        $arm = Get-Content -Raw -Path $script:MainTemplatePath | ConvertFrom-Json

        # Find the DCR resource + pull its streamDeclarations keys.
        $dcr = $arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' } | Select-Object -First 1
        if ($dcr) {
            $script:DcrStreams = @($dcr.properties.streamDeclarations.PSObject.Properties.Name) |
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
            if (-not ($nd.properties.template.PSObject.Properties.Name -contains 'variables')) { continue }
            if ($nd.properties.template.variables.PSObject.Properties.Name -contains 'tableNames') {
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
                        if ($tblName -match '^MDE_\w+_CL$') {
                            $script:CustomTables += $tblName
                            continue
                        }
                        # Case (c): ARM expression — extract "/MDE_Xyz_CL" substring
                        if ($r.name -match "'/(MDE_\w+_CL)'") {
                            $script:CustomTables += $matches[1]
                            continue
                        }
                        # Case (c-alt): look inside properties.schema.name (literal)
                        if ($r.PSObject.Properties.Name -contains 'properties' -and
                            $r.properties.PSObject.Properties.Name -contains 'schema' -and
                            $r.properties.schema.PSObject.Properties.Name -contains 'name') {
                            $schemaName = $r.properties.schema.name
                            if ($schemaName -is [string] -and $schemaName -match '^MDE_\w+_CL$') {
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

    # -------- Drift report -------------------------------------------------
    # Build an array of [stream,status] pairs for any mismatches. A single
    # Should assertion on .Count gives us a one-line pass but prints the
    # full drift list on failure via -Because.
    $script:Drift = @()
    $manifestSet     = $script:ManifestStreams
    $dcrDataSet      = @($script:DcrStreams  | Where-Object { $_ -notin $script:SystemStreams })
    $tableDataSet    = @($script:CustomTables | Where-Object { $_ -notin $script:SystemStreams })

    foreach ($s in $manifestSet) {
        if ($s -notin $dcrDataSet)   { $script:Drift += [pscustomobject]@{ Stream = $s; Status = 'missing-in-dcr' } }
        if ($s -notin $tableDataSet) { $script:Drift += [pscustomobject]@{ Stream = $s; Status = 'missing-in-custom-tables' } }
    }
    foreach ($s in $dcrDataSet) {
        if ($s -notin $manifestSet) { $script:Drift += [pscustomobject]@{ Stream = $s; Status = 'orphan-dcr-stream' } }
    }
    foreach ($s in $tableDataSet) {
        if ($s -notin $manifestSet) { $script:Drift += [pscustomobject]@{ Stream = $s; Status = 'orphan-custom-table' } }
    }
}

Describe 'Manifest / DCR / custom-tables consistency' {

    It 'manifest contains exactly 45 streams (v0.1.0-beta.1 — 2 write endpoints removed vs v1.0.2)' {
        $script:ManifestStreams.Count | Should -Be 45
    }

    It 'DCR declares exactly 47 streams (45 data + 2 system)' {
        $script:DcrStreams.Count | Should -Be 47
    }

    It 'custom-tables declares exactly 47 tables (45 data + 2 system)' {
        $script:CustomTables.Count | Should -Be 47
    }

    It 'DCR contains both system streams (Heartbeat + AuthTestResult)' {
        $script:DcrStreams | Should -Contain 'MDE_Heartbeat_CL'
        $script:DcrStreams | Should -Contain 'MDE_AuthTestResult_CL'
    }

    It 'custom-tables contains both system tables (Heartbeat + AuthTestResult)' {
        $script:CustomTables | Should -Contain 'MDE_Heartbeat_CL'
        $script:CustomTables | Should -Contain 'MDE_AuthTestResult_CL'
    }

    It 'zero drift between the three layers' {
        $driftList = ($script:Drift | ForEach-Object { "$($_.Stream) -> $($_.Status)" }) -join "`n  "
        $script:Drift.Count | Should -Be 0 -Because "drift detected:`n  $driftList"
    }
}

Describe 'Per-stream DCR coverage' -ForEach @(
    # One It per manifest stream, so failure picks out the bad row precisely.
    # BeforeDiscovery doesn't run the Import, so we re-read the manifest here.
    (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1')).Endpoints |
        ForEach-Object { @{ StreamName = $_.Stream; Tier = $_.Tier } }
) {

    It "stream <StreamName> (<Tier>) has a DCR streamDeclaration" {
        $script:DcrStreams | Should -Contain $StreamName
    }

    It "stream <StreamName> (<Tier>) has a custom table" {
        $script:CustomTables | Should -Contain $StreamName
    }
}
