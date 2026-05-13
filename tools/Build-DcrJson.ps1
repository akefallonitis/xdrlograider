<#
.SYNOPSIS
    Generates 19 Data Collection Rule JSON files (18 per-sub-area + 1 ConnectorHealth)
    from manifests/defender.psd1.

.DESCRIPTION
    Reads the manifest, groups entries by sub-area, and emits one DCR JSON file
    per sub-area to deploy/dcrs/. Each DCR is a standalone ARM resource (type,
    apiVersion, name, location, properties, dependsOn) that mainTemplate.json
    splices via a copy block.

    Per Rule 8, every DCR streamDeclaration carries the 10 mandatory columns:
        TimeGenerated · Endpoint · EntityId · SuccessKind · HttpStatus
        · RawJson · RawResponseBody · SubArea · Tier · LicenseHint
    Plus ProjectionMap typed columns (Phase 1 = empty; v0.3.0+ populates).

    The 19th DCR (XdrConnectorHealth) carries 14 columns including the
    populated Notes dynamic field per Rule 12.

.PARAMETER ManifestPath
    Path to manifests/defender.psd1. Defaults to ../manifests/defender.psd1.

.PARAMETER OutputDir
    Output directory for DCR JSON files. Defaults to ../deploy/dcrs/.

.EXAMPLE
    pwsh ./tools/Build-DcrJson.ps1
    # Generates 19 DCR JSON files in deploy/dcrs/
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1'),
    [string] $OutputDir    = (Join-Path $PSScriptRoot '..' 'deploy' 'dcrs')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Pilot/Phase-1 invariants
$SubAreas = @(
    'action_center', 'attack_simulator', 'cloud_apps', 'configuration', 'data_lake',
    'endpoint_configuration', 'endpoint_devices', 'entity_pivots', 'exposure_management',
    'files', 'identity', 'multi_tenant', 'portal_services', 'secure_score',
    'sentinel_precision', 'streaming', 'threat_analytics', 'vulnerability_management'
)

function ConvertTo-PascalCase {
    param([Parameter(Mandatory)][string] $Snake)
    $parts = $Snake -split '_'
    ($parts | ForEach-Object {
        if ($_.Length -eq 0) { return '' }
        $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant()
    }) -join ''
}

# ----- Mandatory column set per Rule 8 ---------------------------------------
$MandatoryCols = @(
    [ordered]@{ name = 'TimeGenerated';    type = 'datetime' }
    [ordered]@{ name = 'Endpoint';         type = 'string'   }
    [ordered]@{ name = 'EntityId';         type = 'string'   }
    [ordered]@{ name = 'SuccessKind';      type = 'string'   }
    [ordered]@{ name = 'HttpStatus';       type = 'int'      }
    [ordered]@{ name = 'RawJson';          type = 'dynamic'  }
    [ordered]@{ name = 'RawResponseBody';  type = 'string'   }
    [ordered]@{ name = 'SubArea';          type = 'string'   }
    [ordered]@{ name = 'Tier';             type = 'string'   }
    [ordered]@{ name = 'LicenseHint';      type = 'string'   }
)

# ----- ConnectorHealth column set (Decision 15 / Rule 12 / H13) --------------
# 11 typed cols + Notes (dynamic). ConnectorVersion + ConnectorBuildId surface
# the deployed build to operators from the latest heartbeat row. Notes carries
# the LEAN aggregate JSON only (cardState · dlqDepth · openCircuits · fatalError).
# Per-stream detail lives in XdrTierState Storage Table — keeping it out of LA
# cuts heartbeat ingest cost ~100x vs the pilot's bloated Notes.perStream form.
$ConnectorHealthCols = @(
    [ordered]@{ name = 'TimeGenerated';     type = 'datetime' }
    [ordered]@{ name = 'FunctionName';      type = 'string'   }
    [ordered]@{ name = 'Tier';              type = 'string'   }
    [ordered]@{ name = 'Portal';            type = 'string'   }
    [ordered]@{ name = 'StreamsAttempted';  type = 'int'      }
    [ordered]@{ name = 'StreamsSucceeded';  type = 'int'      }
    [ordered]@{ name = 'RowsIngested';      type = 'int'      }
    [ordered]@{ name = 'LatencyMs';         type = 'int'      }
    [ordered]@{ name = 'ConnectorVersion';  type = 'string'   }
    [ordered]@{ name = 'ConnectorBuildId';  type = 'string'   }
    [ordered]@{ name = 'Notes';             type = 'dynamic'  }
)

# ----- 1) Validate manifest (two-stage parse — Phase 1 manifest >95KB) ------
$ManifestPath = (Resolve-Path $ManifestPath).Path
$manifest = $null
try {
    $manifest = Import-PowerShellDataFile -Path $ManifestPath -ErrorAction Stop
} catch {
    $sb = [scriptblock]::Create((Get-Content -Raw -Path $ManifestPath))
    $manifest = & $sb
}
if (-not $manifest.Endpoints) { throw "Manifest at $ManifestPath has no Endpoints array" }

