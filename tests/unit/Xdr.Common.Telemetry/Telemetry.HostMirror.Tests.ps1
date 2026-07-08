#Requires -Version 7.4
# F-OBS-1: Track-XdrException must host-mirror to the Information stream ([exn] ...) so a caught-then-tracked
# exception lands in AppTraces — workspace-mode AppInsights does NOT reliably surface /v2/track ExceptionData,
# so the connector's own exception telemetry was invisible (the class of gap that let the live auth crash-loop
# hide). Track-XdrEvent already mirrors; this brings the exception path to parity. Transport + host both mocked.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
}

Describe 'Track-XdrException host-mirror (F-OBS-1)' {
    BeforeEach {
        Mock -ModuleName Xdr.Common.Telemetry Send-XdrTelemetryEnvelope { }
        Mock -ModuleName Xdr.Common.Telemetry Write-Host { }
    }

    It 'mirrors the exception to the host stream as [exn] <Type>: <message> with properties' {
        Track-XdrException -Exception ([System.InvalidOperationException]::new('boom happened')) -Properties @{ Op = 'GetHistory' }
        Should -Invoke -ModuleName Xdr.Common.Telemetry Write-Host -Times 1 -ParameterFilter {
            "$Object" -match '^\[exn\] InvalidOperationException: boom happened' -and "$Object" -match 'Op=GetHistory'
        }
    }

    It 'still sends the ExceptionData envelope (the mirror is ADDITIVE, not a replacement)' {
        Track-XdrException -Exception ([System.Exception]::new('x'))
        Should -Invoke -ModuleName Xdr.Common.Telemetry Send-XdrTelemetryEnvelope -Times 1
    }

    It 'is silenced when XDRLR_TRACE_TO_HOST=0 (steady-state opt-out · same switch as Track-XdrEvent)' {
        $env:XDRLR_TRACE_TO_HOST = '0'
        try { Track-XdrException -Exception ([System.Exception]::new('quiet')) }
        finally { Remove-Item Env:XDRLR_TRACE_TO_HOST -ErrorAction SilentlyContinue }
        Should -Invoke -ModuleName Xdr.Common.Telemetry Write-Host -Times 0
    }
}
