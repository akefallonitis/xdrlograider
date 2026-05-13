# Capture-References.ps1
#
# Build the references/ tree under v2 by combining:
#   (a) nodoc OpenAPI schema per endpoint (always)
#   (b) live SA-backed response per endpoint (Defender portal only)
#
# Output layout: references/<portal>/<sub-area>/<endpoint>/{nodoc.yml,live.json,metadata.json}
#
# Re-runnable. Per-endpoint files overwrite on each run.

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Portal = 'defender',   # validated dynamically against $portalMap keys
    [string]$OnlySubArea = '',                                # optional filter (renamed to avoid var-name collision with loop var)
    [string]$NodocRoot = "$PSScriptRoot\..\..\xdrlograider\.internal\nodoc-reference\specifications",
    [string]$OutputRoot = "$PSScriptRoot\..\references",
    [string]$EnvFile = "$PSScriptRoot\..\..\xdrlograider\tests\.env.local",
    [switch]$NoLive,                                          # skip live probe even for Defender
    [switch]$IndexOnly,                                       # skip probe + extraction; just re-emit indexes from existing metadata.json
    [int]$LiveTimeoutSec = 30,
    [int]$LiveBatchDelayMs = 250                              # gap between probes to be gentle
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Portal -> nodoc dir mapping
# ---------------------------------------------------------------------------
# Per-portal config:
#   NodocDir(s):  source spec directory under .internal/nodoc-reference/specifications/
#   BaseHost:     portal host (used for live HTTP probes)
#   ClientId:     Entra public-client app for Get-EntraEstsAuth
#   HasLive:      $true if our SA can authenticate (verified 2026-05-12 via Test-MultiPortalAuth)
#   PathPrefix:   portal-specific URL prefix prepended to nodoc paths (e.g. /apiproxy for Defender)
#
# Live-auth verified portals (2026-05-12 probe):
#   defender, purview, teams — Get-EntraEstsAuth completes; cookies set
# Failed auth (Entra $Config parser fails — need v0.2.0 research):
#   intune, entra, m365-admin, security-copilot
# API hosts CONFIRMED from nodoc <portal>/specification/openapi.yml servers blocks (2026-05-12).
# Path prefix is what nodoc paths are RELATIVE TO — appended to BaseHost for live probes.
# Different from auth-portal host: e.g., Purview authenticates at compliance.microsoft.com (or purview.microsoft.com)
# but API is at purview.microsoft.com/apiproxy.
$portalMap = @{
    'defender'        = @{ NodocDir='nodoc-defender-xdr/specification'; BaseHost='security.microsoft.com'; PathPrefix='/apiproxy'; ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; AuthHost='security.microsoft.com'; HasLive=$true; AuthStatus='live-verified'; InScopeSubAreas=@('action_center','attack_simulator','cloud_apps','configuration','data_lake','endpoint_configuration','endpoint_devices','entity_pivots','exposure_management','files','identity','multi_tenant','portal_services','secure_score','sentinel_precision','streaming','threat_analytics','vulnerability_management') }
    'purview'         = @{ NodocDirs=@('nodoc-purview/specification','nodoc-purview-portal/specification'); BaseHost='purview.microsoft.com'; PathPrefix='/apiproxy'; ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; AuthHost='purview.microsoft.com'; HasLive=$true; AuthStatus='live-verified' }
    'teams'           = @{ NodocDirs=@('nodoc-teams/specification'); BaseHost='admin.teams.microsoft.com'; PathPrefix=''; ClientId='12128f48-ec9e-42f0-b203-ea49fb6af367'; AuthHost='admin.teams.microsoft.com'; HasLive=$true; AuthStatus='live-verified-portal' }

    # Auth-research-needed portals — Get-EntraEstsAuth $Config parser fails on these.
    # Real API hosts captured for v0.2.0 implementation; AuthHost may differ from BaseHost
    'intune-autopatch'= @{ NodocDirs=@('nodoc-intune-autopatch/specification'); BaseHost='services.autopatch.microsoft.com'; PathPrefix=''; ClientId='0000000a-0000-0000-c000-000000000000'; AuthHost='intune.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'intune-portal'   = @{ NodocDirs=@('nodoc-intune-portal/specification'); BaseHost='intune.microsoft.com'; PathPrefix=''; ClientId='0000000a-0000-0000-c000-000000000000'; AuthHost='intune.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }

    # Entra sub-portals — each uses a different backend API host
    'entra-ibiza-iam' = @{ NodocDirs=@('nodoc-ibiza-iam/specification'); BaseHost='main.iam.ad.ext.azure.com'; PathPrefix='/api'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; AuthHost='portal.azure.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'entra-b2c'       = @{ NodocDirs=@('nodoc-entra-b2c/specification'); BaseHost='main.b2cadmin.ext.azure.com'; PathPrefix=''; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; AuthHost='portal.azure.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'entra-iga'       = @{ NodocDirs=@('nodoc-entra-iga/specification'); BaseHost='elm.iga.azure.com'; PathPrefix=''; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; AuthHost='entra.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'entra-idgov'     = @{ NodocDirs=@('nodoc-entra-idgov/specification'); BaseHost='api.accessreviews.identitygovernance.azure.com'; PathPrefix=''; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; AuthHost='entra.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'entra-pim'       = @{ NodocDirs=@('nodoc-entra-pim/specification'); BaseHost='api.azrbac.mspim.azure.com'; PathPrefix=''; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; AuthHost='portal.azure.com'; HasLive=$false; AuthStatus='auth-research-needed' }

    # M365 ecosystem
    'm365-admin'      = @{ NodocDirs=@('nodoc-m365-admin/specification'); BaseHost='admin.cloud.microsoft'; PathPrefix=''; ClientId='4765445b-32c6-49b0-83e6-1d93765276ca'; AuthHost='admin.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'm365-apps-config'= @{ NodocDirs=@('nodoc-m365-apps-config/specification'); BaseHost='config.office.com'; PathPrefix=''; AuthHost='admin.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'm365-apps-inventory' = @{ NodocDirs=@('nodoc-m365-apps-inventory/specification'); BaseHost='query.inventory.insights.office.net'; PathPrefix=''; AuthHost='admin.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'm365-apps-services'  = @{ NodocDirs=@('nodoc-m365-apps-services/specification'); BaseHost='clients.config.office.net'; PathPrefix=''; AuthHost='admin.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }

    'security-copilot'= @{ NodocDirs=@('nodoc-security-copilot/specification'); BaseHost='api.securitycopilot.microsoft.com'; PathPrefix=''; ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; AuthHost='securitycopilot.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'power-platform'  = @{ NodocDirs=@('nodoc-power-platform/specification'); BaseHost='admin.powerplatform.microsoft.com'; PathPrefix=''; AuthHost='admin.powerplatform.microsoft.com'; HasLive=$false; AuthStatus='auth-research-needed' }
    'sharepoint'      = @{ NodocDirs=@('nodoc-sharepoint-admin/specification'); BaseHost='{tenant}-admin.sharepoint.com'; PathPrefix=''; HasLive=$false; AuthStatus='auth-research-needed' }
    'exchange'        = @{ NodocDirs=@('nodoc-exchange-beta/specification'); BaseHost='admin.exchange.microsoft.com'; PathPrefix=''; ClientId='4765445b-32c6-49b0-83e6-1d93765276ca'; AuthHost='admin.exchange.microsoft.com'; HasLive=$true; AuthStatus='cookie-chain-verified' }
    'viva'            = @{ NodocDirs=@('nodoc-viva-engage/specification'); BaseHost='engage.cloud.microsoft'; PathPrefix=''; HasLive=$false; AuthStatus='low-priority' }
}

# ---------------------------------------------------------------------------
# Text-based YAML path extraction (deterministic, no YAML parser dependency)
# ---------------------------------------------------------------------------
function Get-NodocPathsFromYaml {
    param([string]$YamlPath)

    if (-not (Test-Path $YamlPath)) { return @() }
    $lines = Get-Content -Path $YamlPath
    $i = 0; $n = $lines.Count
    $results = @()

    # Find the 'paths:' top-level key
    while ($i -lt $n -and $lines[$i] -notmatch '^paths\s*:\s*$') { $i++ }
    if ($i -ge $n) { return @() }
    $i++

    while ($i -lt $n) {
        $line = $lines[$i]
        # End of paths: section: next top-level key (column 0)
        if ($line -match '^\S') { break }
        # New path entry: 2-space-indented '/...'
        if ($line -match '^  (/\S[^:]*)\s*:\s*$') {
            $path = $matches[1]
            $startIdx = $i
            $i++
            $methods = @()
            $operationId = $null
            $summary = $null
            while ($i -lt $n) {
                $sub = $lines[$i]
                # Next path at 2 spaces, or top-level key, ends this entry
                if ($sub -match '^  /' -or $sub -match '^\S') { break }
                if ($sub -match '^\s{4}(get|post|put|delete|patch|head|options)\s*:') {
                    $methods += $matches[1]
                }
                if ($sub -match '^\s{6}operationId\s*:\s*(.+)$' -and -not $operationId) {
                    $operationId = $matches[1].Trim()
                }
                if ($sub -match '^\s{6}summary\s*:\s*(.+)$' -and -not $summary) {
                    $summary = $matches[1].Trim()
                }
                $i++
            }
            $endIdx = $i - 1
            # Snip the path block as raw YAML text (so consumers can read it)
            $blockText = ($lines[$startIdx..$endIdx]) -join "`n"
            $results += [pscustomobject]@{
                Path        = $path
                Methods     = $methods
                OperationId = $operationId
                Summary     = $summary
                YamlBlock   = $blockText
                SourceFile  = (Split-Path -Leaf $YamlPath)
            }
        } else {
            $i++
        }
    }
    return $results
}

function Get-EndpointSlug {
    param([string]$OperationId, [string]$Path)
    if ($OperationId) {
        # strip 'Category.' prefix, keep verb+resource
        return ($OperationId -replace '^[^.]+\.', '')
    }
    # fallback: hash-ish from path
    return ($Path -replace '[^A-Za-z0-9]', '_').Trim('_')
}

# ---------------------------------------------------------------------------
# Parameter extraction — pagination + time-filter + other (from nodoc YAML)
# ---------------------------------------------------------------------------
function Parse-NodocParameters {
    param([string]$YamlBlock)

    # Match each parameter under a `parameters:` block. nodoc params are
    # 4-space-indented under the verb, or 6-space under `parameters:`:
    #   <verb>:
    #     parameters:
    #       - name: pageIndex
    #         in: query
    #         description: ...
    #         schema:
    #           type: integer
    #           default: 0
    $params = @()
    $lines = $YamlBlock -split "`n"
    $i = 0; $n = $lines.Count
    while ($i -lt $n) {
        if ($lines[$i] -match '^\s+- name:\s*(\S+)') {
            $name = $matches[1]
            $in = ''; $type = ''; $defaultVal = ''; $desc = ''
            $j = $i + 1
            while ($j -lt $n -and $lines[$j] -notmatch '^\s+- name:' -and $lines[$j] -match '^\s{8,}') {
                if ($lines[$j] -match '^\s+in:\s*(\S+)')         { $in = $matches[1] }
                if ($lines[$j] -match '^\s+description:\s*(.+)$') { $desc = $matches[1].Trim() }
                if ($lines[$j] -match '^\s+type:\s*(\S+)')        { $type = $matches[1] }
                if ($lines[$j] -match '^\s+default:\s*(.+)$')     { $defaultVal = $matches[1].Trim() }
                $j++
            }
            $params += [pscustomobject]@{
                Name    = $name
                In      = $in
                Type    = $type
                Default = $defaultVal
                Description = $desc
            }
            $i = $j
        } else { $i++ }
    }
    return $params
}

function Classify-Parameters {
    param([object[]]$Params)
    $pagination = @{ style='none'; sizeParam=$null; indexParam=$null; tokenParam=$null; defaults=@{} }
    $timeFilter = @{ supported=$false; startParam=$null; endParam=$null; lookbackParam=$null; type=$null }
    $other = @()

    foreach ($p in $Params) {
        $n = $p.Name
        # PAGINATION patterns
        if ($n -match '^(pageIndex|page|pageNumber)$') {
            $pagination.indexParam = $n
            if ($p.Default -eq '0') { $pagination.style = 'pageIndex0Based' }
            elseif ($p.Default -eq '1') { $pagination.style = 'pageIndex1Based' }
            elseif ($pagination.style -eq 'none') { $pagination.style = 'pageIndex-unknown' }
        }
        elseif ($n -match '^(pageSize|size|top|\$top|limit|count|\$count|maxPageSize|maxResults)$') {
            $pagination.sizeParam = $n
            if ($p.Default) { $pagination.defaults[$n] = $p.Default }
        }
        elseif ($n -match '^(skip|\$skip|offset|skipToken|\$skiptoken|continuationToken|nextLink|cursor)$') {
            if ($n -match 'token|cursor') { $pagination.tokenParam = $n; $pagination.style = 'continuationToken' }
            elseif ($n -match 'skip|offset') { $pagination.tokenParam = $n; if ($pagination.style -eq 'none') { $pagination.style = 'offsetLimit' } }
        }
        # TIME FILTER patterns
        elseif ($n -match '^(startDateTime|startTime|since|fromDateTime|fromDate|from|beginDateTime|startDate|sinceDateTime)$') {
            $timeFilter.supported = $true
            $timeFilter.startParam = $n
            $timeFilter.type = if ($p.Type -eq 'string') { 'iso8601' } else { $p.Type }
        }
        elseif ($n -match '^(endDateTime|endTime|untilDateTime|toDateTime|toDate|to|untilDate|until|endDate)$') {
            $timeFilter.supported = $true
            $timeFilter.endParam = $n
        }
        elseif ($n -match '^(lookbackInDays|lookbackDays|daysBack|lookbackHours|hoursBack|sinceMinutes|sinceHours|sinceDays|days|hours)$') {
            $timeFilter.supported = $true
            $timeFilter.lookbackParam = $n
            $timeFilter.type = 'duration-units-from-now'
        }
        # OTHER (filter / sort / id / etc.)
        else {
            $other += $p
        }
    }
    return @{ Pagination=$pagination; TimeFilter=$timeFilter; Other=$other }
}

# ---------------------------------------------------------------------------
# v1 manifest cross-reference — does v1 already have a stream for this path?
# ---------------------------------------------------------------------------
$script:V1ManifestEntries = $null
function Get-V1ManifestEntry {
    param([string]$Path)
    if ($null -eq $script:V1ManifestEntries) {
        $v1ManifestPath = Join-Path $PSScriptRoot '..\..\xdrlograider\src\Modules\Xdr.Defender.Client\endpoints.manifest.psd1'
        if (Test-Path $v1ManifestPath) {
            try {
                $m = Import-PowerShellDataFile $v1ManifestPath
                $script:V1ManifestEntries = @($m.Endpoints | ForEach-Object {
                    [pscustomobject]@{
                        Stream    = $_.Stream
                        Path      = ($_.Path -replace '^/apiproxy', '') -replace '\?.*$', ''
                        RawPath   = $_.Path
                        Tier      = $_.Tier
                        Category  = $_.Category
                    }
                })
            } catch {
                $script:V1ManifestEntries = @()
            }
        } else {
            $script:V1ManifestEntries = @()
        }
    }
    $normalized = ($Path -replace '^/apiproxy', '') -replace '\?.*$', ''
    $hit = $script:V1ManifestEntries | Where-Object { $_.Path -eq $normalized } | Select-Object -First 1
    if ($hit) {
        return [pscustomobject]@{
            v1Stream   = $hit.Stream
            v1Tier     = $hit.Tier
            v1Category = $hit.Category
            v1RawPath  = $hit.RawPath
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# DefenderHarvester reference — Olaf Hartong's 12 known endpoints
# ---------------------------------------------------------------------------
$script:DefenderHarvesterPaths = @(
    'machineactions','customdetections','suppressionrules','machinegroups',
    'dataexportsettings','advancedfeatures','alertservicesettings','timeline',
    'mtp/responseApiPortal/apps','mtp/alertsApiService/alerts','mtp/incidentQueue/incidents',
    'mtp/wdatpApi'
)
function Get-DefenderHarvesterMatch {
    param([string]$Path)
    foreach ($p in $script:DefenderHarvesterPaths) {
        if ($Path -match [regex]::Escape($p)) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Suggested cadence (heuristic per nodoc sub-area)
# ---------------------------------------------------------------------------
$script:CadenceMap = @{
    'action_center'           = '10min'    # event-shaped
    'attack_simulator'        = '6h'
    'cloud_apps'              = '6h'
    'configuration'           = '6h'
    'data_lake'               = '1h'
    'endpoint_configuration'  = 'daily'
    'endpoint_devices'        = 'daily'
    'entity_pivots'           = '1h'        # operator-driven
    'exposure_management'     = '1h'
    'files'                   = '1h'
    'identity'                = 'daily'
    'multi_tenant'            = 'daily'
    'portal_services'         = 'weekly'
    'secure_score'            = 'daily'
    'sentinel_precision'      = '1h'
    'streaming'               = 'weekly'
    'threat_analytics'        = '6h'
    'vulnerability_management'= 'daily'
}

# ---------------------------------------------------------------------------
# Per-portal auth chain hints
# ---------------------------------------------------------------------------
$script:AuthChainMap = @{
    'defender'         = @{ ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; CookieHost='security.microsoft.com'; Method='Get-EntraEstsAuth + sccauth+XSRF'; Status='live-verified-20260512' }
    'purview'          = @{ ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; CookieHost='compliance.microsoft.com'; Method='Get-EntraEstsAuth (shares Defender ClientId)'; Status='live-verified-20260512' }
    'teams'            = @{ ClientId='12128f48-ec9e-42f0-b203-ea49fb6af367'; CookieHost='admin.teams.microsoft.com'; Method='Get-EntraEstsAuth + TAC cookies'; Status='live-verified-20260512' }
    'intune'           = @{ ClientId='0000000a-0000-0000-c000-000000000000'; CookieHost='intune.microsoft.com'; Method='Get-EntraEstsAuth — Entra $Config parser fails; need MSAL/PKCE flow research'; Status='auth-research-needed' }
    'entra'            = @{ ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; CookieHost='entra.microsoft.com'; Method='Get-EntraEstsAuth — $Config parser fails; need MSAL/PKCE flow research'; Status='auth-research-needed' }
    'm365-admin'       = @{ ClientId='4765445b-32c6-49b0-83e6-1d93765276ca'; CookieHost='admin.microsoft.com'; Method='Get-EntraEstsAuth — $Config parser fails; need MSAL/PKCE flow research'; Status='auth-research-needed' }
    'security-copilot' = @{ ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; CookieHost='securitycopilot.microsoft.com'; Method='Get-EntraEstsAuth — $Config missing required fields; need different bootstrap'; Status='auth-research-needed' }
    'power-platform'   = @{ ClientId='?'; CookieHost='admin.powerplatform.microsoft.com'; Method='Not yet probed; ClientId TBD'; Status='auth-research-needed' }
    'm365-apps'        = @{ CookieHost='admin.microsoft.com'; Method='Sub-area of M365 admin'; Status='auth-research-needed' }
    'sharepoint'       = @{ CookieHost='*-admin.sharepoint.com'; Method='Tenant-specific host; ClientId TBD'; Status='auth-research-needed' }
    'exchange'         = @{ Method='Microsoft Graph covers — out of portal-only scope'; Status='out-of-scope-graph-covers' }
    'viva'             = @{ Method='Low operator-value priority'; Status='low-priority' }
}

function Save-EndpointReference {
    param(
        [string]$PortalKey,
        [string]$SubAreaName,
        [pscustomobject]$Endpoint,
        [object]$LiveResult = $null
    )
    $slug = Get-EndpointSlug -OperationId $Endpoint.OperationId -Path $Endpoint.Path
    $endpointDir = Join-Path $OutputRoot (Join-Path $PortalKey (Join-Path $SubAreaName $slug))
    $null = New-Item -Path $endpointDir -ItemType Directory -Force

    # nodoc.yml — raw nodoc YAML fragment for this path
    Set-Content -Path (Join-Path $endpointDir 'nodoc.yml') -Value $Endpoint.YamlBlock -NoNewline

    # Parse nodoc parameters + classify
    $params      = Parse-NodocParameters -YamlBlock $Endpoint.YamlBlock
    $classified  = Classify-Parameters -Params $params
    $v1Ref       = $null
    $harvesterRef= $null
    if ($PortalKey -eq 'defender') {
        $v1Ref        = Get-V1ManifestEntry -Path $Endpoint.Path
        $harvesterRef = Get-DefenderHarvesterMatch -Path $Endpoint.Path
    }
    $cadence = if ($script:CadenceMap.ContainsKey($SubAreaName)) { $script:CadenceMap[$SubAreaName] } else { 'unknown' }
    $authChain = $script:AuthChainMap[$PortalKey]

    # XDRInternals hint — operationId Verb+Resource → likely cmdlet name
    $xdrInternalsHint = $null
    if ($Endpoint.OperationId) {
        $verb,$rest = $Endpoint.OperationId -split '\.', 2
        if ($rest) {
            # operationId 'ActionCenter.GetHistory' → 'Get-XdrActionCenterHistory' (heuristic)
            $xdrInternalsHint = "Get-Xdr$($verb)$($rest -replace '^(Get|List|Query|Set|Update|Create|Delete|Post|Put)', '')"
        }
    }

    # metadata.json — endpoint summary with full enrichment
    $meta = [ordered]@{
        portal             = $PortalKey
        subArea            = $SubAreaName
        slug               = $slug
        operationId        = $Endpoint.OperationId
        path               = $Endpoint.Path
        methods            = $Endpoint.Methods
        summary            = $Endpoint.Summary
        sourceFile         = $Endpoint.SourceFile
        capturedUtc        = (Get-Date).ToUniversalTime().ToString('o')

        # Enrichment for v2 manifest design
        pagination         = $classified.Pagination
        timeFilter         = $classified.TimeFilter
        otherParameters    = $classified.Other
        suggestedCadence   = $cadence
        authChain          = $authChain
        v1Manifest         = $v1Ref
        xdrInternalsHint   = $xdrInternalsHint
        defenderHarvester  = $harvesterRef
    }
    if ($LiveResult) {
        $meta['live'] = [ordered]@{
            httpStatus    = $LiveResult.HttpStatus
            successKind   = $LiveResult.SuccessKind
            rowCount      = $LiveResult.RowCount
            errorText     = $LiveResult.ErrorText
            responseShape = $LiveResult.ResponseShape
        }
    }
    $meta | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $endpointDir 'metadata.json')

    # live.json — captured live response (only when LiveResult provided)
    if ($LiveResult) {
        $live = [ordered]@{
            httpStatus    = $LiveResult.HttpStatus
            successKind   = $LiveResult.SuccessKind
            rowCount      = $LiveResult.RowCount
            errorText     = $LiveResult.ErrorText
            responseShape = $LiveResult.ResponseShape
            sample        = $LiveResult.Sample           # truncated sample for human review
        }
        $live | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $endpointDir 'live.json')
    }
    return $endpointDir
}

function Invoke-LiveProbe {
    # Defender: uses v1's Invoke-MDEPortalEndpoint helper (sccauth+XSRF cookie handling + 401/440 reauth + 429 retry).
    # Other portals: uses raw Invoke-WebRequest with the portal's WebSession (cookies set during Get-EntraEstsAuth).
    param(
        [string]$Path,
        [string]$Method,
        [object]$Session,
        [hashtable]$Headers = @{},
        [string]$PortalKey = 'defender',
        [string]$BaseHost
    )
    $result = [pscustomobject]@{
        HttpStatus    = 0
        SuccessKind   = 'error'
        RowCount      = 0
        ErrorText     = ''
        ResponseShape = $null
        Sample        = $null
    }
    try {
        if ($PortalKey -eq 'defender') {
            $r = Invoke-MDEPortalEndpoint -Session $Session -Path $Path -Method $Method -AdditionalHeaders $Headers
        } else {
            # Generic portal: use the WebSession directly + add X-XSRF-TOKEN from cookies
            $uri = "https://$BaseHost$Path"
            $r = @{ Success=$false; Data=$null; Error='' }
            try {
                $hdrs = @{ 'Accept'='application/json' }
                foreach ($k in $Headers.Keys) { $hdrs[$k] = $Headers[$k] }
                # XSRF cookie is critical for /apiproxy endpoints + most portal SPAs.
                # Look on AuthHost first, then BaseHost (some portals issue XSRF only on AuthHost).
                $xsrfCookie = $null
                $hosts = @($Session.PortalHost, $BaseHost) | Where-Object { $_ } | Select-Object -Unique
                foreach ($h in $hosts) {
                    $xsrfCookie = $Session.WebSession.Cookies.GetCookies("https://$h") | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
                    if ($xsrfCookie) { break }
                }
                if ($xsrfCookie) {
                    $hdrs['X-XSRF-TOKEN'] = [System.Net.WebUtility]::UrlDecode($xsrfCookie.Value)
                }
                $resp = Invoke-WebRequest -Uri $uri -Method $Method -WebSession $Session.WebSession -Headers $hdrs -TimeoutSec 15 -ErrorAction Stop
                $body = $resp.Content
                # detect login-redirect (HTML signs us in again — session expired or cookie not applied)
                if ($body -match '<title>(Sign in|Microsoft .* admin center)' -and $body.Length -gt 500) {
                    $r.Success = $false
                    $r.Error = "auth-redirect-html-200 ($(([int]$resp.StatusCode))) — non-API response"
                } else {
                    try {
                        $r.Data = $body | ConvertFrom-Json -ErrorAction Stop -Depth 30
                        $r.Success = $true
                    } catch {
                        # Non-JSON 200 — could be HTML or text; consider live-empty if short, error otherwise
                        if ($body.Length -lt 50) { $r.Success = $true; $r.Data = $null }
                        else { $r.Success = $false; $r.Error = "non-json-200: $(($body.Length))b" }
                    }
                }
            } catch {
                $resErr = $_.Exception.Response
                if ($resErr) {
                    $r.Error = "HTTP $([int]$resErr.StatusCode)"
                } else {
                    $r.Error = "exception: $($_.Exception.Message)"
                }
            }
        }
        if ($r.Success) {
            $parsed = $r.Data
            $result.HttpStatus = 200
            if ($null -eq $parsed) {
                $result.SuccessKind = 'live-empty'
            } elseif ($parsed -is [array]) {
                $result.SuccessKind = if (@($parsed).Count -gt 0) { 'live' } else { 'live-empty' }
                $result.RowCount    = @($parsed).Count
                $result.ResponseShape = 'array'
            } else {
                $unwrapKey = $null
                foreach ($k in 'value','items','results','data','entries','rules','machines','sensors','tenants','outbreaks','recommendations','assets','metrics','aggregations','attackPaths','chokePoints','topTargets','suppressionRules','customDetections','machineGroups','roleDefinitions','tenantContext','workspace','indicators','simulations','campaigns','users','reports') {
                    if ($parsed.PSObject.Properties[$k]) { $unwrapKey = $k; break }
                }
                if ($unwrapKey) {
                    $inner = $parsed.$unwrapKey
                    if ($inner -is [array]) {
                        $result.SuccessKind = if (@($inner).Count -gt 0) { 'live' } else { 'live-empty' }
                        $result.RowCount    = @($inner).Count
                        $result.ResponseShape = "wrapper:$unwrapKey[]"
                    } else {
                        $result.SuccessKind = 'live'
                        $result.RowCount    = 1
                        $result.ResponseShape = "wrapper:$unwrapKey"
                    }
                } else {
                    $result.SuccessKind = 'live'
                    $result.RowCount    = 1
                    $result.ResponseShape = 'object'
                }
            }
            # Build sample: keep first 5 items of arrays, full structure of objects
            try {
                if ($parsed -is [array]) {
                    $sampleItems = @($parsed | Select-Object -First 5)
                    $result.Sample = @{ truncatedTo = 5; totalRows = @($parsed).Count; items = $sampleItems }
                } elseif ($parsed -is [pscustomobject] -and $result.ResponseShape -match '^wrapper:(.+)\[\]$') {
                    $wrapperKey = $matches[1]
                    $inner = $parsed.$wrapperKey
                    $sampleItems = @($inner | Select-Object -First 5)
                    # Clone the outer object but replace the wrapper array with the truncated sample
                    $clone = [ordered]@{}
                    foreach ($prop in $parsed.PSObject.Properties) {
                        if ($prop.Name -eq $wrapperKey) {
                            $clone[$prop.Name] = $sampleItems
                        } else {
                            $clone[$prop.Name] = $prop.Value
                        }
                    }
                    $clone['_truncatedTo'] = 5
                    $clone['_totalRows']   = @($inner).Count
                    $result.Sample = $clone
                } else {
                    $result.Sample = $parsed
                }
            } catch {
                $result.Sample = @{ _serializeError = $_.Exception.Message }
            }
        } else {
            # Helper returned error; classify per HTTP status code in $r.Error string
            $err = [string]$r.Error
            $result.ErrorText = $err
            $statusFromMsg = 0
            if ($err -match '\b(4\d\d|5\d\d)\b') { $statusFromMsg = [int]$matches[1] }
            $result.HttpStatus = $statusFromMsg
            $result.SuccessKind = if ($statusFromMsg -eq 429) { 'rate-limited' } else { 'error' }
            if ($err.Length -gt 600) { $err = $err.Substring(0,600) + '...[truncated]' }
            $result.Sample = $err
        }
    } catch {
        $result.SuccessKind = 'error'
        $result.ErrorText   = "exception: $($_.Exception.Message)"
    }
    return $result
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$portals = if ($Portal -eq 'all') { $portalMap.Keys } else { @($Portal) }

# Auth setup — multi-portal capable now (Defender, Purview, Teams admin all live)
# Each portal-live capable in $portalMap (HasLive=$true) gets its own session.
$portalSessions = @{}    # portalKey -> session object
$cred = $null
if (-not $IndexOnly -and -not $NoLive) {
    if (-not (Test-Path $EnvFile)) {
        Write-Host "ENV file not found: $EnvFile — skipping all live probes" -ForegroundColor Yellow
    } else {
        Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
            $k,$v = $_ -split '=', 2; Set-Item -Path "env:$k" -Value $v
        }
        $v1Modules = "$PSScriptRoot/../../xdrlograider/src/Modules"
        foreach ($m in 'Xdr.Common.Telemetry','Xdr.Common.Auth','Xdr.Common.Manifest','Xdr.Sentinel.Ingest','Xdr.Defender.Auth','Xdr.Defender.Client') {
            Import-Module (Join-Path $v1Modules "$m/$m.psd1") -Force -Global -ErrorAction SilentlyContinue
        }
        $cred = @{ upn=$env:XDRLR_TEST_UPN; password=$env:XDRLR_TEST_PASSWORD; totpBase32=$env:XDRLR_TEST_TOTP_SECRET }

        $liveTargets = $portals | Where-Object { $portalMap[$_].HasLive -eq $true -and $portalMap[$_].ClientId }
        if ($liveTargets.Count -eq 0) {
            Write-Host "No live-capable portals selected." -ForegroundColor DarkGray
        }
        $firstAuth = $true
        foreach ($pkey in $liveTargets) {
            $pm = $portalMap[$pkey]
            if (-not $firstAuth) {
                Write-Host "  (waiting 35s for TOTP step rotation before next portal auth...)" -ForegroundColor DarkGray
                Start-Sleep -Seconds 35
            }
            $firstAuth = $false
            Write-Host "Authenticating SA to $($pm.BaseHost) (ClientId $($pm.ClientId.Substring(0,8))…)" -ForegroundColor Cyan
            if ($pkey -eq 'defender') {
                # Use v1's Connect-DefenderPortal which adds Defender-specific sccauth verification
                try {
                    $sess = Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred -Force
                    $portalSessions[$pkey] = $sess
                    Write-Host "  Authenticated. TenantId=$($sess.TenantId)" -ForegroundColor Green
                } catch {
                    Write-Host "  Auth FAILED — $($_.Exception.Message)" -ForegroundColor Yellow
                }
            } else {
                # Other portals: use portal-generic Get-EntraEstsAuth at AuthHost (may differ from BaseHost)
                $authHost = if ($pm.AuthHost) { $pm.AuthHost } else { $pm.BaseHost }
                try {
                    $auth = Get-EntraEstsAuth -Method 'CredentialsTotp' -Credential $cred -ClientId $pm.ClientId -PortalHost $authHost
                    $portalSessions[$pkey] = [pscustomobject]@{
                        WebSession = $auth.Session
                        TenantId   = $null
                        Method     = 'CredentialsTotp'
                        PortalHost = $authHost
                        BaseHost   = $pm.BaseHost
                    }
                    Write-Host "  Authenticated to $authHost (API host: $($pm.BaseHost))" -ForegroundColor Green
                } catch {
                    Write-Host "  Auth FAILED — $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
    }
}

$totalEndpoints = 0
$liveCounts = @{ live=0; 'live-empty'=0; 'rate-limited'=0; error=0; 'no-live'=0 }

foreach ($p in $portals) {
    $cfg = $portalMap[$p]
    if (-not $cfg) { Write-Host "Unknown portal: $p — skipping" -ForegroundColor Yellow; continue }
    $portalDir = Join-Path $OutputRoot $p
    $null = New-Item -Path $portalDir -ItemType Directory -Force

    # Determine which YAML files to read for this portal. Some portals (intune, teams,
    # security-copilot, exchange, viva, m365-apps, sharepoint) ship a SINGLE openapi.yml
    # — others (defender, entra, purview, m365-admin, power-platform) ship sub-area
    # files alongside an aggregated openapi.yml. Include openapi.yml only when it's
    # the only YAML in the directory.
    $yamlFiles = @()
    $dirs = if ($cfg.ContainsKey('NodocDir')) { @($cfg.NodocDir) } else { $cfg.NodocDirs }
    foreach ($d in $dirs) {
        $dir = Join-Path $NodocRoot $d
        if (-not (Test-Path $dir)) { continue }
        $all = @(Get-ChildItem -Path $dir -Filter '*.yml' -File)
        $subAreaFiles = @($all | Where-Object { $_.BaseName -notin 'openapi','common' })
        if ($subAreaFiles.Count -gt 0) {
            $yamlFiles += $subAreaFiles
        } else {
            # Fallback: this dir only has openapi.yml — use it
            $yamlFiles += @($all | Where-Object { $_.BaseName -ne 'common' })
        }
    }

    Write-Host ""
    Write-Host "=== Portal: $p ===" -ForegroundColor Cyan
    if ($IndexOnly) {
        Write-Host "  IndexOnly mode — skipping probe + extraction." -ForegroundColor DarkGray
        continue
    }
    Write-Host "  Source YAML files: $($yamlFiles.Count)" -ForegroundColor DarkGray

    foreach ($yf in $yamlFiles) {
        $subArea = $yf.BaseName
        # Apply in-scope filter for defender + SubArea filter param
        if ($p -eq 'defender' -and $cfg.InScopeSubAreas -and $subArea -notin $cfg.InScopeSubAreas) { continue }
        if ($OnlySubArea -and $subArea -ne $OnlySubArea) { continue }

        $endpoints = Get-NodocPathsFromYaml -YamlPath $yf.FullName
        if ($endpoints.Count -eq 0) { continue }

        Write-Host "  [$p/$subArea] $($endpoints.Count) endpoints" -ForegroundColor Yellow
        foreach ($ep in $endpoints) {
            $liveResult = $null
            $portalSession = $portalSessions[$p]
            $pm = $portalMap[$p]
            if ($portalSession -and -not $NoLive) {
                $method = if ($ep.Methods.Count -gt 0) { ($ep.Methods | Select-Object -First 1).ToUpper() } else { 'GET' }
                if ($ep.Path -match '\{[^}]+\}') {
                    $liveResult = [pscustomobject]@{ HttpStatus=0; SuccessKind='no-live-pathparam'; RowCount=0; ErrorText="path-template; requires fanout"; ResponseShape=$null; Sample=$null }
                } elseif ($method -in 'PUT','DELETE','PATCH') {
                    $liveResult = [pscustomobject]@{ HttpStatus=0; SuccessKind="no-live-method-$method"; RowCount=0; ErrorText="$method endpoint; would mutate"; ResponseShape=$null; Sample=$null }
                } else {
                    $hdrs = @{}
                    if ($ep.Path -match '/mtp/tvm/') { $hdrs['api-version'] = '1.0' }
                    # Compose path with portal prefix
                    $portalPath = if ($pm.PathPrefix) { "$($pm.PathPrefix)$($ep.Path)" } else { $ep.Path }
                    $liveResult = Invoke-LiveProbe -Path $portalPath -Method $method -Session $portalSession -Headers $hdrs -PortalKey $p -BaseHost $pm.BaseHost
                    Start-Sleep -Milliseconds $LiveBatchDelayMs
                }
                $key = $liveResult.SuccessKind
                if (-not $liveCounts.ContainsKey($key)) { $liveCounts[$key] = 0 }
                $liveCounts[$key]++
            } else {
                $liveCounts['no-live']++
            }
            $null = Save-EndpointReference -PortalKey $p -SubAreaName $subArea -Endpoint $ep -LiveResult $liveResult
            $totalEndpoints++
        }
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total endpoints captured: $totalEndpoints"
foreach ($k in $liveCounts.Keys | Sort-Object) {
    if ($liveCounts[$k] -gt 0) {
        Write-Host ("    {0,-25} {1}" -f $k, $liveCounts[$k])
    }
}
Write-Host "  Output: $OutputRoot"

# ---------------------------------------------------------------------------
# Emit per-portal _INDEX.json + per-sub-area _SUBAREA.json indexes
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Building per-portal + per-sub-area indexes..." -ForegroundColor Cyan
foreach ($p in $portals) {
    $portalDir = Join-Path $OutputRoot $p
    if (-not (Test-Path $portalDir)) { continue }
    $subAreas = Get-ChildItem -Path $portalDir -Directory | Sort-Object Name
    $portalIndex = [ordered]@{
        portal       = $p
        authChain    = $script:AuthChainMap[$p]
        capturedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        subAreaCount = $subAreas.Count
        subAreas     = @()
    }
    foreach ($sa in $subAreas) {
        $endpoints = Get-ChildItem -Path $sa.FullName -Directory
        $saIndex = [ordered]@{
            subArea       = $sa.Name
            suggestedCadence = if ($script:CadenceMap.ContainsKey($sa.Name)) { $script:CadenceMap[$sa.Name] } else { 'unknown' }
            endpointCount = $endpoints.Count
            endpoints     = @()
        }
        $cntLive=0; $cntLiveEmpty=0; $cntErr=0; $cntNoLive=0; $cntTimeFilter=0; $cntPagination=0
        $allEntities = New-Object System.Collections.Generic.HashSet[string]
        $allPaginationStyles = New-Object System.Collections.Generic.HashSet[string]
        $needsResearch = New-Object System.Collections.Generic.List[string]
        foreach ($ep in $endpoints) {
            $metaPath = Join-Path $ep.FullName 'metadata.json'
            if (-not (Test-Path $metaPath)) { continue }
            $m = $null
            try { $m = Get-Content $metaPath -Raw | ConvertFrom-Json } catch { continue }
            if (-not $m) { continue }
            $hasLive = $null -ne $m.live
            $liveSK   = if ($hasLive) { [string]$m.live.successKind } else { 'no-live' }
            $liveSt   = if ($hasLive) { [int]$m.live.httpStatus    } else { 0 }
            $liveRows = if ($hasLive) { [int]$m.live.rowCount      } else { 0 }
            $v1S      = if ($m.v1Manifest) { [string]$m.v1Manifest.v1Stream } else { $null }
            $xdrCmd   = if ($m.operationalReference) { [string]$m.operationalReference.xdrInternalsCmdlet } else { '' }
            $epEntities = if ($m.entities) { @($m.entities) } else { @() }
            $saIndex.endpoints += [ordered]@{
                slug                = [string]$m.slug
                operationId         = [string]$m.operationId
                path                = [string]$m.path
                methods             = $m.methods
                paginationStyle     = [string]$m.pagination.style
                timeFilterSupported = [bool]$m.timeFilter.supported
                timeFilterParam     = if ($m.timeFilter.startParam) { [string]$m.timeFilter.startParam } elseif ($m.timeFilter.lookbackParam) { [string]$m.timeFilter.lookbackParam } else { $null }
                suggestedCadence    = [string]$m.suggestedCadence
                liveSuccessKind     = $liveSK
                liveHttpStatus      = $liveSt
                liveRowCount        = $liveRows
                v1Stream            = $v1S
                xdrInternalsCmdlet  = $xdrCmd
                entities            = $epEntities
                parsingNotes        = @($m.parsingNotes)
            }
            switch ($liveSK) {
                'live'       { $cntLive++ }
                'live-empty' { $cntLiveEmpty++ }
                'error'      { $cntErr++ }
                default      { $cntNoLive++ }
            }
            if ($m.timeFilter.supported)         { $cntTimeFilter++ }
            if ($m.pagination.style -ne 'none')  { $cntPagination++; [void]$allPaginationStyles.Add($m.pagination.style) }
            foreach ($e in $epEntities) { [void]$allEntities.Add($e) }
            # Surface endpoints that need design attention
            if ($liveSK -eq 'error' -and ($liveSt -in 400,403,404)) { $needsResearch.Add($m.slug) }
        }
        $saIndex.cntLive = $cntLive
        $saIndex.cntLiveEmpty = $cntLiveEmpty
        $saIndex.cntError = $cntErr
        $saIndex.cntNoLive = $cntNoLive
        $saIndex.cntWithTimeFilter = $cntTimeFilter
        $saIndex.cntWithPagination = $cntPagination
        $saIndex.entitiesAvailable = @($allEntities | Sort-Object)
        $saIndex.paginationStyles  = @($allPaginationStyles | Sort-Object)
        # Value-prop reflection (only Defender for now; v0.2.0 portals get added later)
        $valueProps = @{
            'action_center'='Audit + drift on automated investigation responses + pending operator approvals'
            'attack_simulator'='Phishing simulation campaigns + training completion telemetry'
            'cloud_apps'='MCAS app inventory + governance + shadow-IT discovery'
            'configuration'='Tenant-wide config drift (suppression rules, alert tuning, custom detections, RBAC, TI indicators) — the gap MS does NOT close'
            'data_lake'='Defender Data Lake state + AH data lifecycle'
            'endpoint_configuration'='ASR rules, AV policy bodies, Tamper Protection, EDR-block, WCF — endpoint posture drift'
            'endpoint_devices'='Device inventory with risk+exposure scores; foundation for cross-table joins (Host.MdatpId is the universal join key)'
            'entity_pivots'='Per-entity drill-down (operator-driven; cache for support)'
            'exposure_management'='XSPM attack paths + chokepoints + asset rules + posture metrics — proactive risk posture'
            'files'='File prevalence + reputation (forensic context for incidents)'
            'identity'='MDI surface: DSA, DC sensor coverage, dormant accounts, lateral movement, alert thresholds'
            'multi_tenant'='MTO tenant inventory + workload status (MSSP-grade visibility)'
            'portal_services'='Portal-side service state (rarely-changed informational)'
            'secure_score'='Per-category secure score breakdown + historical trend (DCSPM, TVM SCA, V2 control profiles)'
            'sentinel_precision'='Sentinel-Defender integration state'
            'streaming'='Streaming API destinations (audit data egress)'
            'threat_analytics'='Threat outbreaks + enriched data + top threats (proactive intel correlation)'
            'vulnerability_management'='CVE inventory + software inventory + recommendations + advisories — TVM drift'
        }
        if ($valueProps.ContainsKey($sa.Name)) { $saIndex.valueProp = $valueProps[$sa.Name] }
        $saIndex | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $sa.FullName '_SUBAREA.json')
        $portalIndex.subAreas += [ordered]@{
            subArea         = $sa.Name
            endpointCount   = $endpoints.Count
            cntLive         = $cntLive
            cntLiveEmpty    = $cntLiveEmpty
            cntError        = $cntErr
            cntNoLive       = $cntNoLive
            cntWithTimeFilter = $cntTimeFilter
            cntWithPagination = $cntPagination
            suggestedCadence  = $saIndex.suggestedCadence
            entitiesAvailable = $saIndex.entitiesAvailable
            paginationStyles  = $saIndex.paginationStyles
            valueProp         = $saIndex.valueProp
        }
    }
    $portalIndex | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $portalDir '_PORTAL.json')
    Write-Host ("  Indexed: {0} ({1} sub-areas)" -f $p, $portalIndex.subAreas.Count)
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "  References: $OutputRoot"
Write-Host "  Per-portal index:  <portal>/_PORTAL.json"
Write-Host "  Per-sub-area index: <portal>/<sub-area>/_SUBAREA.json"
