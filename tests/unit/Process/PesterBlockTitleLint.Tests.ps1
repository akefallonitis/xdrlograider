#Requires -Version 7.4
# FH-9 · Pester BLOCK-TITLE LINT (the run-phase `$-` mis-tokenize class). A Describe/Context/It title containing the
# `<-` redirection-shaped token (e.g. the bidirectional `<->`) makes Pester 5.x's run-phase synthetic scriptblock
# mis-tokenize at the block NAME → a spurious `CommandNotFoundException: The term '$-' is not recognized ... at
# <ScriptBlock>, <No file>:1` that fails the whole block with NO relation to the test body. Proven by bisection: a
# scaffold whose Describe name is `... manifest <-> ARM ...` fails 3/3 with that `$-` error; the same name with `to`
# or the Unicode `↔` passes. The generated replay-scaffold template emitted `<->`, so every newly-scaffolded category
# silently broke (the hand-written Operations scaffold survived only because it used `↔`). This is a SILENT class —
# it only surfaces at run phase, never at parse. This guard pins it for every test, hand-written or generated.
# NOTE: the single arrow `->` is FINE and used widely (it parses + runs); ONLY the `<`-led redirection form is banned.

BeforeAll {
    $script:repo  = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:files = @(Get-ChildItem (Join-Path $script:repo 'tests') -Recurse -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue)
}

Describe 'FH-9 · Pester block titles free of the left-arrow redirection token (run-phase mis-tokenize class)' {
    It 'discovers the test corpus (not vacuous)' {
        $script:files.Count | Should -BeGreaterThan 0
    }
    It 'no Describe/Context/It/Before or After title carries the left-arrow redirection token' {
        $offenders = @()
        foreach ($f in $script:files) {
            $ln = 0
            foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                $ln++
                # a block-declaration line (keyword at indent) whose title carries the `<-` redirection form
                if ($line -match "^\s*(Describe|Context|It|BeforeAll|BeforeEach|AfterAll|AfterEach)\b" -and $line -match '<-') {
                    $offenders += ("{0}:{1}" -f $f.Name, $ln)
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because ("these Pester block titles contain '<-' (breaks the run phase with a spurious `$-`); use 'to' or the Unicode arrow: " + ($offenders -join ', '))
    }
}
