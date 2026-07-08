#Requires -Version 7.4
# Anti-drift gate · the pre-push gauntlet's TOTAL axis count is the count of `Test-Axis` registrations in
# Run-PrePushGauntlet.ps1 — the SINGLE source of truth. History: the count drifted to THREE values at once (30 in
# Test-GaReadiness/Onboard/Install-GitHooks · 34 in Hook-PrePush · 35 in ci.yml/release.yml/docs) because every
# reference hardcoded its OWN number. The cure: the runtime summary prints a DERIVED count ($pass+$err), the
# operator-facing prose is number-FREE, and this gate DERIVES the real count from the axis registrations and fails if
# (a) the gauntlet header / ci.yml / release.yml don't reference it, or (b) ANY tracked tool / doc / workflow
# re-introduces a stale hardcoded total (30 or 34). The derivation can NOT be fooled by a literal — it counts the axes.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $gauntlet = Join-Path $script:repo 'tools/Run-PrePushGauntlet.ps1'
    $glines = Get-Content $gauntlet
    # SINGLE SOURCE OF TRUTH: the real axis count == number of Test-Axis registrations.
    $script:realN = @($glines | Where-Object { $_ -match "^Test-Axis '" }).Count
    # WHICH axes (not just how many): the leading number of every Test-Axis registration ('Test-Axis 'NN · ...'). The
    # count alone cannot detect a silent renumber / drop / duplicate that keeps the total the same.
    $script:axisNums = @($glines | Where-Object { $_ -match "^Test-Axis '\d+" } | ForEach-Object { [int]([regex]::Match($_, "^Test-Axis '(\d+)").Groups[1].Value) })
    $script:hdr = ($glines | Select-Object -First 6) -join "`n"
    $script:ci = Get-Content (Join-Path $script:repo '.github/workflows/ci.yml') -Raw
    $script:rel = Get-Content (Join-Path $script:repo '.github/workflows/release.yml') -Raw
    # Every operator/contributor-facing surface that could re-introduce a hardcoded gauntlet total.
    $roots = @(
        @{ Path = Join-Path $script:repo 'tools';             Filter = '*.ps1' }
        @{ Path = Join-Path $script:repo 'docs';              Filter = '*.md'  }
        @{ Path = Join-Path $script:repo '.github/workflows'; Filter = '*.yml' }
    )
    $script:scan = foreach ($r in $roots) {
        if (Test-Path $r.Path) {
            Get-ChildItem $r.Path -Recurse -File -Filter $r.Filter |
                ForEach-Object { [pscustomobject]@{ Name = $_.Name; Text = (Get-Content $_.FullName -Raw) } }
        }
    }
}

Describe 'anti-drift · gauntlet axis-count is derived + referenced consistently' {
    It 'the gauntlet registers at least one Test-Axis (derivation is sound)' {
        $script:realN | Should -BeGreaterThan 0
    }
    It 'the axis NUMBERS are exactly the contiguous set 1..N (no gap / drop / duplicate · count alone cannot hide a renumber)' {
        # Every Test-Axis registration must lead with a number, the numbers must be unique, and they must form 1..N —
        # so an axis cannot be silently removed/renumbered/duplicated while the TOTAL count stays put (the §35.8 trap,
        # applied to the axis SET itself).
        @($script:axisNums).Count | Should -Be $script:realN -Because 'every Test-Axis registration must lead with its axis number'
        (@($script:axisNums) | Sort-Object -Unique).Count | Should -Be $script:realN -Because "duplicate axis number(s): $((@($script:axisNums) | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name) -join ',')"
        Compare-Object (@($script:axisNums) | Sort-Object) (1..$script:realN) -SyncWindow 0 | Should -BeNullOrEmpty -Because "axis numbers must be the contiguous set 1..$($script:realN) (a gap means an axis was silently dropped or replaced)"
    }
    It 'the gauntlet header declares the real (derived) axis count' {
        $script:hdr | Should -Match "$($script:realN) axes"
    }
    It 'ci.yml references the gauntlet by its ACTUAL (derived) total axis count' {
        $script:ci | Should -Match "$($script:realN)[- ]ax"
    }
    It 'release.yml references the gauntlet by its ACTUAL (derived) total axis count' {
        $script:rel | Should -Match "$($script:realN)[- ]ax"
    }
    It 'no tracked tool / doc / workflow re-introduces a stale hardcoded gauntlet total (30 or 34)' {
        $bad = @($script:scan | Where-Object { $_.Text -match '(30|34)[- ]ax(is|es)' })
        $names = ($bad | ForEach-Object { $_.Name }) -join ', '
        $bad.Count | Should -Be 0 -Because "stale gauntlet total still present in: $names"
    }
}
