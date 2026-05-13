# Finalize-CatalogueWithNodocAuth.ps1
#
# Consolidation pass — replaces my made-up auth descriptions with nodoc's official
# 12 auth patterns from https://nodoc.nathanmcnulty.com/getting-started, and
# references each portal's checked-in Postman collection (at .internal/nodoc-reference/postman/collections/).
#
# Also enriches each sub-area with production-scale considerations
# (pagination-at-scale, delta-poll need, rate-limit risk per cadence).

#Requires -Version 7.0
[CmdletBinding()] param(
    [string]$ReferencesRoot = "$PSScriptRoot\..\references"
)

# nodoc's official 12 auth patterns (from getting-started page, verified 2026-05-12)
# Each entry: pattern name + transport (cookie/bearer) + browser-acquired? + headers needed
$nodocAuthPatterns = @{
    'defender'         = @{ Pattern='Portal session cookies';                  Transport='cookie';  BrowserAcquired=$false; Cookies=@('sccauth','XSRF-TOKEN'); Headers=@('X-XSRF-TOKEN'); PostmanCollection='defender.collection.json'; UnattendedTotpCompatible=$true }
    'purview'          = @{ Pattern='Portal session cookies';                  Transport='cookie';  BrowserAcquired=$false; Cookies=@('sccauth','XSRF-TOKEN'); Headers=@('X-XSRF-TOKEN'); PostmanCollection='purview.collection.json'; UnattendedTotpCompatible=$true }
    'purview-portal'   = @{ Pattern='Portal session + same-origin context (Purview Portal)'; Transport='cookie+downstream-bearer'; BrowserAcquired=$false; Cookies=@('sccauth'); Headers=@('X-XSRF-TOKEN'); Note='Bootstrap state mints downstream bearer tokens for /api/ calls'; PostmanCollection='purview-portal.collection.json'; UnattendedTotpCompatible=$true }
    'exchange'         = @{ Pattern='Portal session + same-origin XHR (Exchange)'; Transport='cookie+xhr-header'; BrowserAcquired=$false; Cookies=@('.AspNetCore.Cookies'); Headers=@('x-requested-with: XMLHttpRequest'); PostmanCollection='exchange-beta.collection.json'; UnattendedTotpCompatible=$true; Note='Out-of-scope per project — Graph covers programmatic surface' }
    'm365-admin'       = @{ Pattern='Portal session + custom headers (M365 Admin)'; Transport='cookie+custom-headers'; BrowserAcquired=$true;  Cookies=@('OIDC-cookies'); Headers=@('AjaxSessionKey','portal-routing-headers','hosting-headers'); Note='AjaxSessionKey + routing/hosting headers extracted from admin shell at session-init'; PostmanCollection='m365-admin.collection.json'; UnattendedTotpCompatible=$false }
    'sharepoint'       = @{ Pattern='Portal session + SharePoint digest';     Transport='cookie+digest-header'; BrowserAcquired=$false; Cookies=@('FedAuth','rtFa'); Headers=@('x-requestdigest','SdkVersion','odata-version'); Host='{tenant}-admin.sharepoint.com'; PostmanCollection='sharepoint-admin.collection.json'; UnattendedTotpCompatible=$true; Note='Cookie flow similar to Defender; SharePoint digest required for POST/PUT/DELETE only' }
    'teams'            = @{ Pattern='Portal bearer tokens + regional discovery'; Transport='bearer'; BrowserAcquired=$true; Headers=@('Authorization: Bearer'); Note='Browser-acquired bearer per service host; same-origin /api/log + resolver calls map tenant to regional backend'; PostmanCollection='teams.collection.json'; UnattendedTotpCompatible=$false }
    'viva'             = @{ Pattern='MSAL PKCE bearer + same-origin GraphQL (Viva Engage)'; Transport='bearer+graphql'; BrowserAcquired=$true; Note='MSAL PKCE with user_impersonation scope; GraphQL on engage.cloud.microsoft + Bayeux relay; auth in handshake body not Authorization header'; PostmanCollection='viva-engage.collection.json'; UnattendedTotpCompatible=$false }
    'm365-apps-config' = @{ Pattern='Portal bearer tokens + diagnostic headers'; Transport='bearer+diag-headers'; BrowserAcquired=$true; Headers=@('Authorization: Bearer','x-api-name','x-correlationid','x-manageoffice-client-sid','x-requested-with'); PostmanCollection='m365-apps-config.collection.json'; UnattendedTotpCompatible=$false }
    'm365-apps-inventory' = @{ Pattern='Portal bearer tokens + diagnostic headers'; Transport='bearer+diag-headers'; BrowserAcquired=$true; Headers=@('Authorization: Bearer','x-api-name','x-correlationid','x-manageoffice-client-sid'); PostmanCollection='m365-apps-inventory.collection.json'; UnattendedTotpCompatible=$false }
    'm365-apps-services'  = @{ Pattern='Portal bearer tokens + diagnostic headers'; Transport='bearer+diag-headers'; BrowserAcquired=$true; Headers=@('Authorization: Bearer'); PostmanCollection='m365-apps-services.collection.json'; UnattendedTotpCompatible=$false }
    'intune-portal'    = @{ Pattern='Portal bearer tokens (Intune)';          Transport='bearer'; BrowserAcquired=$true; PostmanCollection='intune-portal.collection.json'; UnattendedTotpCompatible=$false }
    'intune-autopatch' = @{ Pattern='Portal bearer tokens (Intune Autopatch)';Transport='bearer'; BrowserAcquired=$true; Note='Same as intune-portal — Bearer token acquired via Intune admin MSAL flow, scoped to services.autopatch.microsoft.com'; PostmanCollection='intune-autopatch.collection.json'; UnattendedTotpCompatible=$false }
    'entra-ibiza-iam'  = @{ Pattern='Delegated OAuth2 (Entra IAM / ADIbizaUX)'; Transport='bearer'; BrowserAcquired=$true; Headers=@('Authorization: Bearer','X-Ms-Client-Request-Id'); Note='ADIbizaUX resource via Azure-portal MSAL flow'; PostmanCollection='entra-iam.collection.json'; UnattendedTotpCompatible=$false }
    'entra-pim'        = @{ Pattern='Azure AD bearer tokens (PIM)';            Transport='bearer'; BrowserAcquired=$true; Host='api.azrbac.mspim.azure.com'; PostmanCollection='entra-pim.collection.json'; UnattendedTotpCompatible=$false }
    'entra-b2c'        = @{ Pattern='Azure AD bearer tokens (B2C)';            Transport='bearer'; BrowserAcquired=$true; Host='main.b2cadmin.ext.azure.com'; PostmanCollection='entra-b2c.collection.json'; UnattendedTotpCompatible=$false }
    'entra-iga'        = @{ Pattern='Azure AD bearer tokens (IGA)';            Transport='bearer'; BrowserAcquired=$true; Host='elm.iga.azure.com'; PostmanCollection='entra-iga.collection.json'; UnattendedTotpCompatible=$false }
    'entra-idgov'      = @{ Pattern='Azure AD bearer tokens (IDGov/Access Reviews)'; Transport='bearer'; BrowserAcquired=$true; Host='api.accessreviews.identitygovernance.azure.com'; PostmanCollection='entra-idgov.collection.json'; UnattendedTotpCompatible=$false }
    'power-platform'   = @{ Pattern='Service-specific audiences (Power Platform)'; Transport='bearer-multi-audience'; BrowserAcquired=$true; Note='Different bearer audiences per backend; per-tenant host overrides'; PostmanCollection='power-platform.collection.json'; UnattendedTotpCompatible=$false }
    'security-copilot' = @{ Pattern='Portal bearer tokens (Security Copilot)';  Transport='bearer'; BrowserAcquired=$true; Note='Backend at api.securitycopilot.microsoft.com + api.medeina-ppe.defender.microsoft.com'; PostmanCollection='security-copilot.collection.json'; UnattendedTotpCompatible=$false }
}

