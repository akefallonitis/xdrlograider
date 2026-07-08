#Requires -Version 7.4
<#
.SYNOPSIS
PUBLIC-ALLOWLIST matcher (locked decision G4 · single-repo deny-by-default). Every git-TRACKED path must match
tools/public-allowlist.txt (dir-prefix entries end with '/'; anything else is an exact file). Returns the violation
list; exit 0 = clean, exit 1 = violations. Gauntlet axis 35 is the enforcing caller; the Pester unit test drives
-Paths directly (RED-able without mutating the repo).

.PARAMETER RepoRoot
Repo root (defaults to this script's parent's parent).

.PARAMETER Paths
OPTIONAL explicit path list (forward-slash relative paths). Omitted → `git ls-files` of the repo.

.PARAMETER AllowlistPath
OPTIONAL explicit allowlist file (defaults to tools/public-allowlist.txt under RepoRoot).
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string[]] $Paths,
    [string] $AllowlistPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $AllowlistPath) { $AllowlistPath = Join-Path $RepoRoot 'tools/public-allowlist.txt' }
if (-not (Test-Path $AllowlistPath)) { Write-Error "allowlist missing: $AllowlistPath"; exit 1 }

$entries = @(Get-Content $AllowlistPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
$dirPrefixes = @($entries | Where-Object { $_.EndsWith('/') })
$exactFiles  = [System.Collections.Generic.HashSet[string]]::new([string[]]@($entries | Where-Object { -not $_.EndsWith('/') }), [System.StringComparer]::Ordinal)

if (-not $PSBoundParameters.ContainsKey('Paths')) {
    $Paths = @(& git -C $RepoRoot ls-files)
    if ($LASTEXITCODE -ne 0) { Write-Error 'git ls-files failed'; exit 1 }
}

$violations = [System.Collections.Generic.List[string]]::new()
foreach ($p in $Paths) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $n = $p.Replace('\', '/')
    if ($exactFiles.Contains($n)) { continue }
    $allowed = $false
    foreach ($d in $dirPrefixes) { if ($n.StartsWith($d, [System.StringComparison]::Ordinal)) { $allowed = $true; break } }
    if (-not $allowed) { $violations.Add($n) }
}

foreach ($v in $violations) { Write-Output $v }
exit ([int]($violations.Count -gt 0))
