# Test-MultiPortalAuth.ps1
#
# Probe each Microsoft portal with the SAME SA + TOTP via Get-EntraEstsAuth.
# Different ClientId + PortalHost per portal. Verifies which portals our SA
# can authenticate against — drives multi-portal live-probe coverage.
#
# Per Phase 0 prep: NO mutations. Read-only verification only.
# Spacing: 35s between attempts to avoid TOTP duplicate-code-entered race.

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$EnvFile = "$PSScriptRoot\..\..\xdrlograider\tests\.env.local",
    [string[]]$OnlyPortal = @(),
    [int]$DelaySec = 35
)

$ErrorActionPreference = 'Continue'
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$v1Modules = "$PSScriptRoot\..\..\xdrlograider\src\Modules"

# Load env
Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k,$v = $_ -split '=', 2; Set-Item -Path "env:$k" -Value $v
}

# Import v1 modules (reuse — don't reinvent)
foreach ($m in 'Xdr.Common.Telemetry','Xdr.Common.Auth','Xdr.Common.Manifest','Xdr.Sentinel.Ingest','Xdr.Defender.Auth') {
    Import-Module (Join-Path $v1Modules "$m/$m.psd1") -Force -Global -ErrorAction Stop
}

# Portal probe table
# ClientId references:
#   Defender XDR (security.microsoft.com)        : 80ccca67-54bd-44ab-8625-4b79c4dc7775  (v1 docstring + tested)
#   Purview (compliance.microsoft.com)           : 80ccca67-54bd-44ab-8625-4b79c4dc7775  (v1 docstring — shares Defender)
#   Intune (intune.microsoft.com)                : 0000000a-0000-0000-c000-000000000000  (v1 docstring)
#   Azure Portal (portal.azure.com)              : c44b4083-3bb0-49c1-b47d-974e53cbdf3c  (well-known Azure portal app)
#   Entra (entra.microsoft.com)                  : c44b4083-3bb0-49c1-b47d-974e53cbdf3c  (Azure Portal app — Entra is hosted there)
#   M365 Admin (admin.microsoft.com)             : 4765445b-32c6-49b0-83e6-1d93765276ca  (well-known M365 admin app)
#   Teams Admin (admin.teams.microsoft.com)      : 12128f48-ec9e-42f0-b203-ea49fb6af367  (Teams admin)
#   Power Platform (admin.powerplatform.microsoft.com) : c44b4083-3bb0-49c1-b47d-974e53cbdf3c (Azure Portal app)
#   Security Copilot (securitycopilot.microsoft.com) : 80ccca67-54bd-44ab-8625-4b79c4dc7775 (likely shares Defender)
$portals = @(
    @{ Key='defender';         Host='security.microsoft.com';                ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; CookieName='sccauth';      VerifyEndpoint='/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true' }
    @{ Key='purview';          Host='purview.microsoft.com';                 ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; CookieName='sccauth';      VerifyEndpoint='/apiproxy/mtp/sccManagement/mgmt/TenantContext' }
    @{ Key='sharepoint';       Host='admin.microsoft.com';                   ClientId='4765445b-32c6-49b0-83e6-1d93765276ca'; CookieName='RpsContextCookie'; VerifyEndpoint='/admin/api/sharepoint/sites' }
    @{ Key='exchange';         Host='admin.exchange.microsoft.com';          ClientId='4765445b-32c6-49b0-83e6-1d93765276ca'; CookieName='ECP.AuthCookie'; VerifyEndpoint='/ecp/DDI/DDIService.svc/GetList?schema=Mailbox' }
    @{ Key='intune';           Host='intune.microsoft.com';                  ClientId='0000000a-0000-0000-c000-000000000000'; CookieName='intuneconsole';VerifyEndpoint='/api/serviceconfig' }
    @{ Key='entra';            Host='entra.microsoft.com';                   ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; CookieName='ESTSAUTH';     VerifyEndpoint='/api/Tenant' }
    @{ Key='m365-admin';       Host='admin.microsoft.com';                   ClientId='4765445b-32c6-49b0-83e6-1d93765276ca'; CookieName='RpsContextCookie'; VerifyEndpoint='/admin/api/users' }
    @{ Key='teams-admin';      Host='admin.teams.microsoft.com';             ClientId='12128f48-ec9e-42f0-b203-ea49fb6af367'; CookieName='TAC.AuthCookie'; VerifyEndpoint='/api/v2/Tenants/Current' }
    @{ Key='security-copilot'; Host='securitycopilot.microsoft.com';         ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; CookieName='sccauth';      VerifyEndpoint='/api/security/tenants' }
)

