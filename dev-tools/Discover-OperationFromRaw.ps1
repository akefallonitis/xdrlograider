#Requires -Version 7.4
<#
.SYNOPSIS
Discover candidate Operations for a Category by scanning RAW sources · suggests pilot ranking.

.DESCRIPTION
Per Plan §3.3 dynamic pilot selection · this tool scans references/ to enumerate Operations within
a Category that have at least 1 RAW source (live preferred). Returns ranked candidate list ordered by:
- Live row count descending (40% weight)
- Method simplicity (GET > POST · 25%)
- PathParam dependency (none > with placeholder · 15%)
- Cadence semantic (List/Get > History/Export · 10%)
- License requirement (subset of operator tenant · 10%)

Drives senior-dev pilot selection (or operator override).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Defender','Entra','Intune','Purview','SecurityCopilot')] [string] $Portal,
    [Parameter(Mandatory)] [string] $Category,
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [int] $Top = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$refRoot = Join-Path $RepoRoot 'references'

# ─── Enumerate Operations from OpenAPI spec ──────────────────────────────────
$openapiPortalKey = switch ($Portal) {
    'Defender' { 'nodoc-defender-xdr' }
    'Entra'    { 'nodoc-entra' }
    'Intune'   { 'nodoc-intune' }
    'Purview'  { 'nodoc-purview' }
    'SecurityCopilot' { 'nodoc-security-copilot' }
}
$openapiPath = Join-Path $refRoot "openapi/$openapiPortalKey/specification/$Category.yml"

$operations = @()
if (Test-Path $openapiPath) {
    $content = Get-Content $openapiPath -Raw -ErrorAction SilentlyContinue
    if ($content) {
        # Extract operationId entries
        $regex = [regex] "(?m)^\s+operationId:\s*(\S+)\s*$"
        $matches = $regex.Matches($content)
        foreach ($m in $matches) {
            $opId = $m.Groups[1].Value
            # Find associated method by lookback
            $idx = $m.Index
            $lookback = $content.Substring([math]::Max(0, $idx - 500), [math]::Min(500, $idx))
            $method = $null
            if ($lookback -match '\s+(get|post|put|patch|delete):\s*$') {
                $method = $Matches[1].ToUpperInvariant()
            }
            # Find associated path
            $path = $null
            $deepLookback = $content.Substring([math]::Max(0, $idx - 2000), [math]::Min(2000, $idx))
            if ($deepLookback -match "(?m)^\s+(/[^\s:]+):\s*$") {
                $path = $Matches[1]
            }
            $operations += [pscustomobject]@{
                OperationId  = $opId
                Method       = $method
                Path         = $path
                HasPathParam = ($null -ne $path -and $path -match '\{[^}]+\}')
            }
        }
    }
}

# ─── Augment with live captures (row counts) ────────────────────────────────
foreach ($op in $operations) {
    $liveRowCount = 0
    $liveSource = $null
    $catLower = $Category.ToLowerInvariant()
    $opLower = $op.OperationId.ToLowerInvariant() -replace '\.',''

    # source-final-cross/by-path/<cat>__<op>.json
    $bypath = Join-Path $refRoot "live/source-final-cross/by-path/${catLower}__${opLower}.json"
    if (Test-Path $bypath) {
        $liveSource = $bypath
        try {
            $body = Get-Content $bypath -Raw | ConvertFrom-Json -AsHashtable -Depth 25 -ErrorAction SilentlyContinue
            if ($body) {
                if ($body -is [array]) { $liveRowCount = @($body).Count }
                elseif ($body.ContainsKey('Results')) { $liveRowCount = @($body.Results).Count }
                elseif ($body.ContainsKey('value')) { $liveRowCount = @($body.value).Count }
                elseif ($body.ContainsKey('data')) { $liveRowCount = @($body.data).Count }
                else { $liveRowCount = 1 }  # singleObject
            }
        } catch { }
    }

    # source-xdrlograider-raw/MDE_<Op-or-Cat>_CL-raw.json (category-named captures)
    $opShort = ($op.OperationId -split '\.')[-1]
    $rawPath = Join-Path $refRoot "live/source-xdrlograider-raw/MDE_${opShort}_CL-raw.json"
    if (Test-Path $rawPath) {
        $liveSource = $rawPath
        try {
            $body = Get-Content $rawPath -Raw | ConvertFrom-Json -AsHashtable -Depth 25 -ErrorAction SilentlyContinue
            if ($body) {
                if ($body.ContainsKey('Count')) { $liveRowCount = [int]$body.Count }
                elseif ($body -is [array]) { $liveRowCount = @($body).Count }
                elseif ($body.ContainsKey('Results')) { $liveRowCount = @($body.Results).Count }
                else { $liveRowCount = 1 }
            }
        } catch { }
    }

    Add-Member -InputObject $op -MemberType NoteProperty -Name LiveRowCount -Value $liveRowCount -Force
    Add-Member -InputObject $op -MemberType NoteProperty -Name LiveSource -Value $liveSource -Force

    # Score per §3.3
    $score = 0
    # Event volume (max 40)
    if ($liveRowCount -gt 100) { $score += 40 }
    elseif ($liveRowCount -gt 10) { $score += 30 }
    elseif ($liveRowCount -gt 1) { $score += 20 }
    elseif ($liveRowCount -eq 1) { $score += 10 }
    # Method simplicity (max 25)
    if ($op.Method -eq 'GET') { $score += 25 }
    elseif ($op.Method -eq 'POST') { $score += 10 }
    # PathParam dependency (max 15)
    if (-not $op.HasPathParam) { $score += 15 }
    # Cadence semantic (max 10)
    if ($op.OperationId -imatch '(list|get)' -and $op.OperationId -inotmatch '(history|export)') { $score += 10 }
    elseif ($op.OperationId -imatch 'summary') { $score += 8 }
    # License (max 10) · default MDE
    $score += 10

    Add-Member -InputObject $op -MemberType NoteProperty -Name PilotScore -Value $score -Force
}

# ─── Sort by score · take top N ─────────────────────────────────────────────
$ranked = @($operations | Sort-Object -Property @{Expression='PilotScore';Descending=$true}, @{Expression='LiveRowCount';Descending=$true} | Select-Object -First $Top)

Write-Host "[Discover-OperationFromRaw] $Portal/$Category · $($operations.Count) Operations · top $Top ranked"
Write-Host ""
$rank = 1
foreach ($op in $ranked) {
    $liveTag = if ($op.LiveSource) { '[live]' } else { '[no-live]' }
    $pathTag = if ($op.HasPathParam) { '[PathParam]' } else { '' }
    Write-Host ("  #{0} · score={1,3} · {2,-50} · {3,-6} · rows={4,5} · {5} {6}" -f $rank, $op.PilotScore, $op.OperationId, $op.Method, $op.LiveRowCount, $liveTag, $pathTag)
    $rank++
}

# Return ranked array for piping
return $ranked