# Production-scale considerations per Defender sub-area (extends to other portals later)
$productionScale = @{
    'defender' = @{
        'action_center'           = @{ ExpectedRowsPerHour='100s-1000s'; PaginationStrategy='pageIndex with size=200; loop until empty page'; DeltaPoll='SUPPORTED — sortBy + EventTime fields enable client-side delta'; RateLimitRisk='LOW (event-shaped, server paginates)' }
        'attack_simulator'        = @{ ExpectedRowsPerHour='10s-100s'; PaginationStrategy='page-based'; DeltaPoll='snapshot-only'; RateLimitRisk='LOW' }
        'cloud_apps'              = @{ ExpectedRowsPerHour='10K+ for large tenants (apps + activities)'; PaginationStrategy='continuationToken (MCAS-specific)'; DeltaPoll='SUPPORTED — startDateTime + endDateTime'; RateLimitRisk='HIGH if not delta-polling (MCAS audit volume)' }
        'configuration'           = @{ ExpectedRowsPerHour='100s (config inventory; rarely changes)'; PaginationStrategy='pageIndex0Based; small pages'; DeltaPoll='snapshot — drift detected query-side via KQL'; RateLimitRisk='LOW' }
        'data_lake'               = @{ ExpectedRowsPerHour='varies; data-lake state'; PaginationStrategy='varies'; DeltaPoll='snapshot'; RateLimitRisk='LOW' }
        'endpoint_configuration'  = @{ ExpectedRowsPerHour='100s (policy bodies)'; PaginationStrategy='pageIndex1Based; PerPlatformFanout for Intune endpoint-security'; DeltaPoll='snapshot'; RateLimitRisk='LOW' }
        'endpoint_devices'        = @{ ExpectedRowsPerHour='10K-1M for large tenants (Machines × inventory)'; PaginationStrategy='pageIndex1Based + lookbackInDays=30; respect max pageSize=200'; DeltaPoll='lookbackInDays parameter — daily delta supported'; RateLimitRisk='HIGH (foundational stream; large tenant could hit 429 on initial poll)' }
        'entity_pivots'           = @{ ExpectedRowsPerHour='operator-driven (cache)'; PaginationStrategy='per-entity'; DeltaPoll='n/a — driven by drill-down'; RateLimitRisk='LOW' }
        'exposure_management'     = @{ ExpectedRowsPerHour='1K-10K (XSPM graph + posture metrics)'; PaginationStrategy='pageIndex0Based for posture metrics; POST + scenario header for attack-surface graph'; DeltaPoll='snapshot (XSPM is graph; full snapshot per hour)'; RateLimitRisk='MEDIUM' }
        'files'                   = @{ ExpectedRowsPerHour='10K+ (file prevalence; SHA-keyed)'; PaginationStrategy='per-hash'; DeltaPoll='snapshot per file'; RateLimitRisk='MEDIUM' }
        'identity'                = @{ ExpectedRowsPerHour='100s-1000s (MDI inventory; depends on directory size)'; PaginationStrategy='none for most aatp/ endpoints'; DeltaPoll='newEntryCount endpoints are delta-by-design'; RateLimitRisk='LOW' }
        'multi_tenant'            = @{ ExpectedRowsPerHour='10s (MTO inventory)'; PaginationStrategy='none'; DeltaPoll='snapshot'; RateLimitRisk='LOW' }
        'portal_services'         = @{ ExpectedRowsPerHour='1s-10s'; PaginationStrategy='none'; DeltaPoll='snapshot'; RateLimitRisk='LOW' }
        'secure_score'            = @{ ExpectedRowsPerHour='100s (per-category breakdown)'; PaginationStrategy='none'; DeltaPoll='snapshot — daily change rate'; RateLimitRisk='LOW' }
        'sentinel_precision'      = @{ ExpectedRowsPerHour='varies'; PaginationStrategy='varies'; DeltaPoll='varies'; RateLimitRisk='LOW' }
        'streaming'               = @{ ExpectedRowsPerHour='1s (config inventory)'; PaginationStrategy='none'; DeltaPoll='snapshot'; RateLimitRisk='LOW' }
        'threat_analytics'        = @{ ExpectedRowsPerHour='100s (outbreaks); 1Ks (enriched)'; PaginationStrategy='pageIndex0Based'; DeltaPoll='snapshot; threat-intel feed'; RateLimitRisk='LOW' }
        'vulnerability_management'= @{ ExpectedRowsPerHour='1K-100K for large tenants (CVE inventory + software inventory)'; PaginationStrategy='pageIndex0Based AND 1Based mixed; api-version=1.0 required for some; pageSize=200'; DeltaPoll='snapshot — full inventory per day'; RateLimitRisk='HIGH (TVM endpoints are paginated heavy)' }
    }
}

