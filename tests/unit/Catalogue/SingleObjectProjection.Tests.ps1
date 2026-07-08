#Requires -Version 7.4
# Deferred singleObject derivation · Get-XdrResponseItemSchema must FLAG a non-array object schema (singleObject=$true)
# so the Map-stage callers DEFER it to a LAST-RESORT after the postman tier — a real captured postman example must
# outrank an often-inaccurate nodoc singleObject spec. RED on the naive variants: returning $null left every singleObject
# OpenAPI op RawJson-only; returning the object UNFLAGGED made an inaccurate spec WRONGLY override postman (the
# CloudApps.GetSettings Json→scalar + MultiTenant.ListTenants wrong-cols regression, 2026-06-24). The FLAG lets the
# caller keep openapi-ARRAY immediate (unchanged) while deferring openapi-singleObject. Controls below.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    . "$script:repo\dev-tools\lib\Get-XdrBodyShape.ps1"   # Get-XdrSchemaArrayPropertyKey (dep)
    $src = Get-Content "$script:repo\dev-tools\Build-Catalogue.ps1" -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    foreach ($name in @('Resolve-XdrRef', 'Get-XdrResponseItemSchema')) {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn) { throw "$name not found in Build-Catalogue.ps1" }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}

Describe 'deferred singleObject derivation · Get-XdrResponseItemSchema (A-class regression guard)' {
    It 'FLAGS a singleObject schema (singleObject=$true) so the caller defers it to last-resort after postman' {
        $single = @{ type = 'object'; properties = @{ id = @{ type = 'string' }; name = @{ type = 'string' } } }
        $r = Get-XdrResponseItemSchema $single $null ''
        $r | Should -Not -BeNullOrEmpty
        $r.Contains('singleObject') | Should -BeTrue
        $r['singleObject'] | Should -BeTrue
        @($r.node.properties.Keys) | Should -Contain 'id'
    }
    It 'does NOT flag an ARRAY item schema (openapi-array still derives immediately · unchanged)' {
        $arr = @{ type = 'array'; items = @{ type = 'object'; properties = @{ x = @{ type = 'string' } } } }
        $r = Get-XdrResponseItemSchema $arr $null ''
        $r | Should -Not -BeNullOrEmpty
        $r.Contains('singleObject') | Should -BeFalse
        @($r.node.properties.Keys) | Should -Contain 'x'
    }
    It 'returns $null for a STUB object with no properties (stays empty · never fabricates)' {
        Get-XdrResponseItemSchema @{ type = 'object'; description = 'pending' } $null '' | Should -BeNullOrEmpty
    }
}
