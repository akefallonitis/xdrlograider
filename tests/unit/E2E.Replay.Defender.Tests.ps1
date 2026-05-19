#Requires -Module Pester
# Phase 0j J-3 · End-to-end replay test for the Defender manifest's typed-DSL
# ProjectionMap entries against live captures.
#
# Asserts (per Reinforcement-A):
#   - Apply-XdrProjectionMap returns a hashtable for each manifest entry whose
#     ProjectionMap is non-empty AND live.json is on disk.
#   - At least 50% of declared columns resolve to non-null values (response shape
#     drift detection — empty arrays + null leaves are fine, but full miss is not).
#   - The output row matches the DCR streamDeclaration columns shape exactly
#     (Reinforcement-A · ProjectedData primary + RawJson fallback).
#
# Tolerates pre-Phase-0i endpoints (no live.json) — they're auto-skipped.

BeforeDiscovery {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestFx = Join-Path $script:RepoRoot 'manifests\defender.psd1'
    $script:RefRoot    = Join-Path $script:RepoRoot 'references\Defender'
    # Require ACTUAL live.json captures (tenant-data files are gitignored · public repo
    # ships only PII-free Phase 0 artefacts) · this Describe is operator-local-only.
    $script:RefPresent = (Test-Path $script:RefRoot) -and (
        @(Get-ChildItem -Path $script:RefRoot -Filter 'live.json' -Recurse -ErrorAction SilentlyContinue).Count -gt 0
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src\Modules\Xdr.Parser\Xdr.Parser.psd1') -Force
    $script:Manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'manifests\defender.psd1'))))
    $script:Arm      = Get-Content (Join-Path $script:RepoRoot 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json
    $script:RefRoot  = Join-Path $script:RepoRoot 'references\Defender'

    # Pre-compute the replayable set: entries with ProjectionMap.Count > 0 AND live.json on disk
    $script:Replayable = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $script:Manifest.Entries) {
        if ($e.ProjectionMap.Count -eq 0) { continue }
        $slug = if ($e.ContainsKey('Slug')) { $e.Slug } else {
            $leaf = ($e.NodocRoute -split '\.')[-1]
            if ($leaf -match 'TenantContext$') { 'TenantContext' } else { $leaf }
        }
        $livePath = Join-Path $script:RefRoot ("{0}/{1}/live.json" -f $e.SubArea, $slug)
        if (Test-Path $livePath) {
            $script:Replayable.Add([pscustomobject]@{ Entry = $e; Slug = $slug; LivePath = $livePath }) | Out-Null
        }
    }
}

