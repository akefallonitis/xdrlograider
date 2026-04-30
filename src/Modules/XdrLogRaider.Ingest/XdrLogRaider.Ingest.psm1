# XdrLogRaider.Ingest — backward-compat shim for v0.1.0-beta operators + tests.
#
# Phase 8 of the module-split work renamed this module to Xdr.Sentinel.Ingest
# (so the L1 portal-generic ingest layer sits cleanly alongside Xdr.Common.Auth).
# This shim keeps the legacy XdrLogRaider.Ingest name + the legacy function
# names (Send-ToLogAnalytics, Write-Heartbeat, Get-CheckpointTimestamp, ...)
# by importing the renamed module and re-exporting its public surface.
#
# Operator scripts that `Import-Module XdrLogRaider.Ingest` and call any of
# its existing functions keep working without change. Pester tests that
# `Mock -ModuleName XdrLogRaider.Ingest` need to migrate to '-ModuleName
# Xdr.Sentinel.Ingest' (mock target must match where the function lives).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Import the renamed module. profile.ps1 imports Xdr.Sentinel.Ingest before
# this shim, so Get-Module finds it already loaded. Tests that import this
# shim directly trigger lazy load below.
$sentinelIngest = Get-Module -Name 'Xdr.Sentinel.Ingest'

if (-not $sentinelIngest) {
    $renamedPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'
    if (Test-Path -LiteralPath $renamedPath) {
        Import-Module $renamedPath -Force -Global -ErrorAction Stop
    } else {
        throw "XdrLogRaider.Ingest shim: cannot locate Xdr.Sentinel.Ingest at $renamedPath. Both modules must live under src/Modules/."
    }
}

# Re-export every public function from the renamed module. Each shim wrapper
# declares the EXACT param signature of the renamed module's copy so
# `@PSBoundParameters` splatting forwards every named arg unchanged. Wrong
# signatures here cause silent parameter-binding errors at the shim layer
# even though the real function would accept the call.

function Send-ToLogAnalytics {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $DceEndpoint,
        [Parameter(Mandatory)] [string] $DcrImmutableId,
        [Parameter(Mandatory)] [string] $StreamName,
        [Parameter(Mandatory)] $Rows,
        [int] $MaxBatchBytes = 1MB,
        [int] $MaxRetries = 3
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Send-ToLogAnalytics @PSBoundParameters
}

function Write-Heartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DceEndpoint,
        [Parameter(Mandatory)] [string] $DcrImmutableId,
        [Parameter(Mandatory)] [string] $FunctionName,
        [Parameter(Mandatory)] [string] $Tier,
        [int] $StreamsAttempted = 0,
        [int] $StreamsSucceeded = 0,
        [int] $RowsIngested = 0,
        [int] $LatencyMs = 0,
        $Notes
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Write-Heartbeat @PSBoundParameters
}

function Write-AuthTestResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DceEndpoint,
        [Parameter(Mandatory)] [string] $DcrImmutableId,
        [Parameter(Mandatory)] [pscustomobject] $TestResult
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Write-AuthTestResult @PSBoundParameters
}

function Get-CheckpointTimestamp {
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $StreamName
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Get-CheckpointTimestamp @PSBoundParameters
}

function Set-CheckpointTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $StreamName,
        [datetime] $Timestamp
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Set-CheckpointTimestamp @PSBoundParameters
}

function Get-XdrAuthSelfTestFlag {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [Parameter(Mandatory)] [string] $CheckpointTable
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Get-XdrAuthSelfTestFlag @PSBoundParameters
}

function Invoke-XdrStorageTableEntity {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StorageAccountName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TableName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PartitionKey,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RowKey,

        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Upsert', 'Delete')]
        [string] $Operation,

        [hashtable] $Entity = $null
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Invoke-XdrStorageTableEntity @PSBoundParameters
}

function Send-XdrAppInsightsTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Verbose','Information','Warning','Error','Critical')]
        [string] $SeverityLevel = 'Information',
        [hashtable] $Properties,
        [string] $OperationId
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Send-XdrAppInsightsTrace @PSBoundParameters
}

function Send-XdrAppInsightsCustomEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EventName,
        [hashtable] $Properties,
        [string] $OperationId
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Send-XdrAppInsightsCustomEvent @PSBoundParameters
}

function Send-XdrAppInsightsCustomMetric {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $MetricName,
        [Parameter(Mandatory)] [double] $Value,
        [hashtable] $Properties,
        [string] $OperationId
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Send-XdrAppInsightsCustomMetric @PSBoundParameters
}

function Send-XdrAppInsightsException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Exception] $Exception,
        [hashtable] $Properties,
        [ValidateSet('Warning','Error','Critical')]
        [string] $SeverityLevel = 'Error',
        [string] $OperationId
    )
    & (Get-Module -Name 'Xdr.Sentinel.Ingest') Send-XdrAppInsightsException @PSBoundParameters
}

Export-ModuleMember -Function @(
    'Send-ToLogAnalytics',
    'Write-Heartbeat',
    'Write-AuthTestResult',
    'Get-CheckpointTimestamp',
    'Set-CheckpointTimestamp',
    'Get-XdrAuthSelfTestFlag',
    'Invoke-XdrStorageTableEntity',
    'Send-XdrAppInsightsTrace',
    'Send-XdrAppInsightsCustomEvent',
    'Send-XdrAppInsightsCustomMetric',
    'Send-XdrAppInsightsException'
)
