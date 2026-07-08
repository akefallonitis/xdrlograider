#Requires -Version 7.4
# TYPED-COLUMN CONSUMER (FH-3 unit · approach-B "type AT SOURCE" · 2026-06-16 · proven on the clean foundation).
# Proves the SPARSE ColumnTypes consumer END-TO-END: a manifest op's ColumnTypes ⇒ the TABLE column gets the DECLARED type
# AND the DCR STREAM declares that SAME NATIVE type (set-equal · no string downcast · no coercion layer), and the dataFlow
# transformKql stays the UNIFORM identity 'source'. WHY (approach B): the runtime PARSER emits a NATIVE typed value
# (real→[double], long→[long], int→[int], boolean→[bool], datetime→ISO-8601 string) for a typed column straight from
# ColumnTypes, so the native value lands directly in the native stream column — typing is at the SOURCE (the parser), NOT a
# DCR transform. An UNLISTED projection col ⇒ string (source fidelity). Every emitted type is asserted a valid LA scalar (a
# typo'd `datetimee` would otherwise drop the column at ingest). The ALL-STRING case (2nd synth manifest) proves byte-identity:
# no ColumnTypes ⇒ transformKql='source' ⇒ stream==table (pilot no-regression). The LIVE prove (does the native value actually
# POPULATE the typed column) is at the cat-1 deploy (Tier-2 · Phase 2). Runs the REAL Build-PerCategorySchema against SYNTHETIC
# temp manifests; the parser imports from the real repo; nothing committed is touched.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $bps  = Join-Path $script:repo 'dev-tools\Build-PerCategorySchema.ps1'
    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-fh3-" + [Guid]::NewGuid().ToString('N'))
    $mdir = Join-Path $script:tmp 'manifests\Defender'
    New-Item -ItemType Directory -Path $mdir -Force | Out-Null
    $manifest = @'
@{
    Portal   = 'Defender'
    Category = 'SynthTyped'
    Operations = @(
        @{
            OperationKey   = 'SynthOp'
            DcrStreamName  = 'Custom-Defender_SynthTyped_CL'
            WorkspaceTable = 'Defender_SynthTyped_CL'
            ProjectionMap  = @{ Score = '$.score'; CreatedTime = '$.createdTime'; Count = '$.count'; Flag = '$.flag'; Name = '$.name' }
            ColumnTypes    = @{ Score = 'real'; CreatedTime = 'datetime'; Count = 'long'; Flag = 'boolean' }
        }
    )
}
'@
    Set-Content -Path (Join-Path $mdir 'SynthTyped.psd1') -Value $manifest -Encoding UTF8 -NoNewline
    & pwsh -NoProfile -File $bps -Portal Defender -Category SynthTyped -RepoRoot $script:tmp -OutputMode JSON *> (Join-Path $script:tmp 'build.log')
    $script:exit = $LASTEXITCODE
    $out = Join-Path $script:tmp 'deploy\per-category-schemas\Defender-SynthTyped.json'
    $script:schema = if (Test-Path $out) { Get-Content $out -Raw | ConvertFrom-Json -Depth 50 } else { $null }
    $script:cols = @{}
    if ($script:schema) { foreach ($c in $script:schema.TableResource.properties.schema.columns) { $script:cols[[string]$c.name] = [string]$c.type } }
    $script:dcrCols = @{}
    if ($script:schema) {
        $sk0 = $script:schema.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        foreach ($c in $script:schema.DcrResource.properties.streamDeclarations.$sk0.columns) { $script:dcrCols[[string]$c.name] = [string]$c.type }
    }
    $script:transformKql = if ($script:schema) { [string]$script:schema.DcrResource.properties.dataFlows[0].transformKql } else { '' }

    # F1 · the ALL-STRING case (no ColumnTypes) must stay byte-identical: transformKql='source', stream==table.
    $mAllStr = @'
