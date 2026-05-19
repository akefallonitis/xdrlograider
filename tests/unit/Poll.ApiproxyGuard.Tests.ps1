#Requires -Module Pester
# Locks: Test-ApiproxyPathPrefix accepts only /apiproxy/<known-service>/... ;
# Invoke-DefenderApiproxy throws (does not fall through) when path is wrong.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Poll\Xdr.Poll.psd1'
    $AuthPath   = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1'
    Import-Module $AuthPath -Force
    Import-Module $ModulePath -Force
}

Describe 'Test-ApiproxyPathPrefix' {

    It 'accepts /apiproxy/mtp/sccManagement/mgmt/TenantContext' {
        Test-ApiproxyPathPrefix -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext' | Should -BeTrue
    }
    It 'accepts /apiproxy/mdi/...' {
        Test-ApiproxyPathPrefix -Path '/apiproxy/mdi/sensor/list' | Should -BeTrue
    }
    It 'accepts /apiproxy/mcas/...' {
        Test-ApiproxyPathPrefix -Path '/apiproxy/mcas/things' | Should -BeTrue
    }
    It 'REJECTS /mtp/... (no /apiproxy/ prefix; the v2 BLOCKER)' {
        Test-ApiproxyPathPrefix -Path '/mtp/sccManagement/mgmt/TenantContext' | Should -BeFalse
    }
    It 'REJECTS /apiproxy/INVALID/... (unknown service)' {
        Test-ApiproxyPathPrefix -Path '/apiproxy/notaservice/foo' | Should -BeFalse
    }
    It 'REJECTS empty path at parameter binding (cannot be empty string)' {
        # PowerShell parameter binding rejects empty string by default; the rejection
        # is correct regardless of which layer catches it.
        { Test-ApiproxyPathPrefix -Path '' } | Should -Throw
    }
}

Describe 'Invoke-DefenderApiproxy — path prefix runtime guard' {
    It 'throws when path is missing the /apiproxy/ svc / prefix' {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        { Invoke-DefenderApiproxy -Path '/mtp/foo' -Session $session } | Should -Throw -ExpectedMessage '*missing /apiproxy/*prefix*'
    }
    It 'throws when path uses an unknown service' {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        { Invoke-DefenderApiproxy -Path '/apiproxy/badsvc/foo' -Session $session } | Should -Throw -ExpectedMessage '*missing /apiproxy/*prefix*'
    }
}
