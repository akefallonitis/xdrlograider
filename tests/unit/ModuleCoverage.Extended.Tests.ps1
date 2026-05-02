#Requires -Modules Pester
<#
.SYNOPSIS
    Fills coverage gaps across the 3 runtime modules — edge-case paths that
    weren't exercised by the targeted auth/dispatcher/tier/ingest tests.

    Targets:
      Xdr.Common.Auth (L1 Entra layer; iter-14.0):
        - n/a (covered by Xdr.Common.Auth.Tests.ps1 + Xdr.Common.Auth.AuthChain.Tests.ps1)

      Xdr.Defender.Auth (L2 Defender; iter-14.0):
        - Update-XsrfToken error paths (missing cookie, expired session)
        - Test-DefenderPortalAuth stages (mocked via Connect-DefenderPortal)

      XdrLogRaider.Ingest:
        - Get-XdrAuthSelfTestFlag — all 5 return paths
        - Write-Heartbeat schema + null-safety
        - Write-AuthTestResult schema
        - Checkpoint edge cases

      XdrLogRaider.Client:
        - Expand-MDEResponse on all input shapes
        - ConvertTo-MDEIngestRow with custom IdProperty
        - Path substitution + missing PathParams error
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    # Five-module imports — explicit references for Mock -ModuleName.
    Import-Module "$script:Root/src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1"           -Force
    Import-Module "$script:Root/src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1"   -Force
    Import-Module "$script:Root/src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1"       -Force
    Import-Module "$script:Root/src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1"   -Force
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
}

Describe 'Update-XsrfToken (Xdr.Defender.Auth — iter-14.0 home)' {

    It 'throws when the portal cookie jar has no XSRF-TOKEN' {
        InModuleScope Xdr.Defender.Auth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            # No cookies at all → function should throw with clear message
            { Update-XsrfToken -Session $session -PortalHost 'security.microsoft.com' } |
                Should -Throw -ExpectedMessage '*XSRF-TOKEN missing*'
        }
    }

    It 'URL-decodes the cookie value before returning (portal middleware rejects encoded form)' {
        InModuleScope Xdr.Defender.Auth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://security.microsoft.com/')
            # Cookie stores URL-encoded value (e.g. '+' → '%2B')
            $cookie = [System.Net.Cookie]::new('XSRF-TOKEN', 'abc%2Bdef%3D', '/', 'security.microsoft.com')
            $session.Cookies.Add($uri, $cookie)

            $decoded = Update-XsrfToken -Session $session -PortalHost 'security.microsoft.com'
            $decoded | Should -Be 'abc+def='   # '+' and '=' come back decoded
        }
    }
}

# NOTE: Get-XdrAuthSelfTestFlag tests removed in v0.1.0-beta post-deploy
# hardening — the gate (Get + Set + cooldown) was deleted as a workaround
# that masked the AUTH_SECRET_NAME='mde-portal-auth' bug. Defence-in-depth
# now: Entra account-lockout + Azure Functions [FixedDelayRetry] on timer
# triggers + heartbeat fatalError Notes. See ARCHITECTURE.md auth-chain
# section + tests/arm/AuthSecretNameInvariants.Tests.ps1 for the
# regression gate that locks the CORRECT secret-prefix value.

