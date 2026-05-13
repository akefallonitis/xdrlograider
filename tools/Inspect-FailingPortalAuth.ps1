# Inspect-FailingPortalAuth.ps1 — fetch the raw bootstrap HTML/redirect chain from each
# portal that v1's Get-EntraEstsAuth $Config parser couldn't handle, so we can identify
# the actual auth flow pattern (MSAL.js / PKCE / federated / different $Config var name).

#Requires -Version 7.0
[CmdletBinding()] param()

$portals = @(
    @{ Key='intune';           Host='intune.microsoft.com';                  ClientId='0000000a-0000-0000-c000-000000000000' }
    @{ Key='entra';            Host='entra.microsoft.com';                   ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c' }
    @{ Key='m365-admin';       Host='admin.microsoft.com';                   ClientId='4765445b-32c6-49b0-83e6-1d93765276ca' }
    @{ Key='security-copilot'; Host='securitycopilot.microsoft.com';         ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775' }
    @{ Key='power-platform';   Host='admin.powerplatform.microsoft.com';     ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c' }
)

foreach ($p in $portals) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "[$($p.Key)] $($p.Host) clientId=$($p.ClientId.Substring(0,8))..." -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan

    # Step 1: Unauthenticated GET the portal root — see where it redirects
    Write-Host "Step 1: GET https://$($p.Host)/" -ForegroundColor Yellow
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    try {
        $resp = Invoke-WebRequest -Uri "https://$($p.Host)/" -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -UseBasicParsing
        Write-Host "  Status: $($resp.StatusCode)"
        Write-Host "  Location header: $($resp.Headers.Location | Select-Object -First 1)"
    } catch {
        Write-Host "  Initial GET failed: $($_.Exception.Message)"
        continue
    }

    # Step 2: Follow redirects manually until we hit login.microsoftonline.com
    $url = "https://$($p.Host)/"
    $hops = 0
    while ($hops -lt 10) {
        $hops++
        try {
            $resp = Invoke-WebRequest -Uri $url -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -UseBasicParsing -TimeoutSec 10
        } catch { Write-Host "  Hop $hops error: $($_.Exception.Message)"; break }
        $loc = $resp.Headers.Location | Select-Object -First 1
        $status = [int]$resp.StatusCode
        if ($loc) {
            Write-Host "  Hop $hops ($status): $url"
            Write-Host "                  -> $loc"
            if ($loc.StartsWith('/')) { $url = "https://$([Uri]::new($url).Host)$loc" } else { $url = $loc }
        } else {
            Write-Host "  Hop $hops ($status, no redirect): $url"
            Write-Host "  Content-Type: $($resp.Headers.'Content-Type' | Select-Object -First 1)"
            $contentLen = if ($resp.Content) { $resp.Content.Length } else { 0 }
            Write-Host "  Content length: $contentLen"
            # Sample the response - look for $Config / MSAL / $App / various patterns
            $body = [string]$resp.Content
            $configPatterns = @(
                @{ name='$Config (classic Entra)';   pattern='\$Config\s*=' }
                @{ name='msal config';                pattern='msalConfig|msal\.PublicClientApplication' }
                @{ name='AAD MSAL';                   pattern='_appData|_dataBlob' }
                @{ name='Edge new portal';            pattern='Internal\.Settings|window\.\$Internal' }
                @{ name='PKCE auth state';            pattern='code_challenge|nonce' }
                @{ name='Form post action';           pattern='<form[^>]*action="([^"]*)"' }
                @{ name='SPA root';                   pattern='<div id="root">|<div id="app">|<noscript>You need to enable JavaScript' }
                @{ name='Federated provider';         pattern='credentialProviders|federationMetadataUrl' }
                @{ name='login_hint';                 pattern='login_hint|prompt=' }
            )
            $found = @()
            foreach ($cp in $configPatterns) {
                if ($body -match $cp.pattern) { $found += $cp.name }
            }
            Write-Host "  Pattern matches: $($found -join '; ')"
            if ($body -match '<title>([^<]+)</title>') {
                Write-Host "  Page title: $($matches[1])"
            }
            if ($body -match 'data-state="([^"]{0,300})') {
                Write-Host "  data-state sample: $($matches[1])..."
            }
            break
        }
    }
}
