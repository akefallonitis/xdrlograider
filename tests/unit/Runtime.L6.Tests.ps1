#Requires -Module Pester
# Phase 0l L6 runtime · P-1 facade + P-2 projection + P-3 discovery + P-4 storage table + P-5 heartbeat enhance.
# Tests verify offline contracts only (no live HTTP); operator probe at Phase 0g validates end-to-end.

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Auth\Xdr.Auth.psd1')      -Force
    Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Parser\Xdr.Parser.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Poll\Xdr.Poll.psd1')      -Force
    Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Ingest\Xdr.Ingest.psd1')  -Force
    $script:pollPsm1 = Get-Content -Raw (Join-Path $script:repoRoot 'src\Modules\Xdr.Poll\Xdr.Poll.psm1')
    $script:ingestPsm1 = Get-Content -Raw (Join-Path $script:repoRoot 'src\Modules\Xdr.Ingest\Xdr.Ingest.psm1')
}

Describe 'P-2 · Xdr.Parser · Apply-XdrProjectionMap (Reinforcement-A typed DSL)' -Tag 'l6-runtime' {

    It 'is exported from Xdr.Parser' {
        Get-Command -Module Xdr.Parser -Name 'Apply-XdrProjectionMap' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It '$tostring: cast resolves nested path' {
        $resp = @{ Results = @(@{ ActionId = 42 }, @{ ActionId = 43 }) }
        $map  = @{ Ids = '$tostring:Results[].ActionId' }
        $out  = Apply-XdrProjectionMap -Response $resp -ProjectionMap $map
        $out.Ids | Should -Be @('42','43')
    }

    It '$tolong: + $todatetime: + $tojson: typed casts' {
        $resp = @{ Count = '17'; StartTime = '2026-05-17T12:00:00Z'; Blob = @{ k = 'v' } }
        $map  = @{ Count = '$tolong:Count'; StartUtc = '$todatetime:StartTime'; BlobJson = '$tojson:Blob' }
        $out  = Apply-XdrProjectionMap -Response $resp -ProjectionMap $map
        $out.Count    | Should -Be 17
        $out.StartUtc | Should -Match '^2026-05-17T'
        $out.BlobJson | Should -Match '"k":"v"'
    }

    It 'returns plain literal when DSL prefix absent' {
        $resp = @{ Foo = 'bar' }
        $map  = @{ Constant = 'literal-value' }
        (Apply-XdrProjectionMap -Response $resp -ProjectionMap $map).Constant | Should -Be 'literal-value'
    }
}

Describe 'P-1 · Test-AuthChainHtmlResponse stage-aware classifier (Reinforcement-B)' -Tag 'l6-runtime' {

    It 'expected: HTML at auth-chain stages (Authorize/CredentialPost/KmsiInterrupt/FormPost)' {
        foreach ($stage in 'Authorize','CredentialPost','KmsiInterrupt','FormPost') {
            (Test-AuthChainHtmlResponse -Stage $stage -ContentSnippet '<!DOCTYPE html><html>...') | Should -Be 'expected'
        }
    }

    It 'broken: HTML at data stages (PortalRequest/TenantContext/Apiproxy/OAuthToken/BearerPortalApi)' {
        foreach ($stage in 'PortalRequest','TenantContext','Apiproxy','OAuthToken','BearerPortalApi') {
            (Test-AuthChainHtmlResponse -Stage $stage -ContentSnippet '<!DOCTYPE html><html>...') | Should -Be 'broken'
        }
    }

    It 'not-html: any stage receiving JSON returns not-html' {
        (Test-AuthChainHtmlResponse -Stage 'PortalRequest' -ContentSnippet '{"foo":"bar"}') | Should -Be 'not-html'
    }
}

Describe 'P-1 · AuthChainBrokenException class · defined in Xdr.Poll module' -Tag 'l6-runtime' {

    It 'class definition present in Xdr.Poll psm1 source (verified by regex)' {
        # PowerShell module classes are scope-isolated · cannot be accessed via [type] from outside the module.
        # Verification = source presence + Invoke-XdrPortalRequest throws it on broken HTML at data stages.
        $script:pollPsm1 | Should -Match 'class\s+AuthChainBrokenException\s*:\s*System\.Exception'
        $script:pollPsm1 | Should -Match '\[string\]\$Stage'
        $script:pollPsm1 | Should -Match '\[int\]\$StatusCode'
    }
}

Describe 'P-1 · Invoke-XdrPortalRequest facade exported' -Tag 'l6-runtime' {

    It 'is exported from Xdr.Poll' {
        Get-Command -Module Xdr.Poll -Name 'Invoke-XdrPortalRequest' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'declares PortalConfigEntry + Path + Method + Session + Headers params' {
        $cmd = Get-Command Invoke-XdrPortalRequest
        $cmd.Parameters.Keys | Should -Contain 'PortalConfigEntry'
        $cmd.Parameters.Keys | Should -Contain 'Path'
        $cmd.Parameters.Keys | Should -Contain 'Method'
        $cmd.Parameters.Keys | Should -Contain 'Session'
        $cmd.Parameters.Keys | Should -Contain 'Headers'
    }
}

Describe 'P-3 · Discover-XdrPortalCapabilities + cache behavior (Reinforcement-C)' -Tag 'l6-runtime' {

    BeforeEach {
        Clear-XdrCapabilityCache
    }

    It 'is exported from Xdr.Poll' {
        Get-Command -Module Xdr.Poll -Name 'Discover-XdrPortalCapabilities' | Should -Not -BeNullOrEmpty
    }

    It 'returns snapshot keyed by TenantId with TTL window' {
        $snap = Discover-XdrPortalCapabilities -TenantId 'tenant-A'
        $snap.TenantId | Should -Be 'tenant-A'
        $snap.ExpiresUtc | Should -BeOfType ([datetime])
        ($snap.ExpiresUtc - $snap.CapturedUtc).TotalHours | Should -BeGreaterOrEqual 23
    }

    It 'cache hit returns same snapshot within TTL' {
        $first  = Discover-XdrPortalCapabilities -TenantId 'tenant-B'
        $second = Discover-XdrPortalCapabilities -TenantId 'tenant-B'
        $first.CapturedUtc | Should -Be $second.CapturedUtc
    }

    It '-Force rebuilds snapshot' {
        $first  = Discover-XdrPortalCapabilities -TenantId 'tenant-C'
        Start-Sleep -Milliseconds 10
        $second = Discover-XdrPortalCapabilities -TenantId 'tenant-C' -Force
        $second.CapturedUtc | Should -BeGreaterThan $first.CapturedUtc
    }
}

Describe 'P-3 · Test-XdrEndpointAllowedByCapabilities (RequiresProducts filter)' -Tag 'l6-runtime' {

    It 'returns $true when entry has no RequiresProducts (default allow)' {
        $entry = @{ Slug = 'foo'; RequiresProducts = @() }
        $snap  = @{ Portals = @{ } }
        Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $snap | Should -BeTrue
    }

    It 'returns $true when at least one required product is in snapshot' {
        $entry = @{ Slug = 'foo'; RequiresProducts = @('IsMdatpActive','IsMdiActive') }
        $snap  = @{ Portals = @{ 'Defender::' = @{ ProductsAvailable = @('IsMdatpActive','IsXspmActive') } } }
        Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $snap | Should -BeTrue
    }

    It 'v0.1.0 BYPASS · returns $true even when no required product in snapshot (v0.2.0 will restore $false)' {
        # Π11 · Test-XdrEndpointAllowedByCapabilities is BYPASSED (returns true unconditionally)
        # because Discover-XdrPortalCapabilities is currently a stub returning ProductsAvailable=@().
        # Real R-C implementation deferred to v0.2.0 · API will reject license-blocked endpoints
        # naturally with 401/403/404 at runtime.
        $entry = @{ Slug = 'foo'; RequiresProducts = @('IsMdiActive') }
        $snap  = @{ Portals = @{ 'Defender::' = @{ ProductsAvailable = @('IsMdatpActive') } } }
        Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $snap | Should -BeTrue
    }
}

Describe 'P-4 · Invoke-XdrStorageTableEntity exported (cherry-pick from v3)' -Tag 'l6-runtime' {

    It 'is exported from Xdr.Ingest' {
        Get-Command -Module Xdr.Ingest -Name 'Invoke-XdrStorageTableEntity' | Should -Not -BeNullOrEmpty
    }

    It 'declares 5 verbs (INSERT/UPDATE/GET/QUERY/DELETE) via ValidateSet' {
        $cmd = Get-Command Invoke-XdrStorageTableEntity
        $validate = $cmd.Parameters['Verb'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validate.ValidValues | Should -Contain 'INSERT'
        $validate.ValidValues | Should -Contain 'UPDATE'
        $validate.ValidValues | Should -Contain 'GET'
        $validate.ValidValues | Should -Contain 'QUERY'
        $validate.ValidValues | Should -Contain 'DELETE'
    }

    It 'declares StorageAccount + Table + Verb + PartitionKey + RowKey + Entity + Filter + BearerToken' {
        $cmd = Get-Command Invoke-XdrStorageTableEntity
        $cmd.Parameters.Keys | Should -Contain 'StorageAccount'
        $cmd.Parameters.Keys | Should -Contain 'Table'
        $cmd.Parameters.Keys | Should -Contain 'PartitionKey'
        $cmd.Parameters.Keys | Should -Contain 'BearerToken'
    }
}

Describe 'P-5 · Write-Heartbeat enhanced schema (Reinforcement-B/C columns)' -Tag 'l6-runtime' {

    It 'declares Reinforcement-B/C parameters (ReauthCount + SkippedThisCycle + Capabilities + Portal + Status enum)' {
        $cmd = Get-Command Write-Heartbeat
        $cmd.Parameters.Keys | Should -Contain 'ReauthCount'
        $cmd.Parameters.Keys | Should -Contain 'SkippedThisCycle'
        $cmd.Parameters.Keys | Should -Contain 'Capabilities'
        $cmd.Parameters.Keys | Should -Contain 'Portal'
        $cmd.Parameters.Keys | Should -Contain 'StreamName'
        # Status enum check (5 values · LOCKED at v0.1.0)
        $validate = $cmd.Parameters['Status'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validate.ValidValues | Should -Contain 'OK'
        $validate.ValidValues | Should -Contain 'AuthFatal'
        $validate.ValidValues | Should -Contain 'Error'
        $validate.ValidValues | Should -Contain 'Degraded'
        $validate.ValidValues | Should -Contain 'Capability'
    }

    It 'StreamName defaults to Custom-XdrConnectorHealth_CL (verified via psm1 regex · AST default extraction unreliable)' {
        $script:ingestPsm1 | Should -Match '\[string\]\$StreamName\s*=\s*''Custom-XdrConnectorHealth_CL'''
    }
}
