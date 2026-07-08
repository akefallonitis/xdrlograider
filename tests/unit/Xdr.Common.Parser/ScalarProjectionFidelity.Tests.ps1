# SB1 (live-found 2026-06-12) · scalar projection fidelity — LA string-column safe.
# The generated typed columns are ALL string. The DCE upload does `$rowList | ConvertTo-Json` (Ingest.psm1:192),
# so a native [bool]/[int]/[double] projected value serializes as a JSON `true`/`1`/`1.5` and Log Analytics
# SILENTLY NULLs it against the string column (live-confirmed: GetTenantContext IsMdatpActive:true → NULL,
# AccountMode:1 → NULL · ~52/76 cols lost). Every projected SCALAR must land as a JSON STRING with source
# fidelity (bool → lowercase 'true'/'false'; numbers → invariant; datetime → ISO-8601; string → unchanged,
# never double-encoded). Non-scalars (array/object) stay JSON-serialized as before.

#Requires -Module Pester

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
}

Describe 'SB1 · scalar projection values land as LA-string-safe strings (no silent null)' {
    BeforeAll {
        # singleObject shaped like a real GetTenantContext: bool flags + an int mode + a string + a nested object.
        $body = '{"IsMdatpActive":true,"IsSuspended":false,"AccountMode":1,"KustoHotStorageInDays":30,"EnvironmentName":"Production","ItpMtpPermissions":{"role":"admin","scope":2}}' | ConvertFrom-Json
        $script:row = (ConvertTo-XdrRows -ResponseBody $body -OperationKey 'GetTenantContext' -Category 'Operations' -ResponseShape 'singleObject' -ProjectionMap @{
            IsMdatpActive       = '$.IsMdatpActive'
            IsSuspended         = '$.IsSuspended'
            AccountMode         = '$.AccountMode'
            KustoHotStorageInDays = '$.KustoHotStorageInDays'
            EnvironmentName     = '$.EnvironmentName'
            ItpMtpPermissionsJson = '$.ItpMtpPermissions'
        })[0]
    }

    It 'boolean true → the STRING "true" (not native [bool] which LA nulls)' {
        $script:row['IsMdatpActive'] | Should -BeOfType [string]
        $script:row['IsMdatpActive'] | Should -BeExactly 'true'
    }
    It 'boolean false → the STRING "false" (false must not be dropped as empty either)' {
        $script:row['IsSuspended'] | Should -BeOfType [string]
        $script:row['IsSuspended'] | Should -BeExactly 'false'
    }
    It 'integer → its invariant string ("1", "30") not a JSON number' {
        $script:row['AccountMode'] | Should -BeOfType [string]
        $script:row['AccountMode'] | Should -BeExactly '1'
        $script:row['KustoHotStorageInDays'] | Should -BeExactly '30'
    }
    It 'string passes through UNCHANGED (B-25 no double-encode)' {
        $script:row['EnvironmentName'] | Should -BeOfType [string]
        $script:row['EnvironmentName'] | Should -BeExactly 'Production'
    }
    It 'nested object → compact JSON string (unchanged non-scalar behaviour)' {
        $script:row['ItpMtpPermissionsJson'] | Should -BeOfType [string]
        $script:row['ItpMtpPermissionsJson'] | Should -Match '"role"\s*:\s*"admin"'
    }
    It 'the WHOLE row JSON-serializes with every typed col as a JSON string (the LA contract)' {
        $json = @{ IsMdatpActive = $script:row['IsMdatpActive']; AccountMode = $script:row['AccountMode'] } | ConvertTo-Json -Compress
        # JSON booleans/numbers would appear bare (true / 1); strings are quoted. Assert quoted.
        $json | Should -Match '"IsMdatpActive"\s*:\s*"true"'
        $json | Should -Match '"AccountMode"\s*:\s*"1"'
    }
}

Describe 'SB1 · datetime fidelity (ISO-8601 string, the format that already lands EventTime)' {
    It 'a DateTime projected value → ISO-8601 round-trip string' {
        $iso = '2026-05-06T01:51:53.7605698Z'
        $body = ([pscustomobject]@{ EventTime = [datetime]::Parse($iso).ToUniversalTime() })
        $row = (ConvertTo-XdrRows -ResponseBody $body -OperationKey 'GetHistory' -Category 'Operations' -ResponseShape 'singleObject' -ProjectionMap @{ EventTime = '$.EventTime' })[0]
        $row['EventTime'] | Should -BeOfType [string]
        $row['EventTime'] | Should -Match '^2026-05-06T01:51:53'
    }
}
