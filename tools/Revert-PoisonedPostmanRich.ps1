#requires -Version 7.0
<#
.SYNOPSIS
  ITER10 quality-fix · revert poisoned postman-rich entries to stub.

.DESCRIPTION
  Prior Enrich-PostmanResponseSchemas tool had a status-code bug · accepted
  4xx error-response bodies (87-byte {"error":{"code":"BadRequest","message":..}})
  over empty success bodies ({}/[]) because of MinBodyChars=50 filter.
  Result: 246 entries got Source='postman-rich' but ProjectionMap was just
  Code/Message from error shape · NOT endpoint-specific success schema.

  This tool detects + reverts those entries:
    Source='postman-rich' AND PM has <=5 keys AND keys subset of {Code,Message,ErrorCode,ErrorMessage}
  reverts to Source='stub' + canonical 14-key entity scaffold.

  After this · re-run Enrich-PostmanResponseSchemas (now with 2xx filter) to
  get HONEST endpoint-specific lifts (smaller count · accurate).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestText = Get-Content -Raw -LiteralPath $ManifestPath
$manifest = & ([scriptblock]::Create($manifestText))
$entries = @($manifest.Entries)

$poisoned = @($entries | Where-Object {
    $_.Source -in @('postman-rich','postman') -and
    $_.ProjectionMap -and (
        # Pattern 1 · error-shape (Code/Message/code/message from {"error":{"code":"..","message":".."}})
        (@($_.ProjectionMap.Keys).Count -le 5 -and
         ($_.ProjectionMap.ContainsKey('Code') -or $_.ProjectionMap.ContainsKey('Message') -or
          $_.ProjectionMap.ContainsKey('code') -or $_.ProjectionMap.ContainsKey('message') -or
          $_.ProjectionMap.ContainsKey('ErrorCode'))) -or
        # Pattern 2 · garbage field names (Key_0/Key_1/Key_N from positional array walk)
        (@($_.ProjectionMap.Keys | Where-Object { $_ -match '^Key_\d+$' })).Count -gt 0
    )
})
Write-Host "Detected $($poisoned.Count) poisoned entries · reverting to stub + canonical scaffold" -ForegroundColor Yellow

if ($poisoned.Count -eq 0) { Write-Host 'Nothing to revert'; return }
if (-not $PSCmdlet.ShouldProcess($ManifestPath, "Revert $($poisoned.Count) poisoned entries")) { return }

# Canonical 13-key generic scaffold (matches Apply-ProjectionMaps stub output · all typed-DSL).
# NB: NO _StubSource key here · Manifest.Defender.FullCatalogue Tests asserts every
# ProjectionMap value matches typed-DSL regex `^\$(tostring|toint|...):\$\.{1,2}(...)`,
# a literal sentinel string would fail. Irreducible-stub provenance is tracked via the
# IrreducibleSchema=$true + IrreducibleReason fields at the entry top-level (Mark-IrreducibleStubs.ps1).
$canonicalStub = [ordered]@{
    DeviceId          = '$tostring:$..deviceId|$..machineId'
    UserPrincipalName = '$tostring:$..userPrincipalName|$..upn'
    IpAddress         = '$tostring:$..ipAddress|$..ip'
    Url               = '$tostring:$..url'
    FileHash          = '$tostring:$..fileHash|$..sha256|$..sha1'
    ProcessName       = '$tostring:$..processName'
    AlertId           = '$tostring:$..alertId'
    IncidentId        = '$tostring:$..incidentId'
    MessageId         = '$tostring:$..messageId'
    Mailbox           = '$tostring:$..mailbox'
    AppName           = '$tostring:$..appName'
    ResourceId        = '$tostring:$..resourceId'
    ThreatName        = '$tostring:$..threatName'
}

$lines = [System.Collections.Generic.List[string]]::new()
Get-Content $ManifestPath | ForEach-Object { [void]$lines.Add($_) }

# Build block index (same pattern as Enrich tool)
$blocks = @{}
$current = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if (-not $current -and $ln -match '^        @\{\s*$') {
        $current = @{ Start=$i; EntryKey=$null; PMStart=$null; PMEnd=$null; SourceLine=$null }
    }
    if ($current) {
        if ($ln -match "^\s+EntryKey\s+=\s+'([^']+)'") { $current.EntryKey = $Matches[1] }
        elseif ($ln -match '^\s+ProjectionMap\s+=\s+@\{') { $current.PMStart = $i }
        elseif ($current.PMStart -and -not $current.PMEnd -and $ln -match '^            \}') { $current.PMEnd = $i }
        elseif ($ln -match "^(\s+Source\s+=\s+)'([^']+)'") { $current.SourceLine = $i }
        elseif ($ln -match '^        \},?\s*$') {
            if ($current.EntryKey -and $current.PMStart -and $current.PMEnd) {
                $blocks[$current.EntryKey] = $current
            }
            $current = $null
        }
    }
}

# Apply reverts in reverse order
$poisonedKeys = $poisoned | ForEach-Object { $_.EntryKey }
$sorted = $poisonedKeys | Sort-Object -Property { $blocks[$_].PMEnd } -Descending
$reverted = 0
foreach ($ek in $sorted) {
    $b = $blocks[$ek]
    if (-not $b) { continue }
    # Build new ProjectionMap lines (canonical 14-key stub)
    $pmLines = @('            ProjectionMap        = @{')
    foreach ($k in ($canonicalStub.Keys | Sort-Object)) {
        $v = $canonicalStub[$k] -replace "'", "''"
        $pmLines += "                $k".PadRight(40) + " = '$v'"
    }
    $pmLines += '            }'
    # Replace old PM block
    $lines.RemoveRange($b.PMStart, ($b.PMEnd - $b.PMStart + 1))
    for ($i = $pmLines.Count - 1; $i -ge 0; $i--) {
        $lines.Insert($b.PMStart, $pmLines[$i])
    }
    # Reset Source line to 'stub'
    if ($b.SourceLine) {
        for ($j = $b.PMStart; $j -lt $lines.Count -and $j -lt $b.PMStart + 60; $j++) {
            if ($lines[$j] -match "^(\s+Source\s+=\s+)'([^']+)'(.*)$") {
                $lines[$j] = $Matches[1] + "'stub'" + $Matches[3]
                break
            }
        }
    }
    $reverted++
}

[System.IO.File]::WriteAllLines($ManifestPath, $lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
Write-Host "DONE · reverted $reverted entries · re-run Enrich-PostmanResponseSchemas with the 2xx fix" -ForegroundColor Green

# Verify
$m = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
$m.Entries | Group-Object Source | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize
