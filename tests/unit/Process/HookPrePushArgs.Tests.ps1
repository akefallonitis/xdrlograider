#Requires -Version 7.4
# Φ4.C · the pre-push hook MUST accept git's positional args. git invokes pre-push with `<remote-name> <remote-url>`
# (the .git/hooks/pre-push shim forwards them via "$@" to `pwsh -File Hook-PrePush.ps1`). A bare param() REJECTED
# 'origin' ("A positional parameter cannot be found...") and aborted EVERY push — a real ship-blocker, NOT a
# --no-verify. The param block must carry a ValueFromRemainingArguments catch-all. RED pre-fix (bare param()).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    # Join-Path (OS-native separator) — [Parser]::ParseFile is raw .NET (no `\`→`/` on Linux); a backslash string would
    # yield a nonexistent path → empty AST → ParamBlock null → assertion false (Windows-only false-green; Linux CI caught it).
    $script:hook = Join-Path $script:repo 'tools/hooks/Hook-PrePush.ps1'
    $script:src = Get-Content $script:hook -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:hook, [ref]$null, [ref]$null)
    $script:params = @($ast.ParamBlock.Parameters)
}

Describe 'Φ4.C · Hook-PrePush accepts git positional args (no push-abort)' {
    It 'declares a ValueFromRemainingArguments parameter (tolerates `origin <url>`)' {
        $hasRemaining = $false
        foreach ($p in $script:params) {
            foreach ($attr in $p.Attributes) {
                if ($attr.TypeName.Name -eq 'Parameter') {
                    foreach ($na in $attr.NamedArguments) {
                        if ($na.ArgumentName -eq 'ValueFromRemainingArguments') { $hasRemaining = $true }
                    }
                }
            }
        }
        $hasRemaining | Should -BeTrue
    }
    It 'invokes Run-PrePushGauntlet with NO hardcoded axis total (number-free · the count is derived at runtime)' {
        $script:src | Should -Match 'Run-PrePushGauntlet'
        $script:src | Should -Not -Match '\d+[- ]ax(is|es)'
    }
}
