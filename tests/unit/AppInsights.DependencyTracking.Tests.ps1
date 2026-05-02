#Requires -Modules Pester
<#
.SYNOPSIS
    v0.1.0-beta production-readiness polish — Send-XdrAppInsightsDependency
    test gates. Wraps Microsoft.ApplicationInsights.DataContracts.
    DependencyTelemetry so portal HTTP / DCE / Tables outgoing calls land in
    AI's end-to-end transaction view next to the auth-chain customEvents.

.DESCRIPTION
    Gates by name (referenced in v0.1.0-beta production-readiness plan):
      Dependency.Surface             Send-XdrAppInsightsDependency exported +
                                     declares Target / Name / Success /
                                     DurationMs / ResultCode / Type /
                                     OperationId / Properties parameters.
      Dependency.FallbackInformation Falls back to Write-Information when no
                                     TelemetryClient is loadable.
      Dependency.SecretRedaction     Properties hashtable values for keys
                                     matching password|totpBase32|sccauth|
                                     xsrfToken|passkey|privateKey are redacted
                                     before emission.
      Dependency.OperationIdStamped  Honors -OperationId pass-through and
                                     auto-generates a fresh GUID on omission.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1') -Force
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'Dependency.Surface — Send-XdrAppInsightsDependency exported with the documented signature' {

    It 'is exported by the Xdr.Sentinel.Ingest module' {
        (Get-Module Xdr.Sentinel.Ingest).ExportedFunctions.Keys | Should -Contain 'Send-XdrAppInsightsDependency'
    }

    It 'declares the documented parameter set (Target/Name/Success/DurationMs/ResultCode/Type/OperationId/Properties)' {
        $cmd = Get-Command Send-XdrAppInsightsDependency
        $cmd.Parameters.ContainsKey('Target')      | Should -BeTrue
        $cmd.Parameters.ContainsKey('Name')        | Should -BeTrue
        $cmd.Parameters.ContainsKey('Success')     | Should -BeTrue
        $cmd.Parameters.ContainsKey('DurationMs')  | Should -BeTrue
        $cmd.Parameters.ContainsKey('ResultCode')  | Should -BeTrue
        $cmd.Parameters.ContainsKey('Type')        | Should -BeTrue
        $cmd.Parameters.ContainsKey('OperationId') | Should -BeTrue
        $cmd.Parameters.ContainsKey('Properties')  | Should -BeTrue
    }

    It 'first 4 parameters are mandatory (Target, Name, Success, DurationMs)' {
        $cmd = Get-Command Send-XdrAppInsightsDependency
        $isMandatory = {
            param($p)
            $paramAttr = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }) | Select-Object -First 1
            return $paramAttr -and $paramAttr.Mandatory
        }
        & $isMandatory $cmd.Parameters['Target']     | Should -BeTrue
        & $isMandatory $cmd.Parameters['Name']       | Should -BeTrue
        & $isMandatory $cmd.Parameters['Success']    | Should -BeTrue
        & $isMandatory $cmd.Parameters['DurationMs'] | Should -BeTrue
        # Optional parameters MUST stay optional.
        & $isMandatory $cmd.Parameters['ResultCode']  | Should -BeFalse
        & $isMandatory $cmd.Parameters['Type']        | Should -BeFalse
        & $isMandatory $cmd.Parameters['OperationId'] | Should -BeFalse
        & $isMandatory $cmd.Parameters['Properties']  | Should -BeFalse
    }
}

