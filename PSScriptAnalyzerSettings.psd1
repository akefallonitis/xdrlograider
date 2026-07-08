@{
    # PSScriptAnalyzer configuration · invoked by ci.yml L1 step + Run-PrePushGauntlet axis 15.
    #
    # Severity floor: Warning. Errors fail CI; Warnings are reported but don't block (kept tight
    # via IncludeRules + CustomRulePath rather than via raising every Warning to Error globally).
    Severity      = @('Error','Warning')
    IncludeDefaultRules = $true

    # Exclude rules that conflict with our explicit design:
    #   - PSAvoidUsingWriteHost: we use Write-Host intentionally for FA host logs (visible in App Service Log Stream).
    #   - PSAvoidUsingConvertToSecureStringWithPlainText: known noise rule. The only call site is
    #     Probe-DefenderAuth-Local.ps1 (a local-only operator probe) where the canonical
    #     `env-var → SecureString → Connect-AzAccount -ServicePrincipal` pattern is required. The
    #     secret is in process memory from .env.local (gitignored) before this line; SecureString
    #     wrapping limits SDK-call lifetime, not initial entry.
    ExcludeRules  = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )

    # Custom rule path: enforce the `-isnot [string]` guard at JSON-serialization boundaries.
    # The rule lives in tools/PSScriptAnalyzerRules/ — see XdrTypeCheckBString.psm1 for the
    # check that ConvertTo-Json sites are preceded (within the same scope) by a string-type guard.
    CustomRulePath = @(
        'tools/PSScriptAnalyzerRules'
    )
    RecurseCustomRulePath = $true
}
