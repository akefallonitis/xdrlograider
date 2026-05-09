#Requires -Modules Pester
<#
.SYNOPSIS
    Phase 4 polish P1 (Plan R++++++++++.AMEND-6): execution-based coverage lift
    for Connect-DefenderPortal.ps1 (88 lines, 3% covered → target ~85%+).

.DESCRIPTION
    Existing Auth.ErrorPaths.Tests.ps1 source-pattern matches; never executes the
    function so coverage stays at 3%. Plan Section 0 BANS regex-pattern unit tests
    that pin buggy code shape — required pattern is BEHAVIOURAL: execute with
    realistic input, assert outcome.

    Mocks all collaborators (Get-EntraEstsAuth / Get-DefenderSccauth /
    Send-XdrAppInsights*) at module scope so the function body actually runs.

    Branches exercised (10):
      1. Method snake_case 'credentials_totp' normalization to 'CredentialsTotp'
      2. Method snake_case 'passkey' normalization
      3. Credential.upn missing -> throw
      4. Cache miss happy path: full chain L1 -> L2 -> cache write -> return
      5. Cache hit (age < 50min) -> short-circuit return cached entry
      6. Cache stale (age >= 50min) -> evict + re-authenticate
      7. -Force bypass cache + re-authenticate
      8. AuthChain.Started event emitted on cache miss
      9. AuthChain.AADSTSError catch -> Send-XdrAppInsightsException + re-throw
      10. xdr.auth.chain_step_duration_ms metric emitted per step
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonTele   = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1'
    $script:CommonAuth   = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1'
    $script:DefenderAuth = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1'

    Import-Module $script:CommonTele   -Force -Global -ErrorAction Stop
    Import-Module $script:CommonAuth   -Force -Global -ErrorAction Stop
    Import-Module $script:DefenderAuth -Force -Global -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Telemetry -Force -ErrorAction SilentlyContinue
}

Describe 'Connect-DefenderPortal.Execution — happy path + cache' {

    BeforeEach {
        # Reset module-scope cache between tests
        $module = Get-Module Xdr.Defender.Auth
        if ($module) { & $module { $script:SessionCache = @{} } }

        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Mock -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth {
            return [pscustomobject]@{
                Session = $sess
                Upn     = 'svc@contoso.com'
            }
        }
        Mock -ModuleName Xdr.Defender.Auth Get-DefenderSccauth {
            return [pscustomobject]@{
                Session     = $sess
                TenantId    = '00000000-0000-0000-0000-000000000000'
                AcquiredUtc = [datetime]::UtcNow
            }
        }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomEvent { }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomMetric { }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsException { }
    }

    It 'cache miss: completes L1 + L2 auth chain + writes cache + returns session' {
        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        $result = Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred -PortalHost 'security.microsoft.com'

        $result | Should -Not -BeNullOrEmpty
        $result.Upn | Should -Be 'svc@contoso.com'
        $result.PortalHost | Should -Be 'security.microsoft.com'
        $result.TenantId | Should -Be '00000000-0000-0000-0000-000000000000'
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth -Times 1
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Get-DefenderSccauth -Times 1
    }

    It 'snake_case method credentials_totp normalizes to CredentialsTotp downstream' {
        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        $captured = $null
        Mock -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth {
            $script:capturedMethod = $Method
            $sess2 = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            return [pscustomobject]@{ Session = $sess2; Upn = $Credential.upn }
        }
        Mock -ModuleName Xdr.Defender.Auth Get-DefenderSccauth {
            return [pscustomobject]@{ Session = $Session; TenantId = 'tid'; AcquiredUtc = [datetime]::UtcNow }
        }

        Connect-DefenderPortal -Method 'credentials_totp' -Credential $cred | Out-Null

        # The snake_case input must normalize to PascalCase before being passed downstream
        $script:capturedMethod | Should -Be 'CredentialsTotp'
    }

    It 'snake_case method passkey normalizes to Passkey downstream' {
        $cred = @{ upn = 'svc@contoso.com'; passkey = @{ id = 'k' } }
        Mock -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth {
            $script:capturedMethod = $Method
            $sess3 = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            return [pscustomobject]@{ Session = $sess3; Upn = $Credential.upn }
        }
        Mock -ModuleName Xdr.Defender.Auth Get-DefenderSccauth {
            return [pscustomobject]@{ Session = $Session; TenantId = 'tid'; AcquiredUtc = [datetime]::UtcNow }
        }

        Connect-DefenderPortal -Method 'passkey' -Credential $cred | Out-Null

        $script:capturedMethod | Should -Be 'Passkey'
    }

    It 'cache hit: returns cached entry without re-running auth chain' {
        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }

        # First call: warms the cache
        Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred | Out-Null
        # Second call: should hit cache
        Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred | Out-Null

        # L1 should have been called only ONCE total (1st call); 2nd hit cache
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth -Times 1
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Get-DefenderSccauth -Times 1
        # AuthChain.CacheHit event must have been emitted on the 2nd call
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomEvent -ParameterFilter {
            $EventName -eq 'AuthChain.CacheHit'
        } -Times 1
    }

    It '-Force bypasses cache and re-runs full auth chain' {
        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }

        Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred | Out-Null
        Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred -Force | Out-Null

        Assert-MockCalled -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth -Times 2
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Get-DefenderSccauth -Times 2
    }

    It 'cache stale (age >= 50min) -> evict + re-authenticate' {
        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        # Pre-populate cache with stale entry
        $module = Get-Module Xdr.Defender.Auth
        & $module {
            $script:SessionCache['svc@contoso.com::security.microsoft.com'] = @{
                Session       = ([Microsoft.PowerShell.Commands.WebRequestSession]::new())
                Upn           = 'svc@contoso.com'
                PortalHost    = 'security.microsoft.com'
                TenantId      = 'old-tid'
                AcquiredUtc   = ([datetime]::UtcNow.AddMinutes(-60))
                CorrelationId = 'old-corr'
                _Method       = 'CredentialsTotp'
                _Credential   = @{}
            }
        }

        Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred | Out-Null

        # Stale cache must have been evicted -> full chain runs
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth -Times 1
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomEvent -ParameterFilter {
            $EventName -eq 'AuthChain.CacheEvict'
        } -Times 1
    }
}

