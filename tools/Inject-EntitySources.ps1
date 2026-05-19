#requires -Version 7.0
<#
.SYNOPSIS
  P6 · Build EntitySourceMap for entity-discovery chain · runtime in-cycle iteration.

.DESCRIPTION
  For each manifest entry whose Path contains {xxx} placeholders that are NOT
  workspace-context (subscriptionId · resourceGroupName · workspaceName · workspaceId · tenantId)
  identify the LIST endpoint in the same manifest that produces the entity ID.

  Pattern recognition:
    `{MachineId}` ↔ sibling endpoint with path /machines or slug List*Machines · entity field machineId
    `{Sha256}`    ↔ sibling endpoint with path /files or slug List*Files · entity field sha256
    `{UserAad}`   ↔ sibling endpoint with path /users or slug List*Users · entity field userAad
    etc.

  Output: injects `EntitySourceMap` field into manifest entry:
    EntitySourceMap = @{
        MachineId = @{
            SourceEntryKey = 'EndpointDevices::endpointdevices-listmachines'
            ExtractPath    = '$..machineId'
        }
    }

  Runtime (run.ps1) processes entries in dependency-topological order:
    1. List endpoints run first · cache entity IDs in $entityCache
    2. Entity endpoints run after · iterate cached IDs (cap 100/source/cycle)

.NOTES
  Author: Alex Kefallonitis <al.kefallonitis@gmail.com>
  Created: P6 · 2026-05-20.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Workspace-context placeholders (NOT entity-source · filled from workspaceResourceId)
$WorkspacePlaceholders = @('subscriptionId','resourceGroupName','workspaceName','workspaceId','tenantId')

# Placeholder → list-endpoint pattern map (heuristic · pattern-based)
# Pattern: { placeholderName = @{ slugPattern = 'list*<plural>'; extractPath = '$..<field>' } }
$PlaceholderToSource = @{
    'MachineId'         = @{ Pattern = 'list*machines|getmachines'           ; Field = 'machineId|deviceId|id'         }
    'DeviceId'          = @{ Pattern = 'list*devices|list*machines'          ; Field = 'deviceId|machineId|id'         }
    'Sha256'            = @{ Pattern = 'list*files|filequery'                ; Field = 'sha256|fileHash|hash'          }
    'Sha1'              = @{ Pattern = 'list*files|filequery'                ; Field = 'sha1|fileHash|hash'            }
    'FileHash'          = @{ Pattern = 'list*files|filequery'                ; Field = 'fileHash|sha256|sha1'          }
    'UserAad'           = @{ Pattern = 'list*users|getusers|listidentities'  ; Field = 'userAad|aadId|objectId|id'      }
    'UserId'            = @{ Pattern = 'list*users|listidentities'           ; Field = 'userId|aadId|objectId|id'      }
    'AadId'             = @{ Pattern = 'list*users|listidentities'           ; Field = 'aadId|userAad|objectId|id'     }
    'Sid'               = @{ Pattern = 'list*users|listidentities'           ; Field = 'sid|objectSid'                  }
    'IpAddress'         = @{ Pattern = 'list*ipaddresses|listips'            ; Field = 'ipAddress|ip|address'           }
    'CaseId'            = @{ Pattern = 'list*cases|gethistory'               ; Field = 'caseId|id'                      }
    'IncidentId'        = @{ Pattern = 'list*incidents'                      ; Field = 'incidentId|id'                  }
    'AlertId'           = @{ Pattern = 'list*alerts'                         ; Field = 'alertId|id'                     }
    'RuleId'            = @{ Pattern = 'list*rules|listdetectionrules'       ; Field = 'ruleId|id'                      }
    'ActionId'          = @{ Pattern = 'list*actions|gethistory|getpending'  ; Field = 'actionId|id'                    }
    'TemplateId'        = @{ Pattern = 'list*templates'                      ; Field = 'templateId|id'                  }
    'ManagedDeviceId'   = @{ Pattern = 'list*manageddevices|list*devices'    ; Field = 'managedDeviceId|deviceId|id'    }
    'InitiativeId'      = @{ Pattern = 'list*initiatives'                    ; Field = 'initiativeId|id'                }
    'RoleDefinitionId'  = @{ Pattern = 'list*roledefinitions'                ; Field = 'roleDefinitionId|id'            }
    'AssetId'           = @{ Pattern = 'list*assets|exposureassets'          ; Field = 'assetId|id|resourceId'          }
    'CveId'             = @{ Pattern = 'list*vulnerabilities|listcves'       ; Field = 'cveId|cve|id'                   }
    'RecommendationId'  = @{ Pattern = 'list*recommendations'                ; Field = 'recommendationId|id'            }
    'OutbreakId'        = @{ Pattern = 'list*outbreaks|threatanalytics'      ; Field = 'outbreakId|id'                  }
    'SettingName'       = @{ Pattern = 'list*settings|getsettings'           ; Field = 'settingName|name|id'            }
    'AppId'             = @{ Pattern = 'list*apps|listcloudapps'             ; Field = 'appId|id'                       }
    'PolicyId'          = @{ Pattern = 'list*policies'                       ; Field = 'policyId|id'                    }
    'ResourceId'        = @{ Pattern = 'list*resources|list*assets'          ; Field = 'resourceId|id'                  }
    'TaskId'            = @{ Pattern = 'list*tasks|listremediationtasks'     ; Field = 'taskId|id'                      }
    'Id'                = @{ Pattern = 'list*'                               ; Field = 'id'                             }
}

