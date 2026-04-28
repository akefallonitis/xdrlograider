#Requires -Modules Pester
<#
.SYNOPSIS
    Iter-13.14 root-cause regression gate: locks the invariant that
    Invoke-XdrStorageTableEntity Upsert NEVER sends an `If-Match` header.

.DESCRIPTION
    The iter-13.14 production breakage was caused by sending
    `If-Match: '*'` on a PUT to the Azure Tables REST endpoint. With
    `If-Match: '*'` the PUT becomes "Update Entity" (which 404s if the
    row doesn't exist yet) — first-run validate-auth-selftest then
    couldn't write the gate flag. Without `If-Match`, the PUT becomes
    "Insert-Or-Replace Entity" (creates if missing, replaces if present).

    This is a single-purpose gate file: any future regression that
    re-introduces If-Match on the Upsert branch fails this assertion
    in isolation, making the root cause obvious in CI output.

    Companion file: tests/unit/Invoke-XdrStorageTableEntity.Tests.ps1
    has full coverage; this file exists for cognitive-load reduction.
#>

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:HelperPath   = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Ingest' 'Public' 'Invoke-XdrStorageTableEntity.ps1'
    $script:HelperSource = Get-Content $script:HelperPath -Raw
}

Describe 'iter-13.14 root-cause regression gate — Upsert MUST NOT send If-Match' {

    It 'helper file exists at the canonical path' {
        $script:HelperPath | Should -Exist
    }

    It 'Upsert branch in source does NOT make a TryAddWithoutValidation call for If-Match' {
        # Locate the Upsert branch.
        $upsertBranch = [regex]::Match($script:HelperSource,
            '(?s)if\s*\(\s*\$Operation\s*-eq\s*''Upsert''\s*\)\s*\{(.*?)\}\s*\$resp')
        $upsertBranch.Success | Should -BeTrue -Because 'helper must contain an Upsert branch'

        # Strip PowerShell comments from the branch body so that documentation/
        # historical references to "If-Match" inside the branch (which we WANT
        # there to remind future maintainers of the iter-13.14 root cause) do
        # not false-positive this assertion.
        $branchBody = $upsertBranch.Groups[1].Value
        $branchBody = [regex]::Replace($branchBody, '<#[\s\S]*?#>', '')   # block comments
        $branchBody = [regex]::Replace($branchBody, '(?m)#.*$', '')        # line comments

        # Now assert no actual TryAddWithoutValidation('If-Match'...) call.
        $branchBody | Should -Not -Match "TryAddWithoutValidation\s*\(\s*['""]If-Match['""]" -Because (
            'iter-13.14 root cause: PUT with If-Match becomes Update Entity ' +
            '(returns 404 if row missing). Upsert MUST NOT send If-Match — ' +
            'PUT without If-Match is Insert-Or-Replace, which is what callers want.'
        )
    }

    It 'Delete branch DOES make a TryAddWithoutValidation call for If-Match (companion invariant — unconditional delete)' {
        # Symmetry check: ensure the Delete branch retains If-Match: '*'.
        $deleteBranch = [regex]::Match($script:HelperSource,
            '(?s)if\s*\(\s*\$Operation\s*-eq\s*''Delete''\s*\)\s*\{(.*?)\}')
        $deleteBranch.Success | Should -BeTrue -Because 'helper must contain a Delete branch'
        $deleteBranch.Groups[1].Value | Should -Match "TryAddWithoutValidation\s*\(\s*['""]If-Match['""]" -Because 'Delete without If-Match returns 412 PreconditionFailed; If-Match: ''*'' = unconditional delete'
    }

    It 'PUT verb is used for Upsert (not MERGE — MERGE has different semantics + Az Tables only-PATCH-method)' {
        # Earlier iter-13.14 code used Method=Merge in Invoke-RestMethod; that
        # would have been Update-Or-Merge semantics (also row-must-exist).
        # PUT-without-If-Match is Insert-Or-Replace which is unambiguously
        # what we want for upsert.
        $script:HelperSource | Should -Match "'Upsert'\s*\{\s*\[System\.Net\.Http\.HttpMethod\]::Put\s*\}" -Because 'Upsert must map to PUT (Insert-Or-Replace), not MERGE (Insert-Or-Merge has subtly different field-merge semantics)'
    }
}
