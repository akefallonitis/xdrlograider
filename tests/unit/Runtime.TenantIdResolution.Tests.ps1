#Requires -Module Pester
# Runtime.TenantIdResolution.Tests.ps1 · Phase ε.C · HB-3 fix proof
#
# run.ps1 previously defaulted TenantId to literal 'unknown' when
# Connect-DefenderPortal didn't expose it · all cold-starts collided on
# the same capability cache key across operator tenants. This fix:
#
#  1. Connect-DefenderPortal session.TenantId (operator-passed via -TenantId)
#  2. $env:AZURE_TENANT_ID (set by mainTemplate.json appSetting · subscription().tenantId)
#  3. [guid]::Empty fallback (deterministic shape · NOT literal 'unknown')

BeforeAll {
    $script:repoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:runScript = Join-Path $script:repoRoot 'src\functions\Xdr-Poll\run.ps1'
    $script:runText   = Get-Content -Raw -LiteralPath $script:runScript
}

Describe 'Runtime.TenantIdResolution · HB-3 fix in run.ps1' -Tag 'runtime-chain','tenant-id' {

    It 'run.ps1 prefers $portalSession.TenantId (operator-passed scenario)' {
        $script:runText | Should -Match 'portalSession\.PSObject\.Properties\[''TenantId''\].*portalSession\.TenantId'
    }

    It 'run.ps1 falls back to $env:AZURE_TENANT_ID (production runtime)' {
        $script:runText | Should -Match '\$env:AZURE_TENANT_ID'
    }

    It 'run.ps1 final fallback is [guid]::Empty (NOT literal "unknown")' {
        $script:runText | Should -Match '\[guid\]::Empty\.ToString\(\)'
        # Strip comments first · then assert no TenantId assignment uses 'unknown'
        # (a comment explaining "NOT literal 'unknown'" is allowed · ASSIGNMENT is not)
        $codeOnly = ($script:runText -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        @($codeOnly -split '\r?\n' | Where-Object { $_ -match '\$tenantId\s*=.*''unknown''' }).Count | Should -Be 0
    }
}

Describe 'Runtime.TenantIdResolution · mainTemplate.json wires AZURE_TENANT_ID' -Tag 'runtime-chain','tenant-id' {

    BeforeAll {
        $armPath = Join-Path $script:repoRoot 'deploy\mainTemplate.json'
        $script:Arm = Get-Content -Raw -LiteralPath $armPath | ConvertFrom-Json
    }

    It 'mainTemplate.json appSettings includes AZURE_TENANT_ID' {
        $fa = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $names = @($fa.properties.siteConfig.appSettings | ForEach-Object { $_.name })
        $names | Should -Contain 'AZURE_TENANT_ID'
    }

    It 'AZURE_TENANT_ID value resolves to subscription().tenantId' {
        $fa = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $az = $fa.properties.siteConfig.appSettings | Where-Object { $_.name -eq 'AZURE_TENANT_ID' }
        $az.value | Should -Match 'subscription\(\)\.tenantId'
    }
}
