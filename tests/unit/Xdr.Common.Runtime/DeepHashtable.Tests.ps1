#Requires -Version 7.4
# Regression pin for the live 0-rows blocker: Durable Functions serialization can deliver the Activity entry
# with NESTED ProjectionMap/TimeFilter/Pagination as PSCustomObject. The Activity normalizes only the top level,
# so a nested PSCustomObject ProjectionMap hit ConvertTo-XdrRows' [hashtable] param →
# ParameterBindingArgumentTransformationException on EVERY poll (confirmed live · commit 8cb2d6f). The fix:
# Invoke-XdrEntryPoll deep-normalizes the entry (ConvertTo-XdrDeepHashtable) first. These tests pin both.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    # The poll reads $env:XDRLR_DCE_ENDPOINT before the (mocked) Send-ToDce; set a dummy so the binding
    # completes (an FA appSetting in production · empty in a bare test runspace).
    $env:XDRLR_DCE_ENDPOINT = 'https://dummy.dce.example/ingest'
}

Describe 'ConvertTo-XdrDeepHashtable' {
    It 'converts a top-level PSCustomObject to a plain hashtable' {
        $r = ConvertTo-XdrDeepHashtable -InputObject ([pscustomobject]@{ a = 1; b = 'c' })
        $r -is [hashtable] | Should -BeTrue
        $r['a'] | Should -Be 1
        $r['b'] | Should -Be 'c'
    }
    It 'recursively converts NESTED PSCustomObject values to hashtables' {
        $r = ConvertTo-XdrDeepHashtable -InputObject ([pscustomobject]@{ Outer = [pscustomobject]@{ Inner = 'v' } })
        $r['Outer'] -is [hashtable] | Should -BeTrue
        $r['Outer']['Inner'] | Should -Be 'v'
    }
    It 'converts arrays element-wise (array of PSCustomObject -> array of hashtable)' {
        $r = ConvertTo-XdrDeepHashtable -InputObject @([pscustomobject]@{ x = 1 }, [pscustomobject]@{ x = 2 })
        @($r).Count | Should -Be 2
        $r[0] -is [hashtable] | Should -BeTrue
        $r[1]['x'] | Should -Be 2
    }
    It 'passes scalars / null / datetime through unchanged' {
        ConvertTo-XdrDeepHashtable -InputObject 'str' | Should -Be 'str'
        ConvertTo-XdrDeepHashtable -InputObject 42 | Should -Be 42
        (ConvertTo-XdrDeepHashtable -InputObject $null) | Should -BeNullOrEmpty
        $dt = [datetime]'2026-06-03T10:00:00Z'
        ConvertTo-XdrDeepHashtable -InputObject $dt | Should -Be $dt
    }
    It 'flattens an OrderedHashtable (ConvertFrom-Json -AsHashtable) to a plain hashtable' {
        $oh = '{"k":{"n":1}}' | ConvertFrom-Json -AsHashtable
        $r = ConvertTo-XdrDeepHashtable -InputObject $oh
        $r -is [hashtable] | Should -BeTrue
        $r['k'] -is [hashtable] | Should -BeTrue
        $r['k']['n'] | Should -Be 1
    }
}