@{
    Portal   = 'Defender'
    Category = 'SynthAllStr'
    Operations = @(
        @{
            OperationKey   = 'SynthOp'
            DcrStreamName  = 'Custom-Defender_SynthAllStr_CL'
            WorkspaceTable = 'Defender_SynthAllStr_CL'
            ProjectionMap  = @{ Score = '$.score'; Name = '$.name' }
        }
    )
}
'@
    Set-Content -Path (Join-Path $mdir 'SynthAllStr.psd1') -Value $mAllStr -Encoding UTF8 -NoNewline
    & pwsh -NoProfile -File $bps -Portal Defender -Category SynthAllStr -RepoRoot $script:tmp -OutputMode JSON *> (Join-Path $script:tmp 'build-allstr.log')
    $outA = Join-Path $script:tmp 'deploy\per-category-schemas\Defender-SynthAllStr.json'
    $script:schemaAllStr = if (Test-Path $outA) { Get-Content $outA -Raw | ConvertFrom-Json -Depth 50 } else { $null }
}
AfterAll {
    if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'FH-9 · FH-3 typed-column consumer (sparse · evidence-typed · valid LA scalar)' {
    It 'Build-PerCategorySchema runs (exit 0) and emits a schema' {
        $script:exit | Should -Be 0 -Because ("build.log: " + $(if (Test-Path (Join-Path $script:tmp 'build.log')) { Get-Content (Join-Path $script:tmp 'build.log') -Raw } else { '<none>' }))
        $script:schema | Should -Not -BeNullOrEmpty
    }
    It 'each ColumnTypes-declared column gets the DECLARED type' {
        $script:cols['Score']       | Should -Be 'real'
        $script:cols['CreatedTime'] | Should -Be 'datetime'
        $script:cols['Count']       | Should -Be 'long'
        $script:cols['Flag']        | Should -Be 'boolean'
    }
    It 'an UNLISTED projection column defaults to string (sparse)' {
        $script:cols['Name'] | Should -Be 'string'
    }
    It 'every emitted column type is a valid Log-Analytics scalar (offline coercion-validity)' {
        $valid = @('string','int','long','real','boolean','datetime','guid','dynamic')
        $bad = @($script:cols.GetEnumerator() | Where-Object { $_.Value -notin $valid })
        $bad | Should -BeNullOrEmpty -Because ("columns with a non-LA-scalar type: " + (($bad | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
    }
    It 'a TYPED projection column is declared with its NATIVE type in BOTH the DCR stream and the table (B · parser emits native · no string round-trip)' {
        # B (type-at-source): the runtime parser emits a native [double]/[long]/[bool] for a typed column, so the DCR
        # STREAM declares the SAME native type as the TABLE — they are SET-EQUAL (no string downcast, no coercion layer).
        $script:dcrCols['Score']       | Should -Be 'real'
        $script:dcrCols['CreatedTime'] | Should -Be 'datetime'
        $script:dcrCols['Count']       | Should -Be 'long'
        $script:dcrCols['Flag']        | Should -Be 'boolean'
        $script:cols['Score'] | Should -Be 'real'
        $script:cols['Count'] | Should -Be 'long'
        $script:cols['Flag']  | Should -Be 'boolean'
        # stream name:type set == table name:type set (the B invariant gauntlet axis 14 also enforces)
        $dcr = @($script:dcrCols.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) | Sort-Object
        $tbl = @($script:cols.GetEnumerator()    | ForEach-Object { "$($_.Key):$($_.Value)" }) | Sort-Object
        Compare-Object $dcr $tbl | Should -BeNullOrEmpty
    }
    It 'the DCR transformKql stays the uniform identity source (B types at the parser · no per-category coercion)' {
        $script:transformKql | Should -Be 'source'
    }
    It 'the PARSER emits a NATIVE typed value at source (Apply-XdrProjectionMap + ColumnTypes) — the B keystone' {
        Import-Module (Join-Path $script:repo 'src/Modules/Xdr.Common.Parser/Xdr.Common.Parser.psd1') -Force -DisableNameChecking
        $r = Apply-XdrProjectionMap -Item @{ score = 1.5; count = 7; flag = $true; created = '2026-06-04T00:00:00Z'; name = 'x' } `
            -ProjectionMap @{ Score = '$.score'; Count = '$.count'; Flag = '$.flag'; CreatedTime = '$.created'; Name = '$.name' } `
            -ColumnTypes  @{ Score = 'real'; Count = 'long'; Flag = 'boolean'; CreatedTime = 'datetime' }
        $r['Score'] | Should -BeOfType [double]
        $r['Count'] | Should -BeOfType [long]
        $r['Flag']  | Should -BeOfType [bool]
        $r['CreatedTime'] | Should -BeOfType [string]   # datetime → ISO-8601 string (stream=datetime + identity source coerces)
        $r['Name']  | Should -BeOfType [string]          # untyped → string (source fidelity)
    }
    It 'envelope columns keep their declared type in BOTH stream and table (TimeGenerated=datetime · the one lenient string into datetime stream coercion)' {
        $script:dcrCols['TimeGenerated'] | Should -Be 'datetime'
        $script:cols['TimeGenerated']    | Should -Be 'datetime'
        $script:dcrCols['RawJson']       | Should -Be 'string'
    }
}

Describe 'F1 · all-string category (no ColumnTypes) is byte-identical — transformKql=source · stream==table (pilot no-regression)' {
    It 'builds and emits a schema' {
        $script:schemaAllStr | Should -Not -BeNullOrEmpty
    }
    It 'transformKql stays the identity source (no coercion path)' {
        [string]$script:schemaAllStr.DcrResource.properties.dataFlows[0].transformKql | Should -Be 'source'
    }
    It 'DCR stream column types EQUAL table column types (all-string · no string/typed split)' {
        $sk = $script:schemaAllStr.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcr = @($script:schemaAllStr.DcrResource.properties.streamDeclarations.$sk.columns | ForEach-Object { "$($_.name):$($_.type)" }) | Sort-Object
        $tbl = @($script:schemaAllStr.TableResource.properties.schema.columns | ForEach-Object { "$($_.name):$($_.type)" }) | Sort-Object
        Compare-Object $dcr $tbl | Should -BeNullOrEmpty
    }
}
