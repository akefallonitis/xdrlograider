#Requires -Version 7.4
# T4-PROJ (reaudit 2026-06-12 · operator-caught) · PROJECTION FIDELITY. An op whose LIVE capture was EMPTY (no rows
# on the lab tenant) fell through the MERGE waterfall to the OpenAPI/Postman SYNTHETIC schema, which is camelCase —
# and that casing is WRONG for the Action Center endpoint family (the live API is PascalCase, proven by GetHistory's
# real capture: ActionStatus/DecidedBy/EndTime/EntityType). The parser's JSONPath resolve is case-SENSITIVE, so
# camelCase paths null every typed column at ingest (the "green-but-null" class · data still safe in RawJson). Two
# defects: (1) Build-Catalogue stored ProjectionTier='live' while DISCARDING the real $capTier (openapi/postman) —
# the lie that hid the class from every gate; (2) no mechanism let an empty-capture op inherit a live-proven
# schema-sibling's projection. Fix: ProjectionTier=$capTier (honest) + a projectionAlias curation seam (GetPending
# inherits GetHistory's live PascalCase projection — DOCUMENTED schema-sibling, real live evidence, NOT fabrication).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:cat = Get-Content (Join-Path $repo 'references\inventory\nodoc-defender-xdr\catalogue.json') -Raw | ConvertFrom-Json
    $script:ops = $script:cat.Operations
    function Get-Paths($op) { @($op.ProjectionMap.PSObject.Properties | ForEach-Object { [string]$_.Value }) }
    # a JSONPath whose first key segment starts lowercase = camelCase ($.actionId, $.status) — the wrong-cased class.
    # -cmatch (CASE-SENSITIVE) is mandatory: a plain -match treats [a-z] case-insensitively and would falsely flag PascalCase.
    function Test-AnyCamel($paths) { @($paths | Where-Object { $_ -cmatch '^\$\.[a-z]' }).Count -gt 0 }
}

Describe 'T4-PROJ · GetPending inherits GetHistory live PascalCase projection (schema-sibling consolidation)' {
    It 'GetPending ProjectionMap == GetHistory ProjectionMap (same keys + paths · one consolidated Action Center projection)' {
        $gh = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetHistory' }
        $gp = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetPending' }
        $ghMap = @{}; $gh.ProjectionMap.PSObject.Properties | ForEach-Object { $ghMap[$_.Name] = [string]$_.Value }
        $gpMap = @{}; $gp.ProjectionMap.PSObject.Properties | ForEach-Object { $gpMap[$_.Name] = [string]$_.Value }
        ($gpMap.Keys | Sort-Object) -join ',' | Should -Be (($ghMap.Keys | Sort-Object) -join ',') -Because 'pending + historical share the Action[] schema → one projection'
        foreach ($k in $ghMap.Keys) { $gpMap[$k] | Should -Be $ghMap[$k] -Because "path for $k must match GetHistory" }
    }
    It 'GetPending has ZERO camelCase paths (the live API is PascalCase · case-sensitive parser)' {
        $gp = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetPending' }
        (Test-AnyCamel (Get-Paths $gp)) | Should -BeFalse -Because 'camelCase paths null every typed column at ingest'
    }
    It 'GetPending records honest provenance (ProjectionTier=live-sibling, not the old live lie)' {
        $gp = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetPending' }
        $gp.ProjectionTier | Should -Be 'live-sibling'
    }
}

Describe 'T4-PROJ · ProjectionTier honesty (the discarded $capTier lie is gone)' {
    # camelCase is NOT inherently wrong — it is a PER-ENDPOINT fact of the live API (8 shipped ops have a non-empty
    # live capture whose REAL fields are camelCase; their camelCase projection correctly matches + populates). The
    # LIE was narrower: an op whose live capture was EMPTY fell back to the spec synthetic schema yet was stamped
    # ProjectionTier='live'. The $capTier fix makes that structurally impossible — such ops now read openapi/postman.
    It 'every Shipped op with typed columns records a real ProjectionTier from the allowed set' {
        foreach ($o in @($script:ops | Where-Object { $_.Shipped -and (@($_.ProjectionMap.PSObject.Properties).Count -gt 0) })) {
            $o.ProjectionTier | Should -BeIn @('live','live-sibling','openapi','postman') -Because $o.OperationId
        }
    }
    It 'the spec-fallback tiers are now VISIBLE on shipped ops (the empty-capture lie that stamped them all live is gone)' {
        $tiers = @($script:ops | Where-Object { $_.Shipped -and (@($_.ProjectionMap.PSObject.Properties).Count -gt 0) } | ForEach-Object { [string]$_.ProjectionTier } | Sort-Object -Unique)
        # before the $capTier fix, every empty-capture op was mislabeled 'live'; honesty means openapi/postman appear
        ($tiers -contains 'openapi') -or ($tiers -contains 'postman') | Should -BeTrue -Because 'spec-derived projections must be labeled by their true source, not live'
    }
    It 'a known empty-capture op (ExposureManagement.ListPostureOversightUpdates) is no longer mislabeled live' {
        $o = $script:ops | Where-Object { $_.OperationId -eq 'ExposureManagement.ListPostureOversightUpdates' }
        if ($o -and $o.Shipped -and (@($o.ProjectionMap.PSObject.Properties).Count -gt 0)) {
            $o.ProjectionTier | Should -Not -Be 'live' -Because 'its live capture was empty (results:[]) — the projection is spec/wrapper-derived, not live'
        }
    }
}

