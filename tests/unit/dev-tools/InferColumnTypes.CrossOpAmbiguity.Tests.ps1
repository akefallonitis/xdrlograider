#Requires -Version 7.4
# CROSS-OP AMBIGUITY resolver (dev-tools/Infer-ColumnTypes.ps1) · the type-consistency union in Generate-Manifest
# propagates a curated col-type to EVERY op projecting that col-NAME, so if the same col-name has a DIFFERENT real wire
# type across ops the union over-propagates and DROPS values at ingest (e.g. `Id` is long=1000000024 in
# ListSuppressionRules but a GUID-string in ListUnifiedConnectors → typed long → the GUID drops). Infer-ColumnTypes adds a
# CROSS-OP pass: after per-op inference, a col-name contradicted by ANY op (non-scalar / non-datetime string / a scalar of
# a different family) is dropped from the ENTIRE output (resolve to string, the safe shared-table default).
#
# The tool runs top-to-bottom (no dot-source guard) and resolves its inputs (shape oracle + evidence-index + catalogue +
# fixtures) from its OWN $PSScriptRoot/$RepoRoot. To exercise the real cross-op pass with SYNTHETIC fixtures we COPY the
# script + its lib into a temp scaffold and point a synthetic evidence-index at the synthetic fixtures. Nothing in the repo
# is touched. Fully offline.

Set-StrictMode -Version Latest

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $realTool = Join-Path $script:repo 'dev-tools\Infer-ColumnTypes.ps1'
    $realLib  = Join-Path $script:repo 'dev-tools\lib\Get-XdrBodyShape.ps1'
    $realDisco = Join-Path $script:repo 'dev-tools\lib\Get-XdrDiscoveryShape.ps1'   # the SHAPE-ONLY discovery reader (now part of the tool's lib)

    # Temp scaffold mirroring the real layout the tool expects: <root>/dev-tools/{Infer-ColumnTypes.ps1,lib/...} +
    # <root>/references/inventory/nodoc-defender-xdr/{evidence-index,catalogue}.json + <root>/references/.../fixtures.
    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-infer-xop-" + [Guid]::NewGuid().ToString('N'))
    $devTools = Join-Path $script:tmp 'dev-tools'
    $libDir   = Join-Path $devTools 'lib'
    $invDir   = Join-Path $script:tmp 'references\inventory\nodoc-defender-xdr'
    $fxDir    = Join-Path $script:tmp 'references\live\source-mvp-fixtures'
    New-Item -ItemType Directory -Path $libDir -Force | Out-Null
    New-Item -ItemType Directory -Path $invDir -Force | Out-Null
    New-Item -ItemType Directory -Path $fxDir  -Force | Out-Null
    Copy-Item $realTool (Join-Path $devTools 'Infer-ColumnTypes.ps1') -Force
    Copy-Item $realLib  (Join-Path $libDir   'Get-XdrBodyShape.ps1')  -Force
    Copy-Item $realDisco (Join-Path $libDir  'Get-XdrDiscoveryShape.ps1') -Force   # so the tool's optional discovery dot-source resolves (no discovery/ dir in the scaffold → no discovery pass · the synthetic cross-op result is unchanged)
    $script:toolCopy = Join-Path $devTools 'Infer-ColumnTypes.ps1'

    # Synthetic fixtures exercising the conflict classes. Bodies use the {"value":[{...}]} WRAPPER shape (what the shared
    # shape oracle yields items for · also the real GetDataExportSettings shape) — a 1-element bare array is classified
    # singleObject by the oracle, which has no items to infer over.
    #  OpLong   · Id is a long (1000000024)          + KeepDate is a datetime   (unambiguous · must survive)
    #  OpGuid   · id is a GUID string                 + Other is a long          (unambiguous-per-op · survives)
    #  OpStr    · RuleType is the string 'Predefined' (vs OpRtLong's long RuleType)
    #  OpRtLong · RuleType is a long (1)
    #  OpObj    · Payload is an OBJECT (non-scalar)   vs OpPayNum's numeric Payload
    #  OpPayNum · Payload is a long (5)
    # Expected drops (case-insensitive name-global): id, ruletype, payload. Survivors: keepdate (datetime), other (long).
    function New-Fx { param([string]$Name, [string]$Json) Set-Content -LiteralPath (Join-Path $fxDir "$Name.json") -Value $Json -Encoding UTF8 -NoNewline }
    New-Fx 'OpLong'   '{"value":[{"Id":1000000024,"KeepDate":"2026-01-02T03:04:05Z"}]}'
    New-Fx 'OpGuid'   '{"value":[{"id":"550e8400-e29b-41d4-a716-446655440000","Other":7}]}'
    New-Fx 'OpStr'    '{"value":[{"RuleType":"Predefined"}]}'
    New-Fx 'OpRtLong' '{"value":[{"RuleType":1}]}'
    New-Fx 'OpObj'    '{"value":[{"Payload":{"nested":true}}]}'
    New-Fx 'OpPayNum' '{"value":[{"Payload":5}]}'

    $records = @(
        @{ OperationId = 'Synth.OpLong';   Fixture = 'references/live/source-mvp-fixtures/OpLong.json' }
        @{ OperationId = 'Synth.OpGuid';   Fixture = 'references/live/source-mvp-fixtures/OpGuid.json' }
        @{ OperationId = 'Synth.OpStr';    Fixture = 'references/live/source-mvp-fixtures/OpStr.json' }
        @{ OperationId = 'Synth.OpRtLong'; Fixture = 'references/live/source-mvp-fixtures/OpRtLong.json' }
        @{ OperationId = 'Synth.OpObj';    Fixture = 'references/live/source-mvp-fixtures/OpObj.json' }
        @{ OperationId = 'Synth.OpPayNum'; Fixture = 'references/live/source-mvp-fixtures/OpPayNum.json' }
    )
    @{ Records = $records } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $invDir 'evidence-index.json') -Encoding UTF8
    # Minimal catalogue (the tool only indexes .Operations by OperationId for a ProjectionMap fallback we don't trigger).
    @{ Operations = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $invDir 'catalogue.json') -Encoding UTF8

    # Run the copied tool against the synthetic scaffold (Write-Host log on stream 6; the object on stdout). Merge 6→1 and
    # stringify, keeping only the cross-op-ambiguity lines (the InformationRecord stringifies to its message text).
    $script:log = @(& $script:toolCopy -Portal Defender 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'cross-op ambiguity' })
    $script:out = & $script:toolCopy -Portal Defender 6>$null
}

