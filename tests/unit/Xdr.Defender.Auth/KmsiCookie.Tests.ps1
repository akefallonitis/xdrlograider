#Requires -Version 7.4
# T2-KMSI cookie capture (F2 · §31.4) — the T3 session must persist the ESTSAUTHPERSISTENT value as KmsiCookie
# so the next reauth can silently re-mint sccauth (T2) instead of burning a TOTP (T3).

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
}

Describe 'T2-KMSI cookie capture (F2)' {
    It 'extracts the ESTSAUTHPERSISTENT value from the web session' {
        InModuleScope Xdr.Defender.Auth {
            $ws = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $ws.Cookies.Add([uri]'https://login.microsoftonline.com', [System.Net.Cookie]::new('ESTSAUTHPERSISTENT', 'kmsi-90d-value', '/', '.login.microsoftonline.com'))
            (Get-XdrKmsiCookieValue -WebSession $ws) | Should -Be 'kmsi-90d-value'
        }
    }

    It 'returns empty string when no KMSI cookie is present (→ next reauth falls through to T3)' {
        InModuleScope Xdr.Defender.Auth {
            $ws = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $ws.Cookies.Add([uri]'https://login.microsoftonline.com', [System.Net.Cookie]::new('ESTSAUTH', 'non-persistent', '/', '.login.microsoftonline.com'))
            (Get-XdrKmsiCookieValue -WebSession $ws) | Should -Be ''
        }
    }
}