Describe 'T4-PROJ · PILOT STABILITY · GetHistory itself unchanged (the live-proven projection is the source of truth)' {
    It 'GetHistory keeps its 19-field PascalCase live projection' {
        $gh = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetHistory' }
        $gh.ProjectionTier | Should -Be 'live'
        (Test-AnyCamel (Get-Paths $gh)) | Should -BeFalse
        @($gh.ProjectionMap.PSObject.Properties).Count | Should -BeGreaterThan 15
    }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# §4.B FIX-2 · CATALOGUE⇄MANIFEST PROJECTION PARITY (the missed axis) — the structural gate for the
# empty-ProjectionMap-ships-RawJson-only class. A stale dev-tools/.generated manifest once carried GMTE with
# ProjectionMap=@{} while the catalogue had the full 25-key map → that op shipped RawJson-only (every typed column
# NULL) without any gate going red. This gate makes the divergence UN-SHIPPABLE: for EVERY catalogue op the manifest
# generator SHIPS (Shipped=$true) that carries a non-empty ProjectionMap, the FRESHLY Generate-Manifest'd manifest
# MUST carry the SAME non-empty ProjectionMap (same key set). It FAILS on any empty-map / dropped-key divergence.
# Join key = Provenance.OperationId (stable · immune to the OperationKey within-category disambiguation prefix).
# ════════════════════════════════════════════════════════════════════════════════════════════════
Describe '§4.B FIX-2 · catalogue⇄manifest ProjectionMap parity (a non-empty catalogue projection MUST survive into the manifest)' {
    BeforeAll {
        $script:repo2 = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        Import-Module (Join-Path $script:repo2 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking -ErrorAction Stop
        $cat2 = Get-Content (Join-Path $script:repo2 'references\inventory\nodoc-defender-xdr\catalogue.json') -Raw | ConvertFrom-Json
        # The universe Generate-Manifest emits a projection for: Shipped ops with a non-empty catalogue ProjectionMap.
        $script:shippedProjOps = @($cat2.Operations | Where-Object {
            $_.Shipped -eq $true -and (@($_.ProjectionMap.PSObject.Properties).Count -gt 0)
        })
        # Regenerate the manifest ONCE per category (tokenized -Group); index emitted ProjectionMap key-sets by the
        # stable Provenance.OperationId. A regen failure for a category records an empty index → its ops fail loudly.
        $script:gen2 = Join-Path $script:repo2 'dev-tools\Generate-Manifest.ps1'
        $script:manifestProjByOpId = @{}   # OperationId -> @{ Keys=[string[]]; Category=<group> }
        $cats = @($script:shippedProjOps | ForEach-Object { [string]$_.Category } | Sort-Object -Unique)
        foreach ($grp in $cats) {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-projparity-" + [Guid]::NewGuid().ToString('N') + ".psd1")
            try {
                & pwsh -NoProfile -File $script:gen2 -Portal Defender -Group $grp -OutPath $tmp *> $null
                if (Test-Path $tmp) {
                    $m = Import-PowerShellDataFile $tmp
                    foreach ($mo in @($m.Operations)) {
                        $oid = [string]$mo.Provenance.OperationId
                        if ([string]::IsNullOrEmpty($oid)) { continue }
                        $script:manifestProjByOpId[$oid] = @{
                            Keys     = @($mo.ProjectionMap.Keys | ForEach-Object { [string]$_ })
                            Category = $grp
                        }
                    }
                }
            } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
        }
    }

    It 'the catalogue has shipped ops carrying a non-empty ProjectionMap (the universe is non-trivial)' {
        $script:shippedProjOps.Count | Should -BeGreaterThan 0
    }

    It 'EVERY shipped op with a non-empty catalogue ProjectionMap appears in its regenerated manifest with the SAME non-empty projection key-set' {
        $divergences = @()
        foreach ($op in $script:shippedProjOps) {
            $oid = [string]$op.OperationId
            $catKeys = @($op.ProjectionMap.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
            if (-not $script:manifestProjByOpId.ContainsKey($oid)) {
                $divergences += "$oid · MISSING from regenerated manifest (catalogue has $($catKeys.Count) proj keys)"
                continue
            }
            $manKeys = @($script:manifestProjByOpId[$oid].Keys | Sort-Object)
            if ($manKeys.Count -eq 0) {
                $divergences += "$oid · manifest ProjectionMap is EMPTY (@{}) while catalogue has $($catKeys.Count) keys — the RawJson-only-ships class"
            } elseif (($manKeys -join ',') -ne ($catKeys -join ',')) {
                $catOnly = @($catKeys | Where-Object { $_ -notin $manKeys })
                $manOnly = @($manKeys | Where-Object { $_ -notin $catKeys })
                $divergences += "$oid · projection key-set DIVERGES · cat-only=[$($catOnly -join ';')] manifest-only=[$($manOnly -join ';')]"
            }
        }
        $divergences -join "`n" | Should -BeNullOrEmpty -Because 'a catalogue op with a non-empty ProjectionMap that loses (or empties) that projection in the generated manifest ships RawJson-only — every typed column NULL — with no other gate red (the GMTE empty-map class)'
    }

    It 'GMTE specifically keeps its full 25-key projection end-to-end (catalogue == regenerated manifest · the named regression)' {
        $oid = 'EndpointDevices.GetMachineTimelineEvents'
        $cat = $script:shippedProjOps | Where-Object { $_.OperationId -eq $oid }
        $cat | Should -Not -BeNullOrEmpty -Because 'GMTE must be shipped with a non-empty projection'
        @($cat.ProjectionMap.PSObject.Properties).Count | Should -Be 25
        $script:manifestProjByOpId.ContainsKey($oid) | Should -BeTrue
        @($script:manifestProjByOpId[$oid].Keys).Count | Should -Be 25 -Because 'the stale .generated manifest once had GMTE ProjectionMap=@{} (0 keys) → RawJson-only'
    }
}
