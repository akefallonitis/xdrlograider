#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — Sentinel workbooks MUST NOT reference deleted
    function names or stale tier values in their KQL queries.

.DESCRIPTION
    LIVE FORENSIC 2026-05-06: post-Section-R consolidation (9 functions → 4),
    two workbook panels still hardcoded the deleted Defender-*-Refresh
    function names + a stale 'P0' Tier value:

      ConnectorHealth_CL Panel 1 (case() arms): hardcoded 5 deleted FunctionName
        values → every row fell to default 'Stale' → operator confused.
      ComplianceDashboard health-panel: `where Tier == 'P0'` → Tier ValidateSet
        is ActionCenter|XspmGraph|Configuration|Inventory|Maintenance|Heartbeat;
        no row will ever match → panel always empty.

    This test loads every workbook .json, walks all `query:` strings, and
    asserts:
      - No FunctionName == '<value>' references a deleted function
      - No Tier == '<value>' references a value outside the live ValidateSet
      - Every Connector-Heartbeat / Xdr-Refresh / Xdr-PollOrchestrator /
        Xdr-PollStream reference DOES match the actual src/functions/ list

    Self-updating: the `LiveFunctions` list is computed from src/functions/
    directory entries — adding/removing functions automatically updates
    the test's expectations.
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkbooksDir = Join-Path $script:RepoRoot 'sentinel/workbooks'
    $script:FunctionsDir = Join-Path $script:RepoRoot 'src/functions'

    # Live function names = src/functions/ directory entries.
    $script:LiveFunctions = @(
        Get-ChildItem -Path $script:FunctionsDir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }
    )

    # Live Tier ValidateSet — must match Set-XdrTierStateRow.ps1 ValidateSet
    # AND the cadence map keys + 'Heartbeat' (used by Connector-Heartbeat liveness row).
    $script:LiveTiers = @('ActionCenter','XspmGraph','Configuration','Inventory','Maintenance','Heartbeat')
}

Describe 'Workbook.LiveFunctionTierRefs — no stale FunctionName / Tier references' {

    It 'every FunctionName equality reference in a workbook query points at a LIVE function' {
        $offenders = @()
        $workbookFiles = Get-ChildItem -Path $script:WorkbooksDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue
        foreach ($wb in $workbookFiles) {
            $raw = Get-Content -Raw $wb.FullName
            # Match both single + double quoted operand variants used in JSON-encoded KQL.
            $matches = [regex]::Matches($raw, "FunctionName\s*==\s*['""]([^'""]+)['""]")
            foreach ($m in $matches) {
                $name = $m.Groups[1].Value
                if ($name -notin $script:LiveFunctions) {
                    $offenders += "{0}: FunctionName == '{1}' (live functions: {2})" -f $wb.Name, $name, ($script:LiveFunctions -join ', ')
                }
            }
        }

        $offenders | Should -BeNullOrEmpty -Because (
            "These workbook panels query a FunctionName that is NOT one of the live functions in src/functions/. The query returns zero rows; panels render empty. Section R consolidation deleted: Defender-*-Refresh, Xdr-WriteHeartbeat. Offenders:`n" + ($offenders -join "`n")
        )
    }

    It 'every Tier equality reference in a workbook query uses a value in the live ValidateSet' {
        $offenders = @()
        $workbookFiles = Get-ChildItem -Path $script:WorkbooksDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue
        foreach ($wb in $workbookFiles) {
            $raw = Get-Content -Raw $wb.FullName
            $matches = [regex]::Matches($raw, "Tier\s*==\s*['""]([^'""]+)['""]")
            foreach ($m in $matches) {
                $val = $m.Groups[1].Value
                if ($val -notin $script:LiveTiers) {
                    $offenders += "{0}: Tier == '{1}' (live tiers: {2})" -f $wb.Name, $val, ($script:LiveTiers -join ', ')
                }
            }
        }

        $offenders | Should -BeNullOrEmpty -Because (
            "These workbook panels filter on a Tier value not in the live Set-XdrTierStateRow ValidateSet. Live evidence (2026-05-06): MDE_ComplianceDashboard.json had `where Tier == 'P0'` (legacy taxonomy) — panel always empty. Offenders:`n" + ($offenders -join "`n")
        )
    }
}
