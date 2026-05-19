#Requires -Module Pester
# Locks: Resolve-EntraResponse correctly classifies the 6 states.
# Bug class: classifier intermediate-redirect false-positive (prior xdrlograider v2/v3).

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1'
    Import-Module $script:ModulePath -Force
    $script:FixDir = Join-Path $PSScriptRoot '..\fixtures\synthetic\entra'
}

Describe 'Resolve-EntraResponse — fixture-driven classification' {

    It 'classifies AADSTS50080 from BeginAuth body as aadsts-50080' {
        $fx = Get-Content (Join-Path $script:FixDir 'aadsts-50080.json') -Raw | ConvertFrom-Json
        $resp = [pscustomobject]@{ StatusCode = $fx.statusCode; Content = $fx.body }
        $r = Resolve-EntraResponse -Response $resp -ExpectedStage $fx.stage
        $r.Classification | Should -Be $fx.expectedClassification
    }

    It 'classifies AADSTS50196 throttle as throttle-mfa' {
        $fx = Get-Content (Join-Path $script:FixDir 'aadsts-50196.json') -Raw | ConvertFrom-Json
        $resp = [pscustomobject]@{ StatusCode = $fx.statusCode; Content = $fx.body }
        $r = Resolve-EntraResponse -Response $resp -ExpectedStage $fx.stage
        $r.Classification | Should -Be 'throttle-mfa'
    }

    It 'classifies AADSTS50158 EndAuth as aadsts-50158' {
        $fx = Get-Content (Join-Path $script:FixDir 'aadsts-50158.json') -Raw | ConvertFrom-Json
        $resp = [pscustomobject]@{ StatusCode = $fx.statusCode; Content = $fx.body }
        (Resolve-EntraResponse -Response $resp -ExpectedStage $fx.stage).Classification | Should -Be 'aadsts-50158'
    }

    It 'classifies 302+HTML at ProcessAuth as auth-redirect-intermediate (NOT terminal)' {
        # This is the bug class that wasted weeks in prior forks: classifier flagged
        # intermediate auth-chain redirects as fatal html-redirect, causing the agent
        # to exit 1 even when the chain produced a valid session.
        $fx = Get-Content (Join-Path $script:FixDir 'html-intermediate-302.json') -Raw | ConvertFrom-Json
        $resp = [pscustomobject]@{ StatusCode = $fx.statusCode; Content = $fx.body }
        $r = Resolve-EntraResponse -Response $resp -ExpectedStage $fx.stage
        $r.Classification | Should -Be 'auth-redirect-intermediate'
    }

    It 'classifies 200+HTML at ApiproxyCall as html-terminal (auth lost OR missing /apiproxy/ prefix)' {
        $fx = Get-Content (Join-Path $script:FixDir 'html-terminal-200.json') -Raw | ConvertFrom-Json
        $resp = [pscustomobject]@{ StatusCode = $fx.statusCode; Content = $fx.body }
        $r = Resolve-EntraResponse -Response $resp -ExpectedStage $fx.stage
        $r.Classification | Should -Be 'html-terminal'
    }

    It 'returns unknown on null response (no crash)' {
        (Resolve-EntraResponse -Response $null -ExpectedStage 'BeginAuth').Classification | Should -Be 'unknown'
    }

    It 'returns auth-ok on a plain 200 JSON response with no AADSTS markers' {
        $resp = [pscustomobject]@{ StatusCode = 200; Content = '{"Success":true,"FlowToken":"tok"}' }
        (Resolve-EntraResponse -Response $resp -ExpectedStage 'BeginAuth').Classification | Should -Be 'auth-ok'
    }
}
