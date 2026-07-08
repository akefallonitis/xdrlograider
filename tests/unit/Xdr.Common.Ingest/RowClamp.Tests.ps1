#Requires -Version 7.4
# Per-ROW total-byte clamp · an oversized row (projected typed cols + the 1MB RawJson floor can together exceed the
# ~1MB DCE per-request limit) would 413 → classified terminal → DLQ → SILENT loss. Limit-XdrRowBytes truncates the
# largest string column (visible marker · observable Ingest.RowClamped event) until the row fits. Regression-lock.

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Ingest\Xdr.Common.Ingest.psd1') -Force -DisableNameChecking -ErrorAction Stop
}

Describe 'Limit-XdrRowBytes · oversized-row clamp (no silent 413 → DLQ)' {
    It 'truncates the largest column so the row fits under MaxBytes · preserves envelope + marker' {
        InModuleScope 'Xdr.Common.Ingest' {
            $row = @{ OperationKey='GetHistory'; Portal='Defender'; CorrelationId='cid'; RawJson=('x' * 1500000); ActionId='a1' }
            $out = Limit-XdrRowBytes -Row $row -MaxBytes 900KB -OperationKey 'GetHistory'
            $bytes = [System.Text.Encoding]::UTF8.GetByteCount(($out | ConvertTo-Json -Depth 25 -Compress))
            $bytes | Should -BeLessOrEqual (900KB)
            $out['RawJson']      | Should -Match 'XDRLR-TRUNCATED'
            $out['OperationKey'] | Should -Be 'GetHistory'   # envelope preserved
            $out['ActionId']     | Should -Be 'a1'
        }
    }
    It 'leaves a normal-sized row untouched (no false truncation)' {
        InModuleScope 'Xdr.Common.Ingest' {
            $row = @{ OperationKey='GetHistory'; RawJson='{"ok":1}'; ActionId='a2' }
            $out = Limit-XdrRowBytes -Row $row -MaxBytes 900KB
            $out['RawJson'] | Should -Be '{"ok":1}'
            $out['RawJson'] | Should -Not -Match 'TRUNCATED'
        }
    }
}
