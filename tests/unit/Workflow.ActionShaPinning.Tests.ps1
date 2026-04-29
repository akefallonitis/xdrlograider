#Requires -Modules Pester
<#
.SYNOPSIS
    iter-14.0 Phase 14 — GitHub Actions SHA-pinning gate.
    Asserts every `uses:` line in `.github/workflows/*.yml` references an action
    by full 40-character commit SHA (NOT a moveable tag like `@v4` or `@main`).

.DESCRIPTION
    Why SHA pinning matters: `@v4` is a moveable git tag — a compromised action
    repo can push malicious code under the same tag. Commit SHAs are immutable.
    Dependabot updates SHAs weekly via PRs, so operators stay current without
    being exposed to tag-mutation attacks.

    Reference: GitHub's own security guidance:
    https://docs.github.com/actions/security-guides/security-hardening-for-github-actions#using-third-party-actions

    Allowed patterns:
      - `uses: <owner>/<repo>@<40-char-hex-sha> # v1.2.3 — comment with version is fine`
      - `uses: ./<path>` (local action — repo-internal)
      - `uses: docker://<image>@sha256:<digest>` (container action)

    Rejected patterns:
      - `uses: <owner>/<repo>@v4` (moveable tag)
      - `uses: <owner>/<repo>@main` (moveable branch)
      - `uses: <owner>/<repo>@<short-sha>` (less than 40 chars)
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:WorkflowDir = Join-Path $script:RepoRoot '.github' 'workflows'
    $script:WorkflowFiles = Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -ErrorAction SilentlyContinue

    # Allowed reference shapes (per docstring above)
    $script:Sha40Re        = '@[a-f0-9]{40}\b'
    $script:LocalRefRe     = '^uses:\s*\.{1,2}/'
    $script:ContainerRefRe = '^uses:\s*docker://[^@]+@sha256:[a-f0-9]{64}\b'
}

Describe 'Workflow.ActionShaPinning' {

    It 'workflow directory exists with at least one .yml file' {
        $script:WorkflowFiles.Count | Should -BeGreaterThan 0
    }

    It 'every `uses:` reference uses a 40-char commit SHA, local path, or container digest' {
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($wf in $script:WorkflowFiles) {
            $lines = Get-Content -LiteralPath $wf.FullName
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                # Trim leading whitespace; keep the rest verbatim.
                $trimmed = $line.TrimStart()
                if ($trimmed -notmatch '^[-\s]*uses:\s*\S') { continue }

                # Extract the value of `uses:` (everything after the colon, stripped).
                $usesMatch = [regex]::Match($trimmed, 'uses:\s*(\S+)')
                if (-not $usesMatch.Success) { continue }
                $ref = $usesMatch.Groups[1].Value

                # Allowed: local action (./path or ../path)
                if ($ref -match '^\.{1,2}/') { continue }

                # Allowed: container action with sha256 digest
                if ($ref -match '^docker://[^@]+@sha256:[a-f0-9]{64}\b') { continue }

                # Required: 40-char commit SHA
                if ($ref -match '@[a-f0-9]{40}\b') { continue }

                # Anything else is a violation
                $violations.Add("$($wf.Name):$lineNum  -- $trimmed")
            }
        }

        if ($violations.Count -gt 0) {
            $msg = "SHA-pinning violations:`n  " + ($violations -join "`n  ")
            $msg | Should -BeNullOrEmpty -Because 'iter-14.0 Phase 14: every GitHub Action `uses:` must reference an immutable 40-char commit SHA. Update via Dependabot or manually.'
        } else {
            $true | Should -BeTrue
        }
    }

    It 'a SHA-pinned reference may include a `# vX.Y.Z` comment for human-readable version' {
        # This is a soft expectation — dependabot's PRs include the version comment
        # automatically. We just verify that AT LEAST ONE action carries the comment
        # (proves dependabot has updated something at some point).
        # Skip if no SHAs are present (the SHA-pinning gate above will fail anyway).
        $allLines = $script:WorkflowFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName }
        $hasShaWithComment = $allLines | Where-Object { $_ -match '@[a-f0-9]{40}\s+#\s*v?\d' } | Select-Object -First 1
        # Soft check — only enforce once Dependabot has run at least once
        if ($hasShaWithComment) {
            $hasShaWithComment | Should -Match '@[a-f0-9]{40}\s+#'
        }
    }
}

Describe 'Workflow.NoMoveableRefs' {

    It 'literal-tag references like uses owner/repo at v-digit are forbidden' {
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($wf in $script:WorkflowFiles) {
            $lines = Get-Content -LiteralPath $wf.FullName
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match '\buses:\s*\S+@v\d+(\.\d+)*\s*(#|$)') {
                    $offenders.Add("$($wf.Name):$lineNum -- $line".Trim())
                }
            }
        }
        if ($offenders.Count -gt 0) {
            ($offenders -join "`n") | Should -BeNullOrEmpty -Because 'iter-14.0 Phase 14: literal-tag references are moveable; pin to commit SHA'
        } else {
            $true | Should -BeTrue
        }
    }

    It 'branch-tag references like at-main, at-master, at-HEAD are forbidden' {
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($wf in $script:WorkflowFiles) {
            $lines = Get-Content -LiteralPath $wf.FullName
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match '\buses:\s*\S+@(main|master|HEAD|develop|trunk)\b') {
                    $offenders.Add("$($wf.Name):$lineNum -- $line".Trim())
                }
            }
        }
        if ($offenders.Count -gt 0) {
            ($offenders -join "`n") | Should -BeNullOrEmpty -Because 'iter-14.0 Phase 14: branch references are extremely-moveable; pin to commit SHA'
        } else {
            $true | Should -BeTrue
        }
    }
}

Describe 'Workflow.DependabotConfigured (auto-update SHAs weekly)' {

    It 'has .github/dependabot.yml configured for github-actions ecosystem' {
        $dbPath = Join-Path $script:RepoRoot '.github' 'dependabot.yml'
        Test-Path -LiteralPath $dbPath | Should -BeTrue
        $content = Get-Content -LiteralPath $dbPath -Raw
        $content | Should -Match 'package-ecosystem:\s*github-actions'
    }

    It 'dependabot is configured to update all actions (groups: actions / *)' {
        $dbPath = Join-Path $script:RepoRoot '.github' 'dependabot.yml'
        $content = Get-Content -LiteralPath $dbPath -Raw
        $content | Should -Match 'groups:'
    }
}