if ($OnlyPortal.Count -gt 0) {
    $portals = $portals | Where-Object { $OnlyPortal -contains $_.Key }
}

$cred = @{
    upn        = $env:XDRLR_TEST_UPN
    password   = $env:XDRLR_TEST_PASSWORD
    totpBase32 = $env:XDRLR_TEST_TOTP_SECRET
}
Write-Host "SA: $($cred.upn)" -ForegroundColor DarkGray
Write-Host ""

$results = @()
$first = $true
foreach ($p in $portals) {
    if (-not $first) {
        Write-Host "  (waiting $DelaySec s for TOTP step rotation...)" -ForegroundColor DarkGray
        Start-Sleep -Seconds $DelaySec
    }
    $first = $false
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "[$($p.Key)] $($p.Host) (ClientId $($p.ClientId.Substring(0,8))…)" -ForegroundColor Cyan
    $r = [pscustomobject]@{
        Portal     = $p.Key
        Host       = $p.Host
        ClientId   = $p.ClientId
        AuthStatus = 'unknown'
        AuthError  = $null
        CookiesSet = @()
        ProbeStatus = $null
        ProbeBody   = $null
        TimeMs     = 0
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $auth = Get-EntraEstsAuth `
            -Method 'CredentialsTotp' `
            -Credential $cred `
            -ClientId $p.ClientId `
            -PortalHost $p.Host `
            -ErrorAction Stop
        $r.AuthStatus = 'ok'
        # Inspect cookies set on the portal host
        try {
            $cookies = $auth.Session.Cookies.GetCookies("https://$($p.Host)") | ForEach-Object Name
            $r.CookiesSet = @($cookies)
        } catch { $r.CookiesSet = @('<cookie-enumeration-failed>') }
        # Verify with a sample endpoint probe
        if ($p.VerifyEndpoint) {
            try {
                $resp = Invoke-WebRequest -Uri "https://$($p.Host)$($p.VerifyEndpoint)" `
                    -WebSession $auth.Session -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                $r.ProbeStatus = [int]$resp.StatusCode
                $body = $resp.Content
                if ($body.Length -gt 200) { $body = $body.Substring(0, 200) + '...' }
                $r.ProbeBody = $body
            } catch {
                $rer = $_.Exception.Response
                if ($rer) {
                    $r.ProbeStatus = [int]$rer.StatusCode
                    try { $r.ProbeBody = (New-Object System.IO.StreamReader($rer.GetResponseStream())).ReadToEnd().Substring(0,200) } catch {}
                } else {
                    $r.ProbeBody = "probe-network: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        $r.AuthStatus = 'fail'
        $r.AuthError  = $_.Exception.Message
        if ($r.AuthError.Length -gt 200) { $r.AuthError = $r.AuthError.Substring(0,200) + '...' }
    } finally {
        $sw.Stop(); $r.TimeMs = [int]$sw.ElapsedMilliseconds
    }
    $msg = if ($r.AuthStatus -eq 'ok') {
        "  Auth=OK ($([int]($r.TimeMs/1000))s)  cookies=[$($r.CookiesSet -join ',')]  probe=$($r.ProbeStatus)"
    } else {
        "  Auth=FAIL — $($r.AuthError)"
    }
    $color = if ($r.AuthStatus -eq 'ok') { 'Green' } else { 'Yellow' }
    Write-Host $msg -ForegroundColor $color
    if ($r.AuthStatus -eq 'ok' -and $r.ProbeBody) {
        Write-Host "  Probe body sample: $($r.ProbeBody)" -ForegroundColor DarkGray
    }
    $results += $r
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
$results | Format-Table Portal, Host, AuthStatus, ProbeStatus, TimeMs -AutoSize

# Save JSON for later use
$outFile = "$repoRoot\tests\results\multi-portal-auth-$(Get-Date -Format 'yyyyMMddHHmmss')Z.json"
$null = New-Item -Path (Split-Path $outFile) -ItemType Directory -Force
$results | ConvertTo-Json -Depth 10 | Set-Content $outFile
Write-Host "Saved: $outFile"
