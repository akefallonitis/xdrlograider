# profile.ps1 — Azure Functions PowerShell startup.
# Runs once per worker on cold start. Authenticate via SAMI; load Xdr.* modules.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# SAMI sign-in. Retry up to 3 times on transient IMDS 5xx (cold-start race).
$identityOk = $false
for ($i = 1; $i -le 3 -and -not $identityOk; $i++) {
    try {
        if ($env:MSI_SECRET -or $env:IDENTITY_HEADER) {
            Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
            $identityOk = $true
        } else {
            Write-Warning "profile.ps1: no SAMI environment detected; skipping Connect-AzAccount (local dev?)."
            break
        }
    } catch {
        Write-Warning "profile.ps1: Connect-AzAccount attempt $i failed: $($_.Exception.Message)"
        if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
    }
}

# Import the Xdr.* modules bundled in Modules/. Path inside the FA zip is
# /Modules/<Name>/<Version>/<Name>.psd1 OR /Modules/<Name>/<Name>.psd1.
$moduleRoot = Join-Path $PSScriptRoot 'Modules'
foreach ($name in 'Xdr.Common.Telemetry','Xdr.Auth','Xdr.Poll','Xdr.Ingest','Xdr.Parser') {
    $psd1 = Get-ChildItem -Path (Join-Path $moduleRoot $name) -Filter "$name.psd1" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($psd1) {
        Import-Module $psd1.FullName -Force -ErrorAction Stop
        Write-Information "profile.ps1: imported $name from $($psd1.FullName)" -InformationAction Continue
    } else {
        # ITER4 S6 · Fail-fast on critical module miss. Under StrictMode, run.ps1 calls
        # Write-XdrTelemetry / Connect-DefenderPortal / Send-ToDce immediately at cycle start ·
        # a missing module silently warned at boot → unbounded exception throw mid-cycle · DLQ stranded.
        # Throw at cold-start so Functions runtime surfaces the deployment error visibly.
        throw "profile.ps1: required module '$name' not found under $moduleRoot · function-app.zip is malformed · re-run tools/Build-FunctionAppZip.ps1 and re-deploy."
    }
}
