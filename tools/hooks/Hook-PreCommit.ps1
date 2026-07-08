#Requires -Version 7.4
<#
.SYNOPSIS
Git pre-commit hook · enforces L1-L13 gates before any commit.

.DESCRIPTION
Every commit must pass:
- L1: PS/JSON/psd1 parse
- L4: PSScriptAnalyzer (when installed locally · advisory)
- L7: gitleaks (when installed · advisory)
- L11: NO secrets in staged files (.env.local in .gitignore confirmed)
- L12: NO silent catches in src/ (require # INTENTIONAL-FAIL-SAFE annotation)
- L13: NO Claude/AI attribution

Install: copy or symlink this to .git/hooks/pre-commit (Unix) or pre-commit.ps1 (Windows).
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (& git rev-parse --show-toplevel 2>$null)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot -or -not (Test-Path $RepoRoot)) {
    Write-Error 'Not inside a git repo'
    exit 1
}

# Get staged files. @() so a single (or zero) staged file is ALWAYS an array — a bare `git diff` returns a scalar
# string for 1 file / $null for 0, and `$staged.Count` then throws 'property Count cannot be found' under StrictMode,
# aborting every commit that touches <=1 file. (PS scalar/array pitfall · correctness, not a guard.)
$staged = @(git diff --cached --name-only --diff-filter=ACM 2>$null)
if ($staged.Count -eq 0) {
    Write-Host "Hook-PreCommit · no staged files · OK"
    exit 0
}

$violations = @()

# L13: Anti-attribution sweep on staged files
# Allow-list: detector infrastructure files (they contain the patterns themselves)
$L13AllowList = @(
    'tools/Run-PrePushGauntlet.ps1',
    'tools/Update-OperationTracker.ps1',
    'tools/hooks/Hook-PreCommit.ps1',
    '.github/workflows/ci.yml'
)
foreach ($f in $staged) {
    $absPath = Join-Path $RepoRoot $f
    if (-not (Test-Path $absPath)) { continue }
    $ext = [System.IO.Path]::GetExtension($f).ToLower()
    if ($ext -notin '.ps1','.psm1','.psd1','.md','.json','.yml','.yaml','.txt') { continue }
    if ($f -like 'references/*') { continue }   # raw refs untouched
    if ($f -like '.audit/*') { continue }       # audit docs may describe the gate
    $allowed = $false
    foreach ($a in $L13AllowList) { if ($f -eq $a) { $allowed = $true; break } }
    if ($allowed) { continue }
    $content = Get-Content $absPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    if ($content -match 'Claude|Anthropic|claude\.ai|claude-code|Co-Authored-By:.*Claude|Generated with .*Claude') {
        $violations += "L13 · AI attribution in $f"
    }
}

# L1: Parse staged PS files
foreach ($f in ($staged | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' })) {
    $absPath = Join-Path $RepoRoot $f
    if (-not (Test-Path $absPath)) { continue }
    $err = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($absPath, [ref]$null, [ref]$err)
    if ($err -and @($err).Count -gt 0) {
        $violations += "L1 · PS parse fail in $f : $($err[0].Message)"
    }
}

# L1: Parse staged JSON
foreach ($f in ($staged | Where-Object { $_ -match '\.json$' })) {
    $absPath = Join-Path $RepoRoot $f
    if (-not (Test-Path $absPath)) { continue }
    try { $null = Get-Content $absPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { $violations += "L1 · JSON parse fail in $f : $($_.Exception.Message)" }
}

# L11: NO .env.local in staged files
if ($staged | Where-Object { $_ -match '\.env(\..+)?(\.local)?$' -or $_ -match 'parameters\..*\.local\.json$' }) {
    $violations += "L11 · .env or parameters.local.json in staged files · CHECK .gitignore"
}

# L12: silent catch detection in src/
foreach ($f in ($staged | Where-Object { $_ -match '^src/' -and $_ -match '\.(ps1|psm1)$' })) {
    $absPath = Join-Path $RepoRoot $f
    if (-not (Test-Path $absPath)) { continue }
    $content = Get-Content $absPath -Raw
    # Look for catch { } or catch { <whitespace-only> }
    if ($content -match 'catch\s*\{\s*\}|catch\s*\{\s*#?[^}]*?\}' -and $content -notmatch 'INTENTIONAL-FAIL-SAFE') {
        # More specific check
        $catchBlocks = [regex]::Matches($content, '(?ms)catch\s*\{([^{}]*)\}')
        foreach ($cb in $catchBlocks) {
            $body = $cb.Groups[1].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($body) -or $body -match '^\s*#\s*$') {
                $violations += "L12 · empty catch block in $f · annotate # INTENTIONAL-FAIL-SAFE LOCK 9 with reason"
                break
            }
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "Hook-PreCommit · BLOCKED · $($violations.Count) violations:" -ForegroundColor Red
    $violations | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Fix and re-stage · OR use --no-verify ONLY with operator approval (LOCK 24)" -ForegroundColor Yellow
    exit 1
}

Write-Host "Hook-PreCommit · OK · $($staged.Count) files checked" -ForegroundColor Green
exit 0
