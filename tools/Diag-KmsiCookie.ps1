#Requires -Version 7.4
# Diagnostic: trace Connect-DefenderPortal error
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Modules\Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force

$envFile = Join-Path $PSScriptRoot '..\tests\.env.local'
Get-Content $envFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

$creds = Get-XdrAuthFromKeyVault -FromEnvLocal

try {
    Write-Host "Connect-DefenderPortal (first call · cold cache)..." -ForegroundColor Cyan
    $session = Connect-DefenderPortal -Credentials $creds
    Write-Host "  RefreshType: $($session.RefreshType)" -ForegroundColor Green
    $cookies = $session.Session.Cookies.GetAllCookies()
    Write-Host "  Cookies: $($cookies.Count)"
    foreach ($c in $cookies) {
        Write-Host ("    {0,-25} domain={1,-30} expires={2}" -f $c.Name, $c.Domain, $c.Expires)
    }
    $kmsi = $cookies | Where-Object Name -eq 'ESTSAUTHPERSISTENT' | Select-Object -First 1
    if ($kmsi) {
        $days = [math]::Round(($kmsi.Expires - [datetime]::UtcNow).TotalDays, 2)
        Write-Host "  ESTSAUTHPERSISTENT: present · expires in $days days" -ForegroundColor Green
    } else {
        Write-Host "  ESTSAUTHPERSISTENT: NOT FOUND · KMSI not set by KmsiInterrupt walker" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Connect-DefenderPortal -Force (second call · KMSI SSO test)..." -ForegroundColor Cyan
    $session2 = Connect-DefenderPortal -Credentials $creds -Force -Verbose
    Write-Host "  RefreshType: $($session2.RefreshType)" -ForegroundColor $(if ($session2.RefreshType -eq 'kmsi-sso') { 'Green' } else { 'Yellow' })
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "TYPE: $($_.Exception.GetType().FullName)" -ForegroundColor Red
    Write-Host "AT: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Yellow
    Write-Host "SCRIPT-STACK:" -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace
}