Describe 'Invoke-XdrEntryPoll · PSCustomObject-nested entry (live Durable shape)' {
    It 'polls successfully when ProjectionMap/TimeFilter/Pagination arrive as PSCustomObject (was: ParameterBindingArgumentTransformationException)' {
        $m = Import-PowerShellDataFile (Join-Path $script:Repo 'manifests\Defender\Operations.psd1')
        $op = $m.Operations[0]
        $entry = @{}
        foreach ($k in $op.Keys) { $entry[$k] = $op[$k] }
        $entry['Portal'] = $m.Portal; $entry['Category'] = $m.Category
        $entry['DcrImmutableId'] = 'dcr-test-immutable-id'   # Refresh injects this from the DCR env var (G-Provisioned guarantees non-empty)
        # Simulate Durable PSCustomObject delivery of the NESTED objects (the exact live failure shape).
        foreach ($nested in 'ProjectionMap', 'TimeFilter', 'Pagination') {
            if ($entry.ContainsKey($nested) -and $entry[$nested] -is [System.Collections.IDictionary]) {
                $entry[$nested] = [pscustomobject]$entry[$nested]
            }
        }
        $entry['ProjectionMap'] -is [System.Management.Automation.PSCustomObject] | Should -BeTrue -Because 'test setup must reproduce the PSCustomObject shape'

        $fixture = @{ Count = 2; Results = @(
            @{ ActionId = 'a1'; EventTime = '2026-06-03T10:00:00Z'; Title = 't1' },
            @{ ActionId = 'a2'; EventTime = '2026-06-03T09:00:00Z'; Title = 't2' }
        ) }
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y'; Cookie = 'sccauth=x' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = $fixture; RawBody = '{}' } }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = 2; BytesIngested = 100; ErrorClass = $null; ErrorMessage = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; WindowStartUtc = $null; WindowEndUtc = $null; LastUpdatedUtc = $null; LastItemCount = 0; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCircuitState { @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Test-XdrCircuitClosed { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        # G3 · grant the single-flight lease (real Blob-lease infra absent in unit tests · un-mocked acquire → $null
        # → would skip as 'contended'). Granting exercises the normal deep-normalize → poll path.
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }

        $r = Invoke-XdrEntryPoll -Entry $entry -CorrelationId 'pin'
        $r.Success | Should -BeTrue -Because "deep-normalize must absorb the PSCustomObject nested shape; got ErrorClass=$($r.ErrorClass) Msg=$($r.ErrorMessage)"
        $r.ItemCount | Should -Be 2
    }

    It 'survives the Refresh JSON-serialize -> Activity ConvertFrom-Json -AsHashtable contract and polls to rows' {
        # The runtime contract: Refresh serializes each entry to a JSON string (Durable ToString()'s live
        # nested hashtables to "System.Collections.Hashtable"); the Activity parses it with -AsHashtable.
        $m = Import-PowerShellDataFile (Join-Path $script:Repo 'manifests\Defender\Operations.psd1')
        $op = $m.Operations[0]
        $entry = @{}
        foreach ($k in $op.Keys) { $entry[$k] = $op[$k] }
        $entry['Portal'] = $m.Portal; $entry['Category'] = $m.Category; $entry['DcrImmutableId'] = 'dcr-test-immutable-id'
        $entryJson = $entry | ConvertTo-Json -Depth 20 -Compress                 # Refresh side
        $parsed    = $entryJson | ConvertFrom-Json -AsHashtable -Depth 30        # Activity side
        $parsed['ProjectionMap'] -is [System.Collections.IDictionary] | Should -BeTrue -Because 'JSON round-trip preserves ProjectionMap as a dictionary, not the corrupted string'

        $fixture = @{ Count = 2; Results = @(
            @{ ActionId = 'a1'; EventTime = '2026-06-03T10:00:00Z'; Title = 't1' },
            @{ ActionId = 'a2'; EventTime = '2026-06-03T09:00:00Z'; Title = 't2' }
        ) }
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y'; Cookie = 'sccauth=x' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = $fixture; RawBody = '{}' } }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = 2; BytesIngested = 100; ErrorClass = $null; ErrorMessage = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; WindowStartUtc = $null; WindowEndUtc = $null; LastUpdatedUtc = $null; LastItemCount = 0; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCircuitState { @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Test-XdrCircuitClosed { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        # G3 · grant the single-flight lease (real Blob-lease infra absent in unit tests · un-mocked acquire → $null
        # → would skip as 'contended'). Granting exercises the normal deep-normalize → poll path.
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }

        $r = Invoke-XdrEntryPoll -Entry $parsed -CorrelationId 'json-pin'
        $r.Success | Should -BeTrue -Because "round-tripped entry must poll; got ErrorClass=$($r.ErrorClass) Msg=$($r.ErrorMessage)"
        $r.ItemCount | Should -Be 2
    }
}

