#Requires -Version 7.4
# Verification-honesty (audit 2026-06-15) · Test-GaReadiness -SkipGauntlet must NOT stamp the gauntlet-subsumed gates
# (C1 + C7/C8/C9) as PASS without running them. The pre-fix branch set Pass=$true ("assuming gauntlet GREEN") -> a
# diagnostic -SkipGauntlet run could yield a GA-CANDIDATE verdict on NEVER-EVALUATED gates (a false-pass). The fix marks
# them NOT-EVALUATED (Pass=$false · Inconclusive) + adds a Blocker, so a -SkipGauntlet run can never be GA-CANDIDATE.
# Source-asserted (the live verdict needs Azure · this guard pins the honesty contract in the code, like the deploy-
# assembler tokenizer guard).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:src  = Get-Content (Join-Path $script:repo 'tools\Test-GaReadiness.ps1') -Raw
    # Isolate the -SkipGauntlet branch body (from `if ($SkipGauntlet.IsPresent) {` to the matching `} else {`).
    $m = [regex]::Match($script:src, '(?s)if \(\$SkipGauntlet\.IsPresent\) \{(.*?)\n\} else \{')
    $script:skipBranch = if ($m.Success) { $m.Groups[1].Value } else { '' }
}

Describe 'Verification-honesty · Test-GaReadiness -SkipGauntlet never false-passes the offline gates' {
    It 'the -SkipGauntlet branch is present + isolatable' {
        $script:skipBranch | Should -Not -BeNullOrEmpty
    }
    It 'does NOT stamp C1_Gauntlet as Pass = $true (the false-pass is gone)' {
        $script:skipBranch | Should -Not -Match 'C1_Gauntlet\s*=\s*@\{\s*Pass\s*=\s*\$true'
    }
    It 'does NOT stamp the C1-subsumed gates (C7/C8/C9) as Pass = $true' {
        foreach ($c in @('C7_MultiAxis', 'C8_ManifestHealth', 'C9_PublicSurface')) {
            $script:skipBranch | Should -Not -Match ($c + '\s*=\s*@\{\s*Pass\s*=\s*\$true')
        }
    }
    It 'marks the skipped gates NOT-EVALUATED (Pass=$false) and records a GA Blocker (cannot be GA-CANDIDATE)' {
        $script:skipBranch | Should -Match 'C1_Gauntlet\s*=\s*@\{\s*Pass\s*=\s*\$false'
        $script:skipBranch | Should -Match '\$report\.Blockers\s*\+='
        $script:skipBranch | Should -Match 'NOT EVALUATED|not GA-assessable'
    }
}

# ── V-M5 (2026-06-18 · coupled to Verify-DeployedConnector V-M4) · C6 (and C3) read the per-op D8 gate verdicts from
#    the Sustain-run JSON. Under -AllOps the keys are now "D8f[<opKey>]" etc. (per-op-tagged) — the old un-suffixed
#    lookup ($parsed.Gates.D8f) MISSED → C6 mis-evaluated. C6 must match every gate key by ^D8[cfgh](\[.*\])?$ and
#    require ALL to PASS, AND aggregate across ALL Sustain outputs (not just the last) so a fail in ANY window fails.
Describe 'V-M5 · Test-GaReadiness C6/C3 are -AllOps-aware (suffixed gate keys) and aggregate across ALL Sustain runs' {
    BeforeAll {
        $script:src = Get-Content (Join-Path (Resolve-Path "$PSScriptRoot\..\..\..").Path 'tools\Test-GaReadiness.ps1') -Raw
        # Isolate the C6 block (from its header to the C6 blocker append).
        $script:c6 = [regex]::Match($script:src, '(?s)C6 . D8 data-plane-context sub-gates.*?C6 . D8 data-plane-context FAIL').Value
        # Isolate the C3 block.
        $script:c3 = [regex]::Match($script:src, '(?s)C3 . 0 AppExceptions.*?C3 . AppExceptions check failed').Value
    }
    It 'C6 matches D8 gate keys by the suffix-tolerant regex ^D8[cfgh](\[.*\])?$ (handles D8f AND D8f[op])' {
        $script:c6 | Should -Not -BeNullOrEmpty
        $script:c6 | Should -Match '\^D8\[cfgh\]\(\\\[\.\*\\\]\)\?\$'
        # it no longer reads the fixed un-suffixed keys via $parsed.Gates.D8f (the bug that missed -AllOps keys)
        $script:c6 | Should -Not -Match '\$parsed\.Gates\.\$g'
    }
    It 'C6 requires ALL matching D8 gates to PASS and is honest on absence (no D8 gate present → real miss, not green)' {
        $script:c6 | Should -Match '\$c6AllPass'
        $script:c6 | Should -Match '\$c6AnyD8Gate'
        # pass only if at least one run carried D8 gates AND all matching gates passed
        $script:c6 | Should -Match '\$c6Pass = \$c6AnyD8Gate -and \$c6AllPass'
    }
    It 'C6 aggregates across ALL Sustain runs (iterates parsedSustains · NOT Select-Object -Last 1)' {
        $script:c6 | Should -Match 'for \(\$si = 0; \$si -lt \$script:parsedSustains\.Count'
        $script:c6 | Should -Not -Match 'Select-Object -Last 1'
    }
    It 'C3 also aggregates AppExceptions across ALL Sustain runs (a fail in ANY window fails C3 · not just the last)' {
        $script:c3 | Should -Not -BeNullOrEmpty
        $script:c3 | Should -Match 'for \(\$si = 0; \$si -lt \$script:parsedSustains\.Count'
        $script:c3 | Should -Match '\$c3AllPass'
        $script:c3 | Should -Match '\$c3Pass = \$c3AnyParsed -and \$c3AllPass'
        $script:c3 | Should -Not -Match 'Select-Object -Last 1'
    }
    It 'the shared parsedSustains cache parses EVERY sustain output (joining string[] line-splits before ConvertFrom-Json)' {
        $script:src | Should -Match '\$script:parsedSustains = @\(\)'
        $script:src | Should -Match 'foreach \(\$out in \$sustainOutputs\)'
        $script:src | Should -Match 'ConvertFrom-Json'
    }
    It 'C2 forwards -AllOps to each Sustain run (so the per-op suffixed keys C6 matches are actually produced)' {
        # consistency check the prompt called for: C6 must be consistent with how C2 drives the Sustain runs.
        $script:src | Should -Match "if \(\`$AllOps\.IsPresent\) \{ \`$verifyArgs \+= '-AllOps' \}"
    }
}

