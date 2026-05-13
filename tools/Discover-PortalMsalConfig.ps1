# Discover-PortalMsalConfig.ps1
#
# No-browser, no-SP, no-Graph discovery of each portal SPA's MSAL clientId +
# redirect_uri + audience. Works by HTTP-fetching the portal bootstrap HTML
# and all referenced JS bundles, then grepping for known patterns.
#
# Phase 0 critical: without these client_ids, we cannot replicate the SPA's
# normal browser auth flow unattended (because c44b4083 is NOT pre-authorized
# for portal resources beyond Entra-IBiza-IAM/IGA per AADSTS65002).

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string[]]$Portals = @('intune.microsoft.com','services.autopatch.microsoft.com','securitycopilot.microsoft.com','admin.teams.microsoft.com','admin.powerplatform.microsoft.com','engage.cloud.microsoft','config.office.com','clients.config.office.net','admin.cloud.microsoft','admin.microsoft.com'),
    [int]$MaxJsBundles = 30,
    [int]$JsByteLimit  = 5MB
)

$ErrorActionPreference = 'Continue'
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

# Patterns to extract from JS / HTML
$clientIdPatterns = @(
    'clientId\s*:\s*["'']([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})["'']'
    'client_id\s*:\s*["'']([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})["'']'
    '"clientId"\s*:\s*"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"'
    'aadClientId["''\s:=]+["'']([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})["'']'
    'appId["''\s:=]+["'']([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})["'']'
    'msalAppId["''\s:=]+["'']([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})["'']'
)
$redirectPatterns = @(
    'redirectUri\s*:\s*["'']([^"'']+)["'']'
    'redirect_uri\s*:\s*["'']([^"'']+)["'']'
    '"redirectUri"\s*:\s*"([^"]+)"'
    'postLogoutRedirectUri\s*:\s*["'']([^"'']+)["'']'
)
$audiencePatterns = @(
    'resource\s*:\s*["'']([^"'']+)["'']'
    'audience\s*:\s*["'']([^"'']+)["'']'
    'tokenResource\s*:\s*["'']([^"'']+)["'']'
    '"resource"\s*:\s*"([^"]+)"'
    '"scope"\s*:\s*"([^"]+\.default[^"]*)"'
    '"scopes"\s*:\s*\[["'']([^"'']+\.default[^"'']*)["'']'
    'apiAppId\s*:\s*["'']([^"'']+)["'']'
)
$authorityPatterns = @(
    'authority\s*:\s*["'']([^"'']+)["'']'
    '"authority"\s*:\s*"([^"]+)"'
    'loginUrl\s*:\s*["'']([^"'']+)["'']'
)

# Microsoft's well-known consumer/test/role GUIDs to filter out (noise)
$wellKnownNoise = @(
    '9188040d-6c67-4c5b-b112-36a304b66dad'  # Microsoft consumer tenant
    '62e90394-69f5-4237-9190-012177145e10'  # Global Admin role template
    '00000000-0000-0000-0000-000000000000'
    'f8cdef31-a31e-4b4a-93e4-5f571e91255a'  # Microsoft service tenant
)

# Microsoft public app IDs (known/documented; useful for context, not for noise filter)
$knownPublicClients = @{
    '04b07795-8ddb-461a-bbee-02f9e1bf7b46' = 'Azure CLI (public)'
    '1950a258-227b-4e31-a9cf-717495945fc2' = 'Microsoft Azure PowerShell'
    '14d82eec-204b-4c2f-b7e8-296a70dab67e' = 'Microsoft Graph CLI'
    '80ccca67-54bd-44ab-8625-4b79c4dc7775' = 'Defender XDR Portal (security.microsoft.com)'
    'c44b4083-3bb0-49c1-b47d-974e53cbdf3c' = 'Microsoft Azure AD (Azure portal, Entra portal)'
    '4765445b-32c6-49b0-83e6-1d93765276ca' = 'Microsoft 365 Admin Center'
    '12128f48-ec9e-42f0-b203-ea49fb6af367' = 'Microsoft Teams Admin Center'
    '74658136-14ec-4630-ad9b-26e160ff0fc6' = 'ADIbizaUX (Entra IAM resource)'
}

