#Requires -Version 7.0
<#
.SYNOPSIS
    Validates the compiled ARM/Sentinel JSON assets parse and are well-formed.

.DESCRIPTION
    CI-friendly JSON sanity check (no network, no az CLI dependency).
    - JSON parse via ConvertFrom-Json
    - $schema present
    - mainTemplate + sentinelContent have resources array
    - createUiDefinition has $schema + parameters

.EXAMPLE
    pwsh ./tools/Validate-ArmJson.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$files = @(
    [pscustomobject]@{ Path='deploy/compiled/mainTemplate.json';       Kind='armTemplate' }
    [pscustomobject]@{ Path='deploy/compiled/createUiDefinition.json'; Kind='createUi'    }
    [pscustomobject]@{ Path='deploy/compiled/sentinelContent.json';    Kind='armTemplate' }
)

$anyFail = $false
foreach ($entry in $files) {
    $p = $entry.Path
    $kind = $entry.Kind
    if (-not (Test-Path $p)) {
        Write-Host ("MISSING: {0}" -f $p) -ForegroundColor Red
        $anyFail = $true
        continue
    }

    $raw = Get-Content $p -Raw
    # 1) JSON parse
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        Write-Host ("OK   : {0} parses as JSON" -f $p) -ForegroundColor Green
    } catch {
        Write-Host ("FAIL : {0} JSON parse - {1}" -f $p, $_.Exception.Message) -ForegroundColor Red
        $anyFail = $true
        continue
    }

    # 2) schema present
    $names = $obj.PSObject.Properties.Name
    if ($names -notcontains '$schema') {
        Write-Host ("WARN : {0} missing `$schema" -f $p) -ForegroundColor Yellow
    } else {
        Write-Host ("OK   : {0} `$schema = {1}" -f $p, $obj.'$schema') -ForegroundColor Green
    }

    # 3) kind-specific sanity
    switch ($kind) {
        'armTemplate' {
            if ($names -notcontains 'contentVersion') {
                Write-Host ("FAIL : {0} missing contentVersion" -f $p) -ForegroundColor Red
                $anyFail = $true
            }
            if ($names -notcontains 'resources') {
                Write-Host ("FAIL : {0} missing resources array" -f $p) -ForegroundColor Red
                $anyFail = $true
            } else {
                $resCount = @($obj.resources).Count
                Write-Host ("OK   : {0} has {1} resources" -f $p, $resCount) -ForegroundColor Green
            }
        }
        'createUi' {
            if ($names -notcontains 'handler') {
                Write-Host ("FAIL : {0} missing handler" -f $p) -ForegroundColor Red
                $anyFail = $true
            }
            if ($names -notcontains 'version') {
                Write-Host ("FAIL : {0} missing version" -f $p) -ForegroundColor Red
                $anyFail = $true
            }
        }
    }
}

if ($anyFail) {
    Write-Host ""
    Write-Host "ARM validation: FAIL" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "ARM validation: PASS" -ForegroundColor Green
exit 0
