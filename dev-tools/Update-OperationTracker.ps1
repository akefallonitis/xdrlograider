# tools/Update-OperationTracker.ps1
# Operator tool · updates the internal operation-tracker (gitignored · per-cycle status snapshot).
#
# operation-tracker is the authoritative state for which Operations have been promoted to VERIFIED
# across iterations. Records: status (PENDING/IN_PROGRESS/VERIFIED/REGRESSED) · alpha-round · KQL row counts.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Portal,
    [Parameter(Mandatory)] [string] $Category,
    [Parameter(Mandatory)] [string] $OperationKey,
    [ValidateSet('PENDING','IN_PROGRESS','VERIFIED','REGRESSED')] [string] $Status,
    [int] $PilotRound = 0,
    [int] $RowCount = 0,
    [int] $GatesPassed = 0,
    [int] $GatesTotal = 8,
    [string] $TrackerPath = $(if ($env:XDRLR_TRACKER_PATH) { $env:XDRLR_TRACKER_PATH } else { Join-Path $env:USERPROFILE 'xdrlograider-audit/operation-tracker.json' }),
    [string] $Notes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Ensure parent dir exists
$parent = Split-Path -Parent $TrackerPath
if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

# Load or seed tracker
if (Test-Path $TrackerPath) {
    $tracker = Get-Content $TrackerPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    $tracker = @{
        Schema = 'XdrLogRaider.OperationTracker.v1'
        Created = ([DateTime]::UtcNow).ToString('o')
        Operations = @{}
    }
}

if (-not $tracker.Operations) { $tracker.Operations = @{} }

$key = "${Portal}::${Category}::${OperationKey}"
$now = ([DateTime]::UtcNow).ToString('o')

if (-not $tracker.Operations.ContainsKey($key)) {
    $tracker.Operations[$key] = @{
        Portal       = $Portal
        Category     = $Category
        OperationKey = $OperationKey
        FirstSeen    = $now
        History      = @()
    }
}

$entry = $tracker.Operations[$key]
$entry.Status        = $Status
$entry.LastUpdated   = $now
$entry.PilotRound    = $PilotRound
$entry.RowCount      = $RowCount
$entry.GatesPassed   = "$GatesPassed/$GatesTotal"
if ($Notes) { $entry.LastNotes = $Notes }

# Append to history (last 10 entries)
$histRow = @{ At = $now; Status = $Status; RowCount = $RowCount; GatesPassed = "$GatesPassed/$GatesTotal" }
if ($Notes) { $histRow.Notes = $Notes }
$entry.History = @($entry.History + $histRow | Select-Object -Last 10)

$tracker.LastUpdated = $now

$tracker | ConvertTo-Json -Depth 8 | Set-Content -Path $TrackerPath -Encoding UTF8

Write-Host "[Update-OperationTracker] $key → $Status (Pilot=$PilotRound · Rows=$RowCount · Gates=$GatesPassed/$GatesTotal)"
Write-Host "[Update-OperationTracker] Tracker: $TrackerPath"
exit 0
