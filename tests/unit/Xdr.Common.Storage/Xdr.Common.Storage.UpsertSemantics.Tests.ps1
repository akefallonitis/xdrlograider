#Requires -Version 7.4
# Set-XdrTableEntity UPSERT semantics — the 050a5c0 bug, which was only HALF-applied (checkpoint only).
# PROVES: the default + '*' send NO If-Match header (Azure Tables Insert-Or-Replace → CREATES a first-ever
# entity) while a REAL etag sends a conditional If-Match (412-on-race · the checkpoint atomic path).
# REGRESSION GUARD for the root cause that left XdrTierState / TenantContext / TenantCapabilities /
# XdrCircuitState permanently EMPTY (no durable L2 session → a fresh TOTP auth burned every worker recycle).

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    # WS3.2 · SAVE+RESTORE (no process-wide leak → no real-network 401s from later unmocked reads).
    $script:SavedSa = $env:XDRLR_STORAGE_ACCOUNT
    $env:XDRLR_STORAGE_ACCOUNT = 'testsa'
}

AfterAll {
    if ($null -ne $script:SavedSa) { $env:XDRLR_STORAGE_ACCOUNT = $script:SavedSa } else { Remove-Item Env:XDRLR_STORAGE_ACCOUNT -ErrorAction SilentlyContinue }
}

Describe 'Set-XdrTableEntity · UPSERT-by-default (050a5c0 full fix · all StateStore writers)' {
    BeforeEach {
        # Mock the REST boundary so we can assert exactly which headers Set-XdrTableEntity emits.
        Mock -ModuleName Xdr.Common.Storage Invoke-XdrStorageRest { @{ Success = $true; StatusCode = 204; ETag = 'W/"new"'; Content = '' } }
    }

    It 'default (no -IfMatchETag) sends NO If-Match → Insert-Or-Replace CREATES the entity' {
        $r = Set-XdrTableEntity -TableName 'XdrTierState' -PartitionKey 'Defender' -RowKey 'svc@x.com' -Properties @{ SessionJson = '{}' }
        $r.Success | Should -BeTrue
        Should -Invoke -ModuleName Xdr.Common.Storage Invoke-XdrStorageRest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and -not $ExtraHeaders.ContainsKey('If-Match')
        }
    }

    It "'*' is a no-condition upsert alias → still NO If-Match (else it 404s a non-existent entity)" {
        $null = Set-XdrTableEntity -TableName 'XdrCircuitState' -PartitionKey 'Defender' -RowKey 'op' -Properties @{ State = 'Closed' } -IfMatchETag '*'
        Should -Invoke -ModuleName Xdr.Common.Storage Invoke-XdrStorageRest -Times 1 -Exactly -ParameterFilter {
            -not $ExtraHeaders.ContainsKey('If-Match')
        }
    }

    It 'a REAL etag sends a conditional If-Match (the checkpoint 412-on-race path · UNCHANGED · no regression)' {
        $null = Set-XdrTableEntity -TableName 'XdrCheckpoint' -PartitionKey 'Defender_Operations' -RowKey 'GetHistory' -Properties @{ Cursor = 'x' } -IfMatchETag 'W/"datetime-etag"'
        Should -Invoke -ModuleName Xdr.Common.Storage Invoke-XdrStorageRest -Times 1 -Exactly -ParameterFilter {
            $ExtraHeaders.ContainsKey('If-Match') -and $ExtraHeaders['If-Match'] -eq 'W/"datetime-etag"'
        }
    }
}

Describe 'Set-XdrCachedSession · durable L2 + loud failure' {
    It 'a failed L2 write is surfaced (not silently swallowed) and returns $false' {
        Mock -ModuleName Xdr.Common.Cache Set-XdrTableEntity { @{ Success = $false; StatusCode = 400; Error = 'PropertyValueTooLarge' } }
        $ok = Set-XdrCachedSession -Portal 'Defender' -UPN 'svc@x.com' -SessionData @{ Cookie = 'c' }
        $ok | Should -BeFalse
    }

    It 'a successful L2 write returns $true (upsert path)' {
        Mock -ModuleName Xdr.Common.Cache Set-XdrTableEntity { @{ Success = $true; StatusCode = 204 } }
        $ok = Set-XdrCachedSession -Portal 'Defender' -UPN 'svc@x.com' -SessionData @{ Cookie = 'c' }
        $ok | Should -BeTrue
    }
}
