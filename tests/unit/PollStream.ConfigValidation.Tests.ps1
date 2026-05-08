#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    B1 regression-locker (Plan R+++++++++.2): Xdr-PollStream MUST validate
    config env vars at function entry (before auth chain) and emit AppInsights
    exception with Phase='config-validation' on missing vars. Without this,
    mis-deployed FAs silently fail with connector card stuck Disconnected.

.DESCRIPTION
    Tests the AST shape of src/functions/Xdr-PollStream/run.ps1 — verifies the
    config-validation block exists + checks all 9 required env vars + throws
    before any auth/portal/storage call.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:RunPs1Path = Join-Path $script:RepoRoot 'src/functions/Xdr-PollStream/run.ps1'
    $script:RunPs1Content = Get-Content $script:RunPs1Path -Raw
}

Describe 'Xdr-PollStream config-validation gate (B1 regression-locker)' {

    It 'src/functions/Xdr-PollStream/run.ps1 exists' {
        Test-Path $script:RunPs1Path | Should -BeTrue
    }

    It 'config-validation block exists with Plan R+++++++++.2 reference' {
        $script:RunPs1Content | Should -Match '(?ms)B1 \(Plan R\+\+\+\+\+\+\+\+\+\.2\):.*?config validation' -Because 'B1 fix must be documented inline with plan reference'
    }

    It 'validates all 9 required env vars' {
        # Env var names must appear in the config-validation foreach loop
        foreach ($var in 'KeyVaultUri','AuthSecretName','AuthMethod','DceEndpoint','DcrImmutableIdsJson','StorageAccountName','CheckpointTable','DlqTable','ExpectedTenantId') {
            $script:RunPs1Content | Should -Match "'$var'" -Because "config-validation block must check $var presence"
        }
    }

    It 'throws on missing config (fails fast before auth chain)' {
        # The throw statement must appear AFTER missingConfig accumulation BUT
        # BEFORE the try/catch around Get-XdrAuthFromKeyVault.
        $missingConfigPos = $script:RunPs1Content.IndexOf('$missingConfig = @()')
        $throwPos = $script:RunPs1Content.IndexOf('throw $errMsg')
        $authPos = $script:RunPs1Content.IndexOf('Get-XdrAuthFromKeyVault')

        $missingConfigPos | Should -BeGreaterThan -1 -Because 'config validation block must exist'
        $throwPos | Should -BeGreaterThan $missingConfigPos -Because 'throw must come after accumulation'
        $authPos | Should -BeGreaterThan $throwPos -Because 'throw must precede auth chain (fail-fast pattern)'
    }

    It 'emits AppInsights trace with Phase=config-validation + SeverityLevel=Error' {
        # Send-XdrAppInsightsException requires a real [System.Exception] -Exception param;
        # use Send-XdrAppInsightsTrace -SeverityLevel Error for programmatic config-fail signal.
        $script:RunPs1Content | Should -Match "(?ms)Send-XdrAppInsightsTrace.*?-SeverityLevel\s+'Error'.*?Phase\s*=\s*'config-validation'" -Because 'operator KQL alerts on customDimensions.Phase==config-validation must trigger; emit before throw'
    }

    It 'config-validation block does NOT call portal API or KV before throw' {
        # Extract config-validation block (between $missingConfig = @() and the immediate try { Auth )
        $pattern = '(?ms)\$missingConfig\s*=\s*@\(\)(.*?)try\s*\{\s*\r?\n\s*#\s*Auth'
        $m = [regex]::Match($script:RunPs1Content, $pattern)
        $m.Success | Should -BeTrue -Because 'config-validation block must be located before auth try block'
        $block = $m.Groups[1].Value
        $block | Should -Not -Match 'Invoke-DefenderPortalRequest' -Because 'no portal call before validation passes'
        $block | Should -Not -Match 'Get-XdrAuthFromKeyVault' -Because 'no KV read before validation passes'
        $block | Should -Not -Match 'Send-ToLogAnalytics' -Because 'no DCE call before validation passes'
    }
}
