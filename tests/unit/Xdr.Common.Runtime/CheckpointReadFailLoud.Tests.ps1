#Requires -Version 7.4
# EO1 RED pin (audit 2026-06-12) · Get-XdrCheckpoint must FAIL LOUD (transient) on a storage READ error and
# NEVER return the cold default. The old `catch { return $default }` made a transient 500/timeout/throttle
# indistinguishable from "no checkpoint exists" → the CURSOR op re-ingested the full history as DUPLICATES and
# the follow-up null-ETag save CLOBBERED the real checkpoint row. Genuine absence (Found=false) is the ONLY
# legitimate cold-start path. A transient read must abort the cycle (retry next cadence, checkpoint intact).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Storage    -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
}

Describe 'EO1 · Get-XdrCheckpoint fails loud on a read error (never cold-default)' {
    It 'a transient READ error THROWS (transient) instead of returning a cold default' {
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity { throw 'storage 500 · transient read blip' }
        $err = { Get-XdrCheckpoint -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' } | Should -Throw -PassThru
        $err.Exception.GetType().Name | Should -Be 'XdrPortalTransientException'
    }
    It 'retries the read before giving up (transient blip then success → returns the real checkpoint, no throw)' {
        $script:calls = 0
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity {
            $script:calls++
            if ($script:calls -lt 2) { throw 'storage timeout · transient' }
            @{ Found = $true; ETag = 'W/"e9"'; Entity = @{ Cursor = '2026-06-11T05:00:00Z'; BoundaryKeys = 'a1'; LastItemCount = 3 } }
        }
        $cp = Get-XdrCheckpoint -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory'
        $cp.Cursor | Should -Be '2026-06-11T05:00:00.0000000Z'   # WS-A · read-boundary canonicalises to full-fidelity 'o'
        $cp.ETag   | Should -Be 'W/"e9"'
        $script:calls | Should -BeGreaterThan 1
    }
    It 'genuine ABSENCE (Found=false) returns the cold default (Cursor/ETag null) — the ONLY cold-start path' {
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity { @{ Found = $false } }
        $cp = Get-XdrCheckpoint -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory'
        $cp.Cursor | Should -BeNullOrEmpty
        $cp.ETag   | Should -BeNullOrEmpty
    }
    It 'a present checkpoint is mapped through (Cursor + ETag preserved)' {
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity {
            @{ Found = $true; ETag = 'W/"e1"'; Entity = @{ Cursor = '2026-06-11T00:00:00Z'; BoundaryKeys = 'k1'; LastItemCount = 9 } }
        }
        $cp = Get-XdrCheckpoint -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory'
        $cp.Cursor | Should -Be '2026-06-11T00:00:00.0000000Z'   # WS-A · read-boundary canonicalises to full-fidelity 'o'
        $cp.ETag   | Should -Be 'W/"e1"'
    }
}
