#Requires -Modules Pester
<#
.SYNOPSIS
    profile.ps1 fail-fast contract — env vars + guard.

    1. Every required app-setting env var is referenced (AST check).
    2. Missing-var guard throws at runtime (dot-source simulation).

    Kept AST-centric where possible to avoid dot-sourcing real Az cmdlets.
#>

BeforeDiscovery {
    $ProfilePath = Join-Path $PSScriptRoot '..' '..' 'src' 'profile.ps1'
    # Populate a discovery-phase variable the It -ForEach can read.
    $RequiredEnvVars = @(
        'KEY_VAULT_URI'
        'AUTH_SECRET_NAME'
        'AUTH_METHOD'
        'SERVICE_ACCOUNT_UPN'
        'DCE_ENDPOINT'
        'DCR_IMMUTABLE_ID'
        'STORAGE_ACCOUNT_NAME'
        'CHECKPOINT_TABLE_NAME'
    )
}

BeforeAll {
    $script:ProfilePath = Join-Path $PSScriptRoot '..' '..' 'src' 'profile.ps1'
    $script:RequiredEnvVars = @(
        'KEY_VAULT_URI'
        'AUTH_SECRET_NAME'
        'AUTH_METHOD'
        'SERVICE_ACCOUNT_UPN'
        'DCE_ENDPOINT'
        'DCR_IMMUTABLE_ID'
        'STORAGE_ACCOUNT_NAME'
        'CHECKPOINT_TABLE_NAME'
    )

    $tokens = $null; $parseErrors = $null
    $script:ProfileAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ProfilePath, [ref]$tokens, [ref]$parseErrors
    )
    $script:ProfileParseErrors = $parseErrors
    $script:ProfileText = Get-Content -Raw -Path $script:ProfilePath
}

Describe 'profile.ps1 — parse + env var references' {

    It 'parses without syntax errors' {
        $script:ProfileParseErrors | Should -BeNullOrEmpty
    }

    # Pester 5: -ForEach must receive a value available at discovery time.
    # Using the BeforeDiscovery-level $RequiredEnvVars (same name, no $script:).
    It 'references env var <_>' -ForEach $RequiredEnvVars {
        $varName = $_
        $text = Get-Content -Raw -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'profile.ps1')
        # Match either `$env:FOO` OR `GetEnvironmentVariable('FOO'`) styles
        $hit = ($text -match [regex]::Escape('$env:' + $varName)) -or
               ($text -match "GetEnvironmentVariable\s*\(\s*['""]$varName['""]")
        $hit | Should -BeTrue -Because "profile.ps1 must reference '$varName'"
    }

    It 'contains at least one throw statement guarding missing values' {
        $throws = $script:ProfileAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]
        }, $true)
        $throws | Should -Not -BeNullOrEmpty
    }

    It 'guard message mentions env-var / missing / FATAL concept' {
        $hit = $script:ProfileText -match 'environment variable' -or
               $script:ProfileText -match 'appSettings|app settings' -or
               $script:ProfileText -match 'FATAL' -or
               $script:ProfileText -match 'missing'
        $hit | Should -BeTrue
    }
}

Describe 'profile.ps1 — runtime fail-fast on missing env var' {

    BeforeAll {
        $script:Saved = @{}
        foreach ($name in $script:RequiredEnvVars) {
            $script:Saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        # Stub cmdlets profile.ps1 invokes before the guard.
        function global:Disable-AzContextAutosave { param([string]$Scope) }
        function global:Connect-AzAccount         { param([switch]$Identity, $ErrorAction) }
    }

    AfterAll {
        foreach ($name in $script:Saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:Saved[$name], 'Process')
        }
        Remove-Item function:Disable-AzContextAutosave -ErrorAction SilentlyContinue
        Remove-Item function:Connect-AzAccount         -ErrorAction SilentlyContinue
    }

    It 'dot-sourcing with all required env vars unset raises a terminating error' {
        foreach ($name in $script:RequiredEnvVars) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        [Environment]::SetEnvironmentVariable('MSI_SECRET', $null, 'Process')

        $profilePath = $script:ProfilePath
        # In-process invocation — a fresh scriptblock isolates side-effects
        # (variable pollution, module imports) from our test scope. Much faster
        # than spawning a sub-pwsh (~8s per spawn).
        $err = $null
        try {
            $sb = [scriptblock]::Create(". '$profilePath' *> `$null")
            & $sb
        } catch {
            $err = $_
        }

        $err | Should -Not -BeNullOrEmpty -Because 'profile.ps1 must fail fast when env vars are missing'
        "$($err.Exception.Message)" | Should -Match 'environment variable|missing|FATAL|profile\.ps1' `
            -Because 'thrown message should hint at the cause'
    }

    It 'dot-sourcing with only ONE env var missing also throws' {
        # Populate all but the first.
        foreach ($name in ($script:RequiredEnvVars | Select-Object -Skip 1)) {
            [Environment]::SetEnvironmentVariable($name, "dummy-$name", 'Process')
        }
        [Environment]::SetEnvironmentVariable($script:RequiredEnvVars[0], $null, 'Process')
        [Environment]::SetEnvironmentVariable('MSI_SECRET', $null, 'Process')

        $profilePath = $script:ProfilePath
        $err = $null
        try {
            $sb = [scriptblock]::Create(". '$profilePath' *> `$null")
            & $sb
        } catch {
            $err = $_
        }
        $err | Should -Not -BeNullOrEmpty
    }
}
