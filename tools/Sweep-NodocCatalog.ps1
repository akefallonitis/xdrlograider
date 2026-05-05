<#
.SYNOPSIS
    Sweep the nodoc Defender XDR OpenAPI catalog and produce a v0.1.0 GA inclusion list.

.DESCRIPTION
    Phase J.F.NEW.0 (D'.58 in the v0.1.0 plan) — comprehensive sweep of the
    nodoc.nathanmcnulty.com Defender XDR catalog (~454 GET ops across 23 spec
    files) to identify net-new portal-only streams that should be added to the
    XdrLogRaider connector for v0.1.0 GA.

    Sources:
      - .internal/nodoc-reference/specifications/nodoc-defender-xdr/specification/*.yml

    Methodology:
      1. Walk every spec file under nodoc-reference; parse paths + GET ops + tags.
      2. Cross-reference each path's `/mtp/...` portion against the existing
         endpoints.manifest.psd1 — flag in-manifest vs net-new.
      3. Apply audit-scope filter (per §13.3 of the plan):
         - GET only (no write ops)
         - Not already covered by Microsoft Graph Security / MDE TVM / MDE Public API
         - Path patterns flagged as `public-api-covered` get excluded
      4. Bucket survivors into the 10 nathanmcnulty categories per heuristic
         (spec filename → category) and per-stream override.
      5. Score for v0.1.0 inclusion (operator value × implementation cost).
      6. Emit CSV + 2 markdown reports for human review.

    Output (under tests/online/):
      - NodocCatalogSweep-2026-05-04.csv         — machine-readable full sweep
      - NodocCatalogSweep-2026-05-04.md          — human-readable categorized
      - NodocCatalogSweep-NewInV010.md           — final v0.1.0 inclusion list
      - NodocCatalogSweep-DeferredToV011.md      — deferred backlog

.PARAMETER NodocReferenceRoot
    Path to the cloned nodoc reference repo. Defaults to .internal/nodoc-reference.

.PARAMETER ManifestPath
    Path to the active endpoints.manifest.psd1 to cross-reference against.

.PARAMETER OutputDir
    Where to write the CSV + markdown reports. Defaults to tests/online/.

.EXAMPLE
    pwsh tools/Sweep-NodocCatalog.ps1
#>
[CmdletBinding()]
param(
    [string] $NodocReferenceRoot = (Join-Path $PSScriptRoot '..' '.internal' 'nodoc-reference' 'specifications' 'nodoc-defender-xdr' 'specification'),
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..' 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'),
    [string] $OutputDir = (Join-Path $PSScriptRoot '..' 'tests' 'online')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -----------------------------------------------------------------------------
# Spec file → nodoc category heuristic (overridable per-path below)
# -----------------------------------------------------------------------------
$specFileToCategory = @{
    'action_center.yml'           = @{ Id = 8; Slug = 'ActionCenter'; Name = 'Action Center' }
    'advanced_hunting.yml'        = @{ Id = 5; Slug = 'ConfigurationAndSettings'; Name = 'Configuration and Settings' }
    'alerts_incidents.yml'        = @{ Id = 0; Slug = 'PublicApiCovered'; Name = 'Public API Covered (alerts/incidents)' }
    'attack_simulator.yml'        = @{ Id = 0; Slug = 'OutOfScope'; Name = 'Out of scope (training simulator)' }
    'cloud_apps.yml'              = @{ Id = 5; Slug = 'ConfigurationAndSettings'; Name = 'Configuration and Settings (MCAS)' }
    'common.yml'                  = @{ Id = 0; Slug = 'Schemas'; Name = 'Schemas only (no paths)' }
    'configuration.yml'           = @{ Id = 5; Slug = 'ConfigurationAndSettings'; Name = 'Configuration and Settings' }
    'data_lake.yml'               = @{ Id = 0; Slug = 'OutOfScope'; Name = 'Out of scope (data lake mgmt)' }
    'endpoint_configuration.yml'  = @{ Id = 2; Slug = 'EndpointConfiguration'; Name = 'Endpoint Configuration' }
    'endpoint_devices.yml'        = @{ Id = 1; Slug = 'EndpointDeviceManagement'; Name = 'Endpoint Device Management' }
    'entity_pivots.yml'           = @{ Id = 0; Slug = 'OutOfScope'; Name = 'Out of scope (incident pivots)' }
    'exposure_management.yml'     = @{ Id = 6; Slug = 'ExposureManagement'; Name = 'Exposure Management' }
    'files.yml'                   = @{ Id = 0; Slug = 'PublicApiCovered'; Name = 'Public API covered (file IOCs)' }
    'identity.yml'                = @{ Id = 4; Slug = 'IdentityProtection'; Name = 'Identity Protection' }
    'live_response.yml'           = @{ Id = 0; Slug = 'OutOfScope'; Name = 'Out of scope (LR session mgmt)' }
    'multi_tenant.yml'            = @{ Id = 9; Slug = 'MultiTenantOperations'; Name = 'Multi-Tenant Operations' }
    'openapi.yml'                 = @{ Id = 0; Slug = 'Master'; Name = 'Master spec only' }
    'portal_services.yml'         = @{ Id = 5; Slug = 'ConfigurationAndSettings'; Name = 'Configuration and Settings (portal)' }
    'secure_score.yml'            = @{ Id = 0; Slug = 'PublicApiCovered'; Name = 'Public API covered (Graph secureScores)' }
    'sentinel_precision.yml'      = @{ Id = 0; Slug = 'OutOfScope'; Name = 'Out of scope (Sentinel-side)' }
    'streaming.yml'               = @{ Id = 10; Slug = 'StreamingApi'; Name = 'Streaming API (deprecated)' }
    'threat_analytics.yml'        = @{ Id = 7; Slug = 'ThreatAnalytics'; Name = 'Threat Analytics' }
    'vulnerability_management.yml'= @{ Id = 3; Slug = 'VulnerabilityManagement'; Name = 'Vulnerability Management' }
}

# -----------------------------------------------------------------------------
# Public-API-covered exclusions — heuristic regex on path
# -----------------------------------------------------------------------------
# These paths duplicate functionality available via Microsoft Graph Security,
# MDE TVM public API, or MDE Public API. Excluded from v0.1.0 portal-only scope.
$publicApiCoveredPatterns = @(
    '/alertsApiService/'                  # Graph Security alerts_v2 covers
    '/alertsEmailNotifications/(?!email)' # already-in-manifest carve-out
    '/files/(?!.*config)'                 # MDE Public API /files
    '/recommendationsApi/'                # MDE TVM /recommendations
    '/vulnerabilityApi/'                  # MDE TVM /vulnerabilities
    '/secureScoreApi/'                    # Graph /security/secureScores
    '/incidentsApiService/'               # Graph Security incidents
)

# -----------------------------------------------------------------------------
# UI-helper / metadata noise patterns — exclude (no operator security value)
# -----------------------------------------------------------------------------
# Per user direction (2026-05-04): "not everything needed choose wisely"
$uiNoisePatterns = @(
    '/autocomplete/'              # UI typeahead helpers
    '/metadata\b'                 # schema-only (response is a schema, not data)
    '/dashboard/'                 # UI dashboard widgets
    '/version\b'                  # bundle versions
    '/about/'                     # about box info
    '/boot_constants'             # UI boot data
    '/lcnc_settings'              # low-code-no-code UI
    '/sync_bar'                   # UI state
    '/mail_settings'              # UI cosmetic
    '/manage_admins/is_external'  # UI gating
    '/Find/Trial'                 # marketing
    '/Find/CustomTag'             # UI tag search helper
    '/cdssecuritycopilot/trial'   # marketing
    '/medeina/auth'               # Copilot UI auth
    '/AttackSimulator/'           # training simulator
    '/AdvanceReporting/chart/'    # UI charting
    '/mtp_scopes_and_permissions' # UI permissions check
    '/get_should_display_'        # UI visibility flag
    '/user_config/get_'           # per-user UI prefs
    '/standalone_entities/'       # UI metadata-ish
    '/agents/siem(?!.*config)'    # SIEM agent count (UI dashboard)
    '/{TenantId}/automationRules' # CRUD-write side effects
    '/AutomationRule(s)?\b'       # see above
    '/preview_features/get'       # UI flags
    '/agentVersionCompatibility'  # UI deploy helper
    '/agents/'                    # generic agent UI
    '/global_settings/get'        # noise
    '/get_global_settings'        # noise
    '/get_constants'              # noise
    '/options/'                   # UI options
    '/i18n/'                      # localization
    '/l10n/'                      # localization
    # Additional noise found in Tier A audit (2026-05-04)
    '/filters\b|/filterValues\b|/Filter(s)?(?:Categories)?\b'  # UI dropdown filter lists
    '/(scope|expand)Categor(?:ies|y)\b'                         # filter category lists
    '/[Ii]ds\b|/operationIds\b'                                 # IDs-only listings
    '/changeCount\b|/lastUpdated\b|/activeCount\b'              # UI counter widgets
    '/[Tt]ags\b(?!.*classification)'                            # generic tag list (keep classification tags)
    '/scaRecommendations/(?:filters|tags)'                      # UI helpers
    '/posture/oversight/metrics/ids'                            # IDs only
    '/posture/oversight/easm/vendors'                           # vendor list (UI dropdown)
    '/posture/oversight/scaRecommendations/(?:filters|tags)'    # UI helpers
    '/atc/api/.*StatsItems\b'                                   # UI stat widgets
    '/InMemoryDataModel/'                                       # UI memory store
    '/atc/api/.*?(?:Charts|StatsItems|TilesAggregations)'       # UI chart data
)

# -----------------------------------------------------------------------------
# Cadence-tier heuristic per path
# -----------------------------------------------------------------------------
function Get-CadenceTier {
    param([string]$Path, [string]$Summary)
    $hint = "$Path|$Summary".ToLowerInvariant()
    if ($hint -match '/actioncenter/|/pending|/approval|/case') { return 'ActionCenter' }
    if ($hint -match '/posture/|/xspm|/exposure|/attack') { return 'XspmGraph' }
    if ($hint -match '/timeline|/history|/audit|/event') { return 'Inventory' }   # event-style → Inventory cadence (1d) for v0.1.0; refine later
    if ($hint -match '/license|/sku|/billing|/tenantworkload') { return 'Maintenance' }
    if ($hint -match '/threatanalytics|/threat-?intel|/campaign|/outbreak') { return 'Configuration' }
    if ($hint -match '/policies|/rules|/configuration|/setting|/profile|/config|/policy') { return 'Configuration' }
    if ($hint -match '/devices|/machines|/inventory|/tags|/onboarding|/identity|/serviceaccounts') { return 'Inventory' }
    if ($hint -match '/coverage|/health|/sensors') { return 'Configuration' }
    return 'Configuration'  # default
}

# -----------------------------------------------------------------------------
# Time-filter strategy per path
# -----------------------------------------------------------------------------
function Get-TimeFilterStrategy {
    param([string]$Path, [string]$Method)
    if ($Method -ne 'GET') { return 'n/a' }
    $p = $Path.ToLowerInvariant()
    # Per-entity routes ({deviceId}, {userId}, etc.) → snapshot per entity (driven by parent stream)
    if ($p -match '\{[^}]+id\}') { return 'per-entity-snapshot' }
    # Timeline / event / history → delta via lastModified or eventDateTime
    if ($p -match '/timeline|/history|/event|/activitie?s|/case-?activities|/audit') { return 'delta-by-eventTime' }
    # Configuration / settings / rules / policies → full snapshot (no time filter)
    if ($p -match '/policies|/rules|/configuration|/settings?$|/profile|/policy|/tags?$|/groups?$') { return 'snapshot-full' }
    # XSPM / posture → snapshot (XSPM is graph-state)
    if ($p -match '/posture/|/xspm|/exposure|/attack|/recommend') { return 'snapshot-full' }
    # Threat analytics → snapshot (static reports + occasional refresh)
    if ($p -match '/threatanalytics|/campaign|/outbreak|/intel|/feed') { return 'snapshot-full' }
    # Action center → delta (events are time-stamped)
    if ($p -match '/actioncenter|/pending|/approval|/automation') { return 'delta-by-eventTime' }
    # Inventory (devices, machines, identities) → snapshot per cadence; entity-level diff in parser
    if ($p -match '/devices?$|/machines?$|/inventory|/serviceaccounts|/identity/') { return 'snapshot-full' }
    return 'snapshot-full'   # safe default
}

# -----------------------------------------------------------------------------
# Operator-value heuristic per path
# -----------------------------------------------------------------------------
function Get-OperatorValueScore {
    param([string]$Path, [string]$Summary)
    $h = "$Path|$Summary".ToLowerInvariant()
    # Top-tier (5/5)
    if ($h -match '/devices?$|/machines?$|/timeline\b|/identity/health|/lateral|/serviceaccounts|/posture/|/xspm|/attack|/threat-?intel|/threatanalytics|/campaign|/outbreak') { return 5 }
    # High (4/5)
    if ($h -match '/policies|/rules|/recommend|/criticality|/businessimpact|/asset/|/exposure|/tenantcontext|/onboarding|/health|/audit|/sensors|/coverage|/groups$|/tags$') { return 4 }
    # Medium (3/5)
    if ($h -match '/setting|/profile|/configuration|/connector|/license|/sku|/case|/pending|/automation|/notification|/email_notifications|/rbac|/role|/baseline') { return 3 }
    # Low (2/5)
    if ($h -match '/discovery|/category|/tag$|/governance|/compliance(?!status)') { return 2 }
    # Trivial (1/5) — would have been caught by uiNoisePatterns ideally
    return 1
}

# -----------------------------------------------------------------------------
# Out-of-scope-write exclusions
# -----------------------------------------------------------------------------
$writeOpExclusions = @(
    'PUT', 'POST', 'PATCH', 'DELETE'
)

# -----------------------------------------------------------------------------
# Existing manifest path normalization
# -----------------------------------------------------------------------------
function Get-NormalizedPath {
    param([string]$Path)
    # Strip /apiproxy/ prefix and query string for comparison
    $p = $Path -replace '^/apiproxy/', '/'
    $p = ($p -split '\?')[0]
    # Normalize path params: {var} → {*}
    $p = $p -replace '\{[^}]+\}', '{*}'
    return $p.ToLowerInvariant().TrimEnd('/')
}

Write-Host "Phase J.F.NEW.0 — Nodoc catalog sweep" -ForegroundColor Cyan
Write-Host "  Reference root : $NodocReferenceRoot" -ForegroundColor DarkGray
Write-Host "  Manifest path  : $ManifestPath" -ForegroundColor DarkGray
Write-Host "  Output dir     : $OutputDir" -ForegroundColor DarkGray

if (-not (Test-Path $NodocReferenceRoot)) {
    throw "Nodoc reference not found at $NodocReferenceRoot. Clone with: git clone --depth 1 https://github.com/nathanmcnulty/nodoc.git .internal/nodoc-reference"
}
if (-not (Test-Path $ManifestPath)) {
    throw "Manifest not found at $ManifestPath"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Load existing manifest paths (normalized)
$manifest = Import-PowerShellDataFile -Path $ManifestPath
$existingPaths = @{}
foreach ($e in $manifest.Endpoints) {
    $key = Get-NormalizedPath -Path $e.Path
    $existingPaths[$key] = $e.Stream
}
Write-Host "  Existing manifest streams: $($existingPaths.Count)" -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# Parse each YAML spec file (regex-based — no PS-yaml dependency)
# -----------------------------------------------------------------------------
$allOps = New-Object System.Collections.Generic.List[object]
foreach ($specFile in Get-ChildItem -Path $NodocReferenceRoot -Filter '*.yml' | Sort-Object Name) {
    $catInfo = $specFileToCategory[$specFile.Name]
    if (-not $catInfo) {
        Write-Warning "No category mapping for $($specFile.Name) — skipping"
        continue
    }
    # Read file and normalize line endings (YAML uses CRLF on Windows)
    $rawText = [System.IO.File]::ReadAllText($specFile.FullName)
    $lines = $rawText -split "`r?`n"

    # Parser state
    $currentPath = $null
    $currentMethod = $null
    $currentSummary = $null
    $currentOpId = $null
    $currentTags = @()
    $currentResponseRef = $null
    $inOp = $false
    $inResponses = $false

    function _Emit-CurrentOp {
        if ($script:currentMethod -and $script:currentPath) {
            $allOps.Add([pscustomobject]@{
                SpecFile      = $specFile.Name
                CategoryId    = $catInfo.Id
                CategorySlug  = $catInfo.Slug
                CategoryName  = $catInfo.Name
                Method        = $script:currentMethod.ToUpperInvariant()
                Path          = $script:currentPath
                OpId          = $script:currentOpId
                Summary       = $script:currentSummary
                Tags          = ($script:currentTags -join ',')
                ResponseRef   = $script:currentResponseRef
            })
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].TrimEnd("`r")  # strip CR if any

        # Path line: 2-space indent, starts with / and ends with :
        if ($line -match '^  (/[^:\s]+):\s*$') {
            # Emit any pending op before switching path
            if ($currentMethod -and $currentPath) {
                $allOps.Add([pscustomobject]@{
                    SpecFile      = $specFile.Name
                    CategoryId    = $catInfo.Id
                    CategorySlug  = $catInfo.Slug
                    CategoryName  = $catInfo.Name
                    Method        = $currentMethod.ToUpperInvariant()
                    Path          = $currentPath
                    OpId          = $currentOpId
                    Summary       = $currentSummary
                    Tags          = ($currentTags -join ',')
                    ResponseRef   = $currentResponseRef
                })
            }
            $currentPath = $matches[1]
            $currentMethod = $null
            $currentSummary = $null
            $currentOpId = $null
            $currentTags = @()
            $currentResponseRef = $null
            $inOp = $false
            $inResponses = $false
            continue
        }

        # Method line: 4-space indent, http verb
        if ($line -match '^    (get|post|put|patch|delete):\s*$') {
            # Emit any pending op
            if ($currentMethod -and $currentPath) {
                $allOps.Add([pscustomobject]@{
                    SpecFile      = $specFile.Name
                    CategoryId    = $catInfo.Id
                    CategorySlug  = $catInfo.Slug
                    CategoryName  = $catInfo.Name
                    Method        = $currentMethod.ToUpperInvariant()
                    Path          = $currentPath
                    OpId          = $currentOpId
                    Summary       = $currentSummary
                    Tags          = ($currentTags -join ',')
                    ResponseRef   = $currentResponseRef
                })
            }
            $currentMethod = $matches[1]
            $currentSummary = $null
            $currentOpId = $null
            $currentTags = @()
            $currentResponseRef = $null
            $inOp = $true
            $inResponses = $false
            continue
        }

        if (-not $inOp) { continue }

        # Track when we enter the responses block (8-space indent)
        if ($line -match '^      responses:\s*$') {
            $inResponses = $true
            continue
        }

        if ($line -match '^      summary:\s*(.+)$') {
            $currentSummary = ($matches[1] -replace '^[''"]|[''"]$').Trim()
        } elseif ($line -match '^      operationId:\s*(.+)$') {
            $currentOpId = ($matches[1] -replace '^[''"]|[''"]$').Trim()
        } elseif ($line -match '^      tags:\s*\[([^\]]*)\]') {
            $currentTags = ($matches[1] -split ',' | ForEach-Object { $_.Trim() -replace '^[''"]|[''"]$' })
        } elseif ($inResponses -and $line -match '\$ref:\s*[''"]?#/components/schemas/(\w+)') {
            if (-not $currentResponseRef) { $currentResponseRef = $matches[1] }
        } elseif ($inResponses -and $line -match 'items:\s*$') {
            # next line likely $ref to schema
        } elseif ($inResponses -and $line -match '\$ref:\s*[''"]?(?:[^''#"]+)?#/components/schemas/(\w+)') {
            if (-not $currentResponseRef) { $currentResponseRef = $matches[1] }
        }
    }

    # Flush last op in file
    if ($currentMethod -and $currentPath) {
        $allOps.Add([pscustomobject]@{
            SpecFile      = $specFile.Name
            CategoryId    = $catInfo.Id
            CategorySlug  = $catInfo.Slug
            CategoryName  = $catInfo.Name
            Method        = $currentMethod.ToUpperInvariant()
            Path          = $currentPath
            OpId          = $currentOpId
            Summary       = $currentSummary
            Tags          = ($currentTags -join ',')
            ResponseRef   = $currentResponseRef
        })
    }
}

Write-Host "  Total ops parsed: $($allOps.Count)" -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# Apply scope filters
# -----------------------------------------------------------------------------
foreach ($op in $allOps) {
    $exclusions = New-Object System.Collections.Generic.List[string]

    if ($op.Method -in $writeOpExclusions) {
        $exclusions.Add("write-op-$($op.Method)") | Out-Null
    }

    foreach ($pat in $publicApiCoveredPatterns) {
        if ($op.Path -match $pat) {
            $exclusions.Add("public-api-covered:$pat") | Out-Null
            break
        }
    }

    foreach ($pat in $uiNoisePatterns) {
        if ($op.Path -match $pat) {
            $exclusions.Add("ui-noise:$pat") | Out-Null
            break
        }
    }

    if ($op.CategoryId -eq 0) {
        $exclusions.Add("category-$($op.CategorySlug)") | Out-Null
    }

    # Cross-ref existing manifest
    $normalized = Get-NormalizedPath -Path $op.Path
    $existingStream = $existingPaths[$normalized]
    if ($existingStream) {
        $exclusions.Add("already-in-manifest:$existingStream") | Out-Null
    }

    # Compute cadence + time-filter + value (even for excluded so report is consistent)
    $cadence = Get-CadenceTier -Path $op.Path -Summary $op.Summary
    $tfStrategy = Get-TimeFilterStrategy -Path $op.Path -Method $op.Method
    $valueScore = Get-OperatorValueScore -Path $op.Path -Summary $op.Summary

    Add-Member -InputObject $op -NotePropertyName 'NormalizedPath' -NotePropertyValue $normalized -Force
    Add-Member -InputObject $op -NotePropertyName 'AlreadyInManifest' -NotePropertyValue ([string]::IsNullOrEmpty($existingStream) -eq $false) -Force
    Add-Member -InputObject $op -NotePropertyName 'ExistingStream' -NotePropertyValue $existingStream -Force
    Add-Member -InputObject $op -NotePropertyName 'Exclusions' -NotePropertyValue ($exclusions -join '; ') -Force
    Add-Member -InputObject $op -NotePropertyName 'InScope' -NotePropertyValue ($exclusions.Count -eq 0) -Force
    Add-Member -InputObject $op -NotePropertyName 'Cadence' -NotePropertyValue $cadence -Force
    Add-Member -InputObject $op -NotePropertyName 'TimeFilterStrategy' -NotePropertyValue $tfStrategy -Force
    Add-Member -InputObject $op -NotePropertyName 'OperatorValueScore' -NotePropertyValue $valueScore -Force
    # Tier classification (per §14.1.2 of plan)
    $tier = if (-not $op.InScope) { 'Excluded' }
            elseif ($valueScore -ge 5) { 'A' }
            elseif ($valueScore -ge 4) { 'B' }
            else { 'C' }
    Add-Member -InputObject $op -NotePropertyName 'InclusionTier' -NotePropertyValue $tier -Force
}

$inScope    = @($allOps | Where-Object InScope)
$alreadyIn  = @($allOps | Where-Object AlreadyInManifest)
$writeOps   = @($allOps | Where-Object { $_.Method -in $writeOpExclusions })
$publicCov  = @($allOps | Where-Object { $_.Exclusions -match 'public-api-covered' })
$uiNoise    = @($allOps | Where-Object { $_.Exclusions -match 'ui-noise' })
$outOfScope = @($allOps | Where-Object { $_.CategoryId -eq 0 })
$tierA      = @($inScope | Where-Object InclusionTier -eq 'A')
$tierB      = @($inScope | Where-Object InclusionTier -eq 'B')
$tierC      = @($inScope | Where-Object InclusionTier -eq 'C')

Write-Host ""
Write-Host "Sweep results:" -ForegroundColor Cyan
Write-Host "  Total ops             : $($allOps.Count)" -ForegroundColor White
Write-Host "  Already in manifest   : $($alreadyIn.Count)" -ForegroundColor Green
Write-Host "  Write ops (excluded)  : $($writeOps.Count)" -ForegroundColor DarkGray
Write-Host "  Public-API-covered    : $($publicCov.Count)" -ForegroundColor DarkGray
Write-Host "  UI/metadata noise     : $($uiNoise.Count)" -ForegroundColor DarkGray
Write-Host "  Out-of-scope spec     : $($outOfScope.Count)" -ForegroundColor DarkGray
Write-Host "  ** IN SCOPE FOR v0.1.0**: $($inScope.Count)" -ForegroundColor Yellow
Write-Host "     - Tier A (must)   : $($tierA.Count)" -ForegroundColor Green
Write-Host "     - Tier B (should) : $($tierB.Count)" -ForegroundColor Yellow
Write-Host "     - Tier C (defer)  : $($tierC.Count)" -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# Group in-scope by category for human review
# -----------------------------------------------------------------------------
$byCategory = $inScope | Group-Object CategorySlug | Sort-Object Name

Write-Host ""
Write-Host "In-scope per category:" -ForegroundColor Cyan
foreach ($g in $byCategory) {
    Write-Host ("  [{0,-30}] {1,3} ops" -f $g.Name, $g.Count) -ForegroundColor White
}

# -----------------------------------------------------------------------------
# Emit CSV
# -----------------------------------------------------------------------------
$csvPath = Join-Path $OutputDir 'NodocCatalogSweep-2026-05-04.csv'
$allOps |
    Select-Object SpecFile, CategoryId, CategorySlug, Method, Path, NormalizedPath,
                  AlreadyInManifest, ExistingStream, InScope, Exclusions, OpId, Summary, Tags |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# -----------------------------------------------------------------------------
# Emit human-readable categorized report
# -----------------------------------------------------------------------------
$mdPath = Join-Path $OutputDir 'NodocCatalogSweep-2026-05-04.md'
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Nodoc catalog sweep — 2026-05-04")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Source: ``.internal/nodoc-reference/specifications/nodoc-defender-xdr/specification/`` (23 yml files)")
[void]$sb.AppendLine("Methodology: Phase J.F.NEW.0 (D'.58) — exhaustive sweep + audit-scope filter")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Tally")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| Bucket | Count |")
[void]$sb.AppendLine("|---|---|")
[void]$sb.AppendLine("| Total ops parsed | $($allOps.Count) |")
[void]$sb.AppendLine("| Already in manifest | $($alreadyIn.Count) |")
[void]$sb.AppendLine("| Write ops (excluded) | $($writeOps.Count) |")
[void]$sb.AppendLine("| Public-API-covered (excluded) | $($publicCov.Count) |")
[void]$sb.AppendLine("| Out-of-scope spec (excluded) | $($outOfScope.Count) |")
[void]$sb.AppendLine("| **IN SCOPE FOR v0.1.0** | **$($inScope.Count)** |")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## In-scope endpoints by category")
[void]$sb.AppendLine("")

foreach ($g in $byCategory) {
    $catId = $g.Group[0].CategoryId
    $catName = $g.Group[0].CategoryName
    $tableName = "Defender_$($g.Name)_CL"
    [void]$sb.AppendLine("### $catId. $catName ($($g.Count) ops)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Workspace table**: ``$tableName``")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Method | Path | Summary | Spec |")
    [void]$sb.AppendLine("|---|---|---|---|")
    foreach ($op in ($g.Group | Sort-Object Path)) {
        $summary = if ($op.Summary) { $op.Summary -replace '\|', '\|' } else { '' }
        if ($summary.Length -gt 80) { $summary = $summary.Substring(0, 77) + '...' }
        [void]$sb.AppendLine("| $($op.Method) | ``$($op.Path)`` | $summary | $($op.SpecFile -replace '\.yml$') |")
    }
    [void]$sb.AppendLine("")
}

[void]$sb.AppendLine("## Already-in-manifest cross-reference")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| Path | Existing stream | Spec |")
[void]$sb.AppendLine("|---|---|---|")
foreach ($op in ($alreadyIn | Sort-Object Path)) {
    [void]$sb.AppendLine("| ``$($op.Path)`` | $($op.ExistingStream) | $($op.SpecFile -replace '\.yml$') |")
}
[void]$sb.AppendLine("")

Set-Content -Path $mdPath -Value $sb.ToString() -Encoding UTF8

# -----------------------------------------------------------------------------
# Emit Tier A — must-include in v0.1.0
# -----------------------------------------------------------------------------
$tierAPath = Join-Path $OutputDir 'NodocCatalogSweep-TierA.md'
$sbA = [System.Text.StringBuilder]::new()
[void]$sbA.AppendLine("# Nodoc catalog sweep — Tier A (MUST in v0.1.0)")
[void]$sbA.AppendLine("")
[void]$sbA.AppendLine("Generated: 2026-05-04")
[void]$sbA.AppendLine("Total Tier A: $($tierA.Count) (operator value 5/5)")
[void]$sbA.AppendLine("")
[void]$sbA.AppendLine("Per user direction: WISE selection — only highest-value portal-only endpoints.")
[void]$sbA.AppendLine("")
[void]$sbA.AppendLine("Each entry includes the proper category mapping, cadence tier (drives polling frequency), and time-filter strategy (drives state + no-duplication discipline).")
[void]$sbA.AppendLine("")
[void]$sbA.AppendLine("| # | Suggested Stream | Category | Workspace Table | Cadence | TimeFilter | Value | Path | Summary |")
[void]$sbA.AppendLine("|---|---|---|---|---|---|---|---|---|")
$idx = 0
foreach ($g in ($tierA | Group-Object CategorySlug | Sort-Object Name)) {
    foreach ($op in ($g.Group | Sort-Object @{e='OperatorValueScore';desc=$true}, Path)) {
        $idx++
        $tableName = "Defender_$($g.Name)_CL"
        $suggestedStream = if ($op.OpId) {
            "MDE_$($op.OpId -replace '\W','')_CL"
        } else {
            $segs = ($op.Path -replace '^/', '' -split '/' | Where-Object { $_ -and $_ -notmatch '^\{' } | Select-Object -Last 2)
            $name = ($segs -join '' -replace '\W','')
            "MDE_$($name)_CL"
        }
        $summary = if ($op.Summary) { $op.Summary -replace '\|', '\|' } else { '' }
        if ($summary.Length -gt 50) { $summary = $summary.Substring(0, 47) + '...' }
        [void]$sbA.AppendLine("| $idx | ``$suggestedStream`` | $($g.Name) | ``$tableName`` | $($op.Cadence) | $($op.TimeFilterStrategy) | $($op.OperatorValueScore) | ``$($op.Path)`` | $summary |")
    }
}
Set-Content -Path $tierAPath -Value $sbA.ToString() -Encoding UTF8

# -----------------------------------------------------------------------------
# Emit Tier B — should-include if budget allows
# -----------------------------------------------------------------------------
$tierBPath = Join-Path $OutputDir 'NodocCatalogSweep-TierB.md'
$sbB = [System.Text.StringBuilder]::new()
[void]$sbB.AppendLine("# Nodoc catalog sweep — Tier B (SHOULD in v0.1.0 if budget)")
[void]$sbB.AppendLine("")
[void]$sbB.AppendLine("Generated: 2026-05-04")
[void]$sbB.AppendLine("Total Tier B: $($tierB.Count) (operator value 4/5)")
[void]$sbB.AppendLine("")
[void]$sbB.AppendLine("| # | Suggested Stream | Category | Workspace Table | Cadence | TimeFilter | Value | Path | Summary |")
[void]$sbB.AppendLine("|---|---|---|---|---|---|---|---|---|")
$idx = 0
foreach ($g in ($tierB | Group-Object CategorySlug | Sort-Object Name)) {
    foreach ($op in ($g.Group | Sort-Object @{e='OperatorValueScore';desc=$true}, Path)) {
        $idx++
        $tableName = "Defender_$($g.Name)_CL"
        $suggestedStream = if ($op.OpId) { "MDE_$($op.OpId -replace '\W','')_CL" } else { "MDE_${idx}_CL" }
        $summary = if ($op.Summary) { $op.Summary -replace '\|', '\|' } else { '' }
        if ($summary.Length -gt 50) { $summary = $summary.Substring(0, 47) + '...' }
        [void]$sbB.AppendLine("| $idx | ``$suggestedStream`` | $($g.Name) | ``$tableName`` | $($op.Cadence) | $($op.TimeFilterStrategy) | $($op.OperatorValueScore) | ``$($op.Path)`` | $summary |")
    }
}
Set-Content -Path $tierBPath -Value $sbB.ToString() -Encoding UTF8

# -----------------------------------------------------------------------------
# Emit Tier C deferred to v0.1.1
# -----------------------------------------------------------------------------
$tierCPath = Join-Path $OutputDir 'NodocCatalogSweep-DeferredToV011.md'
$sbC = [System.Text.StringBuilder]::new()
[void]$sbC.AppendLine("# Nodoc catalog sweep — Deferred to v0.1.1")
[void]$sbC.AppendLine("")
[void]$sbC.AppendLine("Total Tier C: $($tierC.Count) (operator value <= 3/5)")
[void]$sbC.AppendLine("")
[void]$sbC.AppendLine("These endpoints are in scope but defer to v0.1.1 due to lower operator-value-per-unit-cost.")
[void]$sbC.AppendLine("")
[void]$sbC.AppendLine("| # | Path | Category | Value | Reason |")
[void]$sbC.AppendLine("|---|---|---|---|---|")
$idx = 0
foreach ($op in ($tierC | Sort-Object CategorySlug, Path)) {
    $idx++
    [void]$sbC.AppendLine("| $idx | ``$($op.Path)`` | $($op.CategorySlug) | $($op.OperatorValueScore) | low-value-or-similar-to-existing |")
}
Set-Content -Path $tierCPath -Value $sbC.ToString() -Encoding UTF8

# -----------------------------------------------------------------------------
# Emit "new in v0.1.0" suggested manifest list (full)
# -----------------------------------------------------------------------------
$inV010Path = Join-Path $OutputDir 'NodocCatalogSweep-NewInV010.md'
$sb2 = [System.Text.StringBuilder]::new()
[void]$sb2.AppendLine("# Nodoc catalog sweep — NEW IN v0.1.0 inclusion list")
[void]$sb2.AppendLine("")
[void]$sb2.AppendLine("Generated: 2026-05-04")
[void]$sb2.AppendLine("Total in-scope: $($inScope.Count)")
[void]$sb2.AppendLine("")
[void]$sb2.AppendLine("## Inclusion candidates — proper category and table mapping")
[void]$sb2.AppendLine("")
[void]$sb2.AppendLine("Per user direction (2026-05-04): every in-scope new stream gets a manifest entry with proper ``CategoryId`` so it lands in the correct ``Defender_<Category>_CL`` workspace table.")
[void]$sb2.AppendLine("")
[void]$sb2.AppendLine("| # | Suggested Stream | Category | Workspace Table | Method | Path | Summary |")
[void]$sb2.AppendLine("|---|---|---|---|---|---|---|")
$idx = 0
foreach ($g in $byCategory) {
    foreach ($op in ($g.Group | Sort-Object Path)) {
        $idx++
        $tableName = "Defender_$($g.Name)_CL"
        # Suggested stream name: derive from operationId or path
        $suggestedStream = if ($op.OpId) {
            "MDE_$($op.OpId -replace '\W','')_CL"
        } else {
            $segs = ($op.Path -replace '^/', '' -split '/' | Where-Object { $_ -and $_ -notmatch '^\{' } | Select-Object -Last 2)
            $name = ($segs -join '' -replace '\W','')
            "MDE_$($name)_CL"
        }
        $summary = if ($op.Summary) { $op.Summary -replace '\|', '\|' } else { '' }
        if ($summary.Length -gt 60) { $summary = $summary.Substring(0, 57) + '...' }
        [void]$sb2.AppendLine("| $idx | ``$suggestedStream`` | $($op.CategoryName) | ``$tableName`` | $($op.Method) | ``$($op.Path)`` | $summary |")
    }
}
Set-Content -Path $inV010Path -Value $sb2.ToString() -Encoding UTF8

Write-Host ""
Write-Host "Outputs written:" -ForegroundColor Green
Write-Host "  - $csvPath"
Write-Host "  - $mdPath"
Write-Host "  - $inV010Path"
Write-Host "  - $tierAPath"
Write-Host "  - $tierBPath"
Write-Host "  - $tierCPath"
Write-Host ""
Write-Host "Next steps (Phase J.F.NEW.1+):" -ForegroundColor Cyan
Write-Host "  1. Human review of NodocCatalogSweep-NewInV010.md"
Write-Host "  2. Pick top-N for v0.1.0 (operator value × cost; defer rest to v0.1.1 backlog)"
Write-Host "  3. Fix CapturePreflight.Tests.ps1 + run online preflight"
Write-Host "  4. Live-capture each picked stream"
Write-Host "  5. Add manifest entries with proper CategoryId per the inclusion list"
