#Requires -Version 7.4
# F-REQHEADERS (2026-06-25) · Generate-Manifest emits per-op REQUEST HEADERS from curation, SPARSELY. Mirrors the
# columnTypes / volatileHashFields seam: the generator reads `requestHeaders` (keyed by OperationId) DIRECTLY from
# curation.json (NOT catalogue-derived) and emits RequestHeaders = @{ '<header>' = '<value>' } onto ONLY the declared op
# — every op WITHOUT a declaration stays byte-identical (no RequestHeaders key). RED before the fix: the field is absent.
#
# Uses a self-contained MOCK RepoRoot (portals.json + catalogue.json + curation.json under a temp dir) — NOT the real
# references/inventory/* curation (the prompt SCOPE LOCK: that flow is owned elsewhere; this proves the mechanism generically).
# Generate-Manifest reads its DATA from -RepoRoot but imports the Parser module from its own $PSScriptRoot, so the temp
# RepoRoot needs only the three JSON inputs.

Describe 'F-REQHEADERS · Generate-Manifest emits RequestHeaders from curation (sparse)' {
    BeforeAll {
        $script:realRepo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:gen      = Join-Path $script:realRepo 'dev-tools/Generate-Manifest.ps1'
        $script:root     = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-reqh-" + [Guid]::NewGuid().ToString('N'))
        $script:invDir   = Join-Path $script:root 'references/inventory/nodoc-mock-tvm'
        $null = New-Item -ItemType Directory -Path $script:invDir -Force

        # portals.json · the single mock portal (PortalKey resolves via the generator's friendly/short fallback → 'NodocMockTvm'
        # from PortalShort, but we drive -Portal by the PortalKey itself, which is always an accepted alias).
        $portals = @{ portals = @(@{ PortalKey = 'nodoc-mock-tvm'; PortalShort = 'nodoc-mock-tvm' }) }
        $portals | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $script:root 'references/inventory/portals.json') -Encoding utf8

        # A minimal-but-VALID catalogue op shape (the fields Generate-Manifest's $entry reads). Two ops in group 'MockCat':
        #   GetTvmThing  · WILL have a requestHeaders curation entry  → manifest carries RequestHeaders
        #   GetPlainList · NO curation entry                          → manifest omits RequestHeaders (sparse invariant)
        $mkOp = {
            param($op, $oid)
            @{
                Operation = $op; OperationId = $oid; Category = 'MockCat'; Subcategory = 'Sub'; Shipped = $true
                Method = 'GET'; SubPortal = 'mock'; Path = "/api/$op"; ResponseShape = 'wrapper'; ItemsContainer = 'value'
                Cadence = '01:00:00'; IngestionMode = 'SNAPSHOT'; CursorField = $null; NaturalKey = @('id')
                TimeFilter = $null; Pagination = $null; RequiresProducts = @(); EntityResolution = 'NotEntity'
                ProjectionMap = @{ id = '$.id' }
                DcrStreamName = 'Custom-Defender_MockCat_CL'; WorkspaceTable = 'Defender_MockCat_CL'
                Provenance = @{ Live = $null; Postman = 'mock.postman'; OpenApi = 'mock.openapi' }
            }
        }
        $catalogue = @{ Operations = @((& $mkOp 'GetTvmThing' 'GetTvmThing'), (& $mkOp 'GetPlainList' 'GetPlainList')) }
        $catalogue | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $script:invDir 'catalogue.json') -Encoding utf8

        # curation.json · declare requestHeaders for GetTvmThing ONLY (and a _doc that must be skipped).
        $curation = @{
            portal = 'Defender'; portalKey = 'nodoc-mock-tvm'
            requestHeaders = @{
                _doc        = 'per-op REQUEST headers'
                GetTvmThing = @{ 'api-version' = '1.0' }
            }
        }
        $curation | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $script:invDir 'curation.json') -Encoding utf8

        $script:out = Join-Path $script:root 'out.psd1'
        & pwsh -NoProfile -File $script:gen -Portal 'nodoc-mock-tvm' -Group 'MockCat' -RepoRoot $script:root -OutPath $script:out *> (Join-Path $script:root 'gen.log')
        $script:manifest = if (Test-Path $script:out) { Import-PowerShellDataFile $script:out } else { $null }
        $script:genLog   = if (Test-Path (Join-Path $script:root 'gen.log')) { Get-Content (Join-Path $script:root 'gen.log') -Raw } else { '' }
    }
    AfterAll { if ($script:root -and (Test-Path $script:root)) { Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'generates the mock manifest (sanity · else the gen log explains why)' {
        $script:manifest | Should -Not -BeNullOrEmpty -Because "Generate-Manifest must emit the mock category. gen.log: $script:genLog"
        @($script:manifest.Operations).Count | Should -Be 2
    }

    It 'the declared op carries RequestHeaders = @{ api-version = 1.0 } (string->string)' {
        $op = $script:manifest.Operations | Where-Object { $_.OperationKey -eq 'GetTvmThing' }
        $op | Should -Not -BeNullOrEmpty
        $op.ContainsKey('RequestHeaders')         | Should -BeTrue -Because 'curation declared a requestHeaders entry for this op'
        $op.RequestHeaders                         | Should -BeOfType [System.Collections.IDictionary]
        $op.RequestHeaders['api-version']          | Should -Be '1.0'
        ([string]$op.RequestHeaders['api-version']) | Should -BeOfType [string]
    }

    It 'the UNDECLARED op OMITS RequestHeaders entirely (the SPARSE / byte-identical invariant)' {
        $op = $script:manifest.Operations | Where-Object { $_.OperationKey -eq 'GetPlainList' }
        $op | Should -Not -BeNullOrEmpty
        $op.ContainsKey('RequestHeaders') | Should -BeFalse -Because 'an op with no curation declaration must stay byte-identical (no RequestHeaders key)'
    }

    It 'the emitted psd1 quotes the hyphenated header key (parseable · round-trips through Import-PowerShellDataFile)' {
        # Import-PowerShellDataFile already succeeded above, but assert the literal quoting so a future serializer change
        # that emits a bare `api-version =` (a parse error) is caught here, not at deploy.
        (Get-Content $script:out -Raw) | Should -Match "'api-version'\s*=\s*'1\.0'"
    }
}
