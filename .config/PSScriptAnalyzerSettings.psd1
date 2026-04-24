@{
    # PSScriptAnalyzer settings for XdrLogRaider.
    # Used by CI (ci.yml) and local dev.

    # Rules we explicitly exclude (with reason) — these generate false-positives
    # for the patterns we use intentionally.
    ExcludeRules = @(
        # Helper script uses ConvertTo-SecureString -AsPlainText to upload user-provided
        # secrets to Key Vault — required by the Az.KeyVault API. The plaintext exists
        # only within one loop iteration and is zeroed via Remove-Variable. Documented
        # in Initialize-XdrLogRaiderAuth.ps1.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )

    # Severity: run all rules by default except excluded.
    Severity = @('Error', 'Warning', 'Information')
}
