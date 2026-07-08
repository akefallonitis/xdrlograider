#Requires -Version 7.4
# PURE content-shape gate for Verify-XdrLiveContent (the machine half of the live-content proof).
# Dot-sourceable + side-effect-free so the offline gauntlet can RED-prove it. Content-correct ⟺
# envelope complete (6 parser-filled cols non-null) + RawJson valid JSON + >=1 ProjectionMap field
# resolved non-null. NOT a count check. The 6 cols MUST match ConvertTo-XdrRows' F2 row contract
# (TimeGenerated/Portal/Category/Subcategory/Operation/RawJson) — OperationKey was DROPPED in F2 (it
# duplicated Operation; RecordId/ParentRecordId/CorrelationId are ingest-injected post-parse, so the
# direct-source proof cannot see them and they are NOT gated here).
Set-StrictMode -Version Latest

function Test-XdrContentShape {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Rows,
        [hashtable] $ProjectionMap = @{}
    )
    $verdict = [ordered]@{ RowCount = 0; EnvelopeOk = $false; ProjectionResolved = 0; ProjectionTotal = 0; RawJsonOk = $false; Pass = $false; Reason = '' }
    $r = @($Rows)
    $verdict.RowCount = $r.Count
    if ($r.Count -lt 1) { $verdict.Reason = '0 rows'; return [pscustomobject]$verdict }
    $row = $r[0]
    if ($row -isnot [System.Collections.IDictionary]) { $verdict.Reason = 'row not a hashtable'; return [pscustomobject]$verdict }

    $envCols = @('TimeGenerated','Portal','Category','Subcategory','Operation','RawJson')
    $missing = @($envCols | Where-Object { -not $row.Contains($_) -or $null -eq $row[$_] -or '' -eq [string]$row[$_] })
    $verdict.EnvelopeOk = ($missing.Count -eq 0)

    $rawOk = $false
    if ($row.Contains('RawJson') -and $row['RawJson']) { try { $null = $row['RawJson'] | ConvertFrom-Json; $rawOk = $true } catch { $rawOk = $false } }
    $verdict.RawJsonOk = $rawOk

    $pm = if ($ProjectionMap) { $ProjectionMap } else { @{} }
    $verdict.ProjectionTotal = $pm.Keys.Count
    $resolved = 0
    foreach ($col in $pm.Keys) { if ($row.Contains($col) -and $null -ne $row[$col] -and '' -ne [string]$row[$col]) { $resolved++ } }
    $verdict.ProjectionResolved = $resolved

    $verdict.Pass = ($verdict.EnvelopeOk -and $rawOk -and $resolved -ge 1)
    if (-not $verdict.Pass) { $verdict.Reason = "envelope=$($verdict.EnvelopeOk) rawjson=$rawOk projected=$resolved/$($verdict.ProjectionTotal) missing=$($missing -join ',')" }
    return [pscustomobject]$verdict
}