Describe 'Connect-DefenderPortal.Execution — error paths + telemetry' {

    BeforeEach {
        $module = Get-Module Xdr.Defender.Auth
        if ($module) { & $module { $script:SessionCache = @{} } }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomEvent { }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomMetric { }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsException { }
    }

    It 'missing upn in Credential hashtable -> throws actionable error' {
        $cred = @{ password = 'p'; totpBase32 = 'JBSW' }   # No upn

        { Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred } |
            Should -Throw -ExpectedMessage "*upn*"
    }

    It 'AADSTS50053 (account locked) emits AuthChain.AADSTSError + re-throws' {
        Mock -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth {
            throw "Authentication failed: AADSTS50053 - Sign-in was blocked because the account is locked"
        }

        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        { Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred } |
            Should -Throw -ExpectedMessage '*AADSTS50053*'

        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsException -Times 1 -ParameterFilter {
            $Properties.ErrorClass -eq 'AuthChain.AADSTSError' -and
            $Properties.AADSTSCode -eq '50053' -and
            $Properties.Stage      -eq 'credentials'
        }
    }

    It 'AADSTS error in MFA stage (ProcessAuth) classifies Stage=mfa' {
        Mock -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth {
            throw "AADSTS50079 ProcessAuth - User must enroll in MFA"
        }

        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        { Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred } | Should -Throw

        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsException -Times 1 -ParameterFilter {
            $Properties.AADSTSCode -eq '50079' -and
            $Properties.Stage      -eq 'mfa'
        }
    }

    It 'L2 Get-DefenderSccauth failure also routes through AADSTSError catch' {
        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Mock -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth {
            return [pscustomobject]@{ Session = $sess; Upn = $Credential.upn }
        }
        Mock -ModuleName Xdr.Defender.Auth Get-DefenderSccauth {
            throw 'sccauth not issued — Defender callback never set the cookie'
        }

        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        { Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred } |
            Should -Throw -ExpectedMessage '*sccauth*'

        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsException -Times 1
    }
}

Describe 'Connect-DefenderPortal.Execution — telemetry instrumentation' {

    BeforeEach {
        $module = Get-Module Xdr.Defender.Auth
        if ($module) { & $module { $script:SessionCache = @{} } }
        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Mock -ModuleName Xdr.Defender.Auth Get-EntraEstsAuth {
            return [pscustomobject]@{ Session = $sess; Upn = $Credential.upn }
        }
        Mock -ModuleName Xdr.Defender.Auth Get-DefenderSccauth {
            return [pscustomobject]@{ Session = $Session; TenantId = 'tid'; AcquiredUtc = [datetime]::UtcNow }
        }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomEvent { }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomMetric { }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsException { }
    }

    It 'emits AuthChain.Started + AuthChain.Completed events around the chain' {
        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred | Out-Null

        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomEvent -Times 1 -ParameterFilter {
            $EventName -eq 'AuthChain.Started'
        }
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomEvent -Times 1 -ParameterFilter {
            $EventName -eq 'AuthChain.Completed'
        }
    }

    It 'emits xdr.auth.chain_step_duration_ms for both EntraEsts + DefenderSccauth steps' {
        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred | Out-Null

        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomMetric -Times 1 -ParameterFilter {
            $MetricName -eq 'xdr.auth.chain_step_duration_ms' -and
            $Properties.Step -eq 'EntraEsts'
        }
        Assert-MockCalled -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomMetric -Times 1 -ParameterFilter {
            $MetricName -eq 'xdr.auth.chain_step_duration_ms' -and
            $Properties.Step -eq 'DefenderSccauth'
        }
    }

    It 'every event/metric carries OperationId for cross-layer correlation' {
        $cred = @{ upn = 'svc@contoso.com'; password = 'p'; totpBase32 = 'JBSW' }
        $capturedOpIds = @()
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomEvent {
            $script:capturedOpIds += $OperationId
        }
        Mock -ModuleName Xdr.Defender.Auth Send-XdrAppInsightsCustomMetric {
            $script:capturedOpIds += $OperationId
        }
        $script:capturedOpIds = @()

        Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred | Out-Null

        $script:capturedOpIds | Should -Not -BeNullOrEmpty
        # All emissions in same chain share one correlation ID
        $unique = @($script:capturedOpIds | Sort-Object -Unique)
        $unique.Count | Should -Be 1 -Because 'all events in one auth chain share a correlation id'
        # Should be a valid GUID
        { [guid]::Parse($unique[0]) } | Should -Not -Throw
    }
}
