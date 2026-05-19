#Requires -Version 7.4
# Audit live-capture failure modes · used in φ.A to identify fixable failures
# vs truly irreducible (license-gated) before falling back to OpenAPI/Postman.
[CmdletBinding()]
param([string]$FixturesRoot = (Join-Path $PSScriptRoot '..\tests\fixtures\live'))

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$metas = Get-ChildItem $FixturesRoot -Filter 'meta.json' -Recurse | ForEach-Object {
    try { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json } catch { $null }
} | Where-Object { $_ }

Write-Host "Total meta.json: $($metas.Count)" -ForegroundColor Cyan
Write-Host ""

$grouped = $metas | Group-Object Classification | Sort-Object Count -Descending
foreach ($g in $grouped) {
    Write-Host ("[{0,4}] {1}" -f $g.Count, $g.Name) -ForegroundColor $(
        switch -Regex ($g.Name) {
            '^live'                                       { 'Green' }
            'license|unreachable-404'                     { 'DarkRed' }
            'error|exception|html|unresolved|skipped-w'   { 'Yellow' }
            default                                       { 'White' }
        }
    )
    # Show 3 samples per category
    $samples = @($g.Group | Select-Object -First 3)
    foreach ($s in $samples) {
        $method = if ($s.PSObject.Properties['Method'] -and $s.Method) { [string]$s.Method } else { '?' }
        $path = if ($s.PSObject.Properties['Path'] -and $s.Path) { [string]$s.Path } else { '?' }
        $sc = if ($s.PSObject.Properties['StatusCode']) { [string]$s.StatusCode } else { '?' }
        # Truncate path for readability
        if ($path.Length -gt 80) { $path = $path.Substring(0, 77) + '...' }
        Write-Host ("      {0,-6} {1,-80} → {2}" -f $method, $path, $sc) -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Categorization for fallback decision (operator-directed methodology):" -ForegroundColor Cyan
$irreducible = @($metas | Where-Object { $_.Classification -match '^(license-gated|unreachable-404|skipped-write|skipped-mutation|skipped-pathparams)$' }).Count
$fixable     = @($metas | Where-Object { $_.Classification -match '^(error-|exception|html-|unresolved-)' }).Count
$live        = @($metas | Where-Object { $_.Classification -match '^live' }).Count
$other       = $metas.Count - $irreducible - $fixable - $live
Write-Host ("  live (verified working)              : {0,4}" -f $live)        -ForegroundColor Green
Write-Host ("  truly irreducible (license/mutation) : {0,4}" -f $irreducible) -ForegroundColor DarkRed
Write-Host ("  FIXABLE (debug → re-probe)           : {0,4}" -f $fixable)     -ForegroundColor Yellow
Write-Host ("  other (unclassified)                 : {0,4}" -f $other)       -ForegroundColor White
