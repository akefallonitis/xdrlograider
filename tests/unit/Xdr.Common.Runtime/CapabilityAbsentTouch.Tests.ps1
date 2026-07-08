#Requires -Version 7.4
# WS3.1 RED pin · the capability-absent cadence-touch must PRESERVE the full checkpoint. Save-XdrCheckpointAtomic
# writes ALL properties on every save; the old touch passed only Cursor/BoundaryKeys, so the omitted Resume*
# params' defaults (0/''/''/'') WIPED an in-progress multi-cycle drain's resume position + pending high-water
# whenever a posture (403/404) landed mid-drain. Revert the fix → the captured write carries '' → RED.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Storage    -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
}

Describe 'WS3.1 · capability-absent touch preserves Resume* (mid-drain posture must not wipe the drain)' {
    It 'the touched checkpoint write carries the ORIGINAL ResumePage/ResumeCursor/ResumeHighWater/ResumeBoundaryKeys' {
        $global:XdrTouchCaptured = $null
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y'; TenantId = 't1' } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-token' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCircuitState { @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        # Mid-drain checkpoint: committed Cursor + live U1 resume state.
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint {
            @{ OperationKey = 'PostureOp'; Cursor = '2026-06-10T00:00:00.0000000Z'; BoundaryKeys = 'k1,k2'
               ResumePage = 7; ResumeCursor = 'tok-7'; ResumeHighWater = '2026-06-11T05:00:00.0000000Z'; ResumeBoundaryKeys = 'rk1'
               WindowStartUtc = $null; WindowEndUtc = $null; LastUpdatedUtc = '2026-06-11T04:00:00Z'; LastItemCount = 5; ETag = 'W/"e1"' }
        }
        # The poll throws a capability-absent posture (403 read) on the first authenticated fetch.
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrAuthenticated {
            throw (New-XdrException -Type PortalTerminal -Message 'HTTP 403 for https://x' -Properties @{ StatusCode = 403; OperationKey = 'PostureOp'; Url = 'https://x'; ResponseBody = '' })
        }
        # Capture the touched write (Save-XdrCheckpointAtomic → Set-XdrTableEntity).
        Mock -ModuleName Xdr.Common.Runtime Set-XdrTableEntity {
            $global:XdrTouchCaptured = $Properties
            @{ Success = $true; StatusCode = 204; Error = $null }
        }

        $entry = @{ OperationKey = 'PostureOp'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'
                    SubPortal = 'mtp'; Path = '/posture/op'; IngestionMode = 'CURSOR'; CursorField = 'EventTime'
                    NaturalKey = @('Id'); ProjectionMap = @{ Id = '$.Id' }; DcrImmutableId = 'dcr-x'; DcrStreamName = 'Custom-X' }
        $r = Invoke-XdrEntryPoll -Entry $entry -CorrelationId 'pin-touch'

        $r.Success | Should -BeTrue            # posture = clean no-op, not a failure
        $global:XdrTouchCaptured | Should -Not -BeNullOrEmpty
        $global:XdrTouchCaptured['Cursor']             | Should -Be '2026-06-10T00:00:00.0000000Z'
        $global:XdrTouchCaptured['BoundaryKeys']       | Should -Be 'k1,k2'
        $global:XdrTouchCaptured['ResumePage']         | Should -Be 7
        $global:XdrTouchCaptured['ResumeCursor']       | Should -Be 'tok-7'
        $global:XdrTouchCaptured['ResumeHighWater']    | Should -Be '2026-06-11T05:00:00.0000000Z'
        $global:XdrTouchCaptured['ResumeBoundaryKeys'] | Should -Be 'rk1'
    }
}
