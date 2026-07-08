#Requires -Version 7.4
# Φ4.C prevention (structural gate) — [System.Management.Automation.Language.Parser]::ParseFile is a RAW .NET API that
# does NOT normalize `\`→`/` on Linux (unlike PowerShell cmdlets Get-Content/Resolve-Path/Join-Path). A test that feeds
# ParseFile a path built from a DOUBLE-QUOTED interpolated backslash string (e.g. "$repo\tools\X.ps1") passes on Windows
# but yields a null/empty AST on the Linux CI runner — a Windows-only FALSE-GREEN that slipped 3 Φ4.A tests past the
# local (Windows) gauntlet and only surfaced in CI. The Windows-only gauntlet cannot catch this class; this gate can.
# Rule: every ParseFile path MUST come from Join-Path / Resolve-Path / .FullName (single-quoted Join-Path children are
# fine — Join-Path normalizes). RED pre-fix (the 3 Φ4.A tests were offenders).

Describe 'Φ4.C · ParseFile paths are cross-platform (no double-quoted backslash strings)' {
    It 'no *.Tests.ps1 feeds a double-quoted backslash path to [Parser]::ParseFile' {
        $repo = (Resolve-Path "$PSScriptRoot/../../..").Path
        $testRoot = Join-Path $repo 'tests'
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($f in Get-ChildItem $testRoot -Recurse -Filter '*.Tests.ps1') {
            $perr = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$perr)
            if (-not $ast) { continue }
            $calls = $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Member -and $n.Member.Value -eq 'ParseFile'
                }, $true)
            foreach ($c in $calls) {
                $pathArg = @($c.Arguments)[0]
                if (-not $pathArg) { continue }
                # If the path is a variable, resolve it to its same-file assignment RHS text.
                $txt = $pathArg.Extent.Text
                if ($pathArg -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $vn = $pathArg.VariablePath.UserPath -replace '^(script|global|local):', ''
                    $assign = $ast.FindAll({ param($n)
                            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            (($n.Left.VariablePath.UserPath -replace '^(script|global|local):', '') -eq $vn)
                        }, $true) | Select-Object -First 1
                    if ($assign) { $txt = $assign.Right.Extent.Text }
                }
                # Offender ⟺ a double-quoted (interpolated) string segment that contains a backslash.
                if ($txt -match '"[^"]*\\[^"]*"') {
                    $offenders.Add("$($f.Name): ParseFile path $txt — use Join-Path or forward-slash")
                }
            }
        }
        if ($offenders.Count) { Write-Host ("OFFENDERS:`n" + ($offenders -join "`n")) }
        $offenders.Count | Should -Be 0
    }
}
