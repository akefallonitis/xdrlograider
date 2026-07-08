#Requires -Version 7.4
# Φ2 G-A · generic read-via-POST BodyTemplate derivation. Proves Get-XdrPostmanBodyTemplate EXTRACTS a real request body
# from the Postman corpus and REJECTS key_N stubs + empty {} + arrays + non-JSON + missing (never fabricates), and that
# the derived catalogue is honest (BodyTemplates are real objects · 0 POST ops ship · include-gated). RED on pre-G-A:
# the reader did not exist and the catalogue carried 0 BodyTemplates. v0.1.0 Φ2 deliverable.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    # AST-extract the function under test (do NOT dot-source Build-Catalogue — it would run the whole build).
    $src = Get-Content "$script:repo\dev-tools\Build-Catalogue.ps1" -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $fn  = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-XdrPostmanBodyTemplate' }, $true)
    if (-not $fn) { throw 'Get-XdrPostmanBodyTemplate not found in Build-Catalogue.ps1 (G-A not wired)' }
    . ([scriptblock]::Create($fn.Extent.Text))
    $script:PostmanCache = @{}; $script:PostmanBodyIndex = @{}   # script-scope deps the function reads

    # synthetic Postman collection: one real body, one key_N stub, one empty {}, one array, one missing-body
    $script:fix = Join-Path ([IO.Path]::GetTempPath()) "xdrlr-bt-fix-$([guid]::NewGuid().Guid).json"
    $coll = @{ info = @{ name = 'fix' }; item = @(
        @{ name = 'real';  request = @{ method = 'POST'; url = @{ path = @('api', 'real') };  body = @{ mode = 'raw'; raw = '{"filters":{"type":"X"},"top":50}' } } }
        @{ name = 'stub';  request = @{ method = 'POST'; url = @{ path = @('api', 'stub') };  body = @{ mode = 'raw'; raw = '{"key_1":"v","key_2":"w"}' } } }
        @{ name = 'empty'; request = @{ method = 'POST'; url = @{ path = @('api', 'empty') }; body = @{ mode = 'raw'; raw = '{}' } } }
        @{ name = 'arr';   request = @{ method = 'POST'; url = @{ path = @('api', 'arr') };   body = @{ mode = 'raw'; raw = '[1,2,3]' } } }
        @{ name = 'nobody'; request = @{ method = 'POST'; url = @{ path = @('api', 'nobody') } } }
    ) }
    $coll | ConvertTo-Json -Depth 30 | Set-Content $script:fix -Encoding utf8
}
AfterAll { if ($script:fix -and (Test-Path $script:fix)) { Remove-Item $script:fix -Force } }

Describe 'Φ2 G-A · Get-XdrPostmanBodyTemplate (extract-real · reject-garbage · never-fabricate)' {
    It 'EXTRACTS a real request body (object with real keys)' {
        $b = Get-XdrPostmanBodyTemplate $script:fix '/api/real' 'POST'
        $b | Should -Not -BeNullOrEmpty
        ($b | ConvertFrom-Json).top | Should -Be 50
    }
    It 'REJECTS a key_N stub body → $null' { Get-XdrPostmanBodyTemplate $script:fix '/api/stub'  'POST' | Should -BeNullOrEmpty }
    It 'REJECTS an empty {} body → $null'  { Get-XdrPostmanBodyTemplate $script:fix '/api/empty' 'POST' | Should -BeNullOrEmpty }
    It 'REJECTS an array body → $null'     { Get-XdrPostmanBodyTemplate $script:fix '/api/arr'   'POST' | Should -BeNullOrEmpty }
    It 'REJECTS a missing body → $null'    { Get-XdrPostmanBodyTemplate $script:fix '/api/nobody' 'POST' | Should -BeNullOrEmpty }
    It 'returns $null for an unknown path (never fabricates)' { Get-XdrPostmanBodyTemplate $script:fix '/api/zzz' 'POST' | Should -BeNullOrEmpty }
}

