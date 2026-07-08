#Requires -Version 7.4
# Φ4.A · Rollback-ArmDeployment safety contract. (1) Test-XdrRollbackRequest (pure · git-only · AST-extracted) REFUSES a
# blind/unsafe rollback: empty ref / bad ref → not Safe; a real ref carrying deploy/mainTemplate.json → Safe. (2) the
# tool source carries NO destructive command (RG delete / keyvault purge|delete / no-wait detached run) and ALWAYS
# what-ifs before any create (create gated behind -Execute · Incremental/additive only). RED pre-fix (no tool exists).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    # Join-Path (OS-native separator) — [Parser]::ParseFile is raw .NET (no `\`→`/` on Linux); a backslash string would
    # yield a nonexistent path → null AST → null-deref (Windows-only false-green; the Linux CI runner caught it).
    $script:tool = Join-Path $script:repo 'tools/Rollback-ArmDeployment.ps1'
    $script:src = Get-Content $script:tool -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-XdrRollbackRequest'
        }, $true) | Select-Object -First 1
    $script:Validate = $fn.Body.GetScriptBlock()
}

Describe 'Φ4.A · Rollback-ArmDeployment safety' {
    Context 'Test-XdrRollbackRequest · refuse a blind/unsafe rollback' {
        It 'empty GoodRef → REFUSED (never a blind redeploy)' {
            (& $script:Validate -GoodRef '' -RepoRoot $script:repo).Safe | Should -BeFalse
        }
        It 'bogus GoodRef → REFUSED' {
            (& $script:Validate -GoodRef 'definitely-not-a-ref-zzz999' -RepoRoot $script:repo).Safe | Should -BeFalse
        }
        It 'HEAD (real ref carrying deploy/mainTemplate.json) → Safe' {
            (& $script:Validate -GoodRef 'HEAD' -RepoRoot $script:repo).Safe | Should -BeTrue
        }
    }
    Context 'destructive-op guards (source contract)' {
        It 'contains NO resource-group delete' { $script:src | Should -Not -Match 'group\s+delete' }
        It 'contains NO keyvault purge/delete' { $script:src | Should -Not -Match 'keyvault\s+(purge|delete)' }
        It 'contains NO no-wait detached flag' { $script:src | Should -Not -Match '--no-wait' }
        It 'what-ifs ALWAYS before any create (gate precedes mutation)' {
            $wi = $script:src.IndexOf('what-if')
            $cr = $script:src.IndexOf('deployment group create')
            $wi | Should -BeGreaterThan -1
            $cr | Should -BeGreaterThan -1
            $wi | Should -BeLessThan $cr
        }
        It 'gates the create behind -Execute (default = dry-run)' { $script:src | Should -Match 'if \(-not \$Execute\)' }
        It 'uses Incremental mode only (additive · never Complete)' {
            $script:src | Should -Match "'Incremental'"
            $script:src | Should -Not -Match "'Complete'"
        }
    }
}
