#Requires -Module Pester
# Locks tools/lib/Hook-PreCommit.lib.ps1 helper-function contracts:
#   - Test-CommitMessageHasRequiredSections: AXIS/PRIOR-GATES/VERIFY/LOCK detection + one-axis-only
#   - Test-StagedFilesNeedT3: auth/portal/manifest/Connect-* path matching
#   - Test-StagedFilesNeedArmTtk: deploy/arm and deploy/sentinel path matching
#   - Test-T3Freshness: probe-auth-*.json age vs MaxAgeHours window
# Plus integration sanity that tools/Hook-PreCommit.ps1 + tools/Install-PreCommitHook.ps1 exist.

BeforeAll {
    $script:repoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:libPath       = Join-Path $script:repoRoot 'tools\lib\Hook-PreCommit.lib.ps1'
    $script:hookScript    = Join-Path $script:repoRoot 'tools\Hook-PreCommit.ps1'
    $script:installScript = Join-Path $script:repoRoot 'tools\Install-PreCommitHook.ps1'
    # Dot-source lib so helpers are in this scope (Pester runs in fresh scope per file)
    . $script:libPath
}

Describe 'Hook-PreCommit · lib helpers exist + script artefacts present' -Tag 'hook-precommit' {

    It 'tools/lib/Hook-PreCommit.lib.ps1 is on disk' {
        Test-Path $script:libPath | Should -BeTrue
    }

    It 'tools/Hook-PreCommit.ps1 is on disk' {
        Test-Path $script:hookScript | Should -BeTrue
    }

    It 'tools/Install-PreCommitHook.ps1 is on disk' {
        Test-Path $script:installScript | Should -BeTrue
    }

    It 'defines 5 lib helpers in dot-sourced scope' {
        Get-Command -Name 'Test-CommitMessageHasRequiredSections' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command -Name 'Test-StagedFilesNeedT3'                -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command -Name 'Test-StagedFilesNeedArmTtk'            -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command -Name 'Test-T3Freshness'                      -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command -Name 'Test-T3ProbeSuccess'                   -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-T3ProbeSuccess · per-portal ChainSuccess content check' -Tag 'hook-precommit' {

    BeforeEach {
        $script:tmpIterRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-probesuccess-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:tmpIterRoot -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:tmpIterRoot -ErrorAction SilentlyContinue
    }

    It 'returns Found=$false when iter root missing' {
        $r = Test-T3ProbeSuccess -IterRoot (Join-Path $script:tmpIterRoot 'nope')
        $r.Found | Should -BeFalse
    }

    It 'returns Found=$false when no probe-auth*.json under iter root' {
        $r = Test-T3ProbeSuccess -IterRoot $script:tmpIterRoot
        $r.Found | Should -BeFalse
    }

    It 'returns AllSuccess=$true when all probes show ChainSuccess=true' {
        $iter = Join-Path $script:tmpIterRoot 'iter-allgreen'
        New-Item -ItemType Directory -Path $iter -Force | Out-Null
        $payload = @{
            TimestampUtc = '2026-05-17T00:00:00Z'
            Probes = @(
                @{ Portal = 'Defender'; SubPortal = ''; ChainSuccess = $true }
                @{ Portal = 'Purview';  SubPortal = ''; ChainSuccess = $true }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content -Path (Join-Path $iter 'probe-auth-multi.json') -Value $payload

        $r = Test-T3ProbeSuccess -IterRoot $script:tmpIterRoot
        $r.Found       | Should -BeTrue
        $r.AllSuccess  | Should -BeTrue
        $r.ProbeCount  | Should -Be 2
        $r.SuccessByPortal['Defender'] | Should -BeTrue
        $r.SuccessByPortal['Purview']  | Should -BeTrue
    }

    It 'returns AllSuccess=$false + FailuresByPortal populated when ANY probe ChainSuccess=false' {
        $iter = Join-Path $script:tmpIterRoot 'iter-mixed'
        New-Item -ItemType Directory -Path $iter -Force | Out-Null
        $payload = @{
            TimestampUtc = '2026-05-17T00:00:00Z'
            Probes = @(
                @{ Portal = 'Defender'; SubPortal = '';    ChainSuccess = $true }
                @{ Portal = 'Entra';    SubPortal = 'IAM'; ChainSuccess = $false; Error = 'AADSTS50011 redirect URI mismatch' }
                @{ Portal = 'Entra';    SubPortal = 'PIM'; ChainSuccess = $false; Error = 'AADSTS50011 redirect URI mismatch' }
            )
        } | ConvertTo-Json -Depth 5
        Set-Content -Path (Join-Path $iter 'probe-auth-multi.json') -Value $payload

        $r = Test-T3ProbeSuccess -IterRoot $script:tmpIterRoot
        $r.Found       | Should -BeTrue
        $r.AllSuccess  | Should -BeFalse
        $r.ProbeCount  | Should -Be 3
        @($r.FailuresByPortal).Count | Should -Be 2
        @($r.FailuresByPortal)[0].Portal | Should -Be 'Entra'
        @($r.FailuresByPortal)[0].Error  | Should -Match 'AADSTS50011'
    }

    It 'gracefully handles single-portal probe schema (no Probes[] wrapper)' {
        $iter = Join-Path $script:tmpIterRoot 'iter-singlportal'
        New-Item -ItemType Directory -Path $iter -Force | Out-Null
        # Single-portal probe writes the top-level object directly (no Probes[])
        $payload = @{
            Portal = 'Defender'
            ChainSuccess = $true
            TimestampUtc = '2026-05-17T00:00:00Z'
        } | ConvertTo-Json -Depth 5
        Set-Content -Path (Join-Path $iter 'probe-auth.json') -Value $payload

        $r = Test-T3ProbeSuccess -IterRoot $script:tmpIterRoot
        $r.Found      | Should -BeTrue
        $r.ProbeCount | Should -Be 1
        $r.AllSuccess | Should -BeTrue
    }

    It 'returns parse error reason when JSON malformed' {
        $iter = Join-Path $script:tmpIterRoot 'iter-broken'
        New-Item -ItemType Directory -Path $iter -Force | Out-Null
        Set-Content -Path (Join-Path $iter 'probe-auth-multi.json') -Value '{not valid json'

        $r = Test-T3ProbeSuccess -IterRoot $script:tmpIterRoot
        $r.Found  | Should -BeTrue
        $r.Reason | Should -Match 'parse'
    }
}

Describe 'Test-CommitMessageHasRequiredSections · commit message gate' -Tag 'hook-precommit' {

    It 'returns empty for a valid commit message with all 4 required sections' {
        $msg = @"
feat(tools): example

AXIS: single axis description

PRIOR GATES RE-AUDIT:
[x] prior phase artefacts on disk

VERIFICATION MATRIX:
T1 ok

LOCK:
[x] one axis confirmed
"@
        $issues = Test-CommitMessageHasRequiredSections -Message $msg
        @($issues).Count | Should -Be 0
    }

    It 'detects missing AXIS section' {
        $msg = @"
feat(x): change

PRIOR GATES: ok
VERIFY: ok
LOCK: ok
"@
        $issues = @(Test-CommitMessageHasRequiredSections -Message $msg)
        $issues.Count | Should -Be 1
        $issues[0] | Should -Match 'Missing AXIS'
    }

    It 'detects multiple AXIS sections (multi-axis commit · G5 violation)' {
        $msg = @"
feat(x): bundled change

AXIS: first axis

PRIOR GATES: ok

AXIS: sneaky second axis

VERIFY: ok
LOCK: ok
"@
        $issues = @(Test-CommitMessageHasRequiredSections -Message $msg)
        $issues.Count | Should -BeGreaterOrEqual 1
        ($issues -join ' ') | Should -Match 'Multiple AXIS'
    }

    It 'detects missing PRIOR GATES section' {
        $msg = @"
feat(x): change

AXIS: single axis
VERIFY: ok
LOCK: ok
"@
        $issues = @(Test-CommitMessageHasRequiredSections -Message $msg)
        ($issues -join ' ') | Should -Match 'Missing PRIOR GATES'
    }

    It 'detects missing VERIFY section' {
        $msg = @"
feat(x): change

AXIS: single axis
PRIOR GATES: ok
LOCK: ok
"@
        $issues = @(Test-CommitMessageHasRequiredSections -Message $msg)
        ($issues -join ' ') | Should -Match 'Missing VERIF'
    }

    It 'detects missing LOCK section' {
        $msg = @"
feat(x): change

AXIS: single axis
PRIOR GATES: ok
VERIFY: ok
"@
        $issues = @(Test-CommitMessageHasRequiredSections -Message $msg)
        ($issues -join ' ') | Should -Match 'Missing LOCK'
    }

    It 'detects all 4 missing sections in an empty message' {
        $msg = "feat(x): no sections at all"
        $issues = @(Test-CommitMessageHasRequiredSections -Message $msg)
        $issues.Count | Should -BeGreaterOrEqual 4
    }

    It 'accepts PRIOR GATES RE-AUDIT (full template wording)' {
        $msg = @"
feat(x): change

AXIS: change
PRIOR GATES RE-AUDIT: ok
VERIFICATION MATRIX: ok
LOCK: ok
"@
        @(Test-CommitMessageHasRequiredSections -Message $msg).Count | Should -Be 0
    }
}

Describe 'Test-StagedFilesNeedT3 · auth/portal/manifest path detection' -Tag 'hook-precommit' {

    It 'returns false for empty staged list' {
        Test-StagedFilesNeedT3 -StagedFiles @() | Should -BeFalse
    }

    It 'returns false for pure docs/test/CI files' {
        $staged = @(
            'README.md',
            'tests/unit/Manifest.Schema.Tests.ps1',
            '.github/workflows/ci.yml'
        )
        Test-StagedFilesNeedT3 -StagedFiles $staged | Should -BeFalse
    }

    It 'returns true when Xdr.Auth module touched' {
        Test-StagedFilesNeedT3 -StagedFiles @('src/Modules/Xdr.Auth/Xdr.Auth.psm1') | Should -BeTrue
    }

    It 'returns true when Xdr.Poll module touched' {
        Test-StagedFilesNeedT3 -StagedFiles @('src/Modules/Xdr.Poll/Xdr.Poll.psm1') | Should -BeTrue
    }

    It 'returns true when defender.psd1 manifest touched' {
        Test-StagedFilesNeedT3 -StagedFiles @('manifests/defender.psd1') | Should -BeTrue
    }

    It 'returns true when any *.psd1 manifest touched' {
        Test-StagedFilesNeedT3 -StagedFiles @('manifests/entra.psd1') | Should -BeTrue
    }

    It 'returns true when Xdr-Poll function touched' {
        Test-StagedFilesNeedT3 -StagedFiles @('functionapp/Xdr-Poll/run.ps1') | Should -BeTrue
    }
}

Describe 'Test-StagedFilesNeedArmTtk · deploy path detection' -Tag 'hook-precommit' {

    It 'returns false for empty staged list' {
        Test-StagedFilesNeedArmTtk -StagedFiles @() | Should -BeFalse
    }

    It 'returns false for module/test changes' {
        $staged = @(
            'src/Modules/Xdr.Auth/Xdr.Auth.psm1',
            'tests/unit/Auth.Classifier.Tests.ps1'
        )
        Test-StagedFilesNeedArmTtk -StagedFiles $staged | Should -BeFalse
    }

    It 'returns true when deploy/arm/* touched' {
        Test-StagedFilesNeedArmTtk -StagedFiles @('deploy/arm/mainTemplate.json') | Should -BeTrue
    }

    It 'returns true when deploy/sentinel/* touched' {
        Test-StagedFilesNeedArmTtk -StagedFiles @('deploy/sentinel/sentinelContent.json') | Should -BeTrue
    }
}

Describe 'Test-T3Freshness · probe-auth recency window' -Tag 'hook-precommit' {

    # Per-test isolation: each `It` gets its own temp iter root, removed in cleanup.
    BeforeEach {
        $script:tmpIterRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-hook-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:tmpIterRoot -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:tmpIterRoot) {
            Remove-Item -Recurse -Force $script:tmpIterRoot -ErrorAction SilentlyContinue
        }
    }

    It 'returns Fresh=$false when iter root does not exist' {
        $result = Test-T3Freshness -IterRoot (Join-Path $script:tmpIterRoot 'nope') -MaxAgeHours 24
        $result.Fresh | Should -BeFalse
        $result.Reason | Should -Match 'Iter root not found'
    }

    It 'returns Fresh=$false when iter root has no probe-auth*.json' {
        $emptyIter = Join-Path $script:tmpIterRoot 'iter-empty'
        New-Item -ItemType Directory -Path $emptyIter -Force | Out-Null
        $result = Test-T3Freshness -IterRoot $script:tmpIterRoot -MaxAgeHours 24
        $result.Fresh | Should -BeFalse
        $result.Reason | Should -Match 'No probe-auth'
    }

    It 'returns Fresh=$true for a probe-auth.json written just now' {
        $iter = Join-Path $script:tmpIterRoot 'iter-fresh'
        New-Item -ItemType Directory -Path $iter -Force | Out-Null
        $probeFile = Join-Path $iter 'probe-auth-multi.json'
        Set-Content -Path $probeFile -Value '{"TimestampUtc":"now"}'
        $result = Test-T3Freshness -IterRoot $script:tmpIterRoot -MaxAgeHours 24
        $result.Fresh | Should -BeTrue
        $result.Path | Should -Be $probeFile
    }

    It 'returns Fresh=$false for a probe-auth.json older than MaxAgeHours' {
        $iter = Join-Path $script:tmpIterRoot 'iter-stale'
        New-Item -ItemType Directory -Path $iter -Force | Out-Null
        $probeFile = Join-Path $iter 'probe-auth-stale.json'
        Set-Content -Path $probeFile -Value '{"TimestampUtc":"old"}'
        (Get-Item $probeFile).LastWriteTime = (Get-Date).AddHours(-48)
        $result = Test-T3Freshness -IterRoot $script:tmpIterRoot -MaxAgeHours 24
        $result.Fresh | Should -BeFalse
        $result.Reason | Should -Match '\d+h old'
    }
}
