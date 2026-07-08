#Requires -Version 7.4
# CONTENT-DEDUP / VALUE GATE (operator 2026-06-09). Cataloguing ship decisions require MANUAL telemetry-level value +
# content-dedup verification, NOT only programmatic — internal portals surface the SAME telemetry from many endpoint
# aspects (export/list/tile/summary/aggregate/filters). Path-level dedup + value-class heuristics catch STRUCTURAL
# mirrors but MISS semantic dups across unrelated paths (e.g. CloudApps.GetSettings == Configuration.GetCloudAppsSettings,
# different categories, no shared stem). This gate computes each shipped op's content-signature (its sorted ProjectionMap
# field-set = the 'what data' fingerprint) and FAILS if any two shipped ops collide WITHOUT a recorded verdict in
# curation.json signatureDecisions — forcing the manual review structurally. confirmLive verdicts are PROVISIONAL until
# the live-pilot proves the row-sets (DoD). Tiny field-sets (<3) ship RawJson-floor and are too thin for a dup signal.

Describe 'Content-dedup gate · no un-reviewed telemetry duplicate ships' {
    BeforeAll {
        function Get-XdrContentSignature {
            param($Op)
            $pm = if ($Op.ProjectionMap) { @($Op.ProjectionMap.PSObject.Properties.Name) } else { @() }
            if ($pm.Count -lt 3) { return $null }   # <3 fields: RawJson-floor op · not a reliable dup signal
            return (($pm | Sort-Object) -join ',')
        }
        $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $cat  = Get-Content "$repo\references\inventory\nodoc-defender-xdr\catalogue.json" -Raw | ConvertFrom-Json
        $script:shipped = @($cat.Operations | Where-Object { $_.Shipped })
        $cur  = Get-Content "$repo\references\inventory\nodoc-defender-xdr\curation.json" -Raw | ConvertFrom-Json
        $script:decisions = @{}
        if ($cur.PSObject.Properties.Name -contains 'signatureDecisions') {
            foreach ($p in $cur.signatureDecisions.PSObject.Properties) { if ($p.Name -ne '_doc') { $script:decisions[$p.Name] = $p.Value } }
        }
        $bySig = @{}
        foreach ($o in $script:shipped) {
            $s = Get-XdrContentSignature $o
            if ($s) { if (-not $bySig.ContainsKey($s)) { $bySig[$s] = @() }; $bySig[$s] += [string]$o.OperationId }
        }
        $script:collisions = @($bySig.Keys | Where-Object { $bySig[$_].Count -gt 1 } | ForEach-Object { ,@($bySig[$_] | Sort-Object) })
        Write-Host "[ContentSignatures] shipped=$($script:shipped.Count) · >=3-field collisions=$($script:collisions.Count) · recorded verdicts=$($script:decisions.Count)"
    }

    It 'every >=3-field content-signature collision among SHIPPED ops carries a recorded manual verdict (no silent double-poll)' {
        foreach ($cluster in $script:collisions) {
            $key = ($cluster -join '|')
            $script:decisions.ContainsKey($key) | Should -BeTrue -Because "shipped ops [$key] share an identical telemetry signature and MUST carry a curation.json signatureDecisions verdict (manual telemetry-level review)"
        }
    }

    It 'every recorded verdict is well-formed (decision in distinct|duplicate|candidate)' {
        foreach ($k in $script:decisions.Keys) {
            $script:decisions[$k].decision | Should -BeIn @('distinct','duplicate','candidate') -Because "verdict '$k'"
        }
    }

    It 'the 2 known Defender candidates are on record (tenant-group · cloud-apps-settings)' {
        $script:decisions.ContainsKey('MultiTenant.GetEffectiveTenantGroup|MultiTenant.ListTenantGroups') | Should -BeTrue
        $script:decisions.ContainsKey('CloudApps.GetSettings|Configuration.GetCloudAppsSettings') | Should -BeTrue
    }

    It 'RED-able · the signature detector actually fires on an identical-but-reordered field-set (not vacuous)' {
        $a    = [pscustomobject]@{ ProjectionMap = [pscustomobject]@{ f1='$.a'; f2='$.b'; f3='$.c' } }
        $b    = [pscustomobject]@{ ProjectionMap = [pscustomobject]@{ f3='$.c'; f1='$.a'; f2='$.b' } }
        $tiny = [pscustomobject]@{ ProjectionMap = [pscustomobject]@{ f1='$.a'; f2='$.b' } }
        (Get-XdrContentSignature $a) | Should -Not -BeNullOrEmpty
        (Get-XdrContentSignature $a) | Should -Be (Get-XdrContentSignature $b) -Because 'order-independent field-set signatures must collide'
        (Get-XdrContentSignature $tiny) | Should -BeNullOrEmpty -Because '<3 fields is below the dup-signal threshold (RawJson-floor)'
    }
}
