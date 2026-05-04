#Requires -Modules Pester
<#
.SYNOPSIS
    Phase L.0 CRITICAL regression test per Section 0.A of
    .claude/plans/immutable-splashing-waffle.md.

.DESCRIPTION
    The auth-selftest gate was removed in commit bc9ab51 (Get/Set-XdrAuthSelfTestFlag
    functions deleted). The orphan `Set-XdrAuthSelfTestFlag` call in
    Invoke-TierPollWithHeartbeat.ps1 fatal-error path was missed and would have
    thrown "command not found" on EVERY fatal error, masking the original fatal
    AND preventing the heartbeat from emitting the fatal-error row.

    Phase L.0 fix: orphan call removed.
    This test prevents regression by:
      1. Verifying the source file does NOT contain `Set-XdrAuthSelfTestFlag` outside comments.
      2. Verifying no other module references either Get- or Set-XdrAuthSelfTestFlag.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:TargetFile = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Public' 'Invoke-TierPollWithHeartbeat.ps1'
}

Describe 'Phase L.0 CRITICAL — Set-XdrAuthSelfTestFlag orphan call regression' {
    It 'Invoke-TierPollWithHeartbeat.ps1 contains NO active call to Set-XdrAuthSelfTestFlag' {
        $content = Get-Content -Raw -Path $script:TargetFile
        # Strip comments (lines starting with #) before checking for invocation
        $codeLines = ($content -split "`n") | Where-Object { $_ -notmatch '^\s*#' }
        $codeOnly = $codeLines -join "`n"
        $codeOnly | Should -Not -Match 'Set-XdrAuthSelfTestFlag\s+(?!\s*=)' -Because 'Phase L.0 CRITICAL: orphan call removed; would mask fatal errors otherwise'
    }

    It 'No source file references Set-XdrAuthSelfTestFlag (function deleted in bc9ab51)' {
        $srcFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'src') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($f in $srcFiles) {
            $content = Get-Content -Raw -Path $f.FullName
            # Strip comment lines before checking
            $codeLines = ($content -split "`n") | Where-Object { $_ -notmatch '^\s*#' }
            $codeOnly = $codeLines -join "`n"
            if ($codeOnly -match 'Set-XdrAuthSelfTestFlag|Get-XdrAuthSelfTestFlag') {
                $offenders.Add($f.FullName.Substring($script:RepoRoot.Length + 1))
            }
        }
        $offenders | Should -BeNullOrEmpty -Because 'Functions deleted in bc9ab51; any reference is dead code that will throw at runtime'
    }
}

Describe 'Phase L.0 — fatal-error path emits heartbeat (not blocked by orphan call)' {
    It 'Invoke-TierPollWithHeartbeat.ps1 catches fatal + writes heartbeat with fatalError Notes' {
        $content = Get-Content -Raw -Path $script:TargetFile
        # Verify the fatal-catch block calls Write-Heartbeat with fatalError in Notes
        $content | Should -Match 'fatalError\s*=\s*\$errMsg' -Because 'fatal-error path must emit fatalError Notes for operator visibility'
        # Verify Write-Heartbeat is called WITHIN the fatal-catch block
        $content | Should -Match 'Write-Heartbeat[\s\S]+fatalError' -Because 'Write-Heartbeat must be called in fatal-catch path'
    }
}
