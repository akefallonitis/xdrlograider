#Requires -Version 7.4
# Φ4.D · Verify-DeployedVersion's pure SHA-compare core (Compare-XdrDeployedSha) — the gate that proves the live FA is
# running HEAD before any postdeploy KQL means anything. AST-extracted (no Azure · no dot-source mandatory-param prompt)
# and exercised with synthetic SHAs: equal→Match, short-vs-full prefix→Match, different→DRIFT, empty/unknown/too-short→
# Inconclusive. RED pre-fix (the tool/function did not exist → AST extraction yields null → invocation fails).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    # Join-Path (OS-native separator) — [Parser]::ParseFile is a raw .NET API that does NOT normalize `\` on Linux, so a
    # "$repo\tools\..." backslash string yields a nonexistent path → null AST → null-deref (Windows-only false-green).
    $tool = Join-Path $script:repo 'tools/Verify-DeployedVersion.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($tool, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Compare-XdrDeployedSha'
        }, $true) | Select-Object -First 1
    $script:Compare = $fn.Body.GetScriptBlock()
    $script:full = 'abcdef0123456789abcdef0123456789abcdef01'   # synthetic 40-char commit
}

Describe 'Φ4.D · Compare-XdrDeployedSha (BUILD_SHA==HEAD core)' {
    It 'equal full SHAs → Match' {
        $r = & $script:Compare -DeployedSha $script:full -ExpectedSha $script:full
        $r.Match | Should -BeTrue
        $r.Inconclusive | Should -BeFalse
    }
    It 'short deployed (7) is a prefix of full HEAD → Match (tolerates short-vs-full)' {
        $r = & $script:Compare -DeployedSha $script:full.Substring(0, 7) -ExpectedSha $script:full
        $r.Match | Should -BeTrue
    }
    It 'different SHAs → DRIFT (not Match · not Inconclusive)' {
        $r = & $script:Compare -DeployedSha ('a' * 40) -ExpectedSha ('b' * 40)
        $r.Match | Should -BeFalse
        $r.Inconclusive | Should -BeFalse
        $r.Detail | Should -Match 'DRIFT'
    }
    It 'empty deployed (no probe in window) → Inconclusive (never a false PASS)' {
        (& $script:Compare -DeployedSha '' -ExpectedSha $script:full).Inconclusive | Should -BeTrue
    }
    It "'unknown' deployed (unstamped) → Inconclusive" {
        (& $script:Compare -DeployedSha 'unknown' -ExpectedSha $script:full).Inconclusive | Should -BeTrue
    }
    It 'empty expected (HEAD) → Inconclusive' {
        (& $script:Compare -DeployedSha $script:full -ExpectedSha '').Inconclusive | Should -BeTrue
    }
    It 'too-short commit (<7) → Inconclusive (cannot safely compare)' {
        (& $script:Compare -DeployedSha 'abc' -ExpectedSha $script:full).Inconclusive | Should -BeTrue
    }
}

Describe 'Φ4.D · FA-package tooling-tolerance — the version gate does not false-DRIFT a tooling-only commit' {
    # 2026-06-23 regression guard: a verify-tooling commit (tools/+tests/, NOT in the FA package) advances HEAD past the
    # correctly-unchanged deployed FA, so the raw SHA==HEAD gate false-DRIFTed the round re-prove. The gate now tolerates
    # the mismatch when the deployed commit's FA package (src/manifests) is byte-identical to HEAD's. Dot-sourced with a
    # dummy -WorkspaceId (no prompt; the script early-returns on InvocationName=='.' before any live az), so both helper
    # fns are in scope.
    BeforeAll {
        . (Join-Path $script:repo 'tools/Verify-DeployedVersion.ps1') -WorkspaceId '00000000-0000-0000-0000-000000000000'
        $script:head   = (git -C $script:repo rev-parse HEAD 2>$null).Trim()
        $script:lastFa = (git -C $script:repo log -1 --format=%H -- src manifests 2>$null).Trim()
    }
    It 'Get-XdrFaPackagePathspec is exactly the shipped package paths (src + manifests · NOT tools/tests)' {
        $ps = @(Get-XdrFaPackagePathspec)
        $ps | Should -Contain 'src'; $ps | Should -Contain 'manifests'
        $ps | Should -Not -Contain 'tools'; $ps | Should -Not -Contain 'tests'
    }
    It 'a tooling-only HEAD (no src/manifests delta since the last FA-package commit) is TOLERATED -> TRUE' {
        Test-XdrFaPackageUnchanged -DeployedSha $script:lastFa -ExpectedSha $script:head -RepoRoot $script:repo | Should -BeTrue
    }
    It 'a real FA-package delta is NOT tolerated -> FALSE (deployed lacks a src/manifests change · stays DRIFT)' {
        $beforeFa = (git -C $script:repo rev-parse "$($script:lastFa)^" 2>$null).Trim()
        Test-XdrFaPackageUnchanged -DeployedSha $beforeFa -ExpectedSha $script:head -RepoRoot $script:repo | Should -BeFalse
    }
    It 'empty / whitespace SHA -> FALSE (fail-safe: an unverifiable compare is drift, never a silent green)' {
        Test-XdrFaPackageUnchanged -DeployedSha '' -ExpectedSha $script:head -RepoRoot $script:repo | Should -BeFalse
        Test-XdrFaPackageUnchanged -DeployedSha $script:head -ExpectedSha '   ' -RepoRoot $script:repo | Should -BeFalse
    }
}

Describe 'Φ4.G · WorkspaceId resolver is robust (GUID passthrough · ARM id via -g/-n · no error mask)' {
    BeforeAll { $script:src = Get-Content (Join-Path $script:repo 'tools/Verify-DeployedVersion.ps1') -Raw }
    It 'passes a raw customerId GUID through unchanged (detects the GUID shape first · no az call)' {
        $script:src | Should -Match '\$guidRe\s*='
        $script:src | Should -Match '\$WorkspaceId -match \$guidRe'
    }
    It 'resolves an ARM id via the reliable -g <rg> -n <name> form (the --ids form failed for this workspace)' {
        $script:src | Should -Match 'workspace show -g \$wsRg -n \$wsName --query customerId'
        $script:src | Should -Match '/resourceGroups/'
        $script:src | Should -Match '/workspaces/'
    }
    It 'surfaces the real az error on failure (no 2>$null mask on the resolver · rule §2)' {
        $script:src | Should -Match 'Failed to resolve WorkspaceId.*az: \$res'
        $script:src | Should -Match 'workspace show -g \$wsRg -n \$wsName.*2>&1'
    }
}
