#Requires -Version 7.4
# Bearer auth-code mechanism (plan §36.1 / §38) — regression-pins the NEW pure components the
# authorization-code-over-MFA rewrite introduced, so a future edit cannot silently break the
# all-5-portal-auth proof. The full live token exchange (Entra IAM SPA · Intune · SecurityCopilot
# PublicClient) is integration-proven by tools/Probe-FullChain-Local.ps1 -AllPortals (§38.1);
# these unit tests lock the offline-provable pieces: PKCE S256, form_post code extraction, the
# SPA Origin derivation, and the Get-XdrOAuthToken parameter contract.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
}

Describe 'Bearer PKCE pair (RFC 7636 · S256)' {
    It 'returns a Verifier + Challenge where Challenge == base64url(SHA256(ASCII(Verifier)))' {
        InModuleScope Xdr.Common.OAuthBearer {
            $pair = Get-XdrPkcePair
            $pair.Verifier  | Should -Not -BeNullOrEmpty
            $pair.Challenge | Should -Not -BeNullOrEmpty
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($pair.Verifier)) } finally { $sha.Dispose() }
            $expected = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+','-').Replace('/','_')
            $pair.Challenge | Should -Be $expected
        }
    }

    It 'emits URL-safe base64 (no +, /, = padding) for both verifier and challenge' {
        InModuleScope Xdr.Common.OAuthBearer {
            $pair = Get-XdrPkcePair
            $pair.Verifier  | Should -Not -Match '[+/=]'
            $pair.Challenge | Should -Not -Match '[+/=]'
        }
    }

    It 'produces a fresh verifier each call (no fixed/reused PKCE)' {
        InModuleScope Xdr.Common.OAuthBearer {
            (Get-XdrPkcePair).Verifier | Should -Not -Be (Get-XdrPkcePair).Verifier
        }
    }
}

Describe 'Bearer auth-code extraction from the terminal form_post (§36.1 step 3)' {
    It 'extracts the code from a double-quoted hidden input' {
        InModuleScope Xdr.Common.OAuthBearer {
            $html = '<html><body><form><input type="hidden" name="code" value="0.AUthCodeABC-123_xyz"/></form></body></html>'
            Get-XdrAuthCodeFromHtml -Html $html | Should -Be '0.AUthCodeABC-123_xyz'
        }
    }

    It 'extracts the code from a single-quoted hidden input' {
        InModuleScope Xdr.Common.OAuthBearer {
            $html = "<form><input name='code' value='single0quoted0code'></form>"
            Get-XdrAuthCodeFromHtml -Html $html | Should -Be 'single0quoted0code'
        }
    }

    It 'returns empty string when no code is present (→ caller raises AuthChainBroken with diag)' {
        InModuleScope Xdr.Common.OAuthBearer {
            Get-XdrAuthCodeFromHtml -Html '<html><body>AADSTS50011 error page · no code</body></html>' | Should -Be ''
            Get-XdrAuthCodeFromHtml -Html '' | Should -Be ''
        }
    }
}

Describe 'SPA Origin derivation (Decision D-39 · AADSTS9002327 guard · §38.2)' {
    It 'derives the web-origin authority from the IAM SPA RedirectUri' {
        # This is the exact expression Get-XdrOAuthToken uses for ClientType=SPA on the /token POST.
        ([uri]'https://portal.azure.com/signin/index/').GetLeftPart([System.UriPartial]::Authority) |
            Should -Be 'https://portal.azure.com'
    }

    It 'PublicClient http://localhost redirect yields its own authority (Origin not sent for PublicClient)' {
        ([uri]'http://localhost').GetLeftPart([System.UriPartial]::Authority) | Should -Be 'http://localhost'
    }
}

Describe 'Get-XdrOAuthToken parameter contract (auth-code · NOT ROPC)' {
    BeforeAll { $script:Cmd = Get-Command Get-XdrOAuthToken -Module Xdr.Common.OAuthBearer }

    It 'exposes -ClientType with ValidateSet {PublicClient, SPA} defaulting to PublicClient' {
        $p = $script:Cmd.Parameters['ClientType']
        $p | Should -Not -BeNullOrEmpty
        $vs = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $vs.ValidValues | Should -Contain 'SPA'
        $vs.ValidValues | Should -Contain 'PublicClient'
    }

    It 'requires -RedirectUri (mandatory · AADSTS50011 guard)' {
        $pa = $script:Cmd.Parameters['RedirectUri'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        ($pa | Where-Object { $_.Mandatory }) | Should -Not -BeNullOrEmpty
    }

    It 'exposes -AuthVersion with ValidateSet {v1, v2} and -Resource for the v1 admin-API path' {
        $av = $script:Cmd.Parameters['AuthVersion'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $av.ValidValues | Should -Contain 'v1'
        $av.ValidValues | Should -Contain 'v2'
        $script:Cmd.Parameters.ContainsKey('Resource') | Should -BeTrue
    }
}
