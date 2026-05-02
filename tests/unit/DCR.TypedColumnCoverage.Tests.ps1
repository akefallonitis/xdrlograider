#Requires -Modules Pester

# Wire-chaining gate: every non-deprecated manifest stream's ProjectionMap must
# be fully reflected in the compiled ARM template's DCR streamDeclarations
# (column names + types). This is the single guard that proves
# manifest=source-of-truth flows through Bicep into the deployed DCR.
#
# Without this test, FA-side ConvertTo-MDEIngestRow could project a typed
# column (e.g. ActionStatus from MDE_ActionCenter_CL.ProjectionMap) that the
# DCR doesn't declare — and the DCE would silently drop it at ingest. Or
# worse, FA could project a string while DCR declares a datetime, and
# typed-col KQL queries would parse-fail.
#
# Cast hint -> DCR column type mapping:
#   $tostring (or default)   string
#   $toint / $tolong         int
#   $tobool                  boolean
#   $todatetime              datetime
#   $todouble / $todecimal   real
#   $toguid                  string
#   $json                    dynamic

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Manifest = (Import-PowerShellDataFile (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')).Endpoints
    $script:Arm = Get-Content (Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json') -Raw | ConvertFrom-Json

    # 47 streams partitioned across 5 DCRs sharing one DCE — union them.
    $dcrs = @($script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
    $script:DcrSchemas = @{}
    foreach ($dcr in $dcrs) {
        foreach ($prop in $dcr.properties.streamDeclarations.PSObject.Properties) {
            $script:DcrSchemas[$prop.Name] = $prop.Value.columns
        }
    }

    # Hint-prefix -> ARM column type. Values mirror Project-EntityField
    # (see src/Modules/Xdr.Defender.Client/Endpoints/_ProjectionHelpers.ps1).
    $script:CastTypeMap = @{
        '$tostring'   = 'string'
        '$toint'      = 'int'
        '$tolong'     = 'int'
        '$tobool'     = 'boolean'
        '$todatetime' = 'datetime'
        '$todouble'   = 'real'
        '$todecimal'  = 'real'
        '$toguid'     = 'string'
        '$json'       = 'dynamic'
    }
}

Describe 'DCR typed columns mirror manifest ProjectionMap' {

    It 'every non-deprecated manifest stream has a typed-column DCR streamDeclaration matching its ProjectionMap' {
        $drift = @()
        foreach ($e in $script:Manifest) {
            if ($e.ContainsKey('Availability') -and $e.Availability -eq 'deprecated') { continue }
            if (-not $e.ContainsKey('ProjectionMap')) { continue }
            if (-not $e.ProjectionMap -or @($e.ProjectionMap.Keys).Count -eq 0) { continue }

            $streamKey = "Custom-$($e.Stream)"
            if (-not $script:DcrSchemas.ContainsKey($streamKey)) {
                $drift += "$streamKey -> missing-in-dcr"
                continue
            }

            $dcrCols = @{}
            foreach ($c in $script:DcrSchemas[$streamKey]) {
                $dcrCols[$c.name] = $c.type
            }

            foreach ($k in $e.ProjectionMap.Keys) {
                $hint = [string]$e.ProjectionMap[$k]
                $expectedType = 'string'
                if ($hint -match '^(\$\w+):') {
                    $prefix = $matches[1]
                    if ($script:CastTypeMap.ContainsKey($prefix)) {
                        $expectedType = $script:CastTypeMap[$prefix]
                    }
                }
                if (-not $dcrCols.ContainsKey($k)) {
                    $drift += "${streamKey}.${k} -> missing column"
                } elseif ($dcrCols[$k] -ne $expectedType) {
                    $drift += "${streamKey}.${k} -> declared as $($dcrCols[$k]) but ProjectionMap implies $expectedType"
                }
            }
        }
        $reason = "DCR typed-column schema must mirror manifest ProjectionMap (manifest=source of truth):`n  " + ($drift -join "`n  ")
        $drift | Should -BeNullOrEmpty -Because $reason
    }

    It 'every non-deprecated manifest stream DCR schema includes all 4 base columns + ProjectionMap keys' {
        $drift = @()
        $baselineCols = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')
        foreach ($e in $script:Manifest) {
            if ($e.ContainsKey('Availability') -and $e.Availability -eq 'deprecated') { continue }
            $streamKey = "Custom-$($e.Stream)"
            if (-not $script:DcrSchemas.ContainsKey($streamKey)) {
                $drift += "$streamKey -> missing-in-dcr"
                continue
            }
            $dcrColNames = @($script:DcrSchemas[$streamKey] | ForEach-Object { $_.name })
            $projKeys = if ($e.ContainsKey('ProjectionMap') -and $e.ProjectionMap) { @($e.ProjectionMap.Keys) } else { @() }
            $expectedCols = $baselineCols + $projKeys
            $extra = @($dcrColNames | Where-Object { $_ -notin $expectedCols })
            if ($extra.Count -gt 0) {
                $drift += "${streamKey} -> extra cols: $($extra -join ', ')"
            }
            foreach ($expected in $expectedCols) {
                if ($dcrColNames -notcontains $expected) {
                    $drift += "${streamKey}.${expected} -> missing"
                }
            }
        }
        $reason = "DCR schema column set must equal {base 4} + ProjectionMap keys:`n  " + ($drift -join "`n  ")
        $drift | Should -BeNullOrEmpty -Because $reason
    }
}
