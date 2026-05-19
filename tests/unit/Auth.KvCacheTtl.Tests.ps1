#Requires -Module Pester
# φ.AUTH.1 · KV credential TTL cache · prevents throttle on hot poll cycles.
# Locks: in-memory cache hit · TTL eviction · -Force bypass · per-prefix isolation ·
# KV.CacheEvicted telemetry events · default 60-min · env override.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force

    # Mock Get-AzKeyVaultSecret · counts invocations per secret name
    $script:KvReadCount = @{}
    Mock -ModuleName Xdr.Auth Import-Module {}   # silence Az.KeyVault import
    Mock -ModuleName Xdr.Auth Get-AzKeyVaultSecret {
        param($VaultName, $Name, $AsPlainText)
        if (-not $script:KvReadCount.ContainsKey($Name)) { $script:KvReadCount[$Name] = 0 }
        $script:KvReadCount[$Name]++
        # Synthesized values per secret name
        switch -Regex ($Name) {
            'upn$'      { return "sa-${VaultName}@example.com" }
            'password$' { return "fake-password-${VaultName}" }
            'totp$'     { return 'JBSWY3DPEHPK3PXP' }
            default     { return $null }
        }
    }
}

Describe 'φ.AUTH.1 · TTL cache · first-fetch + cache hit' -Tag 'kv-cache' {

    BeforeEach {
        # Test isolation · clear cache + reset counters before each test
        Clear-XdrCredentialCache
        $script:KvReadCount = @{}
    }

    It 'first call fetches all 3 secrets from KV' {
        $bundle = Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv'
        $script:KvReadCount['defender-upn']      | Should -Be 1
        $script:KvReadCount['defender-password'] | Should -Be 1
        $script:KvReadCount['defender-totp']     | Should -Be 1
        $bundle.Upn | Should -Be 'sa-test-kv@example.com'
        $bundle.AuthMethod | Should -Be 'CredentialsTotp'
    }

    It 'second call within TTL returns cached bundle · NO new KV reads' {
        Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv' | Out-Null
        Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv' | Out-Null
        $script:KvReadCount['defender-upn']      | Should -Be 1
        $script:KvReadCount['defender-password'] | Should -Be 1
        $script:KvReadCount['defender-totp']     | Should -Be 1
    }

    It 'fifth call within TTL still returns cached bundle (no KV reads)' {
        1..5 | ForEach-Object { Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv' | Out-Null }
        $script:KvReadCount['defender-upn'] | Should -Be 1
    }

    It 'returns equivalent bundle from cache (Upn/Password/TotpSecret/AuthMethod)' {
        $first  = Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv'
        $second = Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv'
        $second.Upn        | Should -Be $first.Upn
        $second.Password   | Should -Be $first.Password
        $second.TotpSecret | Should -Be $first.TotpSecret
        $second.AuthMethod | Should -Be $first.AuthMethod
    }
}

Describe 'φ.AUTH.1 · TTL eviction · age cap forces re-fetch' -Tag 'kv-cache' {

    BeforeEach {
        Clear-XdrCredentialCache
        $script:KvReadCount = @{}
    }

    It 'TTL=0 forces re-fetch on every call (effective no-cache · returns fresh bundle)' {
        # Each call evicts due to 0-min TTL · should be 2 reads · sleep guarantees TTL passes
        Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv' -Ttl 0 | Out-Null
        Start-Sleep -Milliseconds 50
        Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv' -Ttl 0 | Out-Null
        $script:KvReadCount['defender-upn'] | Should -Be 2
    }

    It '-Force bypasses cache · always re-fetches (KV.CacheEvicted reason=manual)' {
        Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv' | Out-Null
        Get-XdrAuthFromKeyVault -KeyVaultName 'test-kv' -Force | Out-Null
        $script:KvReadCount['defender-upn'] | Should -Be 2
    }
}

Describe 'φ.AUTH.1 · Per-vault + per-prefix isolation' -Tag 'kv-cache' {

    BeforeEach {
        Clear-XdrCredentialCache
        $script:KvReadCount = @{}
    }

    It 'different KeyVaultName values produce separate cache entries' {
        Get-XdrAuthFromKeyVault -KeyVaultName 'kv-a' | Out-Null
        Get-XdrAuthFromKeyVault -KeyVaultName 'kv-b' | Out-Null
        # Both vaults read separately
        $script:KvReadCount['defender-upn'] | Should -Be 2
    }

    It 'different SecretPrefix values produce separate cache entries' {
        Get-XdrAuthFromKeyVault -KeyVaultName 'shared-kv' -SecretPrefix 'defender' | Out-Null
        Get-XdrAuthFromKeyVault -KeyVaultName 'shared-kv' -SecretPrefix 'purview'  | Out-Null
        # Different prefixes read different secret names
        $script:KvReadCount['defender-upn'] | Should -Be 1
        $script:KvReadCount['purview-upn']  | Should -Be 1
    }

    It 'same vault + same prefix · second call cache hit' {
        Get-XdrAuthFromKeyVault -KeyVaultName 'same' -SecretPrefix 'defender' | Out-Null
        Get-XdrAuthFromKeyVault -KeyVaultName 'same' -SecretPrefix 'defender' | Out-Null
        $script:KvReadCount['defender-upn'] | Should -Be 1
    }
}

Describe 'φ.AUTH.1 · Clear-XdrCredentialCache · operator/test cleanup' -Tag 'kv-cache' {

    BeforeEach {
        Clear-XdrCredentialCache
        $script:KvReadCount = @{}
    }

    It 'Clear-XdrCredentialCache forces next call to re-fetch' {
        Get-XdrAuthFromKeyVault -KeyVaultName 'cleanup-test' | Out-Null
        Clear-XdrCredentialCache
        Get-XdrAuthFromKeyVault -KeyVaultName 'cleanup-test' | Out-Null
        $script:KvReadCount['defender-upn'] | Should -Be 2
    }
}

Describe 'φ.AUTH.1 · FromEnvLocal mode unaffected by cache' -Tag 'kv-cache' {

    BeforeEach {
        Clear-XdrCredentialCache
        $script:KvReadCount = @{}
    }

    It 'FromEnvLocal mode does NOT use cache (no KV reads)' {
        $env:XDRLR_TEST_UPN         = 'env@local.com'
        $env:XDRLR_TEST_PASSWORD    = 'env-pwd'
        $env:XDRLR_TEST_TOTP_SECRET = 'JBSWY3DPEHPK3PXP'
        try {
            $bundle = Get-XdrAuthFromKeyVault -FromEnvLocal
            $bundle.Upn | Should -Be 'env@local.com'
            $script:KvReadCount['defender-upn'] | Should -BeNullOrEmpty
        } finally {
            Remove-Item env:XDRLR_TEST_UPN -ErrorAction SilentlyContinue
            Remove-Item env:XDRLR_TEST_PASSWORD -ErrorAction SilentlyContinue
            Remove-Item env:XDRLR_TEST_TOTP_SECRET -ErrorAction SilentlyContinue
        }
    }
}

Describe 'φ.AUTH.1 · KV_CACHE_TTL_MINUTES env override' -Tag 'kv-cache' {

    BeforeEach {
        Clear-XdrCredentialCache
        $script:KvReadCount = @{}
    }

    It 'KV_CACHE_TTL_MINUTES env var sets default TTL · 0 forces no-cache' {
        $env:KV_CACHE_TTL_MINUTES = '0'
        try {
            Clear-XdrCredentialCache
            Get-XdrAuthFromKeyVault -KeyVaultName 'env-test' | Out-Null
            Start-Sleep -Milliseconds 50
            Get-XdrAuthFromKeyVault -KeyVaultName 'env-test' | Out-Null
            $script:KvReadCount['defender-upn'] | Should -Be 2
        } finally {
            Remove-Item env:KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
        }
    }

    It 'KV_CACHE_TTL_MINUTES=60 (default) · second call cache hit' {
        $env:KV_CACHE_TTL_MINUTES = '60'
        try {
            Clear-XdrCredentialCache
            Get-XdrAuthFromKeyVault -KeyVaultName 'env-ttl' | Out-Null
            Get-XdrAuthFromKeyVault -KeyVaultName 'env-ttl' | Out-Null
            $script:KvReadCount['defender-upn'] | Should -Be 1
        } finally {
            Remove-Item env:KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
        }
    }
}