Describe 'ConvertFrom-XdrActivityInput · Durable orchestrator->activity hop (the empty-entry / .Length 0-rows blocker)' {
    # The Orchestrator passes the activity input as a JSON STRING wrapper. The Durable PS serializer mangled a
    # LIVE hashtable on this hop (keys lost → empty entry → Op=unknown → empty URL → 500 → 0 rows live). This
    # pins reconstruction from EVERY shape Durable can deliver + the never-throw contract.
    BeforeAll {
        $script:op    = @{ OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; ProjectionMap = @{ ActionId = '$.ActionId'; EventTime = '$.EventTime' } }
        $script:ejson = $script:op | ConvertTo-Json -Depth 20 -Compress
        $script:guid  = '11111111-2222-3333-4444-555555555555'
    }
    It 'parses the JSON-STRING wrapper the Orchestrator now emits (entry + nested ProjectionMap + CycleId)' {
        $wrapperJson = @{ EntryJson = $script:ejson; CycleId = $script:guid } | ConvertTo-Json -Compress
        $r = ConvertFrom-XdrActivityInput -InputData $wrapperJson
        $r.CycleId | Should -Be $script:guid
        $r.Entry -is [hashtable] | Should -BeTrue
        $r.Entry['OperationKey'] | Should -Be 'GetHistory'
        $r.Entry['ProjectionMap'] -is [System.Collections.IDictionary] | Should -BeTrue
    }
    It 'parses a live [hashtable] wrapper' {
        $r = ConvertFrom-XdrActivityInput -InputData @{ EntryJson = $script:ejson; CycleId = $script:guid }
        $r.CycleId | Should -Be $script:guid
        $r.Entry['OperationKey'] | Should -Be 'GetHistory'
    }
    It 'parses an OrderedDictionary wrapper' {
        $r = ConvertFrom-XdrActivityInput -InputData ([ordered]@{ EntryJson = $script:ejson; CycleId = $script:guid })
        $r.Entry['OperationKey'] | Should -Be 'GetHistory'
    }
    It 'parses a PSCustomObject wrapper (JSON round-trip path)' {
        $r = ConvertFrom-XdrActivityInput -InputData ([pscustomobject]@{ EntryJson = $script:ejson; CycleId = $script:guid })
        $r.Entry['OperationKey'] | Should -Be 'GetHistory'
        $r.CycleId | Should -Be $script:guid
    }
    It 'UNWRAPS a 1-element array wrapping the hashtable (suspected live shape · was: empty entry + .Length throw)' {
        $r = ConvertFrom-XdrActivityInput -InputData (, @{ EntryJson = $script:ejson; CycleId = $script:guid })
        $r.Entry['OperationKey'] | Should -Be 'GetHistory' -Because 'array-wrapping must not lose the wrapper keys (old PSObject.Properties path read array .Length/.Count as bogus keys)'
        $r.CycleId | Should -Be $script:guid
    }
    It 'honors the legacy Entry fallback (no EntryJson)' {
        $r = ConvertFrom-XdrActivityInput -InputData @{ Entry = @{ OperationKey = 'Legacy'; Portal = 'Defender' }; CycleId = $script:guid }
        $r.Entry['OperationKey'] | Should -Be 'Legacy'
    }
    It 'is case-insensitive on the wrapper keys' {
        $r = ConvertFrom-XdrActivityInput -InputData @{ entryjson = $script:ejson; cycleid = $script:guid }
        $r.Entry['OperationKey'] | Should -Be 'GetHistory'
        $r.CycleId | Should -Be $script:guid
    }
    It 'NEVER throws on null / non-JSON string / scalar (Activity never-throw contract)' {
        { ConvertFrom-XdrActivityInput -InputData $null } | Should -Not -Throw
        (ConvertFrom-XdrActivityInput -InputData $null).Entry | Should -BeOfType [hashtable]
        (ConvertFrom-XdrActivityInput -InputData 'System.Collections.Hashtable').Entry.Count | Should -Be 0
        (ConvertFrom-XdrActivityInput -InputData 42).CycleId | Should -Be ''
    }
    It 'always returns Entry as a [hashtable] (Invoke-XdrEntryPoll [hashtable] param) and CycleId as a string' {
        $r = ConvertFrom-XdrActivityInput -InputData (@{ EntryJson = $script:ejson; CycleId = $script:guid } | ConvertTo-Json -Compress)
        $r.Entry -is [hashtable] | Should -BeTrue
        $r.CycleId | Should -BeOfType [string]
    }
}

Describe 'Full two-hop JSON-string contract · Refresh -> Orchestrator -> Activity (the {"CycleId":[],"EntryJson":[]} fix)' {
    # Live RAW-INPUT on 0a25e68 showed the activity wrapper arriving as {"CycleId":[],"EntryJson":[]} — the
    # Refresh->Orchestrator hop passed $body as a LIVE hashtable and the Durable PS serializer corrupted every
    # string leaf into an empty array. Both hops must pass JSON STRINGS. This pins the data contract end-to-end:
    # values (CycleId GUID + each Entries element + nested ProjectionMap) survive both serialize/parse hops.
    It 'preserves CycleId + Entries string values across the Refresh JSON-string orchestration input' {
        $entry = @{ OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; ProjectionMap = @{ ActionId = '$.ActionId' }; DcrImmutableId = 'dcr-x' }
        $cycleId = '99999999-8888-7777-6666-555555555555'
        # Refresh side: Entries = array of per-entry JSON strings; whole body serialized to ONE JSON string.
        $body = @{ CycleId = $cycleId; CycleStartUtc = '2026-06-04T00:00:00Z'; Entries = @($entry | ConvertTo-Json -Depth 20 -Compress); Portal = 'Defender' }
        $bodyJson = $body | ConvertTo-Json -Depth 25 -Compress
        $bodyJson | Should -BeOfType [string]
        # Durable parses the JSON-string input → orchestrator's $Context.Input (proven dot-access read).
        $cycleData = $bodyJson | ConvertFrom-Json -AsHashtable -Depth 30
        $cycleData.CycleId | Should -Be $cycleId -Because 'the GUID must NOT become an empty array'
        @($cycleData.Entries).Count | Should -Be 1
        ([string]@($cycleData.Entries)[0]).Length | Should -BeGreaterThan 0 -Because 'each Entries element must stay a non-empty JSON string'
    }
    It 'reconstructs a populated entry through BOTH hops (orchestrator activity-input is also a JSON string)' {
        $entry = @{ OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; ProjectionMap = @{ ActionId = '$.ActionId'; EventTime = '$.EventTime' }; DcrImmutableId = 'dcr-x' }
        $cycleId = '99999999-8888-7777-6666-555555555555'
        $body = @{ CycleId = $cycleId; CycleStartUtc = '2026-06-04T00:00:00Z'; Entries = @($entry | ConvertTo-Json -Depth 20 -Compress); Portal = 'Defender' }
        $cycleData = ($body | ConvertTo-Json -Depth 25 -Compress) | ConvertFrom-Json -AsHashtable -Depth 30   # hop 1: Refresh->Orchestrator
        foreach ($entryJson in $cycleData.Entries) {
            $activityInput = @{ EntryJson = $entryJson; CycleId = $cycleData.CycleId } | ConvertTo-Json -Compress  # hop 2: Orchestrator->Activity
            $parsed = ConvertFrom-XdrActivityInput -InputData $activityInput
            $parsed.CycleId | Should -Be $cycleId
            $parsed.Entry['OperationKey'] | Should -Be 'GetHistory'
            $parsed.Entry['ProjectionMap'] -is [System.Collections.IDictionary] | Should -BeTrue
            $parsed.Entry['DcrImmutableId'] | Should -Be 'dcr-x'
        }
    }
}

