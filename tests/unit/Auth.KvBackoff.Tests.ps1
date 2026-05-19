#Requires -Module Pester
# Π11.C2 · KV exponential backoff with jitter · 3 attempts · 250ms · 1s · 4s ± 50ms.
# Without backoff: first 429 (KV throttle at 2000 ops/10s) trips auth-failure circuit → cascade.
# With backoff: most transient throttles absorbed silently · only persistent failure trips circuit.
# KV.RetryAttempt telemetry per retry · KV.FetchFailed only on final exhaustion.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force

    # Per-test attempt counter · controls when the mock returns success vs. throws transient
    $script:AttemptsBySecret = @{}
    $script:FailUntilAttempt = @{}   # secret name → attempt index at which it succeeds

    Mock -ModuleName Xdr.Auth Import-Module {}
    Mock -ModuleName Xdr.Auth Get-AzKeyVaultSecret {
        param($VaultName, $Name, $AsPlainText, $ErrorAction)
        if (-not $script:AttemptsBySecret.ContainsKey($Name)) { $script:AttemptsBySecret[$Name] = 0 }
        $script:AttemptsBySecret[$Name]++
        $threshold = if ($script:FailUntilAttempt.ContainsKey($Name)) { [int]$script:FailUntilAttempt[$Name] } else { 0 }
        if ($script:AttemptsBySecret[$Name] -le $threshold) {
            throw [System.Net.WebException]::new("KV throttle: 429 TooManyRequests on '$Name'")
        }
        switch -Regex ($Name) {
            'upn$'         { return 'sa@test.local' }
            'password$'    { return 'pass' }
            'totp$'        { return 'JBSWY3DPEHPK3PXP' }
            default        { return $null }
        }
    }
}

Describe 'Π11.C2 · KV exponential backoff' -Tag 'tier1','unit' {

    BeforeEach {
        Clear-XdrCredentialCache
        $script:AttemptsBySecret = @{}
        $script:FailUntilAttempt = @{}
    }

    It 'absorbs 1 transient 429 then succeeds on attempt 2 (no exception bubbles)' {
        # upn fails on attempt 1, succeeds on attempt 2. Total reads = 2.
        $script:FailUntilAttempt['defender-upn'] = 1
        { Get-XdrAuthFromKeyVault -KeyVaultName 'kv-test' } | Should -Not -Throw
        $script:AttemptsBySecret['defender-upn'] | Should -BeGreaterOrEqual 2
    }

    It 'absorbs 2 consecutive 429s then succeeds on attempt 3' {
        $script:FailUntilAttempt['defender-upn']      = 2
        $script:FailUntilAttempt['defender-password'] = 2
        $script:FailUntilAttempt['defender-totp']     = 2
        { Get-XdrAuthFromKeyVault -KeyVaultName 'kv-test' } | Should -Not -Throw
        $script:AttemptsBySecret['defender-upn']      | Should -Be 3
        $script:AttemptsBySecret['defender-password'] | Should -Be 3
        $script:AttemptsBySecret['defender-totp']     | Should -Be 3
    }

    It 'throws on persistent 429 after exhausting 3 attempts' {
        # Always throw → 3 attempts → final throw bubbles
        $script:FailUntilAttempt['defender-upn'] = 99
        { Get-XdrAuthFromKeyVault -KeyVaultName 'kv-test' } | Should -Throw
        $script:AttemptsBySecret['defender-upn'] | Should -Be 3
    }

    It 'returns $null for optional secrets when missing (no throw · no retry storm)' {
        # auth-method + passkey-pem are -Optional · default to $null without retries
        # mandatory secrets (upn/password/totp) succeed first try
        { $bundle = Get-XdrAuthFromKeyVault -KeyVaultName 'kv-test'; $bundle } | Should -Not -Throw
        $bundle = Get-XdrAuthFromKeyVault -KeyVaultName 'kv-test'
        $bundle.AuthMethod | Should -Be 'CredentialsTotp'
        $bundle.Passkey    | Should -BeNullOrEmpty
    }

    It 'non-transient errors (auth denied) propagate immediately (no retry)' {
        # Mock throw non-429 error → should NOT retry · single attempt then bubble
        Mock -ModuleName Xdr.Auth Get-AzKeyVaultSecret {
            param($VaultName, $Name, $AsPlainText, $ErrorAction)
            if (-not $script:AttemptsBySecret.ContainsKey($Name)) { $script:AttemptsBySecret[$Name] = 0 }
            $script:AttemptsBySecret[$Name]++
            throw "Forbidden: caller lacks Key Vault Secrets User role"
        }
        { Get-XdrAuthFromKeyVault -KeyVaultName 'kv-test' } | Should -Throw '*Forbidden*'
        $script:AttemptsBySecret['defender-upn'] | Should -Be 1
    }
}
