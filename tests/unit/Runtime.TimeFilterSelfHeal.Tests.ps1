#Requires -Module Pester
# Π10 · TimeFilter self-heal (Π8d feature) test coverage · closes documented gap.
#
# Validates that run.ps1's per-entry pagination loop:
#   1. Injects ?since= query param on first page when TimeFilter=Supported + LastPolledUtc present
#   2. Detects HTTP 400 response with TF param injected and retries without TF
#   3. Emits Runtime.TimeFilterRejected telemetry on the retry path
#   4. Continues cycle gracefully even when TF rejected (no crash · entry succeeds via retry)
#
# Coverage gap addressed: source-grep verification only (no behavior simulation).
# This file uses source-grep too (matching project conventions) since the cycle body is
# inside an Azure Function with $env: state, runspace, and module dependencies that can't
# be Pester-mocked cheaply.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RunSource = Get-Content -Raw (Join-Path $script:RepoRoot 'src/functions/Xdr-Poll/run.ps1')
}

Describe 'Π10 · TimeFilter self-heal (Π8d) source verification' -Tag 'tier1','runtime','timefilter' {

    It 'run.ps1 injects ?since= when TimeFilter=Supported + LastPolledUtc' {
        $script:RunSource | Should -Match 'tfSupported.*-and.*lastPolledUtc.*-and.*loopGuard\s*-eq\s*1'
        $script:RunSource | Should -Match 'Add-XdrUrlQueryParam.*-Name\s*\$tfParam.*-Value\s*\$sinceStr'
    }

    It 'run.ps1 records tfInjected flag for downstream self-heal' {
        $script:RunSource | Should -Match '\$tfInjected\s*=\s*\$false'
        $script:RunSource | Should -Match '\$tfInjected\s*=\s*\$true'
    }

    It 'run.ps1 detects 400 + tfInjected and triggers self-heal retry' {
        $script:RunSource | Should -Match 'if\s*\(\$sc\s*-eq\s*400\s*-and\s*\$tfInjected\)'
    }

    It 'run.ps1 emits Runtime.TimeFilterRejected telemetry on self-heal' {
        $script:RunSource | Should -Match "EventName\s*'Runtime\.TimeFilterRejected'"
        $script:RunSource | Should -Match "Strategy\s*=\s*'self-heal-retry-without-tf'"
    }

    It 'run.ps1 rebuilds URL without TF param on retry' {
        $script:RunSource | Should -Match '\$urlNoTF\s*=\s*\[string\]\$e\.Path'
    }

    It 'run.ps1 preserves continuation token on TF self-heal retry' {
        $script:RunSource | Should -Match 'if\s*\(\$continuation\s*-and\s*\$paginationKey\)\s*\{[\s\S]{0,200}\$urlNoTF\s*=\s*Add-XdrUrlQueryParam'
    }

    It 'run.ps1 invokes Invoke-DefenderApiproxy AGAIN on retry (not -Force, just retry once)' {
        # The 400 → retry-once pattern · MaxRetries=1 on the inner call.
        # ITER5 extended: retry path also carries -Headers/-Query/-PathParams · regex allows them between -Method and -MaxRetries.
        $script:RunSource | Should -Match 'urlNoTF.*-Session\s+\$session\s+-Method\s+\$e\.Method.*-MaxRetries\s+1'
    }

    It 'Π10 · paginationKey is hoisted OUT of if($continuation) branch (StrictMode safety)' {
        # Critical fix: paginationKey must be defined BEFORE first request so TF self-heal
        # on first-page rejection can reference it safely
        $script:RunSource | Should -Match '\$paginationKey\s*=\s*switch\s*\(\[string\]\$e\.Pagination\)[\s\S]+do\s*\{'
    }

    It 'Π10 · loopGuard cap raised to 1000 (vuln_mgmt 1000+ pages safety)' {
        $script:RunSource | Should -Match 'loopGuard\s*-gt\s*1000'
        $script:RunSource | Should -Match "EventName\s*'Runtime\.PaginationLoopGuardHit'"
    }

    It 'Π10 · empty-string continuation token is treated as no-resume' {
        $script:RunSource | Should -Match '\[string\]::IsNullOrEmpty\(\$resumeContinuationToken\)'
    }

    It 'Π10 · datetime parse uses AssumeUniversal+AdjustToUniversal (no double-convert)' {
        $script:RunSource | Should -Match 'DateTimeStyles\]::RoundtripKind\s*-bor\s*\[System\.Globalization\.DateTimeStyles\]::AssumeUniversal\s*-bor\s*\[System\.Globalization\.DateTimeStyles\]::AdjustToUniversal'
    }

    It 'Π11 · LicenseBlocked telemetry REMOVED (Π10 scope-creep · would emit on legitimate endpoints since R-C is stubbed)' {
        # Π10 added Runtime.LicenseBlocked without operator ask. Since Discover-XdrPortalCapabilities
        # is a stub (ProductsAvailable=@()), the filter would have fired on 410 of 519 entries that
        # have non-empty RequiresProducts · misleading noise. Π11 reverted both the telemetry
        # emission AND the filter (returns true unconditionally · API rejects license-blocked).
        $script:RunSource | Should -Not -Match "EventName\s*'Runtime\.LicenseBlocked'"
    }

    It 'Π10 · ProductsAvailable PSObject property is guarded under StrictMode' {
        $script:RunSource | Should -Match "PSObject\.Properties\[`?'ProductsAvailable'`?\]"
    }

    It 'Π10 · AuthFatal classifier no longer matches plain "sccauth" substring' {
        # The new regex should require specific failure patterns (cookie expired, not present, etc.)
        $script:RunSource | Should -Match 'sccauth\s+cookie\s+expired|sccauth\s+not\s+present'
        # And should NOT have the loose `sccauth` substring alone in the classifier
        $script:RunSource | Should -Not -Match "match\s+'AADSTS\|Authentication failed\|TOTP rejected\|sccauth\|AuthChainBroken'"
    }
}

Describe 'Π10 · Manifest LIVESTREAM ↔ TimeFilter alignment' -Tag 'tier1','manifest','alignment' {
    BeforeAll {
        $script:Manifest = & ([scriptblock]::Create((Get-Content -Raw (Join-Path $script:RepoRoot 'manifests/defender.psd1'))))
    }

    It 'every LIVESTREAM entry has TimeFilter=Supported' {
        $bad = @($script:Manifest.Entries | Where-Object { $_.IngestionMode -eq 'LIVESTREAM' -and $_.TimeFilter -ne 'Supported' })
        $bad.Count | Should -Be 0 -Because "LIVESTREAM endpoints need incremental delta read (TF=Supported)"
    }

    It 'every SNAPSHOT entry has TimeFilter=NotSupported (full-state read)' {
        $bad = @($script:Manifest.Entries | Where-Object { $_.IngestionMode -eq 'SNAPSHOT' -and $_.TimeFilter -eq 'Supported' })
        $bad.Count | Should -Be 0 -Because "SNAPSHOT endpoints take full snapshots · TF would be wasteful (saved by Π8d self-heal at runtime but classifier should be right)"
    }

    It 'TimeFilter=Supported count equals LIVESTREAM count (1:1 alignment)' {
        $tfSupported = @($script:Manifest.Entries | Where-Object TimeFilter -eq 'Supported').Count
        $liveStream  = @($script:Manifest.Entries | Where-Object IngestionMode -eq 'LIVESTREAM').Count
        $tfSupported | Should -Be $liveStream
    }
}
