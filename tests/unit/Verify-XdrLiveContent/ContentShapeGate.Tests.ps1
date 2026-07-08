#Requires -Version 7.4
# P2 · Verify-XdrLiveContent content-shape gate (the machine half of the live-content proof) + the LOCAL-ONLY
# CI refusal. RED-able: the pure gate must FAIL on empty/incomplete/wrong content and the tool must REFUSE under CI.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    . (Join-Path $script:repoRoot 'tools/lib/Xdr.ContentShapeGate.ps1')
    $script:pm = @{ AccountType = '$.AccountType'; GeoRegion = '$.GeoRegion' }
    # Mirrors ConvertTo-XdrRows' F2 row contract EXACTLY: 6 parser-filled envelope cols (NO OperationKey — F2
    # dropped it as a duplicate of Operation) + the projected typed cols. If this row drifts from the parser, the
    # gate's GREEN here would lie about the live direct-source proof.
    function script:New-GoodRow {
        @{ TimeGenerated = '2026-06-09T00:00:00Z'; Portal = 'Defender'
           Category = 'Operations'; Subcategory = 'Multi-Tenant'; Operation = 'GetTenantContext'
           RawJson = '{"AccountType":"Production","GeoRegion":"Europe3"}'; AccountType = 'Production'; GeoRegion = 'Europe3' }
    }
}

Describe 'P2 · Test-XdrContentShape · content-correct ⟺ envelope + rawjson + >=1 projected (NOT count)' {
    It 'GREEN on a content-correct row' {
        $v = Test-XdrContentShape -Rows @(script:New-GoodRow) -ProjectionMap $script:pm
        $v.Pass | Should -BeTrue
        $v.EnvelopeOk | Should -BeTrue
        $v.RawJsonOk | Should -BeTrue
        $v.ProjectionResolved | Should -BeGreaterThan 0
    }
    It 'RED on 0 rows (the historical 0-row failure)' {
        $v = Test-XdrContentShape -Rows @() -ProjectionMap $script:pm
        $v.Pass | Should -BeFalse
        $v.Reason | Should -Be '0 rows'
    }
    It 'RED when an envelope col is null/missing' {
        $row = script:New-GoodRow; $row['Portal'] = $null
        $v = Test-XdrContentShape -Rows @($row) -ProjectionMap $script:pm
        $v.Pass | Should -BeFalse
        $v.EnvelopeOk | Should -BeFalse
    }
    It 'RED when the Operation op-identity col is missing (the F2 col that replaced OperationKey)' {
        $row = script:New-GoodRow; $row.Remove('Operation')
        $v = Test-XdrContentShape -Rows @($row) -ProjectionMap $script:pm
        $v.Pass | Should -BeFalse
        $v.EnvelopeOk | Should -BeFalse
    }
    It 'GREEN without OperationKey — the gate must NOT require the F2-dropped stale col (regression: universal RED-shape)' {
        $row = script:New-GoodRow; $row.Remove('OperationKey')  # New-GoodRow already omits it; explicit for intent
        $v = Test-XdrContentShape -Rows @($row) -ProjectionMap $script:pm
        $v.Pass | Should -BeTrue
        $v.EnvelopeOk | Should -BeTrue
    }
    It 'RED when RawJson is not valid JSON' {
        $row = script:New-GoodRow; $row['RawJson'] = 'not-json'
        $v = Test-XdrContentShape -Rows @($row) -ProjectionMap $script:pm
        $v.Pass | Should -BeFalse
        $v.RawJsonOk | Should -BeFalse
    }
    It 'RED when NO ProjectionMap field resolves (empty/wrong content)' {
        $row = script:New-GoodRow; $row.Remove('AccountType'); $row.Remove('GeoRegion')
        $v = Test-XdrContentShape -Rows @($row) -ProjectionMap $script:pm
        $v.Pass | Should -BeFalse
        $v.ProjectionResolved | Should -Be 0
    }
}

Describe 'P2 · Verify-XdrLiveContent is LOCAL-ONLY · refuses under CI (creds never in CI)' {
    It 'exits 2 when $env:CI is set' {
        $tool = Join-Path $script:repoRoot 'tools/Verify-XdrLiveContent.ps1'
        $prev = $env:CI
        $env:CI = 'true'
        try { & pwsh -NoProfile -File $tool -Mode A *> $null; $code = $LASTEXITCODE } finally { if ($null -eq $prev) { Remove-Item env:CI -ErrorAction SilentlyContinue } else { $env:CI = $prev } }
        $code | Should -Be 2
    }
}
