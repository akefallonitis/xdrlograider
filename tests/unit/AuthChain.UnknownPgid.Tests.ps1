#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.9 (O1 lock): when Resolve-EntraInterruptPage hits an unknown pgid,
    the auth chain MUST emit a Write-Warning with diagnostic context (so
    operators can root-cause from App Insights traces).

    iter-14.0 update: Resolve-InterruptPage was renamed to Resolve-EntraInterruptPage
    and moved out of Xdr.Portal.Auth/Private/Get-EstsCookie.ps1 into
    Xdr.Common.Auth/Public/Resolve-EntraInterruptPage.ps1. The source-level
    diagnostic-warning lock is unchanged otherwise.

.DESCRIPTION
    Live evidence (sign-in logs 2026-04-27): error 399218 "user
    confirmation is required to sign in to this tenant" surfaced after MFA
    succeeded. This is a NEW interrupt page Entra introduced beyond the 3
    known ones (KmsiInterrupt / CmsiInterrupt / ConvergedProofUpRedirect)
    that our auth chain handles.

    Iter 13.9 added a Write-Warning in the `default` branch of the pgid
    switch that captures: pgid name, sErrorCode, sErrTxt, content length,
    and a "if this recurs, capture HTML and add a handler" instruction.

    This test reads the source file to verify the warning is permanently
    locked. If a future refactor drops the Write-Warning, the test fails
    immediately.
#>

BeforeAll {
    $script:RepoRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'

    Import-Module $script:CommonModulePath -Force -ErrorAction Stop
    Set-StrictMode -Version Latest
}

AfterAll {
    Remove-Module Xdr.Common.Auth -Force -ErrorAction SilentlyContinue
}

Describe 'Auth chain — unknown pgid emits Write-Warning (iter 13.9 O1 lock; iter-14.0 location)' {

    It 'Resolve-EntraInterruptPage default branch contains diagnostic Write-Warning' {
        # Source-level assertion: read the file + verify the default branch
        # implementation includes a Write-Warning with all required context
        # tokens (pgid, sErrorCode, contentLen). This is the simplest lock
        # for a behaviour that's hard to exercise in isolation.
        $resolvePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Public' 'Resolve-EntraInterruptPage.ps1'
        $content = Get-Content $resolvePath -Raw

        # Find the default branch in Resolve-EntraInterruptPage's switch.
        $hasDefaultWithWarning = $false
        $lines = $content -split "`n"
        $inDefault = $false
        $sawWarning = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\s*default\s*\{') {
                $inDefault = $true
                $sawWarning = $false
                continue
            }
            if ($inDefault) {
                if ($line -match 'Write-Warning') { $sawWarning = $true }
                # Match closing brace at start of line as end of default
                if ($line -match '^\s*\}\s*$' -and $sawWarning) {
                    $hasDefaultWithWarning = $true
                    break
                }
                if ($line -match '^\s*\}\s*$') {
                    $inDefault = $false
                }
            }
        }
        $hasDefaultWithWarning | Should -BeTrue -Because (
            'iter-13.9 O1 lock: the default branch of the pgid switch in ' +
            'Resolve-EntraInterruptPage MUST emit a Write-Warning so unknown ' +
            'interrupts (e.g. AADSTS399218 user-confirmation surface) leave ' +
            'a diagnostic trail for operators in App Insights.'
        )

        # The warning message must include the diagnostic tokens
        $content | Should -Match 'UNKNOWN pgid' -Because 'warning text must signal "unknown pgid" so log filtering catches it'
        $content | Should -Match 'sErrorCode'   -Because 'warning must include sErrorCode for AADSTS code-based triage'
        $content | Should -Match 'contentLen'   -Because 'warning must include content length so operators know whether HTML was returned'
    }

    It 'KmsiInterrupt + CmsiInterrupt + ConvergedProofUpRedirect handlers still present (regression guard)' {
        # iter-13.x has been hardening this surface; a future refactor must
        # not accidentally drop one of the 3 known handlers.
        $resolvePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Public' 'Resolve-EntraInterruptPage.ps1'
        $content = Get-Content $resolvePath -Raw

        $content | Should -Match "'KmsiInterrupt'"            -Because 'KMSI handler must remain'
        $content | Should -Match "'CmsiInterrupt'"            -Because 'Cmsi handler must remain'
        $content | Should -Match "'ConvergedProofUpRedirect'" -Because 'ConvergedProofUp handler must remain'
    }
}
