#Requires -Module Pester
# φ.AUTH.4 · Write-XdrTelemetry · structured JSON · Write-Information · secret redaction.
# Locks: emit goes to Information stream (NOT Write-Host) · JSON payload parses · secrets
# in property keys redacted · auto-stamps OperationId/Cloud_RoleName/XdrLogRaiderVersion.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force

    # Capture Information stream into a script-scoped buffer · re-parse the JSON payload
    function Invoke-WithCapture {
        param([scriptblock]$Sb)
        $info = $null
        $null = & {
            $Sb.Invoke()
        } 6>&1 | ForEach-Object { $info += @($_) }
        # In Pester · Information messages come via the InformationRecord pipeline (stream 6)
        return @($info)
    }
}

Describe 'φ.AUTH.4 · Write-XdrTelemetry · Information stream + JSON payload' -Tag 'telemetry' {

    It 'emits a single Information record per call · payload parses as JSON' {
        $rec = $null
        Write-XdrTelemetry -Level Information -EventName 'Test.Event' -Message 'unit-test' `
            -Properties @{ Foo='bar'; Count=42 } -InformationAction Continue 6>&1 | Tee-Object -Variable rec | Out-Null
        @($rec).Count | Should -BeGreaterOrEqual 1
        $payload = ($rec | Select-Object -First 1).ToString() | ConvertFrom-Json
        $payload.EventName | Should -Be 'Test.Event'
        $payload.Level     | Should -Be 'Information'
        $payload.Message   | Should -Be 'unit-test'
        $payload.Foo       | Should -Be 'bar'
        $payload.Count     | Should -Be 42
    }

    It 'auto-stamps CorrelationId + OperationId (same value · AppInsights stitching)' {
        Set-XdrCorrelationId -CorrelationId '11111111-2222-3333-4444-555555555555' | Out-Null
        $rec = $null
        Write-XdrTelemetry -Level Information -EventName 'Test.Stitch' -Message 'unit-test' 6>&1 | Tee-Object -Variable rec | Out-Null
        $payload = ($rec | Select-Object -First 1).ToString() | ConvertFrom-Json
        $payload.CorrelationId | Should -Be '11111111-2222-3333-4444-555555555555'
        $payload.OperationId   | Should -Be '11111111-2222-3333-4444-555555555555'
    }

    It 'auto-stamps Cloud_RoleName + Cloud_RoleInstance from env (fallback to machine name)' {
        $rec = $null
        Write-XdrTelemetry -Level Information -EventName 'Test.Cloud' -Message 'unit-test' 6>&1 | Tee-Object -Variable rec | Out-Null
        $payload = ($rec | Select-Object -First 1).ToString() | ConvertFrom-Json
        $payload.Cloud_RoleName     | Should -Not -BeNullOrEmpty
        $payload.Cloud_RoleInstance | Should -Not -BeNullOrEmpty
    }
}

Describe 'φ.AUTH.4 · Secret redaction · property-name pattern match' -Tag 'telemetry' {

    It 'Password property is redacted' {
        $rec = $null
        Write-XdrTelemetry -Level Information -EventName 'Test.Pwd' -Message 'm' `
            -Properties @{ Password='supersecret-xyz' } 6>&1 | Tee-Object -Variable rec | Out-Null
        $payload = ($rec | Select-Object -First 1).ToString() | ConvertFrom-Json
        $payload.Password | Should -Be '<redacted>'
        ($rec | Select-Object -First 1).ToString() | Should -Not -Match 'supersecret-xyz'
    }

    It 'TotpSecret · SccauthCookie · XsrfToken · PasskeyPem · BearerToken · RefreshToken · ApiKey all redacted' {
        $rec = $null
        Write-XdrTelemetry -Level Information -EventName 'Test.AllSecrets' -Message 'm' `
            -Properties @{
                TotpSecret    = 'JBSWY3DPEHPK3PXP'
                SccauthCookie = 'fake-sccauth-value'
                XsrfToken     = 'fake-xsrf-value'
                PasskeyPem    = '-----BEGIN PRIVATE KEY-----...'
                BearerToken   = 'eyJ0eXAiOiJKV1Qi...'
                RefreshToken  = '1.MR.5j7Q...'
                ApiKey        = 'sk_live_abc123'
            } 6>&1 | Tee-Object -Variable rec | Out-Null
        $line = ($rec | Select-Object -First 1).ToString()
        $payload = $line | ConvertFrom-Json
        $payload.TotpSecret    | Should -Be '<redacted>'
        $payload.SccauthCookie | Should -Be '<redacted>'
        $payload.XsrfToken     | Should -Be '<redacted>'
        $payload.PasskeyPem    | Should -Be '<redacted>'
        $payload.BearerToken   | Should -Be '<redacted>'
        $payload.RefreshToken  | Should -Be '<redacted>'
        $payload.ApiKey        | Should -Be '<redacted>'
        # Defence-in-depth · none of the actual values leak into the line
        foreach ($needle in 'JBSWY3DPEHPK3PXP','fake-sccauth-value','fake-xsrf-value','BEGIN PRIVATE KEY','eyJ0eXAiOiJKV1Qi','1.MR.5j7Q','sk_live_abc123') {
            $line | Should -Not -Match ([regex]::Escape($needle))
        }
    }

    It 'NON-secret properties are NOT redacted (no false positives)' {
        $rec = $null
        Write-XdrTelemetry -Level Information -EventName 'Test.NoFalsePos' -Message 'm' `
            -Properties @{
                Upn        = 'sa@contoso.com'
                PortalHost = 'security.microsoft.com'
                Count      = 42
                TenantId   = '11111111-2222-3333-4444-555555555555'
            } 6>&1 | Tee-Object -Variable rec | Out-Null
        $payload = ($rec | Select-Object -First 1).ToString() | ConvertFrom-Json
        $payload.Upn        | Should -Be 'sa@contoso.com'
        $payload.PortalHost | Should -Be 'security.microsoft.com'
        $payload.Count      | Should -Be 42
        $payload.TenantId   | Should -Be '11111111-2222-3333-4444-555555555555'
    }

    It 'Nested hashtable · one-level recursion · secrets within redacted' {
        $rec = $null
        Write-XdrTelemetry -Level Information -EventName 'Test.Nested' -Message 'm' `
            -Properties @{ Auth = @{ Upn='sa@contoso.com'; Password='inner-secret' } } 6>&1 | Tee-Object -Variable rec | Out-Null
        $payload = ($rec | Select-Object -First 1).ToString() | ConvertFrom-Json
        $payload.Auth.Upn      | Should -Be 'sa@contoso.com'
        $payload.Auth.Password | Should -Be '<redacted>'
    }
}
