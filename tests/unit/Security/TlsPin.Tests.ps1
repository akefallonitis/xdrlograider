#Requires -Version 7.4
# Φ4 · outbound TLS-1.2+ pinned CODE-SIDE (§3) — COVERAGE GATE (recurrence-proof · NOT per-site). Enumerates EVERY
# outbound HTTP call in src/ (Invoke-WebRequest · Invoke-RestMethod) via AST and asserts each is either PINNED to TLS
# 1.2/1.3 in its enclosing function, OR is the whitelisted INTERNAL App Service MSI-token call (X-IDENTITY-HEADER · the
# local identity sidecar · HTTP localhost · TLS-moot). Plus the HttpClient path (OAuthBearer · SocketsHttpHandler).
# The per-site predecessor PASSED while 5 real outbound paths (DCE · Storage · Telemetry · KV-secrets · boot-AI) were
# unpinned — this enumerating gate catches all of them. RED if ANY public outbound call lacks a pin. Enum values valid.

BeforeAll {
    $script:repo      = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:srcFiles  = Get-ChildItem (Join-Path $script:repo 'src') -Recurse -File -Include *.psm1, *.ps1
    $script:msiMarker = 'X-IDENTITY-HEADER'   # the App Service managed-identity token endpoint · internal · TLS-moot

    function Get-XdrOutboundCalls {
        param([string]$Path)
        $perr = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$perr)
        if ($perr) { return @() }
        $cmds = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -in @('Invoke-WebRequest', 'Invoke-RestMethod')
            }, $true)
        foreach ($c in $cmds) {
            $fn = $c
            while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
            $scope = if ($fn) { $fn.Extent.Text } else { $ast.Extent.Text }
            [pscustomobject]@{
                File   = Split-Path $Path -Leaf; Line = $c.Extent.StartLineNumber
                Pinned = [bool]($scope -match 'SslProtocol|EnabledSslProtocols')
                Msi    = [bool]($scope -match [regex]::Escape($script:msiMarker))
            }
        }
    }
}

Describe 'Φ4 · outbound TLS coverage gate (§3 · every src/ outbound call pinned-or-MSI)' {
    It 'enumerates outbound calls (sanity · the AST scan actually finds them)' {
        $all = @(foreach ($f in $script:srcFiles) { Get-XdrOutboundCalls -Path $f.FullName })
        $all.Count | Should -BeGreaterThan 5
    }
    It 'EVERY Invoke-WebRequest / Invoke-RestMethod in src/ pins TLS 1.2+ (or is the whitelisted MSI-token call)' {
        $all = @(foreach ($f in $script:srcFiles) { Get-XdrOutboundCalls -Path $f.FullName })
        $unpinned = @($all | Where-Object { -not $_.Pinned -and -not $_.Msi })
        $msg = ($unpinned | ForEach-Object { "$($_.File):$($_.Line)" }) -join ' · '
        $unpinned.Count | Should -Be 0 -Because "unpinned public outbound call(s): $msg"
    }
    It 'the HttpClient outbound path (OAuthBearer token POST) pins via SocketsHttpHandler + the handler ctor' {
        $bearer = Get-Content "$script:repo\src\Modules\Xdr.Common.OAuthBearer\Xdr.Common.OAuthBearer.psm1" -Raw
        $bearer | Should -Match 'SocketsHttpHandler'
        $bearer | Should -Match "EnabledSslProtocols\s*=\s*\[System\.Security\.Authentication\.SslProtocols\]'Tls12, Tls13'"
        $bearer | Should -Match '\[System\.Net\.Http\.HttpClient\]::new\(\$tlsHandler\)'
    }
    It 'the pinned enum values are VALID (cast without error · catches a protocol typo)' {
        { [Microsoft.PowerShell.Commands.WebSslProtocol]'Tls12, Tls13' } | Should -Not -Throw
        { [System.Security.Authentication.SslProtocols]'Tls12, Tls13' } | Should -Not -Throw
    }
}
