#Requires -Version 7.4
<#
.SYNOPSIS
    Validates tests/.env.local for a given tier (1, 2, or 3) and loads env vars into the process.

.DESCRIPTION
    Tier 1 (unit): no env required.
    Tier 2 (integration): AZURE_TENANT_ID + AZURE_CLIENT_ID + XDRLR_SUBSCRIPTION_ID +
                          XDRLR_TEST_RG. AZURE_CLIENT_SECRET optional locally (use device
                          login if blank); required if running unattended.
    Tier 3 (live):        all of the above + XDRLR_TEST_UPN + XDRLR_TEST_PASSWORD +
                          XDRLR_TEST_TOTP_SECRET.
    Tier 4 (live-connected): Pi5 · D-pi4 · all Tier-2 vars + XDRLR_CONNECTOR_RG +
                          XDRLR_WORKSPACE_ID + AZURE_CLIENT_SECRET (required ·
                          unattended SP login for KQL + Storage Table probes).

    Asserts the file is gitignored (defensive). Fails fast with one-line error naming
    the missing var.

.PARAMETER Tier
    Mandatory: 1 | 2 | 3.

.PARAMETER EnvFile
    Default: tests/.env.local relative to repo root.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('1','2','3','4')][string]$Tier,
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env.local')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tierRequirements = @{
    '1' = @()
    '2' = @('AZURE_TENANT_ID','AZURE_CLIENT_ID','XDRLR_SUBSCRIPTION_ID')
    '3' = @('AZURE_TENANT_ID','AZURE_CLIENT_ID','XDRLR_SUBSCRIPTION_ID',
            'XDRLR_TEST_UPN','XDRLR_TEST_PASSWORD','XDRLR_TEST_TOTP_SECRET')
    # Pi5 · Tier 4 (live-connected post-deploy) · SP + connector RG + workspace
    '4' = @('AZURE_TENANT_ID','AZURE_CLIENT_ID','AZURE_CLIENT_SECRET','XDRLR_SUBSCRIPTION_ID',
            'XDRLR_CONNECTOR_RG','XDRLR_WORKSPACE_ID')
}
# Tier 2/3 ALSO need an RG · accept either XDRLR_TEST_RG OR XDRLR_WORKSPACE_RG (whichever is set).
# Tier 4 uses XDRLR_CONNECTOR_RG explicitly (the RG where Deploy-Local.ps1 provisioned the connector).
$rgRequiredTiers = @('2','3')

$required = $tierRequirements[$Tier]
if ($required.Count -eq 0) {
    Write-Verbose "Tier $Tier requires no env vars."
    return
}

# Load env.local
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}

# Defensive: verify .env.local is gitignored at repo root
$repoRoot = Split-Path -Parent $PSScriptRoot
$gitIgnore = Join-Path $repoRoot '.gitignore'
if (Test-Path $gitIgnore) {
    $gi = Get-Content $gitIgnore -Raw
    if ($gi -notmatch '(?m)^\s*tests/\.env\.local\s*$') {
        Write-Warning "tests/.env.local is NOT in .gitignore. Add it before continuing."
    }
}

# Check required vars · use Get-Content fallback for StrictMode-safe null-handling
$missing = @()
foreach ($r in $required) {
    $envEntry = Get-Item "env:$r" -ErrorAction SilentlyContinue
    $v = if ($envEntry) { $envEntry.Value } else { $null }
    if ([string]::IsNullOrWhiteSpace($v)) { $missing += $r }
}
if ($missing.Count -gt 0) {
    throw "Tier $Tier requires env vars: $($required -join ', '). Missing: $($missing -join ', '). Populate $EnvFile (use $EnvFile.example as template)."
}

# Tier 2/3 RG fallback · accept either XDRLR_TEST_RG OR XDRLR_WORKSPACE_RG
if ($Tier -in $rgRequiredTiers) {
    $testRgItem      = Get-Item env:XDRLR_TEST_RG -ErrorAction SilentlyContinue
    $workspaceRgItem = Get-Item env:XDRLR_WORKSPACE_RG -ErrorAction SilentlyContinue
    $testRg      = if ($testRgItem)      { $testRgItem.Value      } else { $null }
    $workspaceRg = if ($workspaceRgItem) { $workspaceRgItem.Value } else { $null }
    if ([string]::IsNullOrWhiteSpace($testRg) -and [string]::IsNullOrWhiteSpace($workspaceRg)) {
        throw "Tier $Tier requires either XDRLR_TEST_RG or XDRLR_WORKSPACE_RG. Populate $EnvFile."
    }
}

Write-Verbose "Tier $Tier env validated: $($required.Count) vars present."