# Walk + update
$portalDirs = Get-ChildItem -Path $ReferencesRoot -Directory
foreach ($pd in $portalDirs) {
    $portalKey = $pd.Name
    $authPattern = $nodocAuthPatterns[$portalKey]
    if (-not $authPattern) { continue }

    $piPath = Join-Path $pd.FullName '_PORTAL.json'
    if (-not (Test-Path $piPath)) { continue }
    try {
        $pi = Get-Content $piPath -Raw | ConvertFrom-Json -Depth 30
    } catch { continue }

    # Replace authFinding with nodoc-authoritative pattern
    $pi | Add-Member -NotePropertyName 'authPattern' -NotePropertyValue ([ordered]@{
        nodocOfficialName        = $authPattern.Pattern
        transport                = $authPattern.Transport
        browserAcquired          = $authPattern.BrowserAcquired
        unattendedTotpCompatible = $authPattern.UnattendedTotpCompatible
        cookies                  = $authPattern.Cookies
        headers                  = $authPattern.Headers
        note                     = $authPattern.Note
        postmanCollection        = "..\..\xdrlograider\.internal\nodoc-reference\postman\collections\$($authPattern.PostmanCollection)"
        nodocReference           = 'https://nodoc.nathanmcnulty.com/getting-started'
    }) -Force

    # Production-scale per sub-area (Defender for now)
    if ($productionScale.ContainsKey($portalKey)) {
        $scale = $productionScale[$portalKey]
        if ($pi.subAreas) {
            $newSubAreas = @()
            foreach ($s in $pi.subAreas) {
                $newS = $s | Select-Object *
                if ($scale.ContainsKey($s.subArea)) {
                    $newS | Add-Member -NotePropertyName 'productionScale' -NotePropertyValue $scale[$s.subArea] -Force
                }
                $newSubAreas += $newS
            }
            $pi | Add-Member -NotePropertyName 'subAreas' -NotePropertyValue $newSubAreas -Force
        }
    }

    $pi | ConvertTo-Json -Depth 30 | Set-Content $piPath
}

Write-Host "=== Final consolidation complete ===" -ForegroundColor Cyan
Write-Host "  Authoritative auth patterns applied (nodoc getting-started, 12 patterns across 20 portals)"
Write-Host "  Postman collections referenced per portal"
Write-Host "  Production-scale considerations attached to Defender sub-areas"
Write-Host ""
Write-Host "=== Per-portal auth viability for unattended TOTP ===" -ForegroundColor Cyan
foreach ($pd in $portalDirs) {
    $pi = Get-Content (Join-Path $pd.FullName '_PORTAL.json') -Raw | ConvertFrom-Json -Depth 30
    if ($pi.authPattern) {
        $ok = if ($pi.authPattern.unattendedTotpCompatible) { 'YES' } else { 'NO (browser-acquired bearer)' }
        '{0,-22} unattended-TOTP-compat: {1,-30}  pattern: {2}' -f $pd.Name, $ok, $pi.authPattern.nodocOfficialName | Write-Host
    }
}
