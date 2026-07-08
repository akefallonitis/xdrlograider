#Requires -Version 7.4
<#
.SYNOPSIS
Operator diagnostic per plan v11 §4.21 + §8.8 · override-sync modes.

.DESCRIPTION
Diagnostic-only tool · NOT used in steady-state. All modes log to AppInsights with
`Override.Applied.<Mode>` events including operator identifier from SAMI. NEVER silent.
NEVER unaudited.

Modes (mutually exclusive · pick one):
  -ForceNow -OperationKey <key>
      Bypass G-Cadence · invoke Force-XdrFullCycle for ONE specific Op.
      Use case: post-deploy sanity · post-onboard immediate verify.
  -ResetCursor -OperationKey <key>
      Invoke Save-XdrCheckpointReset · Cursor='' · LastUpdatedUtc='' · next cycle fires immediately.
      Use case: after schema change · after manifest correction.
  -ResetCursorToUtc <iso8601> -OperationKey <key>
      Set cursor to specific UTC time · re-poll from there.
      Use case: reprocess a window.
  -ForceCapabilityOn -OperationKey <key>
      Skip G-Capability gate for ONE cycle · for testing license-fit code paths.
      Use case: lab tenant lacks license but want to test code path.
  -DryRun (always default for safety · explicit -Apply required to mutate)