AfterAll { if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'Infer-ColumnTypes · cross-op ambiguity resolver (drop a col-name typed differently across ops)' {
    It 'drops `Id`/`id` everywhere (long in one op · GUID-string in another → value-drop at ingest if typed long)' {
        $idVals = @()
        foreach ($op in $script:out.PSObject.Properties) {
            foreach ($c in $op.Value.PSObject.Properties) { if ($c.Name -ieq 'id') { $idVals += "$($op.Name).$($c.Name)" } }
        }
        $idVals | Should -BeNullOrEmpty   # no surviving Id/id type in ANY op
    }
    It 'drops `RuleType`/`ruletype` everywhere (long in one op · string ''Predefined'' in another)' {
        $rt = @()
        foreach ($op in $script:out.PSObject.Properties) {
            foreach ($c in $op.Value.PSObject.Properties) { if ($c.Name -ieq 'ruletype') { $rt += $op.Name } }
        }
        $rt | Should -BeNullOrEmpty
    }
    It 'drops a col that is a NON-SCALAR (object) in one op but numeric in another (`Payload`)' {
        $pl = @()
        foreach ($op in $script:out.PSObject.Properties) {
            foreach ($c in $op.Value.PSObject.Properties) { if ($c.Name -ieq 'payload') { $pl += $op.Name } }
        }
        $pl | Should -BeNullOrEmpty
    }
    It 'KEEPS an unambiguous typed col (KeepDate=datetime · only ever a datetime)' {
        $kd = $null
        foreach ($op in $script:out.PSObject.Properties) {
            foreach ($c in $op.Value.PSObject.Properties) { if ($c.Name -ieq 'keepdate') { $kd = $c.Value } }
        }
        $kd | Should -Be 'datetime'
    }
    It 'KEEPS an unambiguous typed col that only ONE op projects (Other=long)' {
        $ot = $null
        foreach ($op in $script:out.PSObject.Properties) {
            foreach ($c in $op.Value.PSObject.Properties) { if ($c.Name -ieq 'other') { $ot = $c.Value } }
        }
        $ot | Should -Be 'long'
    }
    It 'emits a one-line cross-op-ambiguity log for each dropped col-name (id · ruletype · payload)' {
        ($script:log -join "`n") | Should -Match "dropping type for col 'id'"
        ($script:log -join "`n") | Should -Match "dropping type for col 'ruletype'"
        ($script:log -join "`n") | Should -Match "dropping type for col 'payload'"
    }
    It 'the log states the conservative resolution (resolve to string) and a reason' {
        ($script:log -join "`n") | Should -Match 'resolve to string'
        # the object/array conflict for Payload is reported as a non-scalar observation
        ($script:log | Where-Object { $_ -match "'payload'" }) | Should -Match 'non-scalar'
    }
}
