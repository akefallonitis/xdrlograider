#Requires -Version 7.4
# Clean diag · 2 consecutive Connect-DefenderPortal calls · verify KMSI re-mint
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\src\Modules\Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force

$envFile = Join-Path $PSScriptRoot '..\tests\.env.local'
Get-Content $envFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
}

$creds = Get-XdrAuthFromKeyVault -FromEnvLocal

Write-Host "COLD AUTH (cycle 1) ..." -ForegroundColor Cyan
$s1 = Connect-DefenderPortal -Credentials $creds
Write-Host ("  RefreshType: $($s1.RefreshType)") -ForegroundColor Green

Write-Host ""
Write-Host "-Force (cycle 2 · KMSI SSO expected) ..." -ForegroundColor Cyan
$s2 = Connect-DefenderPortal -Credentials $creds -Force -Verbose 4>&1
$verboseLines = @($s2 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
$sessionObj   = @($s2 | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })[0]
foreach ($v in $verboseLines) {
    if ($v.Message -match 'KMSI|SSO|TOTP|sccauth|interrupt|copied|RefreshType') {
        Write-Host ("  VRB: $($v.Message)") -ForegroundColor Yellow
    }
}
if ($sessionObj) {
    Write-Host ("  Result.RefreshType: $($sessionObj.RefreshType)") -ForegroundColor $(if ($sessionObj.RefreshType -eq 'kmsi-sso') { 'Green' } else { 'Yellow' })
}

Write-Host ""
Write-Host "-Force (cycle 3 · KMSI SSO expected) ..." -ForegroundColor Cyan
$s3 = Connect-DefenderPortal -Credentials $creds -Force
Write-Host ("  RefreshType: $($s3.RefreshType)") -ForegroundColor $(if ($s3.RefreshType -eq 'kmsi-sso') { 'Green' } else { 'Yellow' })