Invariant: -Apply switch must be explicitly passed for any mutation. Default = preview-only.
#>
[CmdletBinding(DefaultParameterSetName='DryRun')]
param(
    [Parameter(ParameterSetName='ForceNow')] [switch] $ForceNow,
    [Parameter(ParameterSetName='ResetCursor')] [switch] $ResetCursor,
    [Parameter(ParameterSetName='ResetCursorToUtc')] [string] $ResetCursorToUtc,
    [Parameter(ParameterSetName='ForceCapabilityOn')] [switch] $ForceCapabilityOn,
    [Parameter()] [string] $OperationKey,
    [Parameter()] [string] $Portal = 'Defender',
    [Parameter()] [string] $Category = 'Operations',
    [Parameter()] [string] $ResourceGroup,
    [Parameter()] [string] $StorageAccount,
    [Parameter()] [string] $FunctionAppName,
    [Parameter()] [string] $Reason = 'operator-override',
    [switch] $Apply,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.." | ForEach-Object Path

$mode = $PSCmdlet.ParameterSetName
$mutating = ($mode -ne 'DryRun')

Write-Host '======================================================================'
Write-Host "Override-XdrSync · operator diagnostic per plan §4.21 + §8.8"
Write-Host '======================================================================'
Write-Host "  Mode          : $mode"
Write-Host "  OperationKey  : $OperationKey"
Write-Host "  Portal        : $Portal"
Write-Host "  Category      : $Category"
Write-Host "  Apply         : $($Apply.IsPresent)"
Write-Host "  Reason        : $Reason"
Write-Host ''

if ($mode -eq 'DryRun' -and -not $ForceNow -and -not $ResetCursor -and -not $ResetCursorToUtc -and -not $ForceCapabilityOn) {
    Write-Host 'No mode specified · select one of -ForceNow / -ResetCursor / -ResetCursorToUtc <iso> / -ForceCapabilityOn'
    Write-Host 'Always pair with -OperationKey and -Apply (or run without -Apply to preview)'
    exit 0
}

if ($mutating -and -not $Apply) {
    Write-Host '[Override-XdrSync] DRY-RUN (default safety) · re-run with -Apply to mutate'
    Write-Host ''
    Write-Host "Would execute:"
    switch ($mode) {
        'ForceNow' {
            Write-Host "  pwsh tools/Force-XdrFullCycle.ps1 -ResourceGroup $ResourceGroup -StorageAccount $StorageAccount -OperationKey $OperationKey"
        }
        'ResetCursor' {
            Write-Host "  Save-XdrCheckpointReset -PartitionKey '${Portal}_${Category}' -OperationKey $OperationKey -Reason '$Reason'"
        }
        'ResetCursorToUtc' {
            Write-Host "  Save-XdrCheckpointReset to UTC=$ResetCursorToUtc -OperationKey $OperationKey"
        }
        'ForceCapabilityOn' {
            Write-Host "  Set FA app setting XDRLR_FORCE_CAPABILITY=$OperationKey for one cycle"
        }
    }
    exit 0
}

# === MUTATING MODES ===
# All modes assume operator has run `az login --service-principal` from .env.local SP creds
# (autonomous post-deploy work per plan §B.1 ownership model · agent runs these)

switch ($mode) {
    'ForceNow' {
        $tool = Join-Path $repoRoot 'tools/Force-XdrFullCycle.ps1'
        if (-not (Test-Path $tool)) { Write-Error 'Force-XdrFullCycle.ps1 missing'; exit 1 }
        if (-not $ResourceGroup -or -not $StorageAccount) { Write-Error '-ResourceGroup and -StorageAccount are required for -ForceNow (Force-XdrFullCycle mandatory params)'; exit 1 }
        Write-Host "[Override-XdrSync] Invoking Force-XdrFullCycle for $OperationKey"
        & pwsh -NoProfile -File $tool -ResourceGroup $ResourceGroup -StorageAccount $StorageAccount -OperationKey $OperationKey
        exit $LASTEXITCODE
    }
    'ResetCursor' {
        # DELEGATE to the real reset CLI (mirrors -ForceNow→Force-XdrFullCycle). Save-XdrCheckpointReset writes the
        # full-rewind checkpoint row directly via the AAD Table REST path; no inline FA invocation needed.
        $tool = Join-Path $repoRoot 'tools/Save-XdrCheckpointReset.ps1'
        if (-not (Test-Path $tool)) { Write-Error 'Save-XdrCheckpointReset.ps1 missing'; exit 1 }
        Write-Host "[Override-XdrSync] Invoking Save-XdrCheckpointReset (full rewind) for $Portal/$Category$(if ($OperationKey) { "/$OperationKey" } else { ' (all ops)' })"
        $rcArgs = @('-Portal', $Portal, '-Category', $Category, '-Reason', 'operator-override', '-Apply')
        if ($OperationKey)   { $rcArgs += @('-OperationKey', $OperationKey) }
        if ($ResourceGroup)  { $rcArgs += @('-ResourceGroup', $ResourceGroup) }
        if ($StorageAccount) { $rcArgs += @('-StorageAccount', $StorageAccount) }
        & pwsh -NoProfile -File $tool @rcArgs
        exit $LASTEXITCODE
    }
    'ResetCursorToUtc' {
        # A reset to a SPECIFIC cursor UTC is NOT a standalone CLI — the runtime resets to a CLEAN baseline (Cursor='')
        # only. For the supported full rewind use -ResetCursor (delegates to Save-XdrCheckpointReset). A value-targeted
        # cursor remains an inline FA operation; refuse loudly rather than print a stale "v0.2.0 will add it" no-op.
        Write-Error "[Override-XdrSync] -ResetCursorToUtc is not a standalone CLI. Use -ResetCursor for the supported full rewind (Save-XdrCheckpointReset); a value-targeted cursor is an inline FA op."
        exit 2
    }
    'ForceCapabilityOn' {
        if (-not $ResourceGroup -or -not $FunctionAppName) {
            Write-Error '-ResourceGroup and -FunctionAppName required for ForceCapabilityOn mode'
            exit 1
        }
        Write-Host "[Override-XdrSync] Setting FA app setting XDRLR_FORCE_CAPABILITY=$OperationKey"
        az functionapp config appsettings set --resource-group $ResourceGroup --name $FunctionAppName --settings "XDRLR_FORCE_CAPABILITY=$OperationKey" --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Applied · next cycle will bypass G-Capability gate for $OperationKey"
            Write-Host "  REMINDER: remove this setting after testing (single-cycle override)"
        }
        exit $LASTEXITCODE
    }
}