Describe 'Φ2 G-A · derived catalogue is honest' {
    BeforeAll {
        $cat = Get-Content "$script:repo\references\inventory\nodoc-defender-xdr\catalogue.json" -Raw | ConvertFrom-Json
        $script:ops = $cat.Operations
        $script:bt  = @($script:ops | Where-Object { $_.BodyTemplate })
    }
    It 'extracts >=1 real BodyTemplate from the corpus (RED on pre-G-A · 0 BodyTemplates)' {
        $script:bt.Count | Should -BeGreaterThan 0
    }
    It 'every BodyTemplate present is a REAL non-empty object (no stub / empty / non-JSON slipped through)' {
        foreach ($o in $script:bt) {
            $obj = $o.BodyTemplate | ConvertFrom-Json
            $obj | Should -BeOfType [pscustomobject]
            $names = @($obj.PSObject.Properties.Name)
            $names.Count | Should -BeGreaterThan 0
            (@($names | Where-Object { $_ -notmatch '^key_?\d+$' }).Count) | Should -BeGreaterThan 0 -Because "$($o.OperationId) must not be an all-key_N stub"
        }
    }
    It 'ships 0 POST ops (honest · corpus telemetry-POST bodies are garbage · §2 G-A)' {
        @($script:ops | Where-Object { $_.Shipped -and $_.Method -eq 'POST' }).Count | Should -Be 0
    }
    It 'BodyTemplate ops are all include-gated (never on an Excluded op)' {
        @($script:bt | Where-Object { $_.ScopeDecision -eq 'Exclude' }).Count | Should -Be 0
    }
}

Describe 'Φ2 G-A · Generate-Manifest emits BodyTemplate (runtime reads $Entry[BodyTemplate] · Runtime.psm1:1774)' {
    # No Validated op carries a BodyTemplate today (the telemetry-grade POST candidates have garbage bodies), so the
    # emit is foundational + must be proven synthetically: a Validated op WITH a BodyTemplate must surface it in the
    # generated manifest. RED on pre-fix (Generate-Manifest had no BodyTemplate emit line).
    It 'emits BodyTemplate into the manifest entry when the op carries one' {
        $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $tmp  = Join-Path ([IO.Path]::GetTempPath()) "xdrlr-btmani-$([guid]::NewGuid().Guid)"
        $inv  = Join-Path $tmp 'references/inventory'
        New-Item -ItemType Directory -Path (Join-Path $inv 'nodoc-defender-xdr') -Force | Out-Null
        try {
            Copy-Item "$repo\references\inventory\portals.json" (Join-Path $inv 'portals.json')
            # Generate-Manifest emits the Shipped ops of a Group; take a real Shipped op (a GET, so byte-real) and graft
            # a BodyTemplate onto it in a test Group — proves the emit path without needing a Validated POST body.
            $op = (Get-Content "$repo\references\inventory\nodoc-defender-xdr\catalogue.json" -Raw | ConvertFrom-Json).Operations |
                  Where-Object { $_.Shipped } | Select-Object -First 1
            $op.Category = 'BtTestGrp'
            $op | Add-Member -NotePropertyName BodyTemplate -NotePropertyValue '{"probe":true}' -Force
            @{ Operations = @($op) } | ConvertTo-Json -Depth 60 | Set-Content (Join-Path $inv 'nodoc-defender-xdr/catalogue.json') -Encoding utf8
            $out = Join-Path $tmp 'out.psd1'
            & pwsh -NoProfile -File "$repo\dev-tools\Generate-Manifest.ps1" -Portal Defender -Group BtTestGrp -RepoRoot $tmp -OutPath $out 2>&1 | Out-Null
            $mani = Get-Content $out -Raw
            $mani | Should -Match 'BodyTemplate'
            $mani | Should -Match 'probe'
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
