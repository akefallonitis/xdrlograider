# Build-AuthResearchCatalogue.ps1
#
# Phase 0 deliverable: mine nodoc (OpenAPI specs + Postman collections + getting-started auth model)
# for every portal in the catalogue, and write a consolidated _AUTH_RESEARCH.json per portal
# documenting everything needed to support BOTH unattended TOTP and Passkey methods.
#
# Goal: SA UPN + (TOTP | Passkey JSON) -> all portal endpoints, unattended, refresh-token-renewed
# every ~85 days. No SP, no Graph dependency, no browser at runtime.
#
# Sources (text-only, no live calls):
#   - .internal/nodoc-reference/specifications/nodoc-<portal>/specification/*.yml (OpenAPI servers + security)
#   - .internal/nodoc-reference/postman/collections/<portal>.collection.json (auth + variables + headers)
#   - .internal/nodoc-reference/src/data/siteData.ts (gettingStartedGuides + accessModels)
#   - xdrlograider/src/Modules/Xdr.Common.Auth/* (proven auth chain capabilities)

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$NodocRoot     = "$PSScriptRoot\..\..\xdrlograider\.internal\nodoc-reference",
    [string]$ReferencesRoot = "$PSScriptRoot\..\references"
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Portal -> nodoc directory + collection mapping
# ---------------------------------------------------------------------------
$portalMap = @{
    'defender'             = @{ NodocDir='nodoc-defender-xdr';        Collection='defender.collection.json' }
    'purview'              = @{ NodocDir='nodoc-purview';             Collection='purview.collection.json' }
    'purview-portal'       = @{ NodocDir='nodoc-purview-portal';      Collection='purview-portal.collection.json' }
    'exchange'             = @{ NodocDir='nodoc-exchange-beta';       Collection='exchange-beta.collection.json' }
    'sharepoint'           = @{ NodocDir='nodoc-sharepoint-admin';    Collection='sharepoint-admin.collection.json' }
    'm365-admin'           = @{ NodocDir='nodoc-m365-admin';          Collection='m365-admin.collection.json' }
    'intune-portal'        = @{ NodocDir='nodoc-intune-portal';       Collection='intune-portal.collection.json' }
    'intune-autopatch'     = @{ NodocDir='nodoc-intune-autopatch';    Collection='intune-autopatch.collection.json' }
    'security-copilot'     = @{ NodocDir='nodoc-security-copilot';    Collection='security-copilot.collection.json' }
    'teams'                = @{ NodocDir='nodoc-teams';               Collection='teams.collection.json' }
    'viva'                 = @{ NodocDir='nodoc-viva-engage';         Collection='viva-engage.collection.json' }
    'power-platform'       = @{ NodocDir='nodoc-power-platform';      Collection='power-platform.collection.json' }
    'm365-apps-config'     = @{ NodocDir='nodoc-m365-apps-config';    Collection='m365-apps-config.collection.json' }
    'm365-apps-services'   = @{ NodocDir='nodoc-m365-apps-services';  Collection='m365-apps-services.collection.json' }
    'm365-apps-inventory'  = @{ NodocDir='nodoc-m365-apps-inventory'; Collection='m365-apps-inventory.collection.json' }
    'entra-ibiza-iam'      = @{ NodocDir='nodoc-ibiza-iam';           Collection='entra-iam.collection.json' }
    'entra-pim'            = @{ NodocDir='nodoc-entra-pim';           Collection='entra-pim.collection.json' }
    'entra-iga'            = @{ NodocDir='nodoc-entra-iga';           Collection='entra-iga.collection.json' }
    'entra-idgov'          = @{ NodocDir='nodoc-entra-idgov';         Collection='entra-idgov.collection.json' }
    'entra-b2c'            = @{ NodocDir='nodoc-entra-b2c';           Collection='entra-b2c.collection.json' }
}

