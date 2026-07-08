#Requires -Version 7.4
# Φ4.G2c (emit side) · the postdeploy auth/reauth gate must distinguish a headless Passkey T3 from a TOTP T3 live.
# The AuthMethod (Passkey | CredentialsTotp) is the discriminator. T3.Started already carried it; T3.Succeeded did
# NOT — so "a Passkey auth SUCCEEDED" could not be proven, only "a Passkey auth was attempted". This pins BOTH the
# Started and Succeeded T3 events to carry AuthMethod. RED pre-fix (T3.Succeeded lacked AuthMethod).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:mod = Join-Path $script:repo 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psm1'
    $script:lines = Get-Content $script:mod
}

Describe 'Φ4.G2c · Defender T3 auth events carry AuthMethod (Passkey vs TOTP discriminator)' {
    It 'parses with no errors' {
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:mod, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'Defender.Auth.T3.Started emits AuthMethod' {
        $line = $script:lines | Where-Object { $_ -match "Defender\.Auth\.T3\.Started'" } | Select-Object -First 1
        $line | Should -Not -BeNullOrEmpty
        $line | Should -Match 'AuthMethod\s*='
    }
    It 'Defender.Auth.T3.Succeeded emits AuthMethod (so a live Passkey SUCCESS is provable, not just attempted)' {
        $line = $script:lines | Where-Object { $_ -match "Defender\.Auth\.T3\.Succeeded'" } | Select-Object -First 1
        $line | Should -Not -BeNullOrEmpty
        $line | Should -Match 'AuthMethod\s*='
    }
}
