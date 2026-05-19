#Requires -Version 7.4
<#
.SYNOPSIS
    Builds the function-app.zip that WEBSITE_RUN_FROM_PACKAGE consumes.
    Verifies layout matches what the FA runtime expects.

.DESCRIPTION
    Layout (FLAT — no extra `functions/` wrapper):
        host.json
        profile.ps1
        requirements.psd1
        Xdr-Poll/function.json
        Xdr-Poll/run.ps1
        Modules/Xdr.Auth/Xdr.Auth.psd1
        Modules/Xdr.Auth/Xdr.Auth.psm1
        Modules/Xdr.Poll/...
        Modules/Xdr.Ingest/...
        manifests/defender.psd1

    Optionally bundles Az.Accounts + Az.KeyVault (since managedDependency is
    disabled in host.json). When -BundleAz is omitted, the zip is smaller and
    relies on the operator running `Save-Module` post-clone (documented).

.PARAMETER OutputPath
    Where to write the zip. Default: <repo>/bin/function-app.zip.

.PARAMETER BundleAz
    Include Az.Accounts + Az.KeyVault pinned to requirements.psd1 versions.

.PARAMETER MaxSizeMB
    Soft cap on zip size. Default 25 (FA WEBSITE_RUN_FROM_PACKAGE soft limit).

.PARAMETER SyncArmDefenderSubAreas
    φ.I · auto-regenerate `defenderSubAreas` ARM variable in deploy/mainTemplate.json
    from manifests/defender.psd1 (sorted · unique SubArea distinct values). Prevents
    drift between manifest reality and ARM template. Default: $true (writes IN-PLACE
    before staging). Set $false to skip (test isolation).
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$BundleAz,
    [int]$MaxSizeMB = 25,
    [bool]$SyncArmDefenderSubAreas = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# φ.I · ARM defenderSubAreas auto-sync from manifest (drift prevention)
function Update-ArmDefenderSubAreas {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$RepoRoot)
    $manifestPath = Join-Path $RepoRoot 'manifests\defender.psd1'
    $armPath      = Join-Path $RepoRoot 'deploy\mainTemplate.json'
    if (-not (Test-Path $manifestPath) -or -not (Test-Path $armPath)) {
        Write-Warning "Update-ArmDefenderSubAreas: source(s) missing · skipping auto-sync"
        return
    }
    $manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $manifestPath)))
    $subAreas = @($manifest.Entries | ForEach-Object SubArea | Sort-Object -Unique)
    if (-not $subAreas -or $subAreas.Count -eq 0) {
        Write-Warning "Update-ArmDefenderSubAreas: manifest has no SubArea field · skipping"
        return
    }
    # Read ARM as JSON (object · preserves order via -AsHashtable)
    $arm = Get-Content -Raw -LiteralPath $armPath | ConvertFrom-Json -AsHashtable
    if (-not $arm.ContainsKey('variables')) {
        Write-Warning "Update-ArmDefenderSubAreas: ARM lacks variables block · skipping"
        return
    }
    $current = if ($arm.variables.ContainsKey('defenderSubAreas')) { @($arm.variables.defenderSubAreas) } else { @() }
    # Compare sorted
    $currentSorted = @($current | Sort-Object)
    $newSorted     = @($subAreas)
    $drift = $false
    if ($currentSorted.Count -ne $newSorted.Count) { $drift = $true }
    else { for ($i=0; $i -lt $newSorted.Count; $i++) { if ($currentSorted[$i] -ne $newSorted[$i]) { $drift = $true; break } } }
    if (-not $drift) {
        Write-Host "  ARM defenderSubAreas already in sync ($($newSorted.Count) entries)" -ForegroundColor DarkGray
        return
    }
    Write-Host "  ARM defenderSubAreas drift detected · updating ($($currentSorted.Count) → $($newSorted.Count))" -ForegroundColor Yellow
    $arm.variables['defenderSubAreas'] = $newSorted
    # Write back · preserve 2-space indent + sorted variables alphabetical NOT enforced (preserve ARM order)
    $json = $arm | ConvertTo-Json -Depth 50
    Set-Content -LiteralPath $armPath -Value $json -Encoding UTF8 -NoNewline
    Write-Host "  ARM defenderSubAreas updated to $($newSorted.Count) entries: $($newSorted -join ', ')" -ForegroundColor Green
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcRoot  = Join-Path $repoRoot 'src'
$mfRoot   = Join-Path $repoRoot 'manifests'

if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'bin\function-app.zip' }
$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

# φ.I · ARM auto-sync · regenerate `defenderSubAreas` from manifest before staging
if ($SyncArmDefenderSubAreas) {
    Write-Host "φ.I · ARM auto-sync · checking defenderSubAreas drift..." -ForegroundColor Cyan
    Update-ArmDefenderSubAreas -RepoRoot $repoRoot
}

$stageDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-faz-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

try {
    # Copy host.json + profile.ps1 + requirements.psd1 to root
    foreach ($f in 'host.json','profile.ps1','requirements.psd1') {
        Copy-Item -Path (Join-Path $srcRoot $f) -Destination $stageDir -Force
    }
    # Copy each function dir
    Get-ChildItem -Path (Join-Path $srcRoot 'functions') -Directory | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $stageDir -Recurse -Force
    }
    # Copy Modules/ (the Xdr.* modules — Az.* bundled separately on -BundleAz)
    $modOut = Join-Path $stageDir 'Modules'
    New-Item -ItemType Directory -Path $modOut -Force | Out-Null
    Get-ChildItem -Path (Join-Path $srcRoot 'Modules') -Directory | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $modOut -Recurse -Force
    }
    # Copy manifests/
    Copy-Item -Path $mfRoot -Destination $stageDir -Recurse -Force

    # Optionally bundle Az modules
    if ($BundleAz) {
        Write-Host "Bundling Az modules (this may pull from PSGallery if not cached)..." -ForegroundColor DarkGray
        $req = Import-PowerShellDataFile -Path (Join-Path $srcRoot 'requirements.psd1')
        foreach ($name in $req.Keys) {
            $version = $req[$name]
            $saveTarget = Join-Path $modOut $name
            Save-Module -Name $name -RequiredVersion $version -Path $modOut -Force -ErrorAction Stop
            Write-Host "  bundled $name $version" -ForegroundColor DarkGray
        }
    }

    # Build the zip
    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $OutputPath -Force

    $sizeMB = [math]::Round((Get-Item $OutputPath).Length / 1MB, 2)
    Write-Host "Built: $OutputPath ($sizeMB MB)" -ForegroundColor Green

    if ($sizeMB -gt $MaxSizeMB) {
        Write-Warning "Zip is $sizeMB MB, soft cap is $MaxSizeMB MB. FA WEBSITE_RUN_FROM_PACKAGE may slow cold-starts."
    }

    [pscustomobject]@{
        Path     = $OutputPath
        SizeMB   = $sizeMB
        Bundled  = if ($BundleAz) { @($req.Keys) } else { @() }
    }
} finally {
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
}
