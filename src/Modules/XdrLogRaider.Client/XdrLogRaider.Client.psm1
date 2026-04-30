# XdrLogRaider.Client — backward-compat shim for v0.1.0-beta operators + tests.
#
# The module-split work renamed this module to Xdr.Defender.Client (so the L3
# Defender-portal layer sits cleanly alongside Xdr.Defender.Auth). This shim
# keeps the legacy XdrLogRaider.Client name + the legacy MDE-prefixed
# function names (Invoke-MDEEndpoint, Invoke-MDETierPoll, ...) by importing
# the renamed module and re-exporting its public surface unchanged.
#
# Operator scripts that `Import-Module XdrLogRaider.Client` and call
# Invoke-MDEEndpoint / Invoke-MDETierPoll / Invoke-TierPollWithHeartbeat keep
# working without change. Pester tests that `Mock -ModuleName XdrLogRaider.Client'
# need to migrate to '-ModuleName Xdr.Defender.Client' (the mock target must
# match where the function actually lives).
#
# v0.2.0+ may deprecate this shim once operators migrate to the L4
# Xdr.Connector.Orchestrator surface (Invoke-XdrTierPoll -Portal 'Defender').

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Import the renamed module. profile.ps1 imports Xdr.Defender.Client before
# this shim, so Get-Module finds it already loaded. Tests that import this
# shim directly trigger lazy load below.
$defenderClient = Get-Module -Name 'Xdr.Defender.Client'

if (-not $defenderClient) {
    $renamedPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'
    if (Test-Path -LiteralPath $renamedPath) {
        Import-Module $renamedPath -Force -Global -ErrorAction Stop
    } else {
        throw "XdrLogRaider.Client shim: cannot locate Xdr.Defender.Client at $renamedPath. Both modules must live under src/Modules/."
    }
}

# Re-export every public function from the renamed module under the same
# legacy name. The function names didn't change (Invoke-MDEEndpoint, etc.) so
# a simple Export-ModuleMember of the renamed module's surface is enough.
# Pester mocks that target '-ModuleName XdrLogRaider.Client' will resolve
# against this re-export.

function Invoke-MDEEndpoint {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Stream,
        [datetime] $FromUtc,
        [hashtable] $PathParams
    )
    & (Get-Module -Name 'Xdr.Defender.Client') Invoke-MDEEndpoint @PSBoundParameters
}

function Invoke-MDETierPoll {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)]
        [ValidateSet('P0', 'P1', 'P2', 'P3', 'P5', 'P6', 'P7')]
        [string] $Tier,
        [Parameter(Mandatory)] $Config,
        [switch] $IncludeDeferred
    )
    & (Get-Module -Name 'Xdr.Defender.Client') Invoke-MDETierPoll @PSBoundParameters
}

function Invoke-TierPollWithHeartbeat {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('P0', 'P1', 'P2', 'P3', 'P5', 'P6', 'P7')]
        [string] $Tier,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FunctionName,
        [ValidateNotNullOrEmpty()]
        [string] $Portal = 'security.microsoft.com'
    )
    & (Get-Module -Name 'Xdr.Defender.Client') Invoke-TierPollWithHeartbeat @PSBoundParameters
}

function Get-MDEEndpointManifest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch] $Force
    )
    & (Get-Module -Name 'Xdr.Defender.Client') Get-MDEEndpointManifest @PSBoundParameters
}

function Invoke-MDEPortalEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        [hashtable] $AdditionalHeaders,
        $Body = $null
    )
    & (Get-Module -Name 'Xdr.Defender.Client') Invoke-MDEPortalEndpoint @PSBoundParameters
}

function ConvertTo-MDEIngestRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entity,
        [Parameter(Mandatory)] [string] $Stream,
        [hashtable] $StaticFields
    )
    & (Get-Module -Name 'Xdr.Defender.Client') ConvertTo-MDEIngestRow @PSBoundParameters
}

function Expand-MDEResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Response,
        [string] $UnwrapProperty
    )
    & (Get-Module -Name 'Xdr.Defender.Client') Expand-MDEResponse @PSBoundParameters
}

Export-ModuleMember -Function @(
    'Invoke-MDEEndpoint',
    'Invoke-MDETierPoll',
    'Invoke-TierPollWithHeartbeat',
    'Get-MDEEndpointManifest',
    'Invoke-MDEPortalEndpoint',
    'ConvertTo-MDEIngestRow',
    'Expand-MDEResponse'
)
