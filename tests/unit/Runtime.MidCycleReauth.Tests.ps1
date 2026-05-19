#Requires -Module Pester
# φ.AUTH.5 · run.ps1 mid-cycle reauth-on-failure behavior contract.
# Locks: AuthChainBrokenException catch block performs -Force reauth → 1× retry →
# emits Auth.MidCycleReauth.{Succeeded,Failed,RetryOk,RetryFail} telemetry per outcome.
# Prior behavior · catch logged + incremented counter but never actually re-authed.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RunPs1 = Join-Path $script:RepoRoot 'src/functions/Xdr-Poll/run.ps1'
    $script:RunSource = Get-Content -Raw -LiteralPath $script:RunPs1
}

Describe 'φ.AUTH.5 · run.ps1 · catch-block contract' -Tag 'midcycle-reauth' {

    It 'run.ps1 catches AuthChainBrokenException' {
        $script:RunSource | Should -Match 'catch\s*\[AuthChainBrokenException\]'
    }

    It 'catch block calls Connect-DefenderPortal -Force (proper -Force reauth · NOT just log)' {
        # Anywhere in the file · the catch path should re-mint a session via -Force
        $script:RunSource | Should -Match 'Connect-DefenderPortal\s+-Credentials\s+\$creds\s+-Force'
    }

    It 'catch block performs 1× retry via Invoke-DefenderApiproxy AFTER reauth' {
        # The retry should call Invoke-DefenderApiproxy with the same Path (the failed endpoint)
        # AND with the NEW $session from -Force reauth.
        $script:RunSource | Should -Match '(?s)reauthOk\s*=\s*\$true.*?Invoke-DefenderApiproxy\s+-Path\s+\$e\.Path'
    }

    It 'emits Auth.MidCycleReauth.Succeeded on successful reauth' {
        $script:RunSource | Should -Match "Auth\.MidCycleReauth\.Succeeded"
    }

    It 'emits Auth.MidCycleReauth.Failed when reauth itself throws' {
        $script:RunSource | Should -Match "Auth\.MidCycleReauth\.Failed"
    }

    It 'emits Auth.MidCycleReauth.RetryOk on successful retry after reauth' {
        $script:RunSource | Should -Match "Auth\.MidCycleReauth\.RetryOk"
    }

    It 'emits Auth.MidCycleReauth.RetryFail when retry still fails' {
        $script:RunSource | Should -Match "Auth\.MidCycleReauth\.RetryFail"
    }

    It 'reauthCount is incremented after the AuthChainBroken catch block runs' {
        # Cycle stat tracking · the file MUST contain $reauthCount++ wired into the catch path
        $script:RunSource | Should -Match '\$reauthCount\+\+'
    }

    It 'totalFailed is incremented on failure paths · Send-ToDce called on success retry path' {
        # On retry fail OR reauth fail · $totalFailed++ executes (visible in file)
        $script:RunSource | Should -Match '\$totalFailed\+\+'
        # On retry success · Send-ToDce dispatches the retried row
        $script:RunSource | Should -Match 'Send-ToDce'
    }
}

Describe 'φ.AUTH.5 · AuthChainBrokenException class is importable + throws correctly' -Tag 'midcycle-reauth' {

    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Poll/Xdr.Poll.psd1') -Force
    }

    It 'AuthChainBrokenException carries Stage + StatusCode' {
        # The class is defined in Xdr.Poll.psm1 · we instantiate inside module scope
        $caught = $null
        try {
            InModuleScope Xdr.Poll {
                throw [AuthChainBrokenException]::new('HTML at data stage', 'PortalRequest', 500)
            }
        } catch {
            $caught = $_
        }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Stage     | Should -Be 'PortalRequest'
        $caught.Exception.StatusCode | Should -Be 500
        $caught.Exception.Message    | Should -Match 'HTML at data stage'
    }
}