Describe 'ConvertTo-MDEIngestRow schema' {

    It 'produces rows with TimeGenerated + SourceStream + EntityId + RawJson' {
        InModuleScope Xdr.Defender.Client {
            $row = ConvertTo-MDEIngestRow -Stream 'MDE_Test_CL' -EntityId 'e-1' -Raw ([pscustomobject]@{ foo = 'bar' })
            $row.TimeGenerated | Should -Not -BeNullOrEmpty
            $row.SourceStream  | Should -Be 'MDE_Test_CL'
            $row.EntityId      | Should -Be 'e-1'
            ($row.RawJson | ConvertFrom-Json).foo | Should -Be 'bar'
        }
    }

    It 'merges Extras into the row' {
        InModuleScope Xdr.Defender.Client {
            $row = ConvertTo-MDEIngestRow -Stream 'MDE_Test_CL' -EntityId 'e-1' `
                -Raw ([pscustomobject]@{ x = 1 }) -Extras @{ deviceId = 'dev-abc' }
            $row.deviceId | Should -Be 'dev-abc'
        }
    }

    It 'TimeGenerated is ISO-8601 with zone suffix' {
        InModuleScope Xdr.Defender.Client {
            $row = ConvertTo-MDEIngestRow -Stream 'MDE_Test_CL' -EntityId 'e-1' -Raw ([pscustomobject]@{})
            $row.TimeGenerated | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$'
        }
    }
}

Describe 'Expand-MDEResponse on varied input shapes' {

    It 'returns ZERO rows on null response (post-deploy contract)' {
        # v0.1.0-beta post-deploy hardening: boundary markers no longer
        # pollute MDE_*_CL tables. Empty/null responses return @() and emit
        # an Ingest.BoundaryMarker AppInsights customEvent for operator
        # visibility. See tests/unit/Expand-MDEResponse.iter14.Tests.ps1
        # for the AppInsights-event assertions.
        InModuleScope Xdr.Defender.Client {
            $r = @(Expand-MDEResponse -Response $null)
            $r.Count | Should -Be 0 -Because 'null response = zero rows; AppInsights event carries the operator signal'
        }
    }

    It 'extracts id from array elements' {
        InModuleScope Xdr.Defender.Client {
            $r = Expand-MDEResponse -Response @(
                [pscustomobject]@{ id = 'one'; name = 'first' }
                [pscustomobject]@{ id = 'two'; name = 'second' }
            )
            $r.Count | Should -Be 2
            $r[0].Id | Should -Be 'one'
            $r[1].Id | Should -Be 'two'
        }
    }

    It 'falls back to index when no id-like property found' {
        InModuleScope Xdr.Defender.Client {
            $r = Expand-MDEResponse -Response @(
                [pscustomobject]@{ foo = 'a' }
                [pscustomobject]@{ foo = 'b' }
            )
            $r[0].Id | Should -Be 'idx-0'
            $r[1].Id | Should -Be 'idx-1'
        }
    }

    It 'uses custom IdProperty list (e.g. ruleId) when provided' {
        InModuleScope Xdr.Defender.Client {
            $r = Expand-MDEResponse -Response @(
                [pscustomobject]@{ ruleId = 'rule-42'; name = 'alertrule' }
            ) -IdProperty @('ruleId')
            $r[0].Id | Should -Be 'rule-42'
        }
    }

    It 'iterates named properties when Response is a keyed object' {
        InModuleScope Xdr.Defender.Client {
            $obj = [pscustomobject]@{
                pua_enabled = $true
                pua_block_mode = 'Audit'
            }
            $r = Expand-MDEResponse -Response $obj
            $r.Count | Should -Be 2
            ($r | Where-Object Id -eq 'pua_enabled').Entity | Should -BeTrue
        }
    }
}

Describe 'Test-DefenderPortalAuth stage reporting' {
    # Stage names: the rewrite-era 'ests-cookie' stage is subsumed under
    # 'auth-chain' (since the L2 module's Connect-DefenderPortal wraps both
    # Get-EntraEstsAuth + Get-DefenderSccauth into one stage). Tests target
    # the L2 function directly so we exercise the actual stage names in
    # production.

    It 'reports auth-chain stage on initial auth failure (Connect-DefenderPortal throws)' {
        InModuleScope Xdr.Defender.Auth {
            Mock Connect-DefenderPortal { throw 'ESTS sign-in blocked by CA' }
            $r = Test-DefenderPortalAuth -Method CredentialsTotp -Credential @{
                upn = 'x@y.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
            }
            $r.Success       | Should -BeFalse
            $r.Stage         | Should -Be 'auth-chain'
            $r.FailureReason | Should -Match 'CA|ESTS'
        }
    }

    It 'reports Success=true + TenantId when every step green (post iter-14.0 split)' {
        InModuleScope Xdr.Defender.Auth {
            $s = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://security.microsoft.com/')
            $sc = [System.Net.Cookie]::new('sccauth', 'real-sccauth-value', '/', 'security.microsoft.com')
            $xs = [System.Net.Cookie]::new('XSRF-TOKEN', 'real-xsrf', '/', 'security.microsoft.com')
            $s.Cookies.Add($uri, $sc); $s.Cookies.Add($uri, $xs)

            Mock Connect-DefenderPortal {
                [pscustomobject]@{
                    Session     = $s
                    Upn         = $Credential.upn
                    PortalHost  = $PortalHost
                    TenantId    = '45f52f35-73d5-4066-8378-fe506ee90fb1'
                    AcquiredUtc = [datetime]::UtcNow
                }
            }
            Mock Invoke-DefenderPortalRequest {
                [pscustomobject]@{ AuthInfo = [pscustomobject]@{ TenantId = '45f52f35-73d5-4066-8378-fe506ee90fb1' } }
            }

            $r = Test-DefenderPortalAuth -Method CredentialsTotp -Credential @{
                upn = 'x@y.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
            }
            $r.Success            | Should -BeTrue
            $r.Stage              | Should -Be 'complete'
            $r.TenantId           | Should -Be '45f52f35-73d5-4066-8378-fe506ee90fb1'
            $r.SampleCallHttpCode | Should -Be 200
        }
    }
}
