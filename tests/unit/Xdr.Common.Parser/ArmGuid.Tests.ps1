#Requires -Version 7.4
# Get-XdrArmGuid · the OFFLINE reproduction of ARM/Bicep template `guid(arg1, arg2, ...)`.
# WS-card-sync Defect-1: tools/Onboard-CategorySurgical.ps1 must create the per-DCR Monitoring Metrics Publisher role
# with the EXACT deterministic NAME deploy/mainTemplate.json computes via ARM `guid(resourceId(DCR), principalId,
# 'MMP-DCR-<cat>')`. A random-GUID name would 409 RoleAssignmentExists on a later full re-deploy (and block the GA
# fresh-deploy gate). This test PROVES the reproduction is byte-exact:
#   1. RFC 9562 §A.4 + Python uuid.uuid5 KNOWN-ANSWER vectors (the v5 byte mechanics: namespace-BE || UTF-8 name, SHA-1,
#      version-5 nibble, RFC-4122 variant) — if these pass, the algorithm is RFC-correct, not a look-alike.
#   2. ARM's FIXED namespace 11fb06fb-712d-4ddd-98c7-e71bbd588830 is the default (Microsoft Bicep string-functions doc).
#   3. The '-' JOIN semantics: guid('a','b') != guid('ab') (ARM concatenates args with a hyphen delimiter).
#   4. Determinism (idempotent · same args → same value).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Parser -Force -DisableNameChecking
}

Describe 'Get-XdrArmGuid · RFC 4122/9562 v5 byte-exactness (known-answer vectors)' {
    # The v5 algorithm is namespace-agnostic; proving these published vectors confirms the byte mechanics are correct
    # (namespace big-endian, UTF-8 name, SHA-1, first-16-bytes, version/variant masking) independent of ARM's namespace.
    It 'matches RFC 9562 §A.4 · uuid5(NAMESPACE_DNS, "www.example.com")' {
        Get-XdrArmGuid -Arguments @('www.example.com') -Namespace '6ba7b810-9dad-11d1-80b4-00c04fd430c8' |
            Should -BeExactly '2ed6657d-e927-568b-95e1-2665a8aea6a2'
    }
    It 'matches Python docs · uuid5(NAMESPACE_DNS, "python.org")' {
        Get-XdrArmGuid -Arguments @('python.org') -Namespace '6ba7b810-9dad-11d1-80b4-00c04fd430c8' |
            Should -BeExactly '886313e1-3b8a-5372-9b90-0c9aee199e5d'
    }
    It 'matches uuid5(NAMESPACE_URL, "http://python.org/")' {
        Get-XdrArmGuid -Arguments @('http://python.org/') -Namespace '6ba7b811-9dad-11d1-80b4-00c04fd430c8' |
            Should -BeExactly '4c565f0d-3f5a-5890-b41b-20cf47701c5e'
    }
    It 'always sets the version nibble to 5 and the RFC-4122 variant (8/9/a/b)' {
        $g = Get-XdrArmGuid -Arguments @('anything', 'goes', 'here')
        $g[14] | Should -BeExactly '5' -Because 'the 13th hex digit (group 3 lead) is the version'
        $g[19] | Should -Match '^[89ab]$' -Because 'the 17th hex digit (group 4 lead) is the variant'
    }
}

Describe 'Get-XdrArmGuid · ARM `guid()` parity (fixed namespace + hyphen-join semantics)' {
    It 'defaults to the ARM/Bicep fixed namespace 11fb06fb-712d-4ddd-98c7-e71bbd588830' {
        # The default (no -Namespace) MUST equal an explicit pass of the ARM namespace.
        $implicit = Get-XdrArmGuid -Arguments @('x', 'y')
        $explicit = Get-XdrArmGuid -Arguments @('x', 'y') -Namespace '11fb06fb-712d-4ddd-98c7-e71bbd588830'
        $implicit | Should -BeExactly $explicit
    }
    It 'joins arguments with a HYPHEN · guid("a","b") != guid("ab") (delimiter is load-bearing)' {
        (Get-XdrArmGuid -Arguments @('a', 'b')) | Should -Not -BeExactly (Get-XdrArmGuid -Arguments @('ab'))
    }
    It 'guid("a","b","c") == guid("a-b-c") (the hyphen-join IS the single-arg form of the joined string)' {
        (Get-XdrArmGuid -Arguments @('a', 'b', 'c')) | Should -BeExactly (Get-XdrArmGuid -Arguments @('a-b-c'))
    }
    It 'is deterministic / idempotent (same args → byte-identical value)' {
        $a = Get-XdrArmGuid -Arguments @('/subscriptions/s/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/xdrlr-dcr-operations-zocqir', '00000000-0000-0000-0000-000000000001', 'MMP-DCR-operations')
        $b = Get-XdrArmGuid -Arguments @('/subscriptions/s/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/xdrlr-dcr-operations-zocqir', '00000000-0000-0000-0000-000000000001', 'MMP-DCR-operations')
        $a | Should -BeExactly $b
    }
    It 'returns a syntactically valid lowercase GUID' {
        $g = Get-XdrArmGuid -Arguments @('a')
        $g | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        [guid]::TryParse($g, [ref]([guid]::Empty)) | Should -BeTrue
    }
}