# Load manifest as script-block (handles dynamic $true)
$manifestText = Get-Content -Raw -LiteralPath $ManifestPath
$manifest = & ([scriptblock]::Create($manifestText))
$entries = @($manifest.Entries)
Write-Host "Loaded $($entries.Count) manifest entries" -ForegroundColor Cyan

# Pre-index: SubArea + Slug pattern → EntryKey (for quick lookup of candidate list endpoints)
$slugIndex = @{}
foreach ($e in $entries) {
    $slugIndex[$e.Slug.ToLowerInvariant()] = $e.EntryKey
}

$plan = [System.Collections.Generic.List[hashtable]]::new()

foreach ($e in $entries) {
    if (-not ($e.Path -match '\{[^}]+\}')) { continue }                   # no placeholders · skip
    if ($e.ContainsKey('EntitySourceMap')) { continue }                    # already injected · skip
    if ($e.ProbeMode -eq 'Excluded') { continue }                          # mutations · skip
    $placeholders = [regex]::Matches($e.Path, '\{([^}]+)\}') | ForEach-Object { $_.Groups[1].Value }
    $entityPHs    = $placeholders | Where-Object { $_ -notin $WorkspacePlaceholders }
    if (@($entityPHs).Count -eq 0) { continue }                            # only workspace-context · no entity-source needed

    $sourceMap = @{}
    $resolved = 0
    foreach ($ph in $entityPHs) {
        if (-not $PlaceholderToSource.ContainsKey($ph)) { continue }
        $patternRegex = $PlaceholderToSource[$ph].Pattern
        # Find candidate list endpoints (Probe-mode · same SubArea preferred · slug matches pattern)
        $candidates = @($entries | Where-Object {
            $_.ProbeMode -in @('Probe','ReadOnlyPost') -and `
            $_.SubArea -eq $e.SubArea -and `
            $_.Slug.ToLowerInvariant() -match $patternRegex
        })
        if ($candidates.Count -eq 0) {
            # Try cross-sub-area
            $candidates = @($entries | Where-Object {
                $_.ProbeMode -in @('Probe','ReadOnlyPost') -and `
                $_.Slug.ToLowerInvariant() -match $patternRegex
            })
        }
        if ($candidates.Count -gt 0) {
            $source = $candidates[0]   # first match wins
            $sourceMap[$ph] = @{
                SourceEntryKey = $source.EntryKey
                ExtractPath    = "`$..$($PlaceholderToSource[$ph].Field -split '\|' | Select-Object -First 1)"
            }
            $resolved++
        }
    }
    if ($resolved -gt 0) {
        [void]$plan.Add(@{ Entry = $e; SourceMap = $sourceMap; Resolved = $resolved; Total = @($entityPHs).Count })
    }
}

Write-Host "Plan · $($plan.Count) entries to inject EntitySourceMap" -ForegroundColor Yellow
Write-Host ("  Fully-resolved entries: " + (@($plan | Where-Object { $_.Resolved -eq $_.Total }).Count))
Write-Host ("  Partially-resolved entries: " + (@($plan | Where-Object { $_.Resolved -lt $_.Total }).Count))

if (-not $PSCmdlet.ShouldProcess($ManifestPath, "Inject $($plan.Count) EntitySourceMap fields")) { return }

# Pass 3: line-by-line manifest mutation · insert EntitySourceMap before closing `},` of each entry block
$lines = [System.Collections.Generic.List[string]]::new()
Get-Content $ManifestPath | ForEach-Object { [void]$lines.Add($_) }

# Build entry-block index (Start line · End line · EntryKey)
$blocks = @{}
$current = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if (-not $current -and $ln -match '^        @\{\s*$') {
        $current = @{ Start = $i; End = $null; EntryKey = $null }
        continue
    }
    if ($current) {
        if ($ln -match "^\s+EntryKey\s+=\s+'([^']+)'") { $current.EntryKey = $Matches[1] }
        elseif ($ln -match '^        \},?\s*$') {
            $current.End = $i
            if ($current.EntryKey) { $blocks[$current.EntryKey] = $current }
            $current = $null
        }
    }
}

# Inject (reverse order to preserve line indices)
$sorted = $plan | Sort-Object -Property { $blocks[$_.Entry.EntryKey].End } -Descending
$inserted = 0
foreach ($item in $sorted) {
    $block = $blocks[$item.Entry.EntryKey]
    if (-not $block) { continue }
    $sm = $item.SourceMap
    $kvs = foreach ($k in $sm.Keys) {
        $src = $sm[$k].SourceEntryKey -replace "'", "''"
        $exp = $sm[$k].ExtractPath    -replace "'", "''"
        "'$k' = @{ SourceEntryKey = '$src'; ExtractPath = '$exp' }"
    }
    $injLine = "            EntitySourceMap      = @{ $($kvs -join '; ') }"
    $lines.Insert($block.End, $injLine)
    $inserted++
}

[System.IO.File]::WriteAllLines($ManifestPath, $lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
Write-Host "DONE · wrote $($lines.Count) lines · injected $inserted EntitySourceMap fields" -ForegroundColor Green

# Verify manifest parses
$manifestTextAfter = Get-Content -Raw -LiteralPath $ManifestPath
$null = & ([scriptblock]::Create($manifestTextAfter))
Write-Host "Manifest parses cleanly after injection" -ForegroundColor Green