Describe 'Dependency.FallbackInformation — Write-Information fallback when no TelemetryClient is loadable' {

    It 'does not throw when AI client is null (unit-test process)' {
        { Send-XdrAppInsightsDependency `
            -Target     'security.microsoft.com' `
            -Name       '/api/settings/GetAdvancedFeaturesSetting' `
            -Success    $true `
            -DurationMs 123 `
            -ResultCode 200 `
            -InformationAction SilentlyContinue
        } | Should -Not -Throw
    }

    It 'emits Write-Information with the dependency identity when no AI client is loadable' {
        # Capture the Information stream so we can assert the fallback content.
        $info = Send-XdrAppInsightsDependency `
            -Target     'security.microsoft.com' `
            -Name       '/api/x/y' `
            -Success    $false `
            -DurationMs 42 `
            -ResultCode 503 `
            -InformationAction Continue 6>&1

        # The fallback message must include the target + name so operators see
        # the call identity even when AI is offline.
        ($info | Out-String) | Should -Match 'security\.microsoft\.com'
        ($info | Out-String) | Should -Match '/api/x/y'
        ($info | Out-String) | Should -Match '503'
    }

    It 'tolerates a $null Properties hashtable' {
        { Send-XdrAppInsightsDependency `
            -Target 'host' -Name '/path' -Success $true -DurationMs 1 `
            -Properties $null -InformationAction SilentlyContinue
        } | Should -Not -Throw
    }
}

Describe 'Dependency.SecretRedaction — Properties hashtable secret keys are redacted before emission' {

    It 'redacts secret keys via the shared ConvertTo-XdrAiSafeProperties helper' {
        InModuleScope Xdr.Sentinel.Ingest {
            $props = @{
                Stream     = 'Custom-MDE_X_CL'
                upn        = 'svc@contoso.com'
                password   = 'super-secret-pw'
                totpBase32 = 'JBSWY3DPEHPK3PXP'
                sccauth    = 'eyJhbGciOiJI...'
                xsrfToken  = 'XYZ-TOKEN'
                passkey    = 'private-passkey-blob'
                privateKey = '-----BEGIN PRIVATE KEY-----'
            }
            $safe = ConvertTo-XdrAiSafeProperties -Properties $props
            $safe['password']   | Should -Be '<redacted>'
            $safe['totpBase32'] | Should -Be '<redacted>'
            $safe['sccauth']    | Should -Be '<redacted>'
            $safe['xsrfToken']  | Should -Be '<redacted>'
            $safe['passkey']    | Should -Be '<redacted>'
            $safe['privateKey'] | Should -Be '<redacted>'
            # Non-secret keys flow through unchanged.
            $safe['Stream']     | Should -Be 'Custom-MDE_X_CL'
            $safe['upn']        | Should -Be 'svc@contoso.com'
        }
    }

    It 'does not mutate the caller hashtable when redaction runs' {
        $orig = @{ password = 'pw1'; sccauth = 'cookie-1'; Stream = 'X' }
        Send-XdrAppInsightsDependency -Target 't' -Name 'n' -Success $true -DurationMs 1 `
            -Properties $orig -InformationAction SilentlyContinue
        # Caller hashtable still holds the raw secrets — redaction operates
        # on the dictionary handed to TelemetryClient, not the input.
        $orig['password'] | Should -Be 'pw1'
        $orig['sccauth']  | Should -Be 'cookie-1'
    }
}

Describe 'Dependency.OperationIdStamped — Add-XdrAiAmbientContext is the source of OperationId stamping' {

    It 'auto-generates a GUID OperationId when none is supplied (shared with other Send-XdrAppInsights*)' {
        InModuleScope Xdr.Sentinel.Ingest {
            $props = [System.Collections.Generic.Dictionary[string,string]]::new()
            $ambient = Add-XdrAiAmbientContext -Properties $props -OperationId $null
            $ambient.OperationId | Should -Not -BeNullOrEmpty
            [Guid]::TryParse($ambient.OperationId, [ref]([Guid]::Empty)) | Should -BeTrue
        }
    }

    It 'pass-through OperationId is preserved verbatim' {
        InModuleScope Xdr.Sentinel.Ingest {
            $props = [System.Collections.Generic.Dictionary[string,string]]::new()
            $known = '9f3b2c1a-4b5e-4d8c-9f0a-1234567890ab'
            $ambient = Add-XdrAiAmbientContext -Properties $props -OperationId $known
            $ambient.OperationId | Should -Be $known
            $props['OperationId'] | Should -Be $known
        }
    }
}
