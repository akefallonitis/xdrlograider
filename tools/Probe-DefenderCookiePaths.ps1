# Probe-DefenderCookiePaths.ps1
#
# Defender XDR cookie-portal targeted probe for paths corrected post-research.
# Uses v1's Xdr.Defender.Auth Connect-DefenderPortal (sccauth+XSRF).
#
# Targets:
#   - /mtp/mdeCustomCollection/rules (corrected from /customDataCollection/)
#   - /mtp/sccManagement/mgmt/TenantContext?realTime=true (XDRInternals canonical)
#   - any other path passed via -ExtraPaths

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$EnvFile = "$PSScriptRoot\..\..\xdrlograider\tests\.env.local",
    [string]$ReferencesRoot = "$PSScriptRoot\..\references",
    [string[]]$ExtraPaths = @()
)

$ErrorActionPreference = 'Stop'
$v1Modules = "$PSScriptRoot\..\..\xdrlograider\src\Modules"

# Load env vars
Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k,$v = $_ -split '=', 2; Set-Item -Path "env:$k" -Value $v
}
$tenant = $env:AZURE_TENANT_ID
$cred = @{ upn=$env:XDRLR_TEST_UPN; password=$env:XDRLR_TEST_PASSWORD; totpBase32=$env:XDRLR_TEST_TOTP_SECRET }

# Import v1 modules
Import-Module (Join-Path $v1Modules 'Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force -Global
Import-Module (Join-Path $v1Modules 'Xdr.Common.Auth\Xdr.Common.Auth.psd1') -Force -Global
Import-Module (Join-Path $v1Modules 'Xdr.Defender.Auth\Xdr.Defender.Auth.psd1') -Force -Global

# v2 OVERRIDE: Complete-TotpMfa with MaximumRedirection=30 (SharePoint dance)
. "$PSScriptRoot\..\src\Modules\Xdr.Common.AuthV2\Private\Complete-TotpMfa.ps1"

$PSDefaultParameterValues['Invoke-WebRequest:MaximumRedirection'] = 30

Write-Host "=== Connecting to Defender portal ===" -ForegroundColor Cyan
$authResult = Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred -PortalHost 'security.microsoft.com' -TenantId $tenant -Force
$session = $authResult.Session
Write-Host "Auth OK." -ForegroundColor Green

# Read XSRF token from session cookies
$xsrf = ''
$cookie = $session.Cookies.GetCookies('https://security.microsoft.com') | Where-Object { $_.Name -eq 'XSRF-TOKEN' } | Select-Object -First 1
if ($cookie) { $xsrf = [System.Net.WebUtility]::UrlDecode($cookie.Value) }

$targets = @(
    @{ Label='CustomCollection rules (corrected)'; Path='/mtp/mdeCustomCollection/rules'; UpdateLive="$ReferencesRoot\defender\endpoint_configuration\ListCustomCollectionRules\live.json" }
    @{ Label='TenantContext canonical'; Path='/mtp/sccManagement/mgmt/TenantContext?realTime=true'; UpdateLive=$null }
)
foreach ($extra in $ExtraPaths) {
    $targets += @{ Label="extra: $extra"; Path=$extra; UpdateLive=$null }
}

$results = @()
foreach ($t in $targets) {
    Write-Host ""
    Write-Host "===> $($t.Label)" -ForegroundColor Cyan
    Write-Host "    GET https://security.microsoft.com/apiproxy$($t.Path)"

    $headers = @{
        'X-XSRF-TOKEN' = $xsrf
        'Accept' = 'application/json'
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'
    }

    try {
        $uri = "https://security.microsoft.com/apiproxy$($t.Path)"
        $resp = Invoke-WebRequest -Uri $uri -WebSession $session -Headers $headers -Method Get -UseBasicParsing -SkipHttpErrorCheck -MaximumRedirection 0 -ErrorAction SilentlyContinue
        $status = $resp.StatusCode
        $body = $resp.Content
        $bodyLen = if ($body) { $body.Length } else { 0 }

        $kind = switch ($status) {
            200 { if ($bodyLen -gt 100) { 'live' } else { 'live-empty' } }
            204 { 'live-empty' }
            429 { 'rate-limited' }
            default { 'error' }
        }

        $sample = if ($body -and $body.Length -gt 0) { ($body.Substring(0, [Math]::Min(500, $body.Length))) -replace '[\r\n]+', ' ' } else { '' }
        $shape = if ($body -and $body.Length -gt 0) { if ($body.TrimStart().StartsWith('[')) { 'array' } elseif ($body.TrimStart().StartsWith('{')) { 'object' } else { 'string' } } else { $null }

        Write-Host "    HTTP $status · body=$bodyLen · kind=$kind · shape=$shape" -ForegroundColor $(if ($kind -eq 'live') { 'Green' } else { 'Yellow' })
        if ($sample) { Write-Host "    Sample: $($sample.Substring(0, [Math]::Min(180, $sample.Length)))..." -ForegroundColor Gray }

        $r = [pscustomobject]@{
            label=$t.Label; path=$t.Path; httpStatus=$status; successKind=$kind; rowCount=$bodyLen; responseShape=$shape; sample=$sample.Substring(0, [Math]::Min(500, $sample.Length)); probedUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $results += $r

        if ($t.UpdateLive -and (Test-Path (Split-Path $t.UpdateLive -Parent))) {
            $liveJson = [ordered]@{
                httpStatus = $status
                successKind = $kind
                rowCount = if ($kind -eq 'live' -and $shape -eq 'array') { try { (ConvertFrom-Json $body).Count } catch { 1 } } else { if ($bodyLen -gt 0) { 1 } else { 0 } }
                errorText = ''
                responseShape = $shape
                sample = $sample.Substring(0, [Math]::Min(500, $sample.Length))
                probedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            $liveJson | ConvertTo-Json -Depth 10 | Set-Content -Path $t.UpdateLive -NoNewline
            Write-Host "    live.json updated: $($t.UpdateLive)" -ForegroundColor Cyan
        }
    } catch {
        Write-Host "    Exception: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "===== Defender cookie-path probe summary =====" -ForegroundColor Cyan
$results | Format-Table -Property label, httpStatus, successKind, rowCount, responseShape -AutoSize