# ----- 2) Verify all 18 sub-areas have entries ------------------------------
$present = @($manifest.Endpoints | ForEach-Object { $_['SubArea'] } | Sort-Object -Unique)
foreach ($s in $SubAreas) {
    if ($s -notin $present) { throw "Sub-area '$s' has zero manifest entries — check Build-Manifest.ps1 filter" }
}

# ----- 3) Emit per-sub-area DCRs --------------------------------------------
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$emitted = 0
foreach ($subArea in $SubAreas) {
    $pascal = ConvertTo-PascalCase -Snake $subArea
    $streamName = "Custom-Defender_${pascal}_CL"
    $outputStream = "Custom-Defender_${pascal}_CL"
    $tableName = "Defender_${pascal}_CL"

    $dcr = [ordered]@{
        type       = 'Microsoft.Insights/dataCollectionRules'
        apiVersion = '2023-03-11'
        name       = "[concat(variables('dcrName'), '-$($subArea -replace '_','-')')]"
        location   = "[parameters('workspaceLocation')]"
        tags       = "[variables('commonTag')]"
        dependsOn  = @(
            "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
            "[concat('customTables-', variables('suffix'))]"
        )
        properties = [ordered]@{
            dataCollectionEndpointId = "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
            streamDeclarations = [ordered]@{}
            destinations = [ordered]@{
                logAnalytics = @(
                    [ordered]@{
                        name                = 'la-destination'
                        workspaceResourceId = "[parameters('existingWorkspaceId')]"
                    }
                )
            }
            dataFlows = @(
                [ordered]@{
                    streams      = @($streamName)
                    destinations = @('la-destination')
                    outputStream = $outputStream
                    transformKql = "source | extend SourceName = '$tableName'"
                }
            )
        }
    }

    $dcr.properties.streamDeclarations[$streamName] = [ordered]@{ columns = $MandatoryCols }

    $jsonPath = Join-Path $OutputDir ("Defender_${pascal}_dcr.json")
    $jsonText = ($dcr | ConvertTo-Json -Depth 20) -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($jsonPath, $jsonText, [System.Text.UTF8Encoding]::new($false))
    $emitted++
    Write-Verbose "  emitted $jsonPath"
}

# ----- 4) Emit ConnectorHealth DCR -------------------------------------------
$healthStream = 'Custom-XdrConnectorHealth_CL'
$healthDcr = [ordered]@{
    type       = 'Microsoft.Insights/dataCollectionRules'
    apiVersion = '2023-03-11'
    name       = "[concat(variables('dcrName'), '-ops')]"
    location   = "[parameters('workspaceLocation')]"
    tags       = "[variables('commonTag')]"
    dependsOn  = @(
        "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
        "[concat('customTables-', variables('suffix'))]"
    )
    properties = [ordered]@{
        dataCollectionEndpointId = "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
        streamDeclarations = [ordered]@{
            $healthStream = [ordered]@{ columns = $ConnectorHealthCols }
        }
        destinations = [ordered]@{
            logAnalytics = @(
                [ordered]@{
                    name                = 'la-destination'
                    workspaceResourceId = "[parameters('existingWorkspaceId')]"
                }
            )
        }
        dataFlows = @(
            [ordered]@{
                streams      = @($healthStream)
                destinations = @('la-destination')
                outputStream = $healthStream
                transformKql = "source | extend SourceName = 'XdrConnectorHealth_CL'"
            }
        )
    }
}
$healthPath = Join-Path $OutputDir 'XdrConnectorHealth_dcr.json'
$healthJson = ($healthDcr | ConvertTo-Json -Depth 20) -replace "`r`n", "`n" -replace "`r", "`n"
[System.IO.File]::WriteAllText($healthPath, $healthJson, [System.Text.UTF8Encoding]::new($false))
$emitted++

Write-Host "Emitted $emitted DCR JSON files in $OutputDir"
Write-Host '  18 per-sub-area DCRs + 1 ConnectorHealth DCR'

# ----- 5) Verify all 19 parse as JSON ----------------------------------------
$failed = 0
foreach ($f in Get-ChildItem $OutputDir -Filter '*_dcr.json') {
    try {
        $null = Get-Content -Raw $f.FullName | ConvertFrom-Json -Depth 20
    } catch {
        Write-Warning "Invalid JSON: $($f.Name) — $_"
        $failed++
    }
}
if ($failed -gt 0) { throw "$failed DCR JSON files failed to parse" }
Write-Host 'All 19 DCR JSONs parsed cleanly.'
