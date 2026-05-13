<#
.SYNOPSIS
    Verifies the 4 hand-authored PowerShell Durable Functions directories under
    src/functions/ — Xdr-Refresh, Xdr-PollOrchestrator, Xdr-PollStream,
    Connector-Heartbeat. Replaces an earlier generator that produced 19 per-sub-area
    timer triggers (rejected topology).

.DESCRIPTION
    v0.1.0 GA topology (Decision 1, plan §2): 4 PowerShell Durable Functions,
    NOT 19 per-sub-area timers, NOT a Queue worker pair. Each directory is
    hand-authored + checked into source. This script's job is to verify the
    files exist + the function.json bindings + the run.ps1 references match
    expectations — it does NOT generate them (pilot pattern; deterministic
    by virtue of being source-of-truth files).

    Verifications:
      1. Exactly 4 dirs present under src/functions/.
      2. Each has function.json + run.ps1.
      3. Bindings:
         - Xdr-Refresh         : timerTrigger 1-min + durableClient 'Starter'
         - Xdr-PollOrchestrator: orchestrationTrigger 'Context'
         - Xdr-PollStream      : activityTrigger name='ActivityInput' (NOT 'Input')
         - Connector-Heartbeat : timerTrigger 5-min
      4. run.ps1 entry points reference the expected module functions:
         - Xdr-Refresh: Get-XdrTierCadenceMap + Start-NewOrchestration
         - Xdr-PollOrchestrator: Invoke-DurableActivity + manifest read
         - Xdr-PollStream: Invoke-MDEEndpoint + Send-ToLogAnalytics
         - Connector-Heartbeat: Write-Heartbeat + Get-XdrTierStateAggregate

.PARAMETER FunctionsRoot
    Function app root. Default: ../src/functions.

.EXAMPLE
    pwsh ./tools/Build-FunctionApp.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $FunctionsRoot = (Join-Path $PSScriptRoot '..' 'src' 'functions')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $FunctionsRoot)) {
    throw "FunctionsRoot does not exist: $FunctionsRoot"
}

$expectedDirs = @{
    'Xdr-Refresh' = @{
        Trigger      = 'timerTrigger'
        Schedule     = '0 \* \* \* \* \*'
        DurableClient = $true
        RunRefs      = @('Get-XdrTierCadenceMap','Start-NewOrchestration','Invoke-XdrStorageTableEntity')
    }
    'Xdr-PollOrchestrator' = @{
        Trigger     = 'orchestrationTrigger'
        BindingName = 'Context'
        RunRefs     = @('Invoke-DurableActivity','Get-XdrEndpointManifest')
    }
    'Xdr-PollStream' = @{
        Trigger     = 'activityTrigger'
        BindingName = 'ActivityInput'  # MUST NOT be 'Input' (shadows $Input automatic)
        RunRefs     = @('Invoke-MDEEndpoint','Send-ToLogAnalytics','Set-XdrTierStateRow','Get-XdrAuthFromKeyVault','Connect-DefenderPortal')
    }
    'Connector-Heartbeat' = @{
        Trigger  = 'timerTrigger'
        Schedule = '0 \*/5 \* \* \* \*'
        RunRefs  = @('Write-Heartbeat','Get-XdrTierStateAggregate','Send-XdrAppInsightsCustomMetric')
    }
}

$problems = @()

# 1) Directory presence
$presentDirs = @(Get-ChildItem -Path $FunctionsRoot -Directory | ForEach-Object { $_.Name })
if ($presentDirs.Count -ne 4) {
    $problems += "Expected exactly 4 function dirs under $FunctionsRoot, found $($presentDirs.Count) ($($presentDirs -join ','))"
}
foreach ($expected in $expectedDirs.Keys) {
    if ($presentDirs -notcontains $expected) {
        $problems += "Missing function dir: $expected"
    }
}
foreach ($actual in $presentDirs) {
    if (-not $expectedDirs.ContainsKey($actual)) {
        $problems += "Unexpected function dir: $actual (allowed: $($expectedDirs.Keys -join ','))"
    }
}

# 2) For each expected dir, verify function.json + run.ps1 contents
foreach ($dir in $expectedDirs.Keys) {
    $dirPath  = Join-Path $FunctionsRoot $dir
    $jsonPath = Join-Path $dirPath 'function.json'
    $ps1Path  = Join-Path $dirPath 'run.ps1'
    if (-not (Test-Path $jsonPath)) { $problems += "$dir/function.json missing"; continue }
    if (-not (Test-Path $ps1Path))  { $problems += "$dir/run.ps1 missing"; continue }

    try {
        $bindings = (Get-Content -Raw $jsonPath | ConvertFrom-Json).bindings
    } catch {
        $problems += "$dir/function.json failed to parse: $($_.Exception.Message)"
        continue
    }

    $spec   = $expectedDirs[$dir]
    $hasTrigger = @($bindings | Where-Object { $_.type -eq $spec.Trigger }).Count -gt 0
    if (-not $hasTrigger) { $problems += "${dir}: expected binding type '$($spec.Trigger)' not found" }

    if ($spec.ContainsKey('Schedule')) {
        $tbinding = $bindings | Where-Object { $_.type -eq $spec.Trigger } | Select-Object -First 1
        if ($tbinding -and $tbinding.schedule -notmatch $spec.Schedule) {
            $problems += "${dir}: timer schedule '$($tbinding.schedule)' does not match expected pattern '$($spec.Schedule)'"
        }
    }
    if ($spec.ContainsKey('BindingName')) {
        $named = $bindings | Where-Object { $_.type -eq $spec.Trigger } | Select-Object -First 1
        if ($named -and $named.name -ne $spec.BindingName) {
            $problems += "${dir}: activity binding name '$($named.name)' must be '$($spec.BindingName)' (avoid `$Input shadow)"
        }
    }
    if ($spec.ContainsKey('DurableClient') -and $spec.DurableClient) {
        $hasClient = @($bindings | Where-Object { $_.type -eq 'durableClient' }).Count -gt 0
        if (-not $hasClient) { $problems += "${dir}: expected durableClient binding not found" }
    }

    # 3) run.ps1 references
    $runContent = Get-Content -Raw $ps1Path
    foreach ($ref in $spec.RunRefs) {
        if ($runContent -notmatch [regex]::Escape($ref)) {
            $problems += "$dir/run.ps1: expected reference to '$ref' not found"
        }
    }
}

if ($problems.Count -gt 0) {
    Write-Host "Build-FunctionApp verifier: FAILED" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    exit 1
}

Write-Host "Build-FunctionApp verifier: PASS (4 Durable function dirs OK)" -ForegroundColor Green
