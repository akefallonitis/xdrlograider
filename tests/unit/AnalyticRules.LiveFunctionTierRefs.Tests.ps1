#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — Sentinel analytic rules + hunting queries
    MUST NOT reference deleted function names or stale tier values.

.DESCRIPTION
    Mirror of Workbook.LiveFunctionTierRefs.Tests.ps1 — same root cause, same
    parity check, applied to .yaml files in sentinel/analytic-rules/ +
    sentinel/hunting-queries/.

    Caught the live B4 bug: XdrOps-ConnectorStaleStream.yaml shipped with a
    cadenceLimits datatable joining on FunctionName values that no row in
    XdrConnectorHealth_CL ever has (5 deleted Defender-*-Refresh names).
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:RulesDir     = Join-Path $script:RepoRoot 'sentinel/analytic-rules'
    $script:HuntingDir   = Join-Path $script:RepoRoot 'sentinel/hunting-queries'
    $script:FunctionsDir = Join-Path $script:RepoRoot 'src/functions'

    $script:LiveFunctions = @(
        Get-ChildItem -Path $script:FunctionsDir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }
    )
    $script:LiveTiers = @('ActionCenter','XspmGraph','Configuration','Inventory','Maintenance','Heartbeat')
}

Describe 'AnalyticRules.LiveFunctionTierRefs — no stale FunctionName / Tier in .yaml KQL' {

    It 'analytic-rule + hunting yaml KQL references only live FunctionName values' {
        $offenders = @()
        $yamls = @(
            Get-ChildItem -Path $script:RulesDir   -Filter '*.yaml' -Recurse -ErrorAction SilentlyContinue
            Get-ChildItem -Path $script:HuntingDir -Filter '*.yaml' -Recurse -ErrorAction SilentlyContinue
        )
        foreach ($y in $yamls) {
            $raw = Get-Content -Raw $y.FullName
            # Compare both quoted-literal forms (KQL-in-yaml uses double quotes commonly).
            $matches = [regex]::Matches($raw, '"(Defender-[A-Za-z]+-Refresh|Xdr-WriteHeartbeat)"')
            foreach ($m in $matches) {
                $offenders += "{0}: literal `"{1}`" (deleted function — Section R consolidation)" -f $y.Name, $m.Groups[1].Value
            }
        }
        $offenders | Should -BeNullOrEmpty -Because (
            "These yaml KQL strings still hardcode legacy Defender-*-Refresh / Xdr-WriteHeartbeat names that were deleted by Section R (9→4 functions). Offenders:`n" + ($offenders -join "`n")
        )
    }

    It 'analytic-rule + hunting yaml KQL Tier filters use values in the live ValidateSet' {
        $offenders = @()
        $yamls = @(
            Get-ChildItem -Path $script:RulesDir   -Filter '*.yaml' -Recurse -ErrorAction SilentlyContinue
            Get-ChildItem -Path $script:HuntingDir -Filter '*.yaml' -Recurse -ErrorAction SilentlyContinue
        )
        foreach ($y in $yamls) {
            $raw = Get-Content -Raw $y.FullName
            $matches = [regex]::Matches($raw, "Tier\s*==\s*['""]([^'""]+)['""]")
            foreach ($m in $matches) {
                $val = $m.Groups[1].Value
                if ($val -notin $script:LiveTiers) {
                    $offenders += "{0}: Tier == '{1}'" -f $y.Name, $val
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because (
            "yaml KQL Tier filter must use one of $($script:LiveTiers -join ', '). Offenders:`n" + ($offenders -join "`n")
        )
    }
}
