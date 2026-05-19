#Requires -Module Pester
# Locks the New-ApiproxyPath builder behaviour. The builder constructs an
# /apiproxy/<service>/<path>?<query> URL fragment from a service enum + a raw
# path + optional query parameters. Pure function — testable offline.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Poll\Xdr.Poll.psd1') -Force
}

Describe 'New-ApiproxyPath builder' -Tag 'auth-builder' {

    It 'is exported from Xdr.Auth' {
        Get-Command -Module Xdr.Auth -Name 'New-ApiproxyPath' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'builds /apiproxy/{service}/{path} for a known service' {
        $p = New-ApiproxyPath -Service 'mtp' -Path 'sccManagement/mgmt/TenantContext'
        $p | Should -Be '/apiproxy/mtp/sccManagement/mgmt/TenantContext'
    }

    It 'normalises a leading slash on Path so the caller does not have to' {
        $p = New-ApiproxyPath -Service 'mtp' -Path '/sccManagement/mgmt/TenantContext'
        $p | Should -Be '/apiproxy/mtp/sccManagement/mgmt/TenantContext'
    }

    It 'appends url-encoded query parameters when supplied' {
        $p = New-ApiproxyPath -Service 'mtp' -Path 'sccManagement/mgmt/TenantContext' -QueryParams @{ realTime = 'true' }
        $p | Should -Be '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true'
    }

    It 'preserves multiple query parameters in stable lexicographic key order' {
        $p = New-ApiproxyPath -Service 'mtp' -Path 'x/y' -QueryParams @{ b = '2'; a = '1' }
        $p | Should -Be '/apiproxy/mtp/x/y?a=1&b=2'
    }

    It 'url-encodes special characters in query values' {
        $p = New-ApiproxyPath -Service 'mtp' -Path 'x/y' -QueryParams @{ q = 'has space & amp' }
        $p | Should -Match '\?q=has\+space\+%26\+amp$|\?q=has%20space%20%26%20amp$'
    }

    It 'throws on unknown service (typo guard)' {
        { New-ApiproxyPath -Service 'notaservice' -Path 'x/y' } | Should -Throw -ExpectedMessage '*service*'
    }

    It 'throws on empty Path (caller must supply something to call)' {
        { New-ApiproxyPath -Service 'mtp' -Path '' } | Should -Throw
    }

    It 'is idempotent when caller already passed an /apiproxy/{service}/ prefix on Path' {
        # A manifest may already have the prefix baked in. The builder should return
        # the input unchanged rather than producing /apiproxy/mtp/apiproxy/mtp/...
        $alreadyPrefixed = '/apiproxy/mtp/sccManagement/mgmt/TenantContext'
        $p = New-ApiproxyPath -Service 'mtp' -Path $alreadyPrefixed
        $p | Should -Be $alreadyPrefixed
    }

    It 'output round-trips through Test-ApiproxyPathPrefix (Xdr.Poll validator)' {
        $p = New-ApiproxyPath -Service 'mtp' -Path 'sccManagement/mgmt/TenantContext' -QueryParams @{ realTime = 'true' }
        Test-ApiproxyPathPrefix -Path $p | Should -BeTrue
    }

    It 'accepts every service in the canonical list' {
        $services = @('mtp','aatp','mcas','mdi','mtoapi','radius','mdc',
                      'm365appprotection','astgws','securityplatform','di',
                      'msgraph','shell','medeina','gws','cdssecuritycopilot','arm')
        foreach ($svc in $services) {
            $p = New-ApiproxyPath -Service $svc -Path 'x'
            $p | Should -Be "/apiproxy/$svc/x" -Because "service '$svc' is in the canonical list"
        }
    }
}
