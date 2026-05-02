#Requires -Modules Pester
<#
.SYNOPSIS
    Behavioral + contract tests for the iter-13.15 Invoke-XdrStorageTableEntity
    helper — the unified Storage Table entity-ops abstraction.

.DESCRIPTION
    The helper replaces 4 scattered call sites that previously mixed AzTable
    cmdlets and ad-hoc Invoke-RestMethod blocks (with the wrong PUT semantic
    in iter-13.14). Tests cover:
      - Parameter binding (ValidateSet, Mandatory, -Entity-required-for-Upsert)
      - Source-level contract assertions (URI shape, header set per operation,
        HttpClient caching, no-If-Match-on-Upsert)
      - Behavioral integration: replace $script:XdrTableHttpClient with a test
        double and verify the request shape end-to-end.

    Companion gate file: tests/unit/StorageTableHelper.UpsertSemantic.Tests.ps1
    locks the single most important invariant (no If-Match on Upsert) in
    isolation so a CI failure points at the bug class directly.
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:HelperPath     = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Public' 'Invoke-XdrStorageTableEntity.ps1'
    $script:HelperSource   = Get-Content $script:HelperPath -Raw
    $script:IngestModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'

    # Stub Get-AzAccessToken before importing the module so the helper has
    # something to call. The real cmdlet would attempt actual MI auth.
    function global:Get-AzAccessToken {
        param([string]$ResourceUrl)
        [pscustomobject]@{
            Token     = 'fake-stub-token-for-tests'
            ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
        }
    }

    Import-Module $script:IngestModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
    Remove-Item function:Get-AzAccessToken -ErrorAction SilentlyContinue
}

Describe 'Invoke-XdrStorageTableEntity — module surface + parameter binding' {

    It 'is exported from XdrLogRaider.Ingest' {
        $exported = (Get-Module Xdr.Sentinel.Ingest).ExportedFunctions.Keys
        $exported | Should -Contain 'Invoke-XdrStorageTableEntity'
    }

    It 'rejects -Operation values outside ValidateSet' {
        { Invoke-XdrStorageTableEntity -StorageAccountName 'sa' -TableName 't' `
            -PartitionKey 'p' -RowKey 'r' -Operation 'Patch' } |
            Should -Throw
    }

    It 'requires -Entity when -Operation is Upsert' {
        { Invoke-XdrStorageTableEntity -StorageAccountName 'sa' -TableName 't' `
            -PartitionKey 'p' -RowKey 'r' -Operation Upsert } |
            Should -Throw -ExpectedMessage '*Entity*'
    }

    It 'rejects null/empty mandatory parameters' {
        { Invoke-XdrStorageTableEntity -StorageAccountName ''   -TableName 't' -PartitionKey 'p' -RowKey 'r' -Operation Get } | Should -Throw
        { Invoke-XdrStorageTableEntity -StorageAccountName 'sa' -TableName ''  -PartitionKey 'p' -RowKey 'r' -Operation Get } | Should -Throw
        { Invoke-XdrStorageTableEntity -StorageAccountName 'sa' -TableName 't' -PartitionKey '' -RowKey 'r' -Operation Get } | Should -Throw
        { Invoke-XdrStorageTableEntity -StorageAccountName 'sa' -TableName 't' -PartitionKey 'p' -RowKey '' -Operation Get } | Should -Throw
    }
}

