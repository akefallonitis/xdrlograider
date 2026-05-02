#Requires -Modules Pester
<#
.SYNOPSIS
    Lock the AUTH_SECRET_NAME ARM env-var value to match the actual KV secret
    naming convention.

.DESCRIPTION
    Live-deploy bug class hit in v0.1.0-beta first-publish:
      AUTH_SECRET_NAME = 'mde-portal-auth'  (legacy single-JSON-blob name)
      Actual KV secrets = 'mde-portal-upn', 'mde-portal-password',
                          'mde-portal-totp', 'mde-portal-auth-method'
                          (per-field secrets per iter-13 refactor)

    Get-XdrAuthFromKeyVault builds names as "$SecretPrefix-upn" etc., so
    when AUTH_SECRET_NAME='mde-portal-auth', it tries to read
    'mde-portal-auth-upn' which doesn't exist. Get-AzKeyVaultSecret returns
    $null (silent), $upnSecret = $null → returned hashtable @{upn=$null;...}
    → Connect-DefenderPortal throws "Credential hashtable must include 'upn'".

    Symptom: every poll-* invocation crashed with that message; Sentinel
    card stayed Disconnected; no per-stream ingestion. Heartbeat-5m kept
    firing because it doesn't auth. Cost: 4+ hours of debugging.

    The fix: AUTH_SECRET_NAME = 'mde-portal' (matches the per-field secret
    prefix). This test locks that invariant against future drift.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:ArmRaw   = Get-Content -LiteralPath $script:ArmPath -Raw
}

Describe 'AuthSecretName.MatchesKvSecretPrefix' {

    It "AUTH_SECRET_NAME ARM env var equals 'mde-portal' (matches per-field KV secret prefix)" {
        # The 4 KV secrets are mde-portal-{upn,password,totp,auth-method}.
        # Get-XdrAuthFromKeyVault concatenates "$SecretPrefix-upn" etc., so
        # the prefix MUST be 'mde-portal' for those names to resolve.
        $script:ArmRaw | Should -Match "'AUTH_SECRET_NAME',\s*'value',\s*'mde-portal'(?!-auth)" -Because (
            "AUTH_SECRET_NAME must equal 'mde-portal' (the KV secret prefix). " +
            "The legacy 'mde-portal-auth' value was a single-JSON-blob secret " +
            "name that became invalid after iter-13 refactored to 4 per-field " +
            "secrets. With the wrong prefix, Get-XdrAuthFromKeyVault builds " +
            "non-existent secret names and returns @{upn=`$null;...}, causing " +
            "Connect-DefenderPortal to throw 'Credential hashtable must include upn'."
        )
    }

    It "AUTH_SECRET_NAME ARM env var is NOT 'mde-portal-auth' (the legacy single-blob name)" {
        $script:ArmRaw | Should -Not -Match "'AUTH_SECRET_NAME',\s*'value',\s*'mde-portal-auth'" -Because (
            'mde-portal-auth was the legacy single-JSON-blob secret name. ' +
            'After iter-13 refactor to per-field secrets, this prefix is invalid. ' +
            "Use 'mde-portal' instead."
        )
    }

    It "ARM template defines all 4 per-field KV secret resources matching SecretPrefix='mde-portal'" {
        # The 4 secrets that Get-XdrAuthFromKeyVault expects under prefix 'mde-portal'.
        foreach ($leaf in 'mde-portal-upn', 'mde-portal-auth-method', 'mde-portal-password', 'mde-portal-totp') {
            $script:ArmRaw | Should -Match "'/$leaf'" -Because (
                "ARM template MUST define a KV secret named '$leaf' (not just $($leaf -replace 'mde-portal', 'mde-portal-auth')) " +
                "because Get-XdrAuthFromKeyVault expects them under the 'mde-portal' prefix."
            )
        }
    }
}
