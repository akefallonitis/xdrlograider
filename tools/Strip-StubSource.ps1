#requires -Version 7.0
<#
.SYNOPSIS
  ITER10 quality-fix · strip _StubSource sentinel key from ProjectionMap.

.DESCRIPTION
  Apply-ProjectionMaps had been injecting a `_StubSource` sentinel key into the
  generic 14-key stub ProjectionMap with a literal string value (e.g.,
  `'irreducible-no-rich-postman-success'`). This violates the Manifest.Defender.FullCatalogue
  test invariant that every ProjectionMap value matches typed-DSL regex
  `^\$(tostring|toint|...):\$\.{1,2}(...)`. Provenance is correctly tracked at
  entry-level via Source + IrreducibleSchema + IrreducibleReason · the PM-key
  sentinel was redundant + test-breaking.

  This tool removes the _StubSource line from every ProjectionMap block.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = [System.Collections.Generic.List[string]]::new()
Get-Content $ManifestPath | ForEach-Object { [void]$lines.Add($_) }
$beforeCount = $lines.Count

# Remove every line matching: ^<whitespace>_StubSource ... $
$kept = [System.Collections.Generic.List[string]]::new()
$stripped = 0
foreach ($ln in $lines) {
    if ($ln -match '^\s+_StubSource\s+=') { $stripped++; continue }
    [void]$kept.Add($ln)
}

if (-not $PSCmdlet.ShouldProcess($ManifestPath, "Strip $stripped _StubSource lines")) { return }

[System.IO.File]::WriteAllLines($ManifestPath, $kept.ToArray(), [System.Text.UTF8Encoding]::new($false))
Write-Host ("Stripped $stripped _StubSource lines · $beforeCount -> $($kept.Count) lines") -ForegroundColor Green

# Verify
$m = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
$cnt = @($m.Entries | Where-Object { $_.ProjectionMap -and $_.ProjectionMap.ContainsKey('_StubSource') }).Count
Write-Host ("Remaining entries with _StubSource: $cnt (expected: 0)") -ForegroundColor Cyan