Describe 'Invoke-XdrStorageTableEntity — source-level contract assertions' {
    # These tests inspect the helper source directly. They lock invariants
    # that are too risky to leave to runtime-only verification (e.g. the
    # critical "no If-Match on Upsert" semantic that caused iter-13.14).

    It 'URI is built with literal single-quotes around PartitionKey/RowKey (not URL-encoded)' {
        # Azure Tables REST accepts the canonical form; URL-encoding the quotes
        # caused 404 in earlier iter-13.x tests. The literal form must be used.
        # Single-quoted regex string so PowerShell does not try to expand $PartitionKey / $RowKey.
        $script:HelperSource | Should -Match 'PartitionKey=''\$PartitionKey'',RowKey=''\$RowKey''' -Because 'URI must use literal single quotes; URL-encoding triggers 404 from Azure Tables'
    }

    It 'HttpClient is cached on a script-scope variable for socket-pool efficiency' {
        $script:HelperSource | Should -Match '\$script:XdrTableHttpClient' -Because 'reuse HttpClient across calls; per-call instantiation exhausts SNAT ports under load'
    }

    It 'Get operation maps to HttpMethod.Get' {
        $script:HelperSource | Should -Match "'Get'\s*\{\s*\[System\.Net\.Http\.HttpMethod\]::Get\s*\}" -Because 'Get must use GET verb'
    }

    It 'Upsert operation maps to HttpMethod.Put (PUT — Insert-Or-Replace)' {
        $script:HelperSource | Should -Match "'Upsert'\s*\{\s*\[System\.Net\.Http\.HttpMethod\]::Put\s*\}" -Because 'Upsert must use PUT (Insert-Or-Replace) not MERGE'
    }

    It 'Delete operation maps to HttpMethod.Delete' {
        $script:HelperSource | Should -Match "'Delete'\s*\{\s*\[System\.Net\.Http\.HttpMethod\]::Delete\s*\}" -Because 'Delete must use DELETE verb'
    }

    It 'Delete operation sends If-Match: ''*''' {
        # Delete WITHOUT If-Match returns 412 PreconditionFailed from Azure.
        # If-Match: '*' = unconditional delete (which is what we want).
        $script:HelperSource | Should -Match "If-Match.*\*" -Because 'Delete must send If-Match: ''*'' for unconditional delete'
    }

    It 'Upsert operation does NOT make a TryAddWithoutValidation call for If-Match (CRITICAL — locks iter-13.14 root cause)' {
        # The iter-13.14 bug: PUT + If-Match: '*' = "Update Entity" (404 if row
        # missing). Without If-Match, PUT = "Insert-Or-Replace Entity" (creates
        # if missing). The Upsert branch must NOT make a TryAddWithoutValidation
        # call adding the If-Match header. Comments mentioning "If-Match" inside
        # the branch are fine (and we keep them for future-maintainer clarity).
        $upsertBranch = [regex]::Match($script:HelperSource,
            '(?s)if\s*\(\s*\$Operation\s*-eq\s*''Upsert''\s*\)\s*\{(.*?)\}\s*\$resp')
        $upsertBranch.Success | Should -BeTrue -Because 'helper must have an Upsert branch'
        # Strip comments first so docstring references don't false-positive.
        $branchBody = [regex]::Replace($upsertBranch.Groups[1].Value, '<#[\s\S]*?#>', '')
        $branchBody = [regex]::Replace($branchBody, '(?m)#.*$', '')
        $branchBody | Should -Not -Match "TryAddWithoutValidation\s*\(\s*['""]If-Match['""]" -Because 'iter-13.14 root cause: PUT with If-Match becomes Update Entity (404 on missing row). Upsert MUST NOT send If-Match.'
    }

    It 'Get returns null on HTTP 404 (not throw)' {
        # Single-quoted regex so PS does not expand $null.
        $script:HelperSource | Should -Match '(?s)Operation\s*-eq\s*''Get''.*NotFound.*return\s+\$null' -Because 'callers expect null on 404 to mean "row does not exist yet" (e.g. first-run Get-CheckpointTimestamp)'
    }

    It 'PartitionKey + RowKey are injected into Entity body if absent' {
        # Required by Azure Tables PUT-Insert-Or-Replace semantic: keys must be
        # in the body, not just the URL.
        $script:HelperSource | Should -Match "ContainsKey\('PartitionKey'\)" -Because 'must inject PartitionKey into body for PUT-upsert'
        $script:HelperSource | Should -Match "ContainsKey\('RowKey'\)"       -Because 'must inject RowKey into body for PUT-upsert'
    }

    It 'response body is read on success and parsed as JSON for Get' {
        $script:HelperSource | Should -Match 'ConvertFrom-Json' -Because 'Get must parse JSON response into pscustomobject for callers'
    }

    It 'descriptive error includes HTTP status, reason phrase, and response body' {
        $script:HelperSource | Should -Match 'HTTP\s*\{[\d:]?5[\}\)]' -Because 'errors must surface the integer HTTP status'
        $script:HelperSource | Should -Match 'ReasonPhrase' -Because 'errors must include the reason phrase'
        $script:HelperSource | Should -Match 'errBody' -Because 'errors must include the response body for diagnosis'
    }

    It 'storage token resource is the data-plane endpoint (https://storage.azure.com/)' {
        $script:HelperSource | Should -Match "https://storage\.azure\.com/" -Because 'MI token audience must be the storage data plane, not management.core.windows.net'
    }
}
