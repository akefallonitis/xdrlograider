# Debug-PurviewProbe.ps1 — direct probe to diagnose 500 errors on Purview
[CmdletBinding()] param()

Set-Location $PSScriptRoot/..
Get-Content '..\xdrlograider\tests\.env.local' | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k,$v = $_ -split '=', 2; Set-Item -Path "env:$k" -Value $v
}
foreach ($m in 'Xdr.Common.Telemetry','Xdr.Common.Auth') {
    Import-Module "..\xdrlograider\src\Modules\$m\$m.psd1" -Force -Global -ErrorAction Stop
}
$cred = @{ upn=$env:XDRLR_TEST_UPN; password=$env:XDRLR_TEST_PASSWORD; totpBase32=$env:XDRLR_TEST_TOTP_SECRET }

Write-Host 'Authenticating to purview.microsoft.com...'
$auth = Get-EntraEstsAuth -Method 'CredentialsTotp' -Credential $cred -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' -PortalHost 'purview.microsoft.com'
$cookies = ($auth.Session.Cookies.GetCookies('https://purview.microsoft.com') | ForEach-Object Name) -join ','
Write-Host "Cookies on purview.microsoft.com: $cookies"

$paths = @(
    '/apiproxy/adtsch/AuditEnabled',
    '/apiproxy/dgws/api/management/tenant',
    '/apiproxy/dpsclient/api/v1/dlp/policies',
    '/apiproxy/imp/api/v1/uam/insiderrisk/cases/'
)
foreach ($path in $paths) {
    $uri = "https://purview.microsoft.com$path"
    Write-Host ""
    Write-Host "=== $path ==="
    try {
        $xsrf = ($auth.Session.Cookies.GetCookies('https://purview.microsoft.com') | Where-Object Name -eq 'XSRF-TOKEN').Value
        $hdrs = @{ 'Accept'='application/json' }
        if ($xsrf) { $hdrs['X-XSRF-TOKEN'] = [System.Net.WebUtility]::UrlDecode($xsrf) }
        $resp = Invoke-WebRequest -Uri $uri -WebSession $auth.Session -Headers $hdrs -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $body = $resp.Content
        if ($body.Length -gt 300) { $body = $body.Substring(0,300) + '...' }
        Write-Host "  OK $([int]$resp.StatusCode): $body"
    } catch {
        $er = $_.Exception.Response
        if ($er) {
            $status = [int]$er.StatusCode
            $body = ''
            try { $body = (New-Object System.IO.StreamReader($er.GetResponseStream())).ReadToEnd() } catch {}
            if ($body.Length -gt 400) { $body = $body.Substring(0,400) + '...' }
            Write-Host "  FAIL ${status}: $body"
        } else {
            Write-Host "  EXC: $($_.Exception.Message)"
        }
    }
}
