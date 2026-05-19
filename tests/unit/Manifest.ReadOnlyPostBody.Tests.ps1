#Requires -Module Pester
# Π11 PHASE2a · ReadOnlyPost endpoints have BodyTemplate populated for v0.2.0 active polling.
# 86 POST telemetry endpoints catalogued · 80 successfully matched against nodoc Postman collections.
# 6 unmatched have path-params ({subscriptionId}/{OutbreakId}/{workspaceName}) that prevent exact match.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'manifests/defender.psd1'
    $content = Get-Content -Raw -LiteralPath $script:ManifestPath
    $script:Manifest = & ([scriptblock]::Create($content))
    $script:Entries = @($script:Manifest.Entries)
    $script:ReadOnlyPost = @($script:Entries | Where-Object { $_.ProbeMode -eq 'ReadOnlyPost' })
    $script:WithBody = @($script:ReadOnlyPost | Where-Object { $_.ContainsKey('BodyTemplate') -and $_.BodyTemplate })
}

Describe 'Π11 PHASE2a · ReadOnlyPost manifest catalogue + BodyTemplate population' -Tag 'tier1','unit','manifest' {

    It 'manifest has exactly 86 ReadOnlyPost entries (POST telemetry catalogue locked)' {
        $script:ReadOnlyPost.Count | Should -Be 86
    }

    It 'at least 80 ReadOnlyPost entries have BodyTemplate populated (Postman match rate >= 93%)' {
        $script:WithBody.Count | Should -BeGreaterOrEqual 80
    }

    It 'every BodyTemplate value parses as valid JSON' {
        foreach ($e in $script:WithBody) {
            { $e.BodyTemplate | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw -Because "EntryKey=$($e.EntryKey) BodyTemplate not valid JSON"
        }
    }

    It 'ReadOnlyPost entries with Method=POST are 100% of the set (no misclassification)' {
        $nonPost = @($script:ReadOnlyPost | Where-Object { $_.Method -ne 'POST' })
        $nonPost.Count | Should -Be 0
    }

    It 'no ReadOnlyPost entry is in the wholesale-drop set (Memory Rule 2 invariant)' {
        # AdvancedHunting / AlertsIncidents / LiveResponse / Graph-proxy must never be probe-candidates.
        $excludedSubAreas = @('AdvancedHunting','AlertsIncidents','LiveResponse')
        $violations = @($script:ReadOnlyPost | Where-Object { $_.SubArea -in $excludedSubAreas })
        $violations.Count | Should -Be 0
    }
}

Describe 'Π11 ProbeMode field invariant across all 519 entries' -Tag 'tier1','unit','manifest' {

    It 'every manifest entry has a ProbeMode field' {
        $missing = @($script:Entries | Where-Object { -not $_.ContainsKey('ProbeMode') })
        $missing.Count | Should -Be 0
    }

    It 'ProbeMode values are in the locked set (6 values · ITER5 expansion)' {
        # ITER5 · added 3 new ProbeMode values to honestly scope what v0.1.0 active-polls:
        #   PathParamGated   = path has {xxx} placeholder we don't fill (entity IDs etc.)
        #   SubPortalAuth    = different sub-portal cookie scope (m365appprotection · mdi · etc)
        #   RequiresEntity   = entity-pivot · needs entity input (v0.3.0 cross-entity scope)
        $allowed = @('Probe','ReadOnlyPost','Excluded','PathParamGated','SubPortalAuth','RequiresEntity')
        $invalid = @($script:Entries | Where-Object { $_.ProbeMode -notin $allowed })
        $invalid.Count | Should -Be 0
    }

    It 'All ProbeMode counts sum to 519 (no orphans across 6 values)' {
        $probe   = @($script:Entries | Where-Object { $_.ProbeMode -eq 'Probe'         }).Count
        $rop     = @($script:Entries | Where-Object { $_.ProbeMode -eq 'ReadOnlyPost'  }).Count
        $exc     = @($script:Entries | Where-Object { $_.ProbeMode -eq 'Excluded'      }).Count
        $ppg     = @($script:Entries | Where-Object { $_.ProbeMode -eq 'PathParamGated'}).Count
        $spa     = @($script:Entries | Where-Object { $_.ProbeMode -eq 'SubPortalAuth' }).Count
        $req     = @($script:Entries | Where-Object { $_.ProbeMode -eq 'RequiresEntity'}).Count
        ($probe + $rop + $exc + $ppg + $spa + $req) | Should -Be 519
    }

    It 'ITER5+P7 reclassifications honest · ≥80 entries deferred from Probe (PathParamGated + SubPortalAuth + RequiresEntity)' {
        # ITER5 reclassified 117 entries · P7 empirical lift moved 19 back to Probe (mdi/identity + mdc + radius that work with sccauth proxy-forwarding)
        # Remaining deferrals: ~48 PathParamGated + ~24 SubPortalAuth + 26 RequiresEntity = ~98 · still operator-honest.
        $reclassified = @($script:Entries | Where-Object { $_.ProbeMode -in @('PathParamGated','SubPortalAuth','RequiresEntity') })
        $reclassified.Count | Should -BeGreaterOrEqual 80
    }
}
