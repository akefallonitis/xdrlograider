#Requires -Version 7.4
<#
.SYNOPSIS
Build deterministic function-app.zip from src/ for FA deployment.

.DESCRIPTION
Packages src/ (host.json + profile.ps1 + requirements.psd1 + functions/ + Modules/)
plus manifests/ (when populated in Phase 2+) into function-app.zip.

Excludes:
- tools/ (CI-only · operator tooling · NEVER inside FA)
- tests/ (replay tests · CI-only)
- .audit/ (audit artifacts · git-tracked but not FA payload)
- references/ (raw sources · git-tracked but not FA payload)
- .git/ · .github/ · *.md (dev metadata)

Determinism: file mtimes normalized to 2026-01-01 · ZIP central directory ordering stable.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string] $OutputPath = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'function-app.zip')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

Write-Host "Build-FunctionAppZip · root=$RepoRoot · output=$OutputPath"

# iter#15 (2026-06-03) · NO Az MODULE BUNDLING. The iter#14 Save-Module pre-stage was removed:
# bundling Az.Accounts + Az.KeyVault as an independently-pinned pair caused Az.KeyVault 6.5.0 to
# fail loading its private assembly (Az.KeyVault.private) against Az.Accounts 5.5.0 on the Legion
# worker (empty RequiredModules in Az.KeyVault.psd1 = no coherence enforcement), cascade-failing the
# load of EVERY Xdr.* module and killing the data plane. The connector now uses managed-identity REST
# everywhere (KV data-plane REST in Xdr.Common.Cache · monitor.azure.com token in Xdr.Common.Ingest ·
# storage.azure.com token in Xdr.Common.Storage) so there is ZERO Az PowerShell dependency at runtime.
# The function-app.zip therefore contains ONLY the ~100KB of src/ (no bundled modules). Any stale
# src/Modules/Az.* directory (left by a prior iter#14 build · gitignored) is excluded below and the
# layout guard at the end FAILS the build if any Az.* entry sneaks into the zip.

# Include list (relative to repo root)
$includeDirs = @('src','manifests')
$includeFiles = @()  # ad-hoc additions

# Exclude patterns within included dirs
$excludePatterns = @(
    '\.git/', '\.github/', '\.audit/', 'references/', 'tools/', 'tests/',
    'node_modules/', '\.venv/', 'venv/', '__pycache__/', '\.pytest_cache/',
    '\.vs/', '\.vscode/', 'bin/', 'obj/',
    'src/Modules/Az\.',   # iter#15 · NEVER bundle Az PowerShell modules (runtime is MSI REST · see header)
    '\.log$', '\.tmp$', '\.zip$', '\.pyc$', 'Thumbs\.db$', '\.DS_Store$'
)

# Collect files
$filesToInclude = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($d in $includeDirs) {
    $dirPath = Join-Path $RepoRoot $d
    if (Test-Path $dirPath) {
        Get-ChildItem -Path $dirPath -Recurse -File -Force | ForEach-Object {
            $relPath = $_.FullName.Substring($RepoRoot.Length + 1) -replace '\\','/'
            $excluded = $false
            foreach ($pat in $excludePatterns) {
                if ($relPath -match $pat) { $excluded = $true; break }
            }
            if (-not $excluded) { $filesToInclude.Add($_) }
        }
    }
}

if ($filesToInclude.Count -eq 0) {
    throw "No files found to include in function-app.zip · src/ + manifests/ both empty"
}

Write-Host "Files to include: $($filesToInclude.Count)"

# Delete existing zip
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