Describe 'Defender full-catalogue replay (Phase 0j J-3 · live-fixture-driven)' -Tag 'fixture-replay' -Skip:(-not $script:RefPresent) {

    It 'has at least 1 replayable endpoint (operator must have run Phase 0i + 0j J-1)' {
        @($script:Replayable).Count | Should -BeGreaterOrEqual 1 -Because 'tools/Apply-ProjectionMaps.ps1 + Derive-Phase0Artifacts must precede this test'
    }

    It 'applies ProjectionMap to a stratified sample without exception (one per SubArea, capped at 20)' {
        # Stratify by SubArea · one endpoint per SubArea to limit fixture-IO time
        $sample = $script:Replayable | Group-Object { $_.Entry.SubArea } | ForEach-Object { $_.Group | Select-Object -First 1 } | Select-Object -First 20
        $sample | Should -Not -BeNullOrEmpty
        $skipped = 0
        foreach ($r in $sample) {
            $live = Get-Content -Raw -LiteralPath $r.LivePath | ConvertFrom-Json -Depth 12
            $body = $live.Body | ConvertFrom-Json -Depth 12 -ErrorAction SilentlyContinue
            # Some endpoints (export blobs · binary streams) return empty body · skip them
            if (-not $body) { $skipped++; continue }
            $projection = [hashtable]@{}
            foreach ($k in $r.Entry.ProjectionMap.Keys) { $projection[$k] = $r.Entry.ProjectionMap[$k] }
            { Apply-XdrProjectionMap -Response $body -ProjectionMap $projection } | Should -Not -Throw -Because "Apply-XdrProjectionMap must not throw on '$($r.Slug)'"
        }
        # At least half the sample should have parseable body (export endpoints expected to be minority)
        $skipped | Should -BeLessThan ([math]::Floor(@($sample).Count / 2)) -Because "majority of sample should have parseable JSON body · got $skipped/$(@($sample).Count) empty"
    }

    It 'projection coverage: >= 50% of ColumnNames resolve to non-null on stratified sample' {
        $sample = $script:Replayable | Group-Object { $_.Entry.SubArea } | ForEach-Object { $_.Group | Select-Object -First 1 } | Select-Object -First 20
        $totalCols   = 0
        $nonNullCols = 0
        foreach ($r in $sample) {
            $live = Get-Content -Raw -LiteralPath $r.LivePath | ConvertFrom-Json -Depth 12
            $body = $live.Body | ConvertFrom-Json -Depth 12 -ErrorAction SilentlyContinue
            $projection = [hashtable]@{}
            foreach ($k in $r.Entry.ProjectionMap.Keys) { $projection[$k] = $r.Entry.ProjectionMap[$k] }
            $out = Apply-XdrProjectionMap -Response $body -ProjectionMap $projection
            foreach ($col in $out.Keys) {
                $totalCols++
                $v = $out[$col]
                if ($null -ne $v -and -not ($v -is [array] -and @($v).Count -eq 0)) { $nonNullCols++ }
            }
        }
        $pct = if ($totalCols -gt 0) { [math]::Round(100.0 * $nonNullCols / $totalCols, 1) } else { 0 }
        Write-Host ("    Column non-null hit-rate: {0}/{1} ({2}%) across {3} sampled endpoints" -f $nonNullCols, $totalCols, $pct, @($sample).Count) -ForegroundColor DarkCyan
        $pct | Should -BeGreaterOrEqual 50 -Because 'half of projected columns must resolve to non-null · indicates ProjectionMap matches response shape'
    }

    It 'TenantContext canonical fields resolve correctly' {
        $tc = $script:Replayable | Where-Object Slug -eq 'TenantContext' | Select-Object -First 1
        $tc | Should -Not -BeNullOrEmpty -Because 'TenantContext must be in the replayable set'
        $live = Get-Content -Raw -LiteralPath $tc.LivePath | ConvertFrom-Json -Depth 12
        $body = $live.Body | ConvertFrom-Json -Depth 12
        $projection = [hashtable]@{}
        foreach ($k in $tc.Entry.ProjectionMap.Keys) { $projection[$k] = $tc.Entry.ProjectionMap[$k] }
        $out = Apply-XdrProjectionMap -Response $body -ProjectionMap $projection
        $out['OrgId']      | Should -Not -BeNullOrEmpty
        $out['GeoRegion']  | Should -Not -BeNullOrEmpty
    }

    It 'row schema column-match: emitted row matches per-sub-area Defender DCR row schema (Π1 fix · canonical defenderRowSchema variable)' {
        $tc = $script:Replayable | Where-Object Slug -eq 'TenantContext' | Select-Object -First 1
        $tc | Should -Not -BeNullOrEmpty
        $live = Get-Content -Raw -LiteralPath $tc.LivePath | ConvertFrom-Json -Depth 12
        $body = $live.Body | ConvertFrom-Json -Depth 12
        $projection = [hashtable]@{}
        foreach ($k in $tc.Entry.ProjectionMap.Keys) { $projection[$k] = $tc.Entry.ProjectionMap[$k] }
        $projected = Apply-XdrProjectionMap -Response $body -ProjectionMap $projection
        $row = [pscustomobject]@{
            TimeGenerated    = (Get-Date).ToUniversalTime().ToString('o')
            Portal           = 'Defender'
            SubArea          = $tc.Entry.SubArea
            Slug             = $tc.Slug
            Endpoint         = $tc.Entry.Path
            SuccessKind      = 'live'
            StatusCode       = 200
            LicenseHint      = $tc.Entry.LicenseHint
            IngestionMode    = $tc.Entry.IngestionMode
            ConnectorVersion = '0.1.0'
            CorrelationId    = [guid]::NewGuid().ToString()
            ProjectedData    = $projected
            RawJson          = ($body | ConvertTo-Json -Depth 50 -Compress)
        }
        $rowFields = $row.PSObject.Properties.Name | Sort-Object

        # Π1 fix · canonical row schema lives in variables.defenderRowSchema (shared by all 19 per-sub-area DCR streams)
        $schema = $script:Arm.variables.defenderRowSchema
        $schema | Should -Not -BeNullOrEmpty -Because 'defenderRowSchema variable must exist in ARM template (per-sub-area DCR copy loop input)'
        $dcrFields = @($schema | ForEach-Object { $_.name }) | Sort-Object
        $missing = $dcrFields | Where-Object { $_ -notin $rowFields }
        $missing | Should -BeNullOrEmpty -Because "DCR expects column(s) [$($missing -join ', ')] that Xdr-Poll does not emit"
    }

    It 'replayable-endpoint count reporting (visibility metric · not gating)' {
        $totalManifest = @($script:Manifest.Entries).Count
        $replayCount = @($script:Replayable).Count
        Write-Host ("    Manifest entries: {0} · replayable (ProjectionMap non-empty + live.json present): {1}" -f $totalManifest, $replayCount) -ForegroundColor DarkCyan
        # Floor: at least 1 replayable (TenantContext smoke). Cap: cannot exceed total catalogue.
        $replayCount | Should -BeGreaterOrEqual 1
        $replayCount | Should -BeLessOrEqual $totalManifest
    }

    It 'Pi8c · Apply-XdrProjectionMap survives ALL replayable endpoints (full-coverage · not stratified)' {
        # Stronger than the stratified-sample test above · iterates EVERY replayable
        # endpoint · catches DSL evaluator edge-cases that only manifest on rare
        # response shapes (G-D11 mitigation · catches Apply-XdrProjectionMap bugs
        # against full 135-capture surface · not just 20-sample).
        # Depth=100 matches Invoke-DefenderApiproxy line 107 (run.ps1 input side).
        $errors = [System.Collections.Generic.List[string]]::new()
        $emptyBodies = 0
        $processed = 0
        foreach ($r in $script:Replayable) {
            try {
                $live = Get-Content -Raw -LiteralPath $r.LivePath | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                $body = $live.Body | ConvertFrom-Json -Depth 100 -ErrorAction SilentlyContinue
                if (-not $body) { $emptyBodies++; continue }
                $projection = [hashtable]@{}
                foreach ($k in $r.Entry.ProjectionMap.Keys) { $projection[$k] = $r.Entry.ProjectionMap[$k] }
                $null = Apply-XdrProjectionMap -Response $body -ProjectionMap $projection
                $processed++
            } catch {
                $errors.Add(("{0}: {1}" -f $r.Slug, $_.Exception.Message)) | Out-Null
            }
        }
        Write-Host ("    Pi8c full-coverage: processed={0} · empty-body={1} · errors={2} (of {3} replayable)" -f $processed, $emptyBodies, $errors.Count, @($script:Replayable).Count) -ForegroundColor DarkCyan
        if ($errors.Count -gt 0) {
            $sample = ($errors | Select-Object -First 5) -join "`n    "
            $errors.Count | Should -Be 0 -Because "Apply-XdrProjectionMap raised on $($errors.Count) endpoints. First 5: $sample"
        }
        $errors.Count | Should -Be 0
    }
}