Describe 'BASE64 hop encoding · Durable parses+empties raw JSON inputs, so both hops base64-encode (live 0a25e68/5151fed fix)' {
    # Live RAW-INPUT proved $Context.Input / activity input arrive as {"CycleId":[],"EntryJson":[]} when the
    # input is raw JSON (Durable empties string leaves). Refresh + Orchestrator now base64-encode; the
    # orchestrator decodes the orchestration input and ConvertFrom-XdrActivityInput decodes the activity input.
    BeforeAll {
        $script:op2    = @{ OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; ProjectionMap = @{ ActionId = '$.ActionId' }; DcrImmutableId = 'dcr-x' }
        $script:ejson2 = $script:op2 | ConvertTo-Json -Depth 20 -Compress
        $script:guid2  = '12121212-3434-5656-7878-909090909090'
    }
    It 'ConvertFrom-XdrActivityInput decodes a BASE64-encoded wrapper (the new Orchestrator->Activity shape)' {
        $wrapperJson = @{ EntryJson = $script:ejson2; CycleId = $script:guid2 } | ConvertTo-Json -Compress
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($wrapperJson))
        $r = ConvertFrom-XdrActivityInput -InputData $b64
        $r.CycleId | Should -Be $script:guid2
        $r.Entry['OperationKey'] | Should -Be 'GetHistory'
        $r.Entry['ProjectionMap'] -is [System.Collections.IDictionary] | Should -BeTrue
    }
    It 'still accepts a BARE JSON wrapper (base64 only attempted on punctuation-free strings)' {
        $wrapperJson = @{ EntryJson = $script:ejson2; CycleId = $script:guid2 } | ConvertTo-Json -Compress
        $r = ConvertFrom-XdrActivityInput -InputData $wrapperJson
        $r.CycleId | Should -Be $script:guid2
        $r.Entry['OperationKey'] | Should -Be 'GetHistory'
    }
    It 'full BASE64 two-hop · Refresh b64 -> Orchestrator decode -> Orchestrator b64 -> Activity decode' {
        # hop 1: Refresh base64-encodes the body JSON; orchestrator base64-decodes + parses.
        $body = @{ CycleId = $script:guid2; CycleStartUtc = '2026-06-04T00:00:00Z'; Entries = @($script:ejson2); Portal = 'Defender' }
        $bodyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 25 -Compress)))
        $cycleData = (([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bodyB64))) | ConvertFrom-Json -AsHashtable -Depth 30)
        $cycleData.CycleId | Should -Be $script:guid2
        foreach ($entryJson in $cycleData.Entries) {
            # hop 2: orchestrator base64-encodes the activity wrapper; activity decodes via the helper.
            $activityB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((@{ EntryJson = $entryJson; CycleId = $cycleData.CycleId } | ConvertTo-Json -Compress)))
            $parsed = ConvertFrom-XdrActivityInput -InputData $activityB64
            $parsed.CycleId | Should -Be $script:guid2
            $parsed.Entry['OperationKey'] | Should -Be 'GetHistory'
            $parsed.Entry['DcrImmutableId'] | Should -Be 'dcr-x'
        }
    }
}
