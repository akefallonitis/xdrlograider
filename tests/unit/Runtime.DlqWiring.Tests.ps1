#Requires -Module Pester
# Runtime.DlqWiring.Tests.ps1 · Phase ε.B · HB-2 fix proof
#
# Asserts run.ps1 composes a DLQ scriptblock + passes it to Send-ToDce.
# Without this wiring · terminal 4xx ingest failures are counted but never
# written to XdrIngestDlq Storage Table · operator can't audit dropped rows.

BeforeAll {
    $script:repoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:runScript = Join-Path $script:repoRoot 'src\functions\Xdr-Poll\run.ps1'
    $script:runText   = Get-Content -Raw -LiteralPath $script:runScript
}

Describe 'Runtime.DlqWiring · HB-2 DLQ handler composed + wired' -Tag 'runtime-chain','dlq' {

    It 'run.ps1 reads STORAGE_ACCOUNT_NAME env var (set by mainTemplate.json appSettings)' {
        $script:runText | Should -Match '\$env:STORAGE_ACCOUNT_NAME'
    }

    It 'run.ps1 composes a `$dlqHandler` scriptblock when STORAGE_ACCOUNT_NAME is present' {
        $script:runText | Should -Match '\$dlqHandler\s*='
        $script:runText | Should -Match 'Invoke-XdrStorageTableEntity'
    }

    It 'DLQ handler writes to XdrIngestDlq table (not some other table)' {
        $script:runText | Should -Match "-Table\s+'XdrIngestDlq'"
    }

    It 'DLQ scriptblock takes (Rows · StatusCode · Body) params matching Send-ToDce contract' {
        $script:runText | Should -Match 'param\(\$Rows,\s*\$StatusCode,\s*\$Body\)'
    }

    It 'Send-ToDce call passes -DlqHandler when handler is composed' {
        $script:runText | Should -Match 'DlqHandler\s*=\s*\$dlqHandler'
    }

    It 'DLQ handler captures CorrelationId for traceability' {
        $script:runText | Should -Match 'CorrelationId'
    }

    It 'DLQ handler caps BodySnippet at 8KB (avoid Storage Table 64KB property limit)' {
        $script:runText | Should -Match 'BodySnippet|Substring\(0,\s*\[math\]::Min\(8192'
    }
}

Describe 'Runtime.DlqWiring · mainTemplate.json wires STORAGE_ACCOUNT_NAME appSetting' -Tag 'runtime-chain','dlq' {

    BeforeAll {
        $armPath = Join-Path $script:repoRoot 'deploy\mainTemplate.json'
        $script:Arm = Get-Content -Raw -LiteralPath $armPath | ConvertFrom-Json
    }

    It 'mainTemplate.json appSettings includes STORAGE_ACCOUNT_NAME' {
        $fa = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $appSettings = $fa.properties.siteConfig.appSettings
        $names = @($appSettings | ForEach-Object { $_.name })
        $names | Should -Contain 'STORAGE_ACCOUNT_NAME'
    }

    It 'STORAGE_ACCOUNT_NAME value resolves to variables.storageName' {
        $fa = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $sa = $fa.properties.siteConfig.appSettings | Where-Object { $_.name -eq 'STORAGE_ACCOUNT_NAME' }
        $sa.value | Should -Match "variables\('storageName'\)"
    }
}
