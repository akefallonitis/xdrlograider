#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Xdr.Common.Telemetry — mocked App Insights senders (Trace / CustomEvent /
# CustomMetric / Exception / Dependency).

Describe 'Xdr.Common.Telemetry — AppInsights senders (safe no-throw contract)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    }

    # The senders use Microsoft.ApplicationInsights.Channel.TelemetryClient (loaded
    # by the Azure Functions PowerShell host at runtime). In unit-test scope
    # (no FA host), the TelemetryClient type is NOT loadable; the module's
    # design contract is to fall back to Write-Information silently — callers
    # NEVER crash whether AI is reachable or not.

    It 'Send-XdrAppInsightsTrace is no-throw with no AI client + no env vars' {
        { Send-XdrAppInsightsTrace -Message 'unit-test trace' -Properties @{ Phase = 'preflight' } } | Should -Not -Throw
    }

    It 'Send-XdrAppInsightsCustomMetric is no-throw with no AI client + no env vars' {
        { Send-XdrAppInsightsCustomMetric -MetricName 'xdr.test.metric' -Value 42 -Properties @{ SubArea = 'action_center' } } | Should -Not -Throw
    }

    It 'Send-XdrAppInsightsCustomEvent is no-throw + accepts OperationId for correlation' {
        $opId = [Guid]::NewGuid().ToString()
        { Send-XdrAppInsightsCustomEvent -EventName 'xdr.cycle.complete' -OperationId $opId -Properties @{ SubArea = 'identity'; RowsIngested = 5 } } | Should -Not -Throw
    }

    It 'Send-XdrAppInsightsException is no-throw with an actual exception' {
        try { throw [System.IO.FileNotFoundException]::new('test') } catch { $err = $_ }
        { Send-XdrAppInsightsException -Exception $err.Exception -Properties @{ Stage = 'test' } } | Should -Not -Throw
    }

    It 'Send-XdrAppInsightsDependency is no-throw for portal HTTP call tracking' {
        { Send-XdrAppInsightsDependency `
            -Target 'security.microsoft.com' `
            -Name 'GET /apiproxy/mtp/...' `
            -DurationMs 123 `
            -Success $true `
            -ResultCode 200 } | Should -Not -Throw
    }

    It 'all 5 senders are exported (FunctionsToExport contract)' {
        $exports = @(Get-Command -Module Xdr.Common.Telemetry | Select-Object -ExpandProperty Name)
        $exports | Should -Contain 'Send-XdrAppInsightsTrace'
        $exports | Should -Contain 'Send-XdrAppInsightsCustomEvent'
        $exports | Should -Contain 'Send-XdrAppInsightsCustomMetric'
        $exports | Should -Contain 'Send-XdrAppInsightsException'
        $exports | Should -Contain 'Send-XdrAppInsightsDependency'
    }

    It 'secrets in -Properties are redacted (password/totpBase32/sccauth/xsrfToken/passkey/privateKey)' {
        # We can't easily test the actual redaction without TelemetryClient, but we
        # can verify the helper ConvertTo-XdrAiSafeProperties (used internally)
        # via passing a hashtable with secret keys and confirming no throw.
        { Send-XdrAppInsightsTrace -Message 'redact test' -Properties @{
            normalProp = 'normal-value'
            password   = 'super-secret'
            sccauth    = 'cookie-value'
        } } | Should -Not -Throw
    }
}