# Normalized mtime for determinism
$normalizedTime = [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

# Create zip
$zipStream = [System.IO.File]::Create($OutputPath)
$archive = [System.IO.Compression.ZipArchive]::new($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    # Sort for stable ordering (determinism)
    $sortedFiles = $filesToInclude | Sort-Object { $_.FullName.Substring($RepoRoot.Length + 1) -replace '\\','/' }
    foreach ($f in $sortedFiles) {
        $rawRel = $f.FullName.Substring($RepoRoot.Length + 1) -replace '\\','/'
        # iter#10 PACKAGING FIX (2026-06-03) · Azure Functions runtime requires host.json + function dirs at PACKAGE ROOT.
        # Repo layout has them under src/ (host.json · profile.ps1 · requirements.psd1) and src/functions/<Name>/ (function definitions).
        # When zipping we MUST strip the src/functions/ prefix from function dirs · AND the src/ prefix from host.json + profile.ps1 + requirements.psd1 + Modules/.
        # Without this strip the deployed zip has src/host.json which the Functions runtime cannot discover · failing with
        # 'No functions were found. A valid host.json file wasnt found in the package root. However, one was located at: /src/host.json'.
        # manifests/ stays at root (no prefix) because the runtime reads them via repo-relative path from profile.ps1.
        if ($rawRel.StartsWith('src/functions/')) {
            $entryName = $rawRel.Substring('src/functions/'.Length)
        } elseif ($rawRel.StartsWith('src/')) {
            $entryName = $rawRel.Substring('src/'.Length)
        } else {
            $entryName = $rawRel
        }
        $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $normalizedTime
        $entryStream = $entry.Open()
        try {
            $fileStream = [System.IO.File]::OpenRead($f.FullName)
            try {
                $fileStream.CopyTo($entryStream)
            } finally { $fileStream.Dispose() }
        } finally { $entryStream.Dispose() }
    }

    # WS4.3 · BUILD_SHA baked INTO the artifact (package root · next to host.json/profile.ps1). profile.ps1
    # reads it artifact-first for Boot.VersionProbe, so the deployed build's identity travels WITH the zip —
    # release, local Deploy-FaPackageLocal and CI all get it for free (no per-tool stamping to forget).
    # Resolved from git HEAD at build time; 'unknown' only when git is unavailable (never fabricated).
    $buildSha = 'unknown'
    try {
        $gitSha = (& git -C $RepoRoot rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitSha) { $buildSha = ([string]$gitSha).Trim() }
    } catch { <# INTENTIONAL-FAIL-SAFE · no git → 'unknown' · the version gate then reports inconclusive, never false-green #> }
    $shaEntry = $archive.CreateEntry('BUILD_SHA', [System.IO.Compression.CompressionLevel]::Optimal)
    $shaEntry.LastWriteTime = $normalizedTime
    $shaStream = $shaEntry.Open()
    try {
        $shaBytes = [System.Text.Encoding]::UTF8.GetBytes($buildSha)
        $shaStream.Write($shaBytes, 0, $shaBytes.Length)
    } finally { $shaStream.Dispose() }
    Write-Host "BUILD_SHA baked into zip: $buildSha"
} finally {
    $archive.Dispose()
    $zipStream.Dispose()
}

$sizeBytes = (Get-Item $OutputPath).Length
$sizeMB = [math]::Round($sizeBytes / 1MB, 2)
$sha256 = (Get-FileHash $OutputPath -Algorithm SHA256).Hash.ToLower()
Write-Host "Built: $OutputPath · ${sizeMB}MB · sha256=$($sha256.Substring(0,16))..."

# iter#10 PACKAGING REGRESSION GUARD (2026-06-03) · verify Azure Functions PowerShell convention
# host.json MUST be at zip ROOT (not under src/) · functions MUST be at zip ROOT (not under src/functions/)
# Per-function · function.json + run.ps1 must both be at <FunctionName>/ directly inside the zip.
# This guard catches the iter#10 'No functions were found · host.json found at /src/host.json' deploy-blocker.
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
$zipForVerify = [System.IO.Compression.ZipFile]::OpenRead($OutputPath)
try {
    $entryNames = @($zipForVerify.Entries | ForEach-Object { $_.FullName })
    $layoutIssues = @()
    if ($entryNames -notcontains 'host.json') { $layoutIssues += "host.json MISSING at zip root" }
    if ($entryNames | Where-Object { $_ -eq 'src/host.json' }) { $layoutIssues += "host.json incorrectly at src/host.json instead of root" }
    $functionDirs = @('XdrDefenderRefresh', 'XdrDefenderOrchestrator', 'XdrDefenderActivity')
    foreach ($fd in $functionDirs) {
        if ($entryNames -notcontains "$fd/function.json") { $layoutIssues += "$fd/function.json MISSING at zip root" }
        if ($entryNames -notcontains "$fd/run.ps1") { $layoutIssues += "$fd/run.ps1 MISSING at zip root" }
    }
    if ($entryNames | Where-Object { $_ -match '^src/functions/' }) { $layoutIssues += "function dirs incorrectly under src/functions/ instead of root" }
    # iter#15 · the FA runtime is MSI-REST only · NO Az PowerShell module may ship inside the zip
    # (bundling Az.KeyVault broke every module load on Legion via the Az.KeyVault.private skew).
    $azEntries = @($entryNames | Where-Object { $_ -match '^Modules/Az\.' })
    if ($azEntries.Count -gt 0) { $layoutIssues += "Az PowerShell module(s) present in zip ($($azEntries.Count) entries · e.g. $($azEntries[0])) · iter#15 forbids bundled Az · runtime is MSI REST" }
    if ($entryNames -notcontains 'profile.ps1') { Write-Warning "profile.ps1 MISSING at zip root · cold-start telemetry + module load + R3 capabilities will not fire" }
    if ($entryNames -notcontains 'requirements.psd1') { Write-Warning "requirements.psd1 MISSING at zip root" }
    if ($layoutIssues.Count -gt 0) {
        $msg = "Build-FunctionAppZip · LAYOUT FAIL · zip violates Azure Functions PowerShell convention:`n  - " + ($layoutIssues -join "`n  - ")
        throw $msg
    }
    Write-Host "Build-FunctionAppZip · LAYOUT GREEN · host.json + 3 function dirs + profile.ps1 + requirements.psd1 at zip root"
} finally {
    $zipForVerify.Dispose()
}

# iter#15 · Az modules must NOT be present (runtime is MSI REST · zero Az PowerShell dependency).
$azStaged = (Test-Path (Join-Path $RepoRoot 'src/Modules/Az.Accounts')) -or (Test-Path (Join-Path $RepoRoot 'src/Modules/Az.KeyVault'))
if ($azStaged) {
    Write-Warning "Stale src/Modules/Az.* present on disk (excluded from zip · gitignored) · safe to delete · runtime no longer uses Az PowerShell"
}

[PSCustomObject]@{
    OutputPath = $OutputPath
    Bytes = $sizeBytes
    MB = $sizeMB
    Sha256 = $sha256
    FileCount = $filesToInclude.Count
    AzStagedLocally = $azStaged
}
