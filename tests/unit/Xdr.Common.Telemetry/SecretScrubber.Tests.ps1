#Requires -Version 7.4
# Telemetry secret-scrubber · caller $Properties AND exception messages are forwarded to AppInsights (AppEvents/
# AppExceptions) + the AppTraces host-mirror VERBATIM, so an auth/poll call site passing sccauth/cookie/token/FlowToken
# would leak a live secret into telemetry. Protect-XdrTelemetryProperties (key deny-list) + Protect-XdrTelemetryMessage
# (value patterns) redact BEFORE both sinks. Regression-lock: no secret value reaches telemetry.

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force -DisableNameChecking -ErrorAction Stop
}

Describe 'Telemetry secret-scrubber (no secret reaches AppInsights/AppTraces)' {
    It 'redacts secret-keyed property values · preserves non-secret keys (diagnostics intact)' {
        InModuleScope 'Xdr.Common.Telemetry' {
            $r = Protect-XdrTelemetryProperties -Properties @{
                sccauth='abc'; Cookie='def'; AccessToken='ghi'; KmsiCookie='jkl'; XsrfToken='mno'; Seed='pqr'
                OperationKey='GetHistory'; CorrelationId='cid-1'; StatusCode='440'
            }
            foreach ($k in 'sccauth','Cookie','AccessToken','KmsiCookie','XsrfToken','Seed') { $r[$k] | Should -Be '***REDACTED***' }
            $r['OperationKey']  | Should -Be 'GetHistory'
            $r['CorrelationId'] | Should -Be 'cid-1'
            $r['StatusCode']    | Should -Be '440'
        }
    }
    It 'redacts FlowToken / code / JWT embedded in an exception message · keeps non-secret context' {
        InModuleScope 'Xdr.Common.Telemetry' {
            $m = Protect-XdrTelemetryMessage -Message 'auth failed: FlowToken=AAABBBCCCDDD code=xyz789abc tok eyJhbGciOiJIUzI.JzdWIiOiJ1c2Vy.SflKxwRJSMeKKF2 op=GetHistory'
            $m | Should -Not -Match 'AAABBBCCCDDD'
            $m | Should -Not -Match 'xyz789abc'
            $m | Should -Not -Match 'eyJhbGciOiJIUzI'
            $m | Should -Match 'GetHistory'
        }
    }
    It 'empty/absent inputs are safe (no throw)' {
        InModuleScope 'Xdr.Common.Telemetry' {
            (Protect-XdrTelemetryProperties -Properties @{}).Count | Should -Be 0
            Protect-XdrTelemetryMessage -Message '' | Should -Be ''
        }
    }
}
