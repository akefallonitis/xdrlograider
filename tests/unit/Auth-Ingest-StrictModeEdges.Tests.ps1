#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.5 behavioral regression gates: auth + ingest paths must survive
    every weird shape upstream Azure cmdlets / HTTP exceptions can produce
    under strict mode.

.DESCRIPTION
    Bug class: $obj.PropertyName access under strict mode throws if the
    property doesn't exist. Real production paths that hit this:

      A) Get-AzAccessToken response shape varies (Az.Accounts 3.x string vs
         5.x SecureString vs mock $null). Strict-mode access on .ExpiresOn
         or .Token can crash the entire DCE ingest flow.

      B) WebException / HttpResponseException .Response property can be $null
         for non-HTTP errors (DNS, TLS, timeout). Strict-mode access on
         .Response.StatusCode crashes the catch block masking the real cause.

    These behavioral tests EXECUTE the production code paths and assert
    they handle each edge case gracefully (no strict-mode crash, returns a
    sensible default or surfaces a meaningful error).
#>

BeforeAll {
    $script:RepoRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:AuthModulePath   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth'   'Xdr.Portal.Auth.psd1'
    $script:IngestModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'

    # Stub Az.* deps before module import (Ingest module resolves at runtime).
    function global:Get-AzAccessToken { param([string]$ResourceUrl) [pscustomobject]@{ Token = 'stub'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }

    Import-Module $script:AuthModulePath   -Force -ErrorAction Stop
    Import-Module $script:IngestModulePath -Force -ErrorAction Stop

    Set-StrictMode -Version Latest
}

Describe 'Send-ToLogAnalytics — Get-AzAccessToken response shape robustness' {

    Context 'Token acquisition handles all observed/possible Get-AzAccessToken response shapes' {

        It 'survives <Description>' -ForEach @(
            @{ Description = 'Az.Accounts 3.x string ExpiresOn';                        TokenObj = ([pscustomobject]@{ Token = 'abc'; ExpiresOn = '2099-01-01T00:00:00Z' }) }
            @{ Description = 'Az.Accounts 5.x DateTimeOffset ExpiresOn';                TokenObj = ([pscustomobject]@{ Token = 'abc'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) }) }
            @{ Description = 'object missing ExpiresOn property entirely';              TokenObj = ([pscustomobject]@{ Token = 'abc' }) }
            @{ Description = 'object with $null ExpiresOn';                             TokenObj = ([pscustomobject]@{ Token = 'abc'; ExpiresOn = $null }) }
            @{ Description = 'object with malformed ExpiresOn string';                  TokenObj = ([pscustomobject]@{ Token = 'abc'; ExpiresOn = 'not-a-date' }) }
        ) {
            param($Description, $TokenObj)

            InModuleScope Xdr.Sentinel.Ingest -Parameters @{ TokenObj = $TokenObj } {
                param($TokenObj)

                # Reset module-scope token cache so each iteration re-acquires.
                $script:MonitorTokenCache  = $null
                $script:MonitorTokenExpiry = [datetime]::MinValue

                Mock Get-AzAccessToken -ModuleName Xdr.Sentinel.Ingest { $TokenObj } -ParameterFilter { $true }
                Mock Invoke-WebRequest -ModuleName Xdr.Sentinel.Ingest { [pscustomobject]@{ StatusCode = 204 } } -ParameterFilter { $true }

                # The thing we MOST care about: Send-ToLogAnalytics must not
                # strict-mode-crash on the token-shape variance. Capture both
                # whether it threw AND the result for completeness.
                $threw = $false
                $errorMessage = $null
                $result = $null
                try {
                    $result = Send-ToLogAnalytics `
                        -DceEndpoint    'https://dce.test/' `
                        -DcrImmutableId 'dcr-stub' `
                        -StreamName     'Custom-MDE_Test_CL' `
                        -Rows           @([pscustomobject]@{ TimeGenerated = (Get-Date).ToString('o'); EntityId = '1'; SourceStream = 'MDE_Test_CL'; RawJson = '{}' })
                } catch {
                    $threw = $true
                    $errorMessage = $_.Exception.Message
                }
                # Iter 13.5 contract: NO strict-mode crash on token-shape variance.
                $threw | Should -BeFalse -Because "iter 13.5: token-shape variance must not strict-mode-crash the ingest path. Got: $errorMessage"
                $result | Should -Not -BeNullOrEmpty
                $result.RowsSent | Should -Be 1
            }
        }
    }
}

Describe 'Send-ToLogAnalytics — exception .Response defensive handling' {

    Context 'Various exception shapes during Invoke-WebRequest' {

        It 'surfaces a meaningful error for <Description>' -ForEach @(
            @{ Description = 'WebException with null .Response (DNS/TLS class)';      MakeException = { New-Object System.Net.WebException ('DNS resolution failed', $null) } }
            @{ Description = 'generic Exception (no .Response property at all)';     MakeException = { New-Object System.Exception ('Generic failure') } }
            @{ Description = 'IOException (no .Response property)';                   MakeException = { New-Object System.IO.IOException ('Disk full') } }
        ) {
            param($Description, $MakeException)

            InModuleScope Xdr.Sentinel.Ingest -Parameters @{ ExFactory = $MakeException } {
                param($ExFactory)

                # Force fresh token acquisition
                $script:MonitorTokenCache  = $null
                $script:MonitorTokenExpiry = [datetime]::MinValue

                Mock Get-AzAccessToken -ModuleName Xdr.Sentinel.Ingest { [pscustomobject]@{ Token = 't'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } } -ParameterFilter { $true }
                Mock Invoke-WebRequest -ModuleName Xdr.Sentinel.Ingest { throw (& $ExFactory) } -ParameterFilter { $true }

                # The exception is non-transient (no statusCode) → after MaxRetries
                # retries, Send-ToLogAnalytics throws with a descriptive message.
                # Test that the message includes "DCE ingest failed" rather than a
                # strict-mode "property not found" crash.
                $errorMessage = $null
                try {
                    Send-ToLogAnalytics `
                        -DceEndpoint    'https://dce.test/' `
                        -DcrImmutableId 'dcr-stub' `
                        -StreamName     'Custom-MDE_Test_CL' `
                        -Rows           @([pscustomobject]@{ TimeGenerated = (Get-Date).ToString('o'); EntityId = '1'; SourceStream = 'MDE_Test_CL'; RawJson = '{}' }) `
                        -MaxRetries     1
                } catch {
                    $errorMessage = $_.Exception.Message
                }
                $errorMessage | Should -Not -BeNullOrEmpty -Because 'iter 13.5: a meaningful error must be raised, not a strict-mode crash'
                $errorMessage | Should -Match 'DCE ingest failed' -Because 'the descriptive wrapper message must survive — strict-mode crash on .Response would replace it with property-not-found error'
            }
        }
    }
}
