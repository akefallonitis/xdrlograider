#Requires -Version 7.4
# T3e (audit 2026-06-12) · THE FIELD-EMITTABILITY GATE — the structural fix for the INERT-DIMENSION class. Eight
# runtime contract dimensions (CursorPath/CursorPrecision/skipTop/ServerOData/LookbackHours/BodyTemplate/typed
# columns/tz-shape) shipped as runtime READS the generation chain could not EMIT — silently dead until an op needed
# them (the token-pagination single-page + the live cursor bug both trace here). This gate makes the class
# UN-SHIPPABLE: every Pagination.*/TimeFilter.*/Entry-knob the runtime reads MUST have a declared emitter in the
# REGISTRY below, and every declared emitter MUST actually exist in the generation-chain source (Build-Catalogue
# branch · curation allow-list · Generate-Manifest whitelist). A new runtime read without an emitter goes RED here.
#
# Emitter classes: generator (Build-Catalogue derives from spec/live evidence) · curation (operator-verified DATA in
# curation.json's timeFilter section · the ONE behavioral-curation seam) · live-evidence (behavioral · live fixtures
# ONLY, never curated — exactly-once safety) · legacy-fallback (back-compat read · documented · no emitter).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:RuntimeSrc   = Get-Content (Join-Path $repo 'src\Modules\Xdr.Common.Runtime\Xdr.Common.Runtime.psm1') -Raw
    $script:CatalogueSrc = Get-Content (Join-Path $repo 'dev-tools\Build-Catalogue.ps1') -Raw
    $script:ManifestSrc  = Get-Content (Join-Path $repo 'dev-tools\Generate-Manifest.ps1') -Raw

    # ── THE CONTRACT REGISTRY · field -> emitter ──
    $script:Registry = @{
        Pagination = @{
            Mode='generator'; ParamLocation='generator'; PageSize='generator'; PageSizeQuery='generator'
            PageIndexQuery='generator'; PageIndexStart='generator'; CursorMode='generator'; LoopGuard='generator'
            TotalCountPath='generator'; SortByQuery='generator'; SortByField='generator'; SortOrderQuery='generator'
            SortOrder='generator'; StopWhenCursorPassed='generator'; SkipQuery='generator'; TopQuery='generator'
            CursorPath='generator'; CursorQuery='generator'
        }
        TimeFilter = @{
            Mode='generator'; FieldName='generator'; FromDateParam='generator'; ToDateParam='generator'
            ParamLocation='generator'
            Operator='curation'; OuterFormat='curation'; ValueFormat='curation'; FilterParam='curation'; RelativeParam='curation'
        }
        Entry = @{
            LookbackHours='generator'; BodyTemplate='generator'
            CursorPrecision='curation'
            CursorField='live-evidence'; NaturalKey='live-evidence'
            CursorPath='legacy-fallback'   # Entry-root back-compat read in Get-XdrNextCursor (Pagination.CursorPath is canonical)
        }
    }

    function Get-SweptReads([string]$Source, [string]$Pattern) {
        @([regex]::Matches($Source, $Pattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }
}

Describe 'T3e · emittability gate · runtime read-surface ⊆ registry (a new read with no declared emitter is RED)' {
    It 'every TimeFilter.* field the runtime reads is registered' {
        $reads = Get-SweptReads $script:RuntimeSrc "\`$tf\['(\w+)'\]"
        $reads.Count | Should -BeGreaterThan 0
        foreach ($f in $reads) {
            $script:Registry.TimeFilter.ContainsKey($f) | Should -BeTrue -Because "the runtime reads TimeFilter.$f but no emitter is declared (the inert-dimension class)"
        }
    }
    It 'every Pagination.* field the runtime reads is registered (all read variables: pg/pgCfg/pgDict)' {
        $reads = Get-SweptReads $script:RuntimeSrc "\`$pg(?:Cfg|Dict)?\['(\w+)'\]"
        $reads.Count | Should -BeGreaterThan 0
        foreach ($f in $reads) {
            $script:Registry.Pagination.ContainsKey($f) | Should -BeTrue -Because "the runtime reads Pagination.$f but no emitter is declared"
        }
    }
    It 'every Entry-level behavioral knob the runtime reads is registered' {
        $reads = Get-SweptReads $script:RuntimeSrc "\`$Entry\['(CursorField|NaturalKey|CursorPrecision|LookbackHours|CursorPath|BodyTemplate)'\]"
        foreach ($f in $reads) {
            $script:Registry.Entry.ContainsKey($f) | Should -BeTrue -Because "the runtime reads Entry.$f but no emitter is declared"
        }
    }
    It 'registry honesty · every registered TimeFilter/Pagination row HAS a runtime read site (no dead rows)' {
        # Pagination.Mode is the CONTRACT DISCRIMINATOR (read by tooling/tests/humans, e.g. the catalogue gates) —
        # the runtime intentionally keys on CursorMode / SkipQuery+TopQuery presence instead. Documented exemption.
        $contractOnly = @('Mode')
        $tfReads = Get-SweptReads $script:RuntimeSrc "\`$tf\['(\w+)'\]"
        $pgReads = Get-SweptReads $script:RuntimeSrc "\`$pg(?:Cfg|Dict)?\['(\w+)'\]"
        foreach ($f in $script:Registry.TimeFilter.Keys) { $tfReads | Should -Contain $f -Because "registry row TimeFilter.$f has no runtime read — stale registry" }
        foreach ($f in ($script:Registry.Pagination.Keys | Where-Object { $_ -notin $contractOnly })) { $pgReads | Should -Contain $f -Because "registry row Pagination.$f has no runtime read — stale registry" }
    }
}

Describe 'T3e · emittability gate · every declared emitter actually EXISTS in the generation chain' {
    It 'every generator-emitted field is present in the Build-Catalogue derivation source' {
        $gen = $script:CatalogueSrc
        foreach ($fam in @('Pagination','TimeFilter','Entry')) {
            foreach ($f in $script:Registry[$fam].Keys) {
                if ($script:Registry[$fam][$f] -ne 'generator') { continue }
                $gen | Should -Match "\b$([regex]::Escape($f))\b" -Because "$fam.$f is declared generator-emitted but Build-Catalogue never writes it (INERT)"
            }
        }
    }
    It 'every curation-emitted field is in the Build-Catalogue curation timeFilter ALLOW-LIST (the one behavioral seam)' {
        $m = [regex]::Match($script:CatalogueSrc, '\$script:XdrCurationTimeFilterKeys\s*=\s*@\(([^)]*)\)')
        $m.Success | Should -BeTrue -Because 'the curation timeFilter seam (allow-listed keys) must exist in Build-Catalogue'
        $listed = @([regex]::Matches($m.Groups[1].Value, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
        foreach ($fam in @('TimeFilter','Entry')) {
            foreach ($f in $script:Registry[$fam].Keys) {
                if ($script:Registry[$fam][$f] -ne 'curation') { continue }
                $listed | Should -Contain $f -Because "$fam.$f is declared curation-emitted but the allow-list does not carry it (INERT)"
            }
        }
    }
    It 'every curated/generated Entry-root knob flows through the Generate-Manifest whitelist (catalogue -> manifest)' {
        # TimeFilter/Pagination blocks pass through verbatim (ConvertTo-Ordered) — pin that; Entry-root knobs each
        # need a conditional-emit row (the lean-envelope discipline) or they die between catalogue and manifest.
        $script:ManifestSrc | Should -Match 'TimeFilter\s*=\s*ConvertTo-Ordered'
        $script:ManifestSrc | Should -Match 'Pagination\s*=\s*ConvertTo-Ordered'
        foreach ($f in @('LookbackHours','BodyTemplate','CursorPrecision')) {
            $script:ManifestSrc | Should -Match "\b$f\b" -Because "Entry.$f must have a Generate-Manifest whitelist row or the catalogue value never reaches the runtime (INERT)"
        }
    }
    It 'live-evidence fields are derived in the Validated branch and NEVER in the curation allow-list (exactly-once safety)' {
        foreach ($f in @('CursorField','NaturalKey')) {
            $script:CatalogueSrc | Should -Match "\b$f\b"
        }
        $m = [regex]::Match($script:CatalogueSrc, '\$script:XdrCurationTimeFilterKeys\s*=\s*@\(([^)]*)\)')
        if ($m.Success) {
            $listed = @([regex]::Matches($m.Groups[1].Value, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
            $listed | Should -Not -Contain 'CursorField' -Because 'the exactly-once cursor field needs LIVE proof, never curation'
            $listed | Should -Not -Contain 'NaturalKey'  -Because 'the exactly-once natural key needs LIVE proof, never curation'
        }
    }
}