# ── 2026-07-05 · C2/C3 Sustain-capture robustness (live-verified defect · Confirm-PostDeploy ga-readiness) ──
#   Two coupled source defects made the ga-readiness gate structurally-unpassable + fragile:
#   (1) FLATTEN TRAP: `$sustainOutputs += $verifyJson` where $verifyJson is a multi-line string[] (pwsh line-split of
#       `& pwsh -File verify 2>&1`) FLATTENS every LINE into a separate array element -> C3/C6 parse each single line
#       as a whole-run JSON -> "runN: unparseable Verify output" for all N lines. Fix: `+= ,$verifyJson` (comma op).
#   (2) MIXED-CAPTURE: 2>&1 merges Verify's stderr/warning lines into the JSON capture; a bare `$joined | ConvertFrom-Json`
#       fails on the first warning line. Fix: extract the JSON object (first '{' .. last '}') before parsing.
#   (3) BARE-STRICT FRAGILITY: a bare single strict Sustain counted a transient exit-1 (INCONCLUSIVE ingest-lag, NOT
#       a defect) as a hard fail -> the N-consecutive gate was fragile. Fix: retry-on-exit-1 (settle+re-poll); exit 2
#       (real defect) never retries; a PERSISTENT inconclusive still fails (retry, not tolerate/mask).
Describe '2026-07-05 · Test-GaReadiness C2/C3 Sustain capture is flatten-safe, mixed-output-safe, and transient-robust' {
    BeforeAll {
        $script:src = Get-Content (Join-Path (Resolve-Path "$PSScriptRoot\..\..\..").Path 'tools\Test-GaReadiness.ps1') -Raw
    }
    It 'C2 preserves each run output as ONE element via the comma operator (no array-flatten trap)' {
        $script:src | Should -Match '\$sustainOutputs \+= ,\$verifyJson'
        # the bare flatten form must be gone
        $script:src | Should -Not -Match '\$sustainOutputs \+= \$verifyJson'
    }
    It 'the comma operator genuinely prevents the flatten (PowerShell semantics · the actual fix)' {
        $multiLine = @('line-1 warning', '{ "Gates": {} }', 'line-3 warning')  # a run output as string[]
        $flattened = @(); $flattened += $multiLine                              # BARE += : flattens
        $preserved = @(); $preserved += ,$multiLine                             # comma op : one element
        $flattened.Count   | Should -Be 3      # the bug: 3 pseudo-runs (one per line)
        $preserved.Count   | Should -Be 1      # the fix: 1 run, still a string[]
        $preserved[0].Count | Should -Be 3     # and that 1 element is still the intact 3-line run output
    }
    It 'C3/C6 parse extracts the JSON object from mixed (warning + JSON) capture' {
        $script:src | Should -Match '\$braceStart = \$joined\.IndexOf\(.\{.\)'
        $script:src | Should -Match '\$braceEnd = \$joined\.LastIndexOf\(.\}.\)'
        $script:src | Should -Match '\$joined\.Substring\(\$braceStart, \$braceEnd - \$braceStart \+ 1\) \| ConvertFrom-Json'
    }
    It 'the brace-extraction genuinely parses a mixed capture that a bare ConvertFrom-Json would reject' {
        $mixed = @(
            'WARNING: op X Cadence unparseable - D7 INCONCLUSIVE',
            '{',
            '  "Gates": { "AppExceptions": { "Pass": true, "Detail": "0 exceptions" } }',
            '}',
            'VERBOSE: done'
        ) -join "`n"
        # a bare parse of the whole mixed blob must fail (documents WHY extraction is needed)...
        { $mixed | ConvertFrom-Json -ErrorAction Stop } | Should -Throw
        # ...while first-{ .. last-} extraction parses cleanly and exposes the gate C3 reads.
        $bs = $mixed.IndexOf('{'); $be = $mixed.LastIndexOf('}')
        $obj = $mixed.Substring($bs, $be - $bs + 1) | ConvertFrom-Json
        $obj.Gates.AppExceptions.Pass | Should -BeTrue
    }
    It 'C2 retries ONLY an INCONCLUSIVE (exit 1) Sustain and never retries exit 2 (real defect) or exit 0' {
        $script:src | Should -Match 'for \(\$attempt = 0; \$attempt -le \$SustainInconclusiveRetries'
        $script:src | Should -Match 'if \(\$verifyExit -ne 1\) \{ break \}'   # 0/2/3 are decisive
        $script:src | Should -Match '\[int\] \$SustainInconclusiveRetries'
    }
}
