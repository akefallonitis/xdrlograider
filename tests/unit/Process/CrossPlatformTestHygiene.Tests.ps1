#Requires -Version 7.4
# METHODOLOGY HARDENING (the junction lesson · 2026-06-14). The LOCAL pre-push gauntlet runs on Windows, so a
# Windows-ONLY filesystem construct in a test passes the local hook but FAILS the ubuntu CI runner (postpush) — a
# structural green-on-Windows / red-on-Linux gap (lived: ManifestShipGates `New-Item -ItemType Junction`). This lint
# scans the test tree for the junction class unless it is $IsWindows-guarded, so the PREPUSH gate catches the
# cross-platform failure mode BEFORE the push, not only after it on CI.

Describe 'Methodology · cross-platform test hygiene' {
    BeforeAll {
        $script:repo      = (Resolve-Path "$PSScriptRoot/../../..").Path
        $script:testFiles = Get-ChildItem (Join-Path $script:repo 'tests') -Recurse -Filter *.ps1 -File
    }

    It 'no `-ItemType Junction` without an $IsWindows guard (junctions are Windows-only — SymbolicLink on Linux)' {
        $offenders = @()
        foreach ($f in $script:testFiles) {
            $lines = @(Get-Content $f.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i].TrimStart().StartsWith('#')) { continue }   # prose/comment mentions are not the construct
                # the LITERAL -ItemType Junction (the Windows-only usage); the guarded pattern uses -ItemType $linkType
                if ($lines[$i] -match '-ItemType\s+Junction\b') {
                    # GUARDED = $IsWindows or a $linkType selector within the 4 preceding lines (the cross-platform pattern)
                    $ctx = ($lines[[Math]::Max(0, $i - 4)..$i] -join "`n")
                    if ($ctx -notmatch '\$IsWindows' -and $ctx -notmatch '\$linkType') { $offenders += "$($f.Name):$($i + 1)" }
                }
            }
        }
        ($offenders -join ', ') | Should -BeNullOrEmpty -Because 'a Windows-only Junction must be $IsWindows-conditional (SymbolicLink on the ubuntu CI runner) — else green-on-Windows, red-on-CI'
    }
}