function Extract-Patterns {
    param([string]$Text, [string[]]$Patterns)
    $found = @{}
    foreach ($p in $Patterns) {
        $matches = [regex]::Matches($Text, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($m in $matches) {
            $val = $m.Groups[1].Value
            if (-not $found.ContainsKey($val)) { $found[$val] = 0 }
            $found[$val]++
        }
    }
    return $found
}

function Get-JsUrlsFromHtml {
    param([string]$Html, [string]$BaseHost)
    $urls = @{}
    # <script src="...">
    foreach ($m in [regex]::Matches($Html, '<script[^>]+src\s*=\s*["'']([^"'']+\.js[^"'']*)["'']')) {
        $u = $m.Groups[1].Value
        if ($u -match '^/' -and $u -notmatch '^//') { $u = "https://$BaseHost$u" }
        elseif ($u -notmatch '^https?:') { $u = "https://$BaseHost/$u" }
        $urls[$u] = 1
    }
    # JS string literals referencing .js files (webpack chunk maps)
    foreach ($m in [regex]::Matches($Html, '["'']([^"''\s]+\.js[^"''\s]*)["'']')) {
        $u = $m.Groups[1].Value
        if ($u -match '^/' -and $u -notmatch '^//') { $u = "https://$BaseHost$u" }
        elseif ($u -match '^https?:') { } else { continue }
        $urls[$u] = 1
    }
    return @($urls.Keys)
}

$summary = @()
foreach ($p in $Portals) {
    Write-Host "================ $p ================" -ForegroundColor Cyan
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new(); $session.UserAgent = $userAgent
    $allText = ''
    try {
        $r = Invoke-WebRequest -Uri "https://$p/" -WebSession $session -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 20 -ErrorAction Stop
        $allText = $r.Content
        Write-Host "  Bootstrap HTML: $($r.Content.Length) bytes"
    } catch { Write-Host "  Bootstrap fetch failed: $($_.Exception.Message)" -ForegroundColor Red; continue }

    # Find JS bundles
    $jsUrls = Get-JsUrlsFromHtml -Html $allText -BaseHost $p
    Write-Host "  JS URLs referenced: $($jsUrls.Count) (fetching up to $MaxJsBundles)"
    $jsFetched = 0
    foreach ($u in $jsUrls | Select-Object -First $MaxJsBundles) {
        try {
            $js = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $sz = $js.Content.Length
            if ($sz -gt $JsByteLimit) { continue }
            $allText += "`n" + $js.Content
            $jsFetched++
        } catch {}
    }
    Write-Host "  JS bundles fetched: $jsFetched / Combined size: $($allText.Length) bytes"

    $clientIds  = Extract-Patterns -Text $allText -Patterns $clientIdPatterns
    $redirects  = Extract-Patterns -Text $allText -Patterns $redirectPatterns
    $audiences  = Extract-Patterns -Text $allText -Patterns $audiencePatterns
    $authorities= Extract-Patterns -Text $allText -Patterns $authorityPatterns

    # Filter noise
    foreach ($n in $wellKnownNoise) { if ($clientIds.ContainsKey($n)) { $clientIds.Remove($n) } }

    Write-Host "  Candidate clientIds:" -ForegroundColor Green
    $cidsSorted = $clientIds.GetEnumerator() | Sort-Object Value -Descending
    $portalClientId = $null
    foreach ($c in $cidsSorted | Select-Object -First 6) {
        $known = if ($knownPublicClients.ContainsKey($c.Key)) { " [$($knownPublicClients[$c.Key])]" } else { '' }
        Write-Host "    $($c.Key)  (x$($c.Value))$known"
        if (-not $portalClientId) { $portalClientId = $c.Key }
    }
    if ($redirects.Count -gt 0) {
        Write-Host "  Candidate redirect_uris:" -ForegroundColor Green
        $redirects.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { Write-Host "    $($_.Key)  (x$($_.Value))" }
    }
    if ($audiences.Count -gt 0) {
        Write-Host "  Candidate audiences:" -ForegroundColor Green
        $audiences.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 | ForEach-Object { Write-Host "    $($_.Key)  (x$($_.Value))" }
    }
    if ($authorities.Count -gt 0) {
        Write-Host "  Candidate authority:" -ForegroundColor DarkGreen
        $authorities.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 2 | ForEach-Object { Write-Host "    $($_.Key)  (x$($_.Value))" }
    }

    $summary += [pscustomobject]@{
        PortalHost = $p
        TopClientId = $portalClientId
        ClientIdCount = $clientIds.Count
        TopRedirect = ($redirects.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
        TopAudience = ($audiences.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    }
}

Write-Host ""
Write-Host "=== Discovery Summary ===" -ForegroundColor Cyan
$summary | Format-Table -AutoSize
