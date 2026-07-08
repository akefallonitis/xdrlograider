#Requires -Version 7.4
# P11 OVERLAP SHIP-GATE (FH-4 · re-sequenced to per-category onboarding · SSOT §7 P11 HARD GATE). Every ONBOARDED op
# (present in a manifests/<Portal>/*.psd1) whose catalogue OfficialApiOverlap == 'Likely' MUST carry a manual
# `overlapVerdict` decision in the portal curation.json before it ships. The Get-OfficialApiOverlap PATH-heuristic
# OVER-flags genuine portal-internal telemetry on a shared path-stem (e.g. /recommendations, /vulnerabilities, /machines);
# the verdict is the operator's per-category "validated manually for value vs official APIs" step. decision=ship => may
# onboard · decision=hold => must NOT be onboarded (and also carry a shipHold). A Likely manifest op with NO verdict FAILS.
# This REPLACES the reverted global auto-hold (b5624a1): the heuristic is too coarse for a Phase-1 global gate, so the
# adjudication is per-op, per-category, recorded as data. RED-demonstrable: delete a verdict for an onboarded Likely op.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:cat  = Get-Content (Join-Path $script:repo 'references/inventory/nodoc-defender-xdr/catalogue.json') -Raw | ConvertFrom-Json
    $script:cur  = Get-Content (Join-Path $script:repo 'references/inventory/nodoc-defender-xdr/curation.json') -Raw | ConvertFrom-Json

    $script:overlap = @{}
    foreach ($op in $script:cat.Operations) { $script:overlap[[string]$op.OperationId] = [string]$op.OfficialApiOverlap }

    $script:verdict = @{}
    if ($script:cur.PSObject.Properties.Name -contains 'overlapVerdict') {
        foreach ($p in $script:cur.overlapVerdict.PSObject.Properties) {
            if ($p.Name -ne '_doc') { $script:verdict[$p.Name] = [string]$p.Value.decision }
        }
    }

    # ONBOARDED ops = every op's Provenance.OperationId across every Defender manifest (the deployed surface).
    $script:onboarded = @()
    $mdir = Join-Path $script:repo 'manifests/Defender'
    if (Test-Path $mdir) {
        foreach ($f in (Get-ChildItem $mdir -Filter '*.psd1' -ErrorAction SilentlyContinue)) {
            $m = Import-PowerShellDataFile -LiteralPath $f.FullName
            foreach ($op in @($m.Operations)) {
                if ($op.Provenance -and $op.Provenance.OperationId) { $script:onboarded += [string]$op.Provenance.OperationId }
            }
        }
    }
    $script:onboarded = @($script:onboarded | Sort-Object -Unique)
}

Describe 'P11 overlap ship-gate · onboarded OfficialApiOverlap=Likely ⇒ manual overlapVerdict (SSOT HARD GATE)' {
    It 'discovers onboarded ops (the gate is not vacuous)' {
        $script:onboarded.Count | Should -BeGreaterThan 0
    }
    It 'every onboarded op with catalogue overlap=Likely has an overlapVerdict decision in curation' {
        $missing = @($script:onboarded | Where-Object { $script:overlap[$_] -eq 'Likely' -and -not $script:verdict.ContainsKey($_) })
        $missing | Should -BeNullOrEmpty -Because "these ONBOARDED overlap=Likely ops ship without a manual value-vs-official-API verdict (P11 HARD GATE): $($missing -join ', ')"
    }
    It 'no overlapVerdict decision=hold op is onboarded (a hold must never ship)' {
        $bad = @($script:onboarded | Where-Object { $script:verdict[$_] -eq 'hold' })
        $bad | Should -BeNullOrEmpty -Because "overlapVerdict=hold but present in a manifest (contradiction · also add a shipHold): $($bad -join ', ')"
    }
    It 'every overlapVerdict decision is ship|hold (no typo / unknown verdict)' {
        # Consume the ONE guarded $script:verdict map (BeforeAll · absence-checked at line 20). Re-accessing the raw
        # $script:cur.overlapVerdict when the key is ABSENT yields a phantom $null property ($null.PSObject.Properties
        # → one ghost item, empty .Name, null .decision → [string]$null='' counts as a "bad" verdict). Empty map ⇒
        # vacuous pass (no verdicts to validate); populated map ⇒ each decision must be ship|hold. Generic to all cases.
        $bad = @($script:verdict.GetEnumerator() | Where-Object { $_.Value -notin @('ship','hold') })
        @($bad).Count | Should -Be 0 -Because "overlapVerdict decisions must be 'ship' or 'hold': $(($bad | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    }
    It 'every overlapVerdict key is a real catalogue OperationId (no stale / typo key)' {
        $unknown = @($script:verdict.Keys | Where-Object { -not $script:overlap.ContainsKey($_) })
        $unknown | Should -BeNullOrEmpty -Because "overlapVerdict keys not present in the catalogue: $($unknown -join ', ')"
    }
}
