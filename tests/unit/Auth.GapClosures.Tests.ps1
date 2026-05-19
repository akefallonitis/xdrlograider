#Requires -Module Pester
# φ.AUTH.7 · Gap-closure tests · 3 functions audit found uncovered.
# Locks: Get-EntraEstsAuth pre-condition validation · Clear-XdrCookieCache cleanup ·
# Clear-XdrAuthCircuit explicit invocation contract.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
}

Describe 'φ.AUTH.7 · Get-EntraEstsAuth · pre-condition validation' -Tag 'auth-gap' {

    It 'throws when Credential lacks upn' {
        $cred = @{ password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
        {
            Get-EntraEstsAuth -Credential $cred -ClientId 'some-client' -PortalHost 'security.microsoft.com'
        } | Should -Throw "*'upn'*"
    }

    It 'throws when AuthProfile=Bearer but RedirectUri missing' {
        $cred = @{ upn = 'sa@contoso.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
        {
            Get-EntraEstsAuth -Credential $cred -ClientId 'some-client' -PortalHost 'login.microsoftonline.com' -AuthProfile Bearer
        } | Should -Throw '*Bearer requires -RedirectUri*'
    }

    It 'throws when AuthVersion=v1 + Bearer but Resource missing (D-38 admin-portal canonical)' {
        $cred = @{ upn = 'sa@contoso.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
        {
            Get-EntraEstsAuth -Credential $cred -ClientId 'some-client' -PortalHost 'login.microsoftonline.com' `
                -AuthProfile Bearer -RedirectUri 'https://portal.azure.com/signin/index/' -AuthVersion v1
        } | Should -Throw '*Resource*'
    }

    It 'Cookie profile does NOT require RedirectUri (only Bearer does)' {
        # We expect this to fail at Invoke-WebRequest (no network) · but the param-validation
        # must PASS first (no early throw about RedirectUri). We catch and inspect the message.
        $cred = @{ upn = 'sa@contoso.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
        $thrown = $null
        try {
            Get-EntraEstsAuth -Credential $cred -ClientId 'some-client' -PortalHost 'nonexistent-test-host.invalid' -AuthProfile Cookie
        } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        # The error MUST NOT be about RedirectUri (proves param-validation passed and got further)
        $thrown.Exception.Message | Should -Not -Match 'RedirectUri'
    }
}

Describe 'φ.AUTH.7 · Clear-XdrCookieCache · operator/test cleanup' -Tag 'auth-gap' {

    It 'is exported by the module' {
        Get-Command Clear-XdrCookieCache -Module Xdr.Auth -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'idempotent · running on empty cache does not throw' {
        { Clear-XdrCookieCache } | Should -Not -Throw
    }

    It 'after seeding $script:SessionCache · Clear empties it · subsequent Connect-DefenderPortal needs fresh chain' {
        # Seed cache via InModuleScope (bypass normal Connect-* path · simulates prior cycle)
        InModuleScope Xdr.Auth {
            if (-not (Get-Variable -Scope Script -Name SessionCache -ErrorAction SilentlyContinue)) {
                $script:SessionCache = @{}
            }
            $script:SessionCache['fake-key::test-host'] = @{ Session = $null; Upn = 'test'; PortalHost = 'test' }
        }
        # Verify the seed worked
        $beforeCount = InModuleScope Xdr.Auth { $script:SessionCache.Count }
        $beforeCount | Should -BeGreaterOrEqual 1
        # Clear
        Clear-XdrCookieCache
        # Cache should now be empty
        $afterCount = InModuleScope Xdr.Auth { $script:SessionCache.Count }
        $afterCount | Should -Be 0
    }
}

Describe 'φ.AUTH.7 · Clear-XdrAuthCircuit · explicit clear contract' -Tag 'auth-gap' {

    It 'is exported by the module' {
        Get-Command Clear-XdrAuthCircuit -Module Xdr.Auth -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'idempotent · running on empty hashtable does not throw' {
        { Clear-XdrAuthCircuit } | Should -Not -Throw
    }

    It 'removes ALL failure-window entries (not just current key)' {
        # Seed multiple keys
        Add-XdrAuthCircuitFailure -Key 'a' -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key 'b' -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key 'b' -Reason 'unit'
        # Verify both keys recorded
        InModuleScope Xdr.Auth { $script:AuthFailureWindow.Count } | Should -BeGreaterOrEqual 2
        # Clear all
        Clear-XdrAuthCircuit
        # Hashtable empty
        InModuleScope Xdr.Auth { $script:AuthFailureWindow.Count } | Should -Be 0
        # Both keys default-closed after clear
        Test-XdrAuthCircuitOpen -Key 'a' | Should -BeFalse
        Test-XdrAuthCircuitOpen -Key 'b' | Should -BeFalse
    }

    It 'emits Auth.FailureCircuit.ClearAll telemetry (audit trail)' {
        $info = $null
        Add-XdrAuthCircuitFailure -Key 'observability-test' -Reason 'unit' 6>&1 | Out-Null
        Clear-XdrAuthCircuit 6>&1 | Tee-Object -Variable info | Out-Null
        # Last emitted record should be the ClearAll telemetry
        $payload = ($info | Select-Object -Last 1).ToString() | ConvertFrom-Json -ErrorAction SilentlyContinue
        $payload.EventName | Should -Be 'Auth.FailureCircuit.ClearAll'
    }
}
