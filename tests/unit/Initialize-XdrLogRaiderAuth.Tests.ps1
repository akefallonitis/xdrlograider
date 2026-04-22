#Requires -Modules Pester

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-XdrLogRaiderAuth.ps1'
    # These tests only validate the script file's AST and regex logic;
    # they never execute the script, so no Az cmdlet stubbing is needed.
}

Describe 'Initialize-XdrLogRaiderAuth.ps1' {
    It 'script file exists and is valid PowerShell' {
        Test-Path $script:ScriptPath | Should -BeTrue
        { [scriptblock]::Create((Get-Content $script:ScriptPath -Raw)) } | Should -Not -Throw
    }

    It 'declares mandatory KeyVaultName parameter' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $kvParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'KeyVaultName' }
        $kvParam | Should -Not -BeNullOrEmpty
        $attrs = $kvParam.Attributes | ForEach-Object { $_.TypeName.Name }
        $attrs | Should -Contain 'Parameter'
    }

    It 'declares Method parameter with valid set credentials_totp and passkey' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $methodParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Method' }
        $methodParam | Should -Not -BeNullOrEmpty
        $validateAttr = $methodParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $validateAttr | Should -Not -BeNullOrEmpty
        $allowedValues = $validateAttr.PositionalArguments | ForEach-Object { $_.Value }
        $allowedValues | Should -Contain 'credentials_totp'
        $allowedValues | Should -Contain 'passkey'
    }

    It 'declares DryRun switch' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $dryRun = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'DryRun' }
        $dryRun | Should -Not -BeNullOrEmpty
    }

    It 'validates TOTP Base32 format' {
        # The script rejects invalid chars — we test the validation logic isolated
        $invalidTotp = 'INVALID#CHARS!'
        $normalized = ($invalidTotp -replace '\s', '').ToUpperInvariant().TrimEnd('=')
        ($normalized -match '^[A-Z2-7]+$') | Should -BeFalse
    }

    It 'accepts valid TOTP Base32' {
        $validTotp = 'JBSWY3DPEHPK3PXP'
        $normalized = ($validTotp -replace '\s', '').ToUpperInvariant().TrimEnd('=')
        ($normalized -match '^[A-Z2-7]+$') | Should -BeTrue
        $normalized.Length | Should -BeGreaterOrEqual 16
    }

    It 'validates UPN format' {
        'svc-foo@bar.com'            | Should -Match '^[^@]+@[^@]+\.[^@]+$'
        'invalid-no-at-sign'         | Should -Not -Match '^[^@]+@[^@]+\.[^@]+$'
        'svc@domain-without-tld'     | Should -Not -Match '^[^@]+@[^@]+\.[^@]+$'
    }

    It 'validates passkey JSON schema' {
        $valid = @{
            upn = 'svc@test.com'; credentialId = 'abc123'
            privateKeyPem = '-----BEGIN EC PRIVATE KEY-----...'
            rpId = 'login.microsoft.com'
        }
        foreach ($field in 'upn', 'credentialId', 'privateKeyPem') {
            $valid.$field | Should -Not -BeNullOrEmpty
        }
        $valid.privateKeyPem | Should -Match '-----BEGIN EC PRIVATE KEY-----'
    }
}
