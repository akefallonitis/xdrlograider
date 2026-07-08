#Requires -Version 7.4
# IN2/IN3 RED pins (audit 2026-06-12).
# IN2 · Send-ToDce must STOP sending chunks after the first failure. A trailing chunk that 2xx's lands in LA but
#       sits ABOVE the contiguous-landed prefix (not checkpointed) → re-fetched next cycle → DUPLICATE. The
#       remaining rows are re-polled next cadence anyway; sending them now only duplicates.
# IN3 · A DCE 401/403 from a STALE cached MSI token must trigger ONE forced re-mint + retry before going terminal→DLQ.

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Ingest\Xdr.Common.Ingest.psd1') -Force -DisableNameChecking
}

Describe 'IN2 · Send-ToDce stops at the first failed chunk (no trailing-success duplicates)' {
    It 'does NOT send chunks after the first failure' {
        Mock -ModuleName Xdr.Common.Ingest Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Ingest Track-XdrException { }
        $script:chunkCall = 0
        Mock -ModuleName Xdr.Common.Ingest Send-XdrDceChunk {
            $script:chunkCall++
            if ($script:chunkCall -eq 2) { return @{ Success = $false; RowsAccepted = 0; StatusCode = 500; ErrorClass = 'XdrPortalTransientException'; ErrorMessage = 'boom' } }
            return @{ Success = $true; RowsAccepted = @($Rows).Count; StatusCode = 204; ErrorClass = $null; ErrorMessage = $null }
        }
        # ~230KB RawJson × 11 rows → several 900KB chunks (>=3) so a 2nd-chunk failure leaves trailing chunks.
        $rows = 1..11 | ForEach-Object { @{ OperationKey = 'X'; ActionId = "r$_"; RawJson = ('a' * 230000) } }
        $r = Send-ToDce -DceEndpoint 'https://dce' -DcrId 'dcr-1' -StreamName 'Custom-X' -Rows $rows
        $r.Success | Should -BeFalse
        Should -Invoke -ModuleName Xdr.Common.Ingest Send-XdrDceChunk -Times 2 -Exactly
    }
}

Describe 'IN3 · a DCE 401 forces ONE token re-mint + retry before DLQ' {
    It 'on 401-then-204, re-mints the token with -Force and SUCCEEDS (no DLQ)' {
        Mock -ModuleName Xdr.Common.Ingest Track-XdrDependency { }
        Mock -ModuleName Xdr.Common.Ingest Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Ingest Track-XdrException { }
        Mock -ModuleName Xdr.Common.Ingest Send-XdrDlq { }
        Mock -ModuleName Xdr.Common.Ingest Get-XdrDcrAuthToken { 'tok' }
        Mock -ModuleName Xdr.Common.Ingest Start-Sleep { }
        InModuleScope Xdr.Common.Ingest { $script:webCall = 0 }
        Mock -ModuleName Xdr.Common.Ingest Invoke-WebRequest {
            $script:webCall++
            if ($script:webCall -eq 1) {
                $ex = [System.Exception]::new('HTTP 401 Unauthorized')
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 }) -Force
                throw $ex
            }
            @{ StatusCode = 204; Content = '' }
        }
        $r = InModuleScope Xdr.Common.Ingest {
            Send-XdrDceChunk -DceEndpoint 'https://dce' -DcrId 'dcr-1' -StreamName 'Custom-X' -Rows @(@{ OperationKey = 'X'; ActionId = 'r1'; RawJson = 'small' }) -MaxRetries 3 -TimeoutSec 5
        }
        $r.Success | Should -BeTrue                                                            # recovered, not DLQ'd
        Should -Invoke -ModuleName Xdr.Common.Ingest Get-XdrDcrAuthToken -ParameterFilter { $Force -eq $true } -Times 1
        Should -Invoke -ModuleName Xdr.Common.Ingest Send-XdrDlq -Times 0
    }
}