# Known authoritative findings (from nodoc + v1 + this session's live-probe evidence)
$authoritativeFindings = @{
    'defender'         = @{ Bucket='A-cookie'; ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; PortalHost='security.microsoft.com'; CookieNames=@('sccauth','XSRF-TOKEN'); Audience='(cookie-based, no audience)'; UnattendedStatus='proven-v1-production-live' }
    'purview'          = @{ Bucket='A-cookie'; ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; PortalHost='purview.microsoft.com'; CookieNames=@('sccauth','XSRF-TOKEN'); Audience='(cookie-based, no audience)'; UnattendedStatus='proven-v1-and-session' }
    'purview-portal'   = @{ Bucket='A-cookie+silent-token'; ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; PortalHost='purview.microsoft.com'; CookieNames=@('sccauth'); Audience='same-origin /api/Auth/getToken mints downstream'; UnattendedStatus='auth-chain-proven; same-origin-token-mint-pending' }
    'exchange'         = @{ Bucket='A-cookie'; ClientId='4765445b-32c6-49b0-83e6-1d93765276ca'; PortalHost='admin.exchange.microsoft.com'; CookieNames=@('.AspNetCore.Cookies','ASLBSA','ASLBSACORS'); Audience='(cookie-based, no audience)'; RequiredHeaders=@('x-requested-with: XMLHttpRequest'); UnattendedStatus='proven-session-16-live-endpoints' }
    'sharepoint'       = @{ Bucket='A-cookie+digest'; ClientId='TBD-discover-from-tenant-admin-spo-bundle'; PortalHost='{tenant}-admin.sharepoint.com'; CookieNames=@('FedAuth','rtFa'); Audience='(cookie-based)'; RequiredHeaders=@('x-requestdigest: <ContextInfo>','SdkVersion','odata-version'); UnattendedStatus='auth-chain-pattern-known; tenant-host + digest pending' }
    'm365-admin'       = @{ Bucket='A-cookie+B-bearer-hybrid'; ClientId='4765445b-32c6-49b0-83e6-1d93765276ca'; PortalHost='admin.cloud.microsoft'; CookieNames=@('RpsContextCookie','AjaxSessionKey'); Audience='https://admin.microsoft.com'; RequiredHeaders=@('AjaxSessionKey','x-portal-routekey','x-adminapp-request','x-ms-mac-appid (blade-specific)','x-ms-mac-hostingapp'); UnattendedStatus='cookie-chain-works-via-Exchange-client; bearer-side pending audience' }
    'intune-portal'    = @{ Bucket='B-bearer'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; PortalHost='intune.microsoft.com'; Audience='TBD: try https://intune.microsoft.com, https://api.manage.microsoft.com, or use existing Intune-service-API resource'; RequiredHeaders=@('x-ms-client-request-id (guid)','x-ms-client-session-id','x-ms-extension-flags','x-requested-with: XMLHttpRequest'); UnattendedStatus='session-proven-auth-chain-end-to-end; code+access_token+refresh_token obtained; API audience TBD' }
    'intune-autopatch' = @{ Bucket='B-bearer'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely'; PortalHost='services.autopatch.microsoft.com'; Audience='https://services.autopatch.microsoft.com'; RequiredHeaders=@('TBD from Postman'); UnattendedStatus='auth-chain-pattern-shared-with-intune; audience known' }
    'security-copilot' = @{ Bucket='B-bearer-multi-host'; ClientId='TBD-extract-from-next-js-bundle'; PortalHost='securitycopilot.microsoft.com'; ApiHosts=@('api.securitycopilot.microsoft.com','api.securityplatform.microsoft.com','us.api.securityplatform.microsoft.com','prod.cds.securitycopilot.microsoft.com'); Audience='TBD per host'; UnattendedStatus='auth-chain-pattern-known; multi-host audience discovery pending' }
    'teams'            = @{ Bucket='B-bearer-regional'; ClientId='TBD-from-msftauth-bundle'; PortalHost='admin.teams.microsoft.com'; ApiHosts=@('admin.teams.microsoft.com','teams.microsoft.com','api.interfaces.records.teams.microsoft.com','monitoringplatform.teams.microsoft.com'); Audience='TBD via regional discovery: POST /api/authsvc/v1.0/users/region'; UnattendedStatus='auth-chain-pattern-known; regional-discovery step required' }
    'viva'             = @{ Bucket='B-bearer-PKCE+Bayeux'; ClientId='TBD-yammer-msal-pkce-client'; PortalHost='engage.cloud.microsoft'; Audience='https://www.yammer.com/user_impersonation'; UnattendedStatus='scope-known; client discovery + Bayeux relay handshake pending' }
    'power-platform'   = @{ Bucket='B-bearer-multi-audience'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely'; PortalHost='admin.powerplatform.microsoft.com'; ApiHosts=@('api.bap.microsoft.com','api.admin.powerplatform.microsoft.com','{region}.adminanalytics.powerplatform.microsoft.com','licensing.powerplatform.microsoft.com','{tenantHost}.tenant.api.powerplatform.com','{organizationHost}.crm.dynamics.com','{portalInfraHost}.portal-infra.dynamics.com'); Audience='per-host: bap=https://api.bap.microsoft.com; dynamics=https://{org}.crm.dynamics.com'; UnattendedStatus='multi-audience pattern known; per-host audience map pending' }
    'm365-apps-config' = @{ Bucket='B-bearer'; ClientId='TBD-from-bundle'; PortalHost='config.office.com'; Audience='TBD'; RequiredHeaders=@('x-api-name','x-correlationid (guid)','x-manageoffice-client-sid','x-requested-with: XMLHttpRequest'); UnattendedStatus='headers known; client + audience pending' }
    'm365-apps-services'= @{ Bucket='B-bearer'; ClientId='TBD-from-bundle'; PortalHost='clients.config.office.net'; Audience='TBD'; RequiredHeaders=@('x-api-name','x-correlationid','x-manageoffice-client-sid','x-requested-with'); UnattendedStatus='same as m365-apps-config' }
    'm365-apps-inventory'=@{ Bucket='B-bearer'; ClientId='TBD-from-bundle'; PortalHost='query.inventory.insights.office.net'; Audience='TBD'; RequiredHeaders=@('x-api-name','x-correlationid','x-manageoffice-client-sid','x-requested-with'); UnattendedStatus='same as m365-apps-config' }
    'entra-ibiza-iam'  = @{ Bucket='C-azure-ad-bearer'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; PortalHost='entra.microsoft.com'; ApiHost='main.iam.ad.ext.azure.com'; Audience='74658136-14ec-4630-ad9b-26e160ff0fc6'; AudienceName='ADIbizaUX'; RequiredHeaders=@('X-Ms-Client-Request-Id (guid)'); UnattendedStatus='FULLY-PROVEN-LIVE-JSON-DATA-RETURNED this session' }
    'entra-pim'        = @{ Bucket='C-azure-ad-bearer'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely'; PortalHost='entra.microsoft.com'; ApiHost='api.azrbac.mspim.azure.com'; Audience='https://api.azrbac.mspim.azure.com'; UnattendedStatus='audience known from nodoc; client likely shared with Entra IAM' }
    'entra-iga'        = @{ Bucket='C-azure-ad-bearer'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely'; PortalHost='entra.microsoft.com'; ApiHost='elm.iga.azure.com'; Audience='https://elm.iga.azure.com'; UnattendedStatus='audience known; client likely shared' }
    'entra-idgov'      = @{ Bucket='C-azure-ad-bearer'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely'; PortalHost='entra.microsoft.com'; ApiHost='api.accessreviews.identitygovernance.azure.com'; Audience='https://api.accessreviews.identitygovernance.azure.com'; UnattendedStatus='audience known; client likely shared' }
    'entra-b2c'        = @{ Bucket='C-azure-ad-bearer'; ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely'; PortalHost='entra.microsoft.com'; ApiHost='main.b2cadmin.ext.azure.com'; Audience='https://main.b2cadmin.ext.azure.com'; RequiredQueryParams=@('tenantId (guid or domain)'); UnattendedStatus='audience known; tenantId query param required per nodoc' }
}

# ---------------------------------------------------------------------------
# Extract OpenAPI servers from a portal's specification directory
# ---------------------------------------------------------------------------
function Get-NodocOpenApiServers {
    param([string]$SpecDir)
    if (-not (Test-Path $SpecDir)) { return @() }
    $servers = @{}
    Get-ChildItem -Path $SpecDir -Filter '*.yml' -File | ForEach-Object {
        $inServers = $false
        $content = Get-Content $_.FullName
        for ($i = 0; $i -lt $content.Count; $i++) {
            $line = $content[$i]
            if ($line -match '^servers\s*:\s*$') { $inServers = $true; continue }
            if ($inServers) {
                if ($line -match '^\S') { $inServers = $false; continue }
                if ($line -match '^\s+-?\s*url\s*:\s*[''"]?([^''"\s]+)[''"]?') { $servers[$matches[1]] = 1 }
            }
        }
    }
    return @($servers.Keys | Sort-Object)
}

# ---------------------------------------------------------------------------
# Extract Postman collection auth + variables
# ---------------------------------------------------------------------------
function Get-PostmanAuth {
    param([string]$CollectionPath)
    if (-not (Test-Path $CollectionPath)) { return $null }
    try {
        $c = Get-Content $CollectionPath -Raw | ConvertFrom-Json
        $authBlock = @{ type = $c.auth.type }
        if ($c.auth.bearer) { $authBlock.bearerToken = @($c.auth.bearer | Select-Object -ExpandProperty value -First 1) -join '' }
        if ($c.auth.apikey) { $authBlock.apikey = $c.auth.apikey }
        $vars = @{}
        if ($c.variable) { foreach ($v in $c.variable) { $vars[$v.key] = $v.value } }
        # Sample one request to capture characteristic headers
        $sampleHeaders = @{}
        function Get-FirstRequest($n) {
            if ($n -is [array]) { foreach ($it in $n) { $r = Get-FirstRequest $it; if ($r) { return $r } } }
            elseif ($n.request) { return $n }
            elseif ($n.item) { return (Get-FirstRequest $n.item) }
            return $null
        }
        $firstReq = Get-FirstRequest $c.item
        if ($firstReq -and $firstReq.request.header) {
            foreach ($h in $firstReq.request.header | Select-Object -First 10) {
                $sampleHeaders[$h.key] = $h.value
            }
        }
        return @{
            auth = $authBlock
            variables = $vars
            sampleHeaders = $sampleHeaders
            sampleRequestName = if ($firstReq) { $firstReq.name } else { $null }
        }
    } catch {
        return @{ error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# Build the consolidated _AUTH_RESEARCH.json per portal
# ---------------------------------------------------------------------------
$summary = @()
foreach ($portal in $portalMap.Keys | Sort-Object) {
    Write-Host "=== $portal ===" -ForegroundColor Cyan
    $cfg = $portalMap[$portal]

    $specDir = Join-Path $NodocRoot "specifications/$($cfg.NodocDir)/specification"
    $collectionPath = Join-Path $NodocRoot "postman/collections/$($cfg.Collection)"

    $servers = Get-NodocOpenApiServers -SpecDir $specDir
    $postman = Get-PostmanAuth -CollectionPath $collectionPath
    $authoritative = $authoritativeFindings[$portal]

    $outDir = Join-Path $ReferencesRoot $portal
    if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }

    $research = [ordered]@{
        portal                = $portal
        catalogue             = @{
            nodocDir            = $cfg.NodocDir
            postmanCollection   = $cfg.Collection
            specPaths           = if (Test-Path $specDir) { (Get-ChildItem -Path $specDir -Filter '*.yml' -File).Count } else { 0 }
            openApiServerUrls   = $servers
        }
        authModel             = if ($authoritative) { @{
            bucket                = $authoritative.Bucket
            clientId              = $authoritative.ClientId
            portalHost            = $authoritative.PortalHost
            apiHost               = $authoritative.ApiHost
            apiHosts              = $authoritative.ApiHosts
            audience              = $authoritative.Audience
            audienceName          = $authoritative.AudienceName
            cookieNames           = $authoritative.CookieNames
            requiredHeaders       = $authoritative.RequiredHeaders
            requiredQueryParams   = $authoritative.RequiredQueryParams
        } } else { @{ unknown = $true } }
        postmanFindings       = $postman
        unattendedAuth        = @{
            totpSupported       = $true                                    # via v1 Complete-CredentialsFlow (RFC 6238)
            passkeySupported    = $true                                    # via v1 Complete-PasskeyFlow (W3C WebAuthn L2 §7.2 ECDSA-P256)
            conditionalAccess   = @{
                requireMfa                       = 'TOTP and Passkey both pass'
                requirePhishingResistantMfa      = 'TOTP FAILS; Passkey passes (FIDO2 satisfies)'
                requireCompliantDevice           = 'Both FAIL; operator must exclude SA from this policy'
                requireHybridJoin                = 'Both FAIL; operator must exclude SA from this policy'
                blockLegacyAuth                  = 'Both pass (modern flow)'
            }
            estsauthpersistent  = @{
                description     = 'Microsoft KMSI cookie issued at LoginOptions=1 via Resolve-EntraInterruptPage'
                lifetime        = '90 days'
                useForSilentRenewal = '/oauth2/v2.0/authorize?prompt=none uses ESTSAUTHPERSISTENT for SSO, mints fresh code without TOTP'
            }
            refreshToken        = @{
                description     = 'Issued when scope contains offline_access; renews access_token silently'
                lifetime        = '~90 days (mirrors KMSI)'
                grant           = 'POST /oauth2/v2.0/token grant_type=refresh_token'
                originHeader    = 'Required for SPA client_id types per AADSTS9002327'
            }
            reauthCadence       = @{
                bootstrap       = 'Once per portal per ~85 days (TOTP or Passkey)'
                steadyState     = 'Refresh access_token every ~50 min via refresh_token (NO TOTP)'
                comparedToV1    = 'v1 does full TOTP-MFA every 50 min (sccauth ~1h life). v2 keeps ESTSAUTHPERSISTENT 90d, silent renewal between bootstraps.'
            }
            sccauthNote         = 'sccauth cookie itself is ~1h life. Renew via silent /authorize+prompt=none using ESTSAUTHPERSISTENT (not via fresh TOTP every cycle).'
        }
        unattendedStatus      = if ($authoritative) { $authoritative.UnattendedStatus } else { 'unknown' }
        kvSecretSchema        = @{
            description = 'Per-portal KV secrets following v1''s mde-portal-* pattern'
            secrets     = @(
                @{ name="$portal-upn";       purpose='Service account UPN'; required=$true }
                @{ name="$portal-password";  purpose='SA password';         required='CredentialsTotp method only' }
                @{ name="$portal-totp";      purpose='Base32 TOTP secret';  required='CredentialsTotp method only' }
                @{ name="$portal-passkey";   purpose='JSON {upn,credentialId,privateKeyPem,rpId}'; required='Passkey method only' }
                @{ name="$portal-refresh";   purpose='Long-lived refresh_token (Bearer portals)'; required='Steady-state polling' }
            )
        }
        generatedUtc          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $outFile = Join-Path $outDir '_AUTH_RESEARCH.json'
    $research | ConvertTo-Json -Depth 12 | Set-Content -Path $outFile
    Write-Host "  Written: $outFile"

    $summary += [pscustomobject]@{
        Portal             = $portal
        Bucket             = if ($authoritative) { $authoritative.Bucket } else { 'unknown' }
        ClientIdStatus     = if ($authoritative.ClientId -match 'TBD') { 'PENDING' } elseif ($authoritative.ClientId) { 'KNOWN' } else { '-' }
        AudienceStatus     = if ($authoritative.Audience -match 'TBD') { 'PENDING' } elseif ($authoritative.Audience) { 'KNOWN' } else { '-' }
        UnattendedStatus   = if ($authoritative) { $authoritative.UnattendedStatus } else { '-' }
        SpecFileCount      = $research.catalogue.specPaths
        OpenApiServerCount = $servers.Count
    }
}

Write-Host ""
Write-Host "=== Catalogue summary ===" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

# ---------------------------------------------------------------------------
# Write master findings index (Markdown) — NOT a doc, an operator-facing
# research consolidation deliverable per Phase 0
# ---------------------------------------------------------------------------
$indexPath = Join-Path $ReferencesRoot '_AUTH_INDEX.md'
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
$md = @()
$md += "# Auth research consolidation — Phase 0 deliverable"
$md += ""
$md += "Generated: $now UTC. Sources: nodoc OpenAPI specs + Postman collections + getting-started auth models + v1 Xdr.Common.Auth + this session's live-probe evidence."
$md += ""
$md += "## Goal"
$md += ""
$md += "Per-portal unattended auth for a single SA using **TOTP** OR **Passkey** (W3C WebAuthn L2 ECDSA-P256). No SP, no public Microsoft API (Graph/MDE REST), no browser at runtime. ESTSAUTHPERSISTENT cookie (90-day KMSI) + refresh_token enable silent renewal without re-issuing TOTP."
$md += ""
$md += "## Auth method matrix (per [v1 AUTH.md](../../xdrlograider/docs/AUTH.md))"
$md += ""
$md += "| CA control | CredentialsTotp | Passkey | Operator action |"
$md += "|---|---|---|---|"
$md += "| Require MFA | Pass | Pass | None |"
$md += "| Require phishing-resistant MFA | **Fail** | Pass | **Use Passkey method** |"
$md += "| Require compliant device | Fail | Fail | Exclude SA from policy |"
$md += "| Require hybrid join | Fail | Fail | Exclude SA from policy |"
$md += "| Block legacy auth | Pass | Pass | None |"
$md += ""
$md += "**Both methods supported.** Operator picks per their CA strictness. TOTP simpler to set up; Passkey survives phishing-resistant MFA."
$md += ""
$md += "## Unattended-auth architecture (v2 — replaces v1's 50-min full re-auth)"
$md += ""
$md += '```'
$md += 'Bootstrap per portal (one-time, ~5 sec):'
$md += '  GET /oauth2/v2.0/authorize?client_id=<portal-client>&redirect_uri=<registered>&response_mode=query'
$md += '       &scope=<resource>/.default+offline_access+openid+profile'
$md += '       &code_challenge=<S256(verifier)>&code_challenge_method=S256'
$md += '    -> SA cred POST + TOTP (or Passkey assertion)'
$md += '    -> KMSI ack (LoginOptions=1)'
$md += '    -> ESTSAUTHPERSISTENT cookie (Expires +90d)'
$md += '    -> form_post lands at redirect_uri with ?code=...'
$md += '  POST /oauth2/v2.0/token grant_type=authorization_code + Origin:<portal-host> + PKCE verifier'
$md += '    -> access_token + refresh_token (resource-scoped)'
$md += '  Store {refresh_token} in KV; the SPA client_id+audience+headers are static per portal.'
$md += ''
$md += 'Steady-state (every ~50 min during access_token validity, NO TOTP):'
$md += '  POST /oauth2/v2.0/token grant_type=refresh_token + Origin:<portal-host>'
$md += '    -> fresh access_token (rotated refresh_token)'
$md += '  GET <api-host>/<endpoint> Authorization:Bearer <access_token> <portal-specific-headers>'
$md += '    -> JSON data'
$md += ''
$md += 'Recovery (~85 days, KMSI expiring soon):'
$md += '  Run bootstrap. ~5 sec. Operator-scheduled.'
$md += '```'
$md += ""
$md += "## Per-portal status"
$md += ""
$md += "| Portal | Bucket | ClientId | Audience | Status |"
$md += "|---|---|---|---|---|"
foreach ($r in $summary) {
    $cl = if ($r.ClientIdStatus -eq 'KNOWN') { '✓' } elseif ($r.ClientIdStatus -eq 'PENDING') { 'pending' } else { '-' }
    $au = if ($r.AudienceStatus -eq 'KNOWN') { '✓' } elseif ($r.AudienceStatus -eq 'PENDING') { 'pending' } else { '-' }
    $md += "| $($r.Portal) | $($r.Bucket) | $cl | $au | $($r.UnattendedStatus) |"
}
$md += ""
$md += "## What's proven live"
$md += ""
$md += "- **defender** (v1 production, ~3 months): 120 live endpoints, full TOTP+sccauth chain"
$md += "- **purview**: 20 live endpoints via session-cookie + same TOTP chain"
$md += "- **exchange**: 16 live endpoints via .AspNetCore.Cookies + x-requested-with"
$md += '- **intune-portal**: TOTP chain -> authorization_code (1504 chars) -> access_token (2495) + refresh_token (1456) -> silent refresh OK; API token-audience requires per-portal discovery'
$md += '- **entra**: same chain as intune via shared c44b4083 client'
$md += '- **entra-ibiza-iam**: FULL END-TO-END -- TOTP -> access_token (ADIbizaUX-scoped) -> silent refresh -> `GET main.iam.ad.ext.azure.com/api/ViralSubscriptions` -> HTTP 200 + real JSON `[{"targetClass":"User",...}]`'
$md += ""
$md += "## Pending discovery (per portal, text-only — no browser)"
$md += ""
$md += "For each Bucket B/C portal: ClientId + Audience + portal-specific Headers. Sources to mine:"
$md += "- nodoc OpenAPI servers (audience hints in baseUrl)"
$md += "- nodoc getting-started auth model per family (headers documented)"
$md += "- nodoc Postman collection auth + sample headers"
$md += "- portal SPA HTML static analysis (clientId GUIDs visible in inline JS)"
$md += "- this session's c44b4083 finding — covers Azure-AD-app SPAs (Intune/Entra family/Power Platform likely)"
$md += ""
$md += "## KV secret schema per portal"
$md += ""
$md += '```'
$md += '<portal>-upn        (always)'
$md += '<portal>-password   (CredentialsTotp method)'
$md += '<portal>-totp       (CredentialsTotp method; Base32)'
$md += '<portal>-passkey    (Passkey method; JSON {upn,credentialId,privateKeyPem,rpId})'
$md += '<portal>-refresh    (long-lived refresh_token; steady-state polling)'
$md += '```'
$md += ""
Set-Content -Path $indexPath -Value ($md -join "`n")
Write-Host "Master index written: $indexPath" -ForegroundColor Green
