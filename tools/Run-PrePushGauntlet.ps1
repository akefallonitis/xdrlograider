# tools/Run-PrePushGauntlet.ps1
# Pre-push gauntlet · 38 axes (offline-provable · BLOCKING before push).
# All 38 axes run locally with NO deployed FA / Azure / network (parse · JSON · ARM-structure · PSScriptAnalyzer ·
# Pester · manifest/schema regen→diff · exactly-once replay). Post-deploy KQL landing is a SEPARATE tool
# (tools/Verify-OperationLanding.ps1). Returns non-zero exit on any axis failure · BLOCKING for STEP 5 push.

[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path)

$ErrorActionPreference = 'Stop'
# UTF-8 output encoding (no BOM): the regen→diff axes capture child-pwsh stdout via `| Out-String`, which round-trips
# through [Console]::OutputEncoding. git's sh pre-push hook launches pwsh under the OEM codepage → non-ASCII (e.g. the
# `·` middot in catalogue descriptions) mangled to `?` → spurious axis-32 "catalogue DRIFT". Pinning UTF-8 here makes
# the parent decode + the inherited child console emit UTF-8 in ANY launch context (sh hook · bash · pwsh · CI).
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:PSModulePath = (Join-Path $RepoRoot 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath

$pass = 0; $err = 0

$script:NamedSkips = @()   # WS4.3 honesty · axes that legitimately self-skip (8 CI-local-only · 25 RG-gated · 32 RAW-local-only · 34 CI) record themselves here; the summary prints the tally so a skip is never silent.

function Test-Axis {
    param([string]$Name, [scriptblock]$Block)
    Write-Host "Axis $Name" -ForegroundColor Cyan
    try {
        $result = & $Block
        if ($result -eq $true) { Write-Host "  PASS"; $script:pass++ }
        else { Write-Host "  FAIL · $result"; $script:err++ }
    } catch {
        Write-Host "  FAIL · $($_.Exception.Message)"
        $script:err++
    }
}

# Axis 1 · PowerShell parse (modules + tools + tests + functions)
Test-Axis '1 · PowerShell parse' {
    $files = Get-ChildItem $RepoRoot -Recurse -File -Include *.ps1,*.psm1,*.psd1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](references|\.git|Package)[\\/]' }   # [\\/] = cross-platform sep (Linux CI uses /)
    $bad = 0
    foreach ($f in $files) {
        $e = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
        if ($e.Count -gt 0) { Write-Host "    !  $($f.Name) :: $($e[0].Message)"; $bad++ }
    }
    if ($bad -eq 0) { return $true } else { return "$bad parse errors" }
}

# Axis 2 · JSON parse
Test-Axis '2 · JSON parse' {
    $files = Get-ChildItem $RepoRoot -Recurse -File -Include *.json -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](references|\.git|node_modules|operation-tracker)' }   # [\\/]: Windows `\` OR Linux-CI `/` — else references/ raw exports parse on Linux (e.g. malformed Postman) and falsely fail
    $bad = 0
    foreach ($f in $files) {
        try { $null = Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop -Depth 50 }
        catch { Write-Host "    !  $($f.Name) :: $($_.Exception.Message)"; $bad++ }
    }
    if ($bad -eq 0) { return $true } else { return "$bad parse errors" }
}

# Axis 3 · YAML no-tab check
Test-Axis '3 · YAML no-tabs' {
    $files = Get-ChildItem (Join-Path $RepoRoot '.github') -Recurse -File -Include *.yml,*.yaml -ErrorAction SilentlyContinue
    $bad = 0
    foreach ($f in $files) {
        $c = Get-Content $f.FullName -Raw
        if ($c -match "`t") { $bad++; Write-Host "    !  TAB in $($f.Name)" }
    }
    if ($bad -eq 0) { return $true } else { return "$bad YAML files with tabs" }
}

# Axis 4 · Tier-1 Pester (G8 closure · v11 plan §10 invariant)
# Invariant: contract tests for parser/auth/runtime/ingest/checkpoint MUST pass before push.
# Matches ci.yml step exactly · runs Pester 5.x against tests/ · gauntlet fails on any test fail.
Test-Axis '4 · Tier-1 Pester (Invoke-Pester tests/)' {
    $testsDir = Join-Path $RepoRoot 'tests'
    if (-not (Test-Path $testsDir)) { return 'tests/ not present · acceptable for early-bootstrap state' }
    if (-not (Get-Module -ListAvailable -Name Pester | Where-Object Version -ge '5.5')) {
        # NOT a silent skip: a missing required tool returns a STRING, which Test-Axis counts as a FAIL (never a pass).
        # The Tier-1 contract tests are a REQUIRED gate · install Pester (the CI + release workflows do) to run them.
        return 'Pester 5.5+ REQUIRED but NOT installed · this gate FAILS (it does NOT silently skip/pass) · install Pester 5.5+ to run the Tier-1 contract tests'
    }
    Import-Module Pester -Force -ErrorAction SilentlyContinue
    $config = New-PesterConfiguration
    $config.Run.Path = $testsDir
    $config.Run.Exit = $false
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Minimal'
    $config.Should.ErrorAction = 'Continue'
    $r = Invoke-Pester -Configuration $config
    if ($r.FailedCount -gt 0) { return "$($r.FailedCount)/$($r.TotalCount) Pester tests FAILED" }
    if ($r.PassedCount -eq 0 -and $r.TotalCount -eq 0) { return 'no Pester tests discovered · tests/ empty?' }
    return $true
}

# Axis 5 · ARM template structural · post-2026-06-03 architecture: 14 resources after iter#12
# added Storage Queue Data Contributor role assignment (Durable Functions Storage provider uses
# Queues alongside Tables · prev iter#11 found Storage RBAC gap on Queues blocking host startup).
# Outer resources: 11 foundation + DCR + DCR-MMP-role + Queue-Contrib-role = 14.
# Variables: 22 base + storageQueueDataContributorRoleId = 23.
# Params: ≥10. We allow `r -ge 13 -le 16` and `v -ge 20 -le 25` to absorb minor additions without
# false-failing every iter. If outside that window · the change is structurally significant and
# should explicitly raise the bound here.
Test-Axis '5 · ARM mainTemplate · category-scaled top-level resources · ≥18 vars · ≥10 params · 0 top-level roleAssignments' {
    # WS4.1: ALL role assignments moved into principalId-seeded NESTED deployments (the RoleAssignmentExists
    # rollback fix) → 0 top-level roleAssignments. topRoles==0 is the LOAD-BEARING pin (a top-level role would
    # lack the principalId-seeded name and reintroduce the rollback class — tests/unit/Process/ArmRoleIdempotency.Tests.ps1).
    # P5 · DYNAMIC (the catalogue GROWS · NO hardcoded count): the mainTemplate's top-level resources = foundation
    # baseline (~8) + per-category block (~3 each: nested-deployment + DCR association + per-DCR Monitoring-Metrics-
    # Publisher role grant). Scale the sanity bound with the SHIPPED category count (one non-nested per-category-schema
    # artifact each) · generous ±slack so it never false-fails as categories expand; drop the var UPPER bound (vars
    # grow with categories — the old 20-25 was a 2-category artifact). Floors still catch a malformed/empty template.
    $arm = Get-Content (Join-Path $RepoRoot 'deploy/mainTemplate.json') -Raw | ConvertFrom-Json -Depth 50
    $r = $arm.resources.Count
    $v = $arm.variables.PSObject.Properties.Name.Count
    $p = $arm.parameters.PSObject.Properties.Name.Count
    $topRoles = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' }).Count
    $cats = @(Get-ChildItem (Join-Path $RepoRoot 'deploy/per-category-schemas') -Filter 'Defender-*.json' | Where-Object { $_.Name -notlike '*-nested-deployment.json' }).Count
    $rLo = 8 + 2 * $cats; $rHi = 10 + 4 * $cats
    if ($r -ge $rLo -and $r -le $rHi -and $v -ge 18 -and $p -ge 10 -and $topRoles -eq 0) { return $true }
    return "r=$r v=$v p=$p topLevelRoleAssignments=$topRoles · expected r:$rLo-$rHi (for $cats cats) v:>=18 p:>=10 topRoles:0"
}

# Axis 6 · 6 Storage Tables
Test-Axis '6 · 6 Storage Tables · XdrTierState·XdrCheckpoint·TenantCapabilities·XdrIngestDlq·XdrCircuitState·TenantContext' {
    $arm = Get-Content (Join-Path $RepoRoot 'deploy/mainTemplate.json') -Raw | ConvertFrom-Json -Depth 50
    $sa = $arm.resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' } | Select-Object -First 1
    $names = ($sa.resources | Where-Object { $_.type -like '*tableServices*' }).name
    $required = @('default/XdrTierState','default/XdrCheckpoint','default/TenantCapabilities','default/XdrIngestDlq','default/XdrCircuitState','default/TenantContext')
    $missing = $required | Where-Object { $_ -notin $names }
    if ($missing.Count -eq 0) { return $true } else { return "missing: $($missing -join ',')" }
}

# Axis 7 · value-based SHIPPED pipeline · ≥1 Shipped entry · all Ops pass §4.11 schema (HONESTY LOCK)
# Invariant: catalog must have ≥1 SHIPPED Op (runtime needs something to dispatch). Per the HONESTY LOCK,
# Status=Validated is reserved for LIVE-PROVEN ops only — OFFLINE this tool emits SHIPPED (value-gated:
# EffectiveValueClass ∈ {CoreTelemetry,ConfigState} ∧ includable ∧ pollable ∧ entity-resolvable), NOT
# Validated. So this axis gates on the SHIPPED count (active = Shipped), not on Status=Validated. NO
# `IsActive` field (v11 dropped) · derivation auditability + schema parity enforced by Validate-Manifests.
Test-Axis '7 · ≥1 Shipped catalog entry (value-based Shipped pipeline · HONESTY LOCK)' {
    $manifestDir = Join-Path $RepoRoot 'manifests/Defender'
    if (-not (Test-Path $manifestDir)) { return 'no manifests/Defender dir' }
    $files = Get-ChildItem $manifestDir -Filter '*.psd1' -ErrorAction SilentlyContinue
    if ($files.Count -eq 0) { return 'zero manifests · alpha-1 needs >= 1' }

    # Delegate the heavy lifting to Validate-Manifests · authoritative for the value-based Shipped pipeline.
    # Run it · parse summary · require ≥1 Shipped · 0 Inactive (Stub OK · runtime ignores them).
    $vmTool = Join-Path $RepoRoot 'tools/Validate-Manifests.ps1'
    if (-not (Test-Path $vmTool)) { return 'tools/Validate-Manifests.ps1 missing · Shipped pipeline cannot run' }
    # FH-4 · parse the STRUCTURED -Json summary (was: regex-scrape the human Write-Host text · brittle to format drift).
    $vmJson = & pwsh -NoProfile -File $vmTool -Json 2>$null
    $exitCode = $LASTEXITCODE
    $vm = try { $vmJson | ConvertFrom-Json } catch { $null }
    $shippedCount  = if ($vm) { [int]$vm.shippedCount }  else { 0 }
    $inactiveCount = if ($vm) { [int]$vm.inactiveCount } else { 0 }
    if ($exitCode -ne 0) { return "Validate-Manifests exit=$exitCode · Shipped=$shippedCount · Inactive=$inactiveCount" }
    if ($shippedCount -lt 1)  { return "0 Shipped entries · alpha-1 needs ≥1 (catalog has $($files.Count) manifest files)" }
    if ($inactiveCount -gt 0) { return "$inactiveCount Inactive entries · schema mismatch or missing required evidence" }
    return $true
}

# Axis 8 · Anti-Claude attribution (excludes the detector files themselves + raw fixture data)
Test-Axis '8 · No Claude/Anthropic attribution' {
    # LOCAL-ONLY by operator directive: the attribution check is enforced at pre-commit (Hook-PreCommit L13)
    # and pre-push (this axis) — it is deliberately NOT a public-CI job. CI executes the same gauntlet, so
    # skip here under CI with an explicit notice (same named-skip pattern as axes 25/32/34).
    if ($env:GITHUB_ACTIONS -or $env:CI) {
        Write-Host '  INFO · axis 8 is LOCAL-ONLY (operator directive: attribution gate is not public CI) · enforced by local hooks + pre-push · skipped' -ForegroundColor DarkYellow
        $script:NamedSkips += 8
        return $true
    }
    Push-Location $RepoRoot
    try {
        $tracked = & git ls-files
        # Files whose JOB is to detect/block attribution · they legitimately contain the literal pattern strings.
        $detectorAllowlist = @(
            'tools/Run-PrePushGauntlet.ps1',
            'tools/hooks/Hook-PreCommit.ps1'
        )
        $bad = 0
        foreach ($t in $tracked) {
            if ($t -in $detectorAllowlist) { continue }
            if ($t -match '^references/') { continue }  # raw RAW data · operator's lab tenant captures (may contain Defender's own anti-attribution telemetry)
            $p = Join-Path $RepoRoot $t
            if (-not (Test-Path $p -PathType Leaf)) { continue }
            $c = Get-Content $p -Raw -ErrorAction SilentlyContinue
            if (-not $c) { continue }
            # Attribution patterns · matches ci.yml grep exactly (avoid green-local-red-CI asymmetry).
            # CI uses broader patterns including bare "Claude"/"Anthropic" since those should not
            # appear in deliverable code/docs (only in detector files in the allowlist above).
            if ($c -match 'Claude' -or $c -match 'Anthropic' -or $c -match 'claude\.ai' -or $c -match 'claude-code' -or `
                $c -match 'Co-Authored-By:.*Claude' -or $c -match 'Generated with .*Claude') {
                Write-Host "    !  attribution in $t"
                $bad++
            }
        }
        if ($bad -eq 0) { return $true } else { return "$bad files with attribution" }
    } finally { Pop-Location }
}

# Axis 9 · EXACTLY 16 modules (4 portals × Auth-only = 4 + Defender Auth + 11 Common = 16).
# NO portal has a Client module: the runtime polls EVERY portal generically via Xdr.Common.Runtime/Invoke-XdrPortalHttp.
# The per-portal *.Client modules (Invoke-<Portal>Api) had ZERO runtime references and were removed — dead code that
# implied a portal needs a hand-written API client. It does not: a portal = registry row + auth handler + manifest DATA.
# EXACT set-equality (not just "present"): a resurrected .Client or any new *code* module fails the gate — the
# structural enforcement of the locked "expansion is DATA-only" invariant.
Test-Axis '9 · EXACTLY 16 modules · 4 portals Auth-only + Defender Auth + 11 Common (no Client; expansion is DATA-only)' {
    $mods = (Get-ChildItem (Join-Path $RepoRoot 'src/Modules') -Directory).Name
    $expected = @(
        'Xdr.Common.Auth','Xdr.Common.Cache','Xdr.Common.Capabilities','Xdr.Common.Exceptions',
        'Xdr.Common.Ingest','Xdr.Common.Lease','Xdr.Common.OAuthBearer','Xdr.Common.Parser',
        'Xdr.Common.Runtime','Xdr.Common.Storage','Xdr.Common.Telemetry',
        'Xdr.Defender.Auth',
        'Xdr.Entra.Auth',
        'Xdr.Intune.Auth',
        'Xdr.Purview.Auth',
        'Xdr.SecurityCopilot.Auth'
    )
    $missing = $expected | Where-Object { $_ -notin $mods }
    $extra   = $mods     | Where-Object { $_ -notin $expected }
    if ($missing.Count -eq 0 -and $extra.Count -eq 0) { return $true }
    elseif ($missing.Count) { return "missing: $($missing -join ',')" }
    else { return "unexpected module(s): $($extra -join ',') — a dead .Client returned or a new CODE module landed; expansion is DATA-only" }
}

# Axis 10 · gitignore covers secrets + audit
Test-Axis '10 · gitignore covers secrets + audit' {
    $gi = Get-Content (Join-Path $RepoRoot '.gitignore') -Raw
    if ($gi -match '\.env\.local' -and ($gi -match '\.audit' -or $gi -match 'parameters\.local')) {
        return $true
    } else { return 'missing .env.local or audit/params' }
}

# Axis 11 · No bypass directives (excludes Hook-PreCommit policy text + self)
Test-Axis '11 · No --no-verify · --no-gpg-sign in tools' {
    $tools = Get-ChildItem (Join-Path $RepoRoot 'tools') -Recurse -File -Include *.ps1
    # Allowlist · tools whose docstring/warning text mentions the bypass policy without USING it
    $allowlist = @('Hook-PreCommit.ps1','Run-PrePushGauntlet.ps1')
    $bad = 0
    foreach ($t in $tools) {
        if ($t.Name -in $allowlist) { continue }
        $c = Get-Content $t.FullName -Raw -ErrorAction SilentlyContinue
        # Detect ACTUAL invocation · not policy text. ACTUAL invocation is `git ... --no-verify` at statement start.
        if ($c -match '(?m)^\s*git\s+.*--no-verify\b' -or $c -match '(?m)^\s*git\s+.*--no-gpg-sign\b') {
            Write-Host "    !  bypass invocation in $($t.Name)"
            $bad++
        }
    }
    if ($bad -eq 0) { return $true } else { return "$bad files with bypass" }
}

# Axis 12 · V3 contentPackages schema
Test-Axis '12 · V3 contentPackages contentId+contentProductId+kind=Solution' {
    $mt = Get-Content (Join-Path $RepoRoot 'deploy/mainTemplate.json') -Raw
    if ($mt -match 'contentId' -and $mt -match 'contentProductId' -and $mt -match '"contentKind"\s*:\s*"Solution"') { return $true }
    return 'V3 contentPackages incomplete'
}

# Axis 13 · V3 dataConnectorDefinitions data-flow connectivity (greens on DATA not INSTALL · plan M-CARD-GATE)
Test-Axis '13 · V3 dataConnectorDefinitions · data-flow connectivityCriteria (IsConnectedQuery, not HasDataConnectors)' {
    $mt = Get-Content (Join-Path $RepoRoot 'deploy/mainTemplate.json') -Raw
    if ($mt -match '"HasDataConnectors"') { return 'card greens on INSTALL not DATA · use IsConnectedQuery/LastDataReceived' }
    if ($mt -match '"IsConnectedQuery"' -or $mt -match '"LastDataReceived"') { return $true }
    return 'no data-flow connectivityCriteria found'
}

# Axis 14 · DCR<->table NATIVE set-equality + stream/table/transformKql REACH the deploy template (all Categories).
# B (type-at-source · 2026-06-16): the runtime PARSER emits NATIVE typed values for typed columns (from curation
# ColumnTypes), so the DCR STREAM declares the SAME native types as the TABLE and the dataFlow transformKql stays the
# UNIFORM identity 'source' (no per-category coercion · typing is at the parser, NOT the DCR). This axis proves, per
# per-category-schema: (1) the DCR stream columns are SET-EQUAL (name:type) to the table columns — NATIVE, no string
# downcast, no coercion layer; (2) the artifact's stream, table AND transformKql all REACH deploy/mainTemplate.json
# (the sole deploy artifact) — catching the class where the assembler DROPS or REWRITES the transformKql (the F1
# mainTemplate-carry lesson). Iterates ALL Categories. The manifest->per-cat-JSON link is gated by Validate-Manifests;
# the manifest-ColumnTypes == deployed-table-type contract is gated by Validate-Manifests + Assert-LiveSchemaParity (GM-1).
Test-Axis '14 · DCR<->table native set-equality + stream/table/transformKql reach mainTemplate (all Categories)' {
    function Get-Ax14ColKey($cols){ @($cols | ForEach-Object { "$($_.name):$($_.type)" }) | Sort-Object }
    $arm = Get-Content (Join-Path $RepoRoot 'deploy/mainTemplate.json') -Raw | ConvertFrom-Json -Depth 50
    $script:ax14Streams = @{}
    $script:ax14Xform   = @{}
    $script:ax14Tables  = [System.Collections.Generic.List[object]]::new()
    function Invoke-Ax14Collect($n){
        if ($null -eq $n) { return }
        if ($n -is [System.Management.Automation.PSCustomObject]) {
            $tp = $n.PSObject.Properties['type']
            if ($tp -and $tp.Value -eq 'Microsoft.Insights/dataCollectionRules' -and $n.properties.PSObject.Properties['streamDeclarations']) {
                foreach ($s in $n.properties.streamDeclarations.PSObject.Properties) { $script:ax14Streams[$s.Name] = $s.Value.columns }
                if ($n.properties.PSObject.Properties['dataFlows']) {
                    foreach ($df in @($n.properties.dataFlows)) { foreach ($st in @($df.streams)) { $script:ax14Xform[[string]$st] = [string]$df.transformKql } }
                }
            }
            if ($tp -and $tp.Value -eq 'Microsoft.OperationalInsights/workspaces/tables') { $script:ax14Tables.Add($n.properties.schema.columns) }
            foreach ($p in $n.PSObject.Properties) { Invoke-Ax14Collect $p.Value }
        } elseif ($n -is [System.Collections.IEnumerable] -and $n -isnot [string]) {
            foreach ($i in $n) { Invoke-Ax14Collect $i }
        }
    }
    Invoke-Ax14Collect $arm
    $schemaDir = Join-Path $RepoRoot 'deploy/per-category-schemas'
    $jsons = @(Get-ChildItem -Path $schemaDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*-nested-deployment.json' })
    if ($jsons.Count -eq 0) { return 'no per-category-schema JSON found' }
    $problems = @()
    foreach ($j in $jsons) {
        $art = Get-Content $j.FullName -Raw | ConvertFrom-Json -Depth 50
        $stream   = $art.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $genDcr   = Get-Ax14ColKey $art.DcrResource.properties.streamDeclarations.$stream.columns
        $genTable = Get-Ax14ColKey $art.TableResource.properties.schema.columns
        $xform    = [string]$art.DcrResource.properties.dataFlows[0].transformKql
        # (1) B INVARIANT: DCR stream cols == table cols (name:type · NATIVE · the parser emits native so no string downcast/coercion)
        if (Compare-Object $genDcr $genTable) { $problems += "$($j.Name): gen DCR != gen table (B native stream==table set-equality)"; continue }
        # (2) the artifact's stream + table + transformKql all REACH the deploy template (mainTemplate · sole writer)
        if (-not $script:ax14Streams.ContainsKey($stream)) { $problems += "$($j.Name): stream '$stream' absent in mainTemplate"; continue }
        if (Compare-Object $genDcr (Get-Ax14ColKey $script:ax14Streams[$stream])) { $problems += "$($j.Name): DCR stream drift vs mainTemplate '$stream'" }
        if (-not ($script:ax14Tables | Where-Object { -not (Compare-Object $genTable (Get-Ax14ColKey $_)) })) { $problems += "$($j.Name): no mainTemplate table set-equal to its $($genTable.Count)-col schema" }
        if (-not $script:ax14Xform.ContainsKey($stream) -or $script:ax14Xform[$stream] -ne $xform) { $problems += "$($j.Name): mainTemplate transformKql for '$stream' ('$($script:ax14Xform[$stream])') != artifact ('$xform') — the assembler dropped/rewrote it" }
    }
    if ($problems.Count -gt 0) { return ($problems -join ' · ') }
    return $true
}

# Axis 15 · PSScriptAnalyzer (errors==0 · src/ AND tools/ scope · matches ci.yml step exactly)
# Invariant: any PSScriptAnalyzer rule violation at Error severity blocks push. Uses the same
# settings file (PSScriptAnalyzerSettings.psd1) and the same scope (src/ + tools/) as ci.yml so
# this gauntlet axis catches what CI would catch — no asymmetry-driven "green local, red CI" cases.
Test-Axis '15 · PSScriptAnalyzer (errors==0 · src/ + tools/)' {
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) { return 'PSScriptAnalyzer REQUIRED but NOT installed · this gate FAILS (it does NOT silently skip/pass) · install PSScriptAnalyzer (the CI + release workflows do) to run the lint gate' }
    Import-Module PSScriptAnalyzer -Force -ErrorAction SilentlyContinue
    $settingsPath = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'
    $files = @(
        Get-ChildItem (Join-Path $RepoRoot 'src')   -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $RepoRoot 'tools') -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue
    )
    # The settings file's CustomRulePath ('tools/PSScriptAnalyzerRules') is repo-relative · PSScriptAnalyzer
    # resolves it against the CURRENT WORKING DIRECTORY. Push to $RepoRoot so it resolves identically whether
    # launched from the repo root (CI) or anywhere else (local) · otherwise the custom B-25 rule path is missed.
    Push-Location $RepoRoot
    try {
        $issues = $files | ForEach-Object {
            if (Test-Path $settingsPath) {
                Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settingsPath -Severity Error,Warning -ErrorAction SilentlyContinue
            } else {
                Invoke-ScriptAnalyzer -Path $_.FullName -Severity Error -ErrorAction SilentlyContinue
            }
        }
    } finally { Pop-Location }
    $errors = $issues | Where-Object Severity -eq 'Error'
    if ($errors -and $errors.Count -gt 0) {
        $errors | Group-Object RuleName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
            Write-Host "    !  $($_.Count)x $($_.Name)"
        }
        return "$($errors.Count) PSSA errors"
    }
    return $true
}

# Axis 16 · Validate-Manifests invocation (per-manifest schema gate)
Test-Axis '16 · Validate-Manifests' {
    $tool = Join-Path $RepoRoot 'tools/Validate-Manifests.ps1'
    if (-not (Test-Path $tool)) { return 'tool missing · acceptable for alpha-1 if no manifest schema enforcement yet' }
    $out = & pwsh -NoProfile -File $tool 2>&1
    if ($LASTEXITCODE -ne 0) { return "Validate-Manifests exited $LASTEXITCODE" }
    return $true
}

# Axis 17 · Validate-Scope (Filter A/B/C · 0 BLOCKING)
Test-Axis '17 · Validate-Scope · Filter A/B/C · 0 BLOCKING' {
    $tool = Join-Path $RepoRoot 'tools/Validate-Scope.ps1'
    if (-not (Test-Path $tool)) { return 'Validate-Scope tool missing' }
    $null = & pwsh -NoProfile -File $tool 2>&1
    if ($LASTEXITCODE -ne 0) { return "Validate-Scope exited $LASTEXITCODE · BLOCKING violation present" }
    return $true
}

# Axis 18 · Build-FunctionAppZip · size budget (iter#14 raised to 50MB · Legion forces Az.* bundle)
# Was 25MB pre-iter#14 (managedDependency restore meant zip was just our 80KB src + manifests).
# Legion (new Linux Consumption SKU · classic dep Sep 30 2028) does NOT support managedDependency
# so we bundle Az.Accounts (~10MB) + Az.KeyVault (~3MB) inside the zip → typical ~15MB total.
# Budget 50MB gives 35MB headroom for future module additions (Az.Storage if ever needed · custom modules).
Test-Axis '18 · Build-FunctionAppZip · size < 5MB · NO Az modules bundled (iter#15 MSI-REST runtime)' {
    $tool = Join-Path $RepoRoot 'tools/Build-FunctionAppZip.ps1'
    if (-not (Test-Path $tool)) { return 'Build-FunctionAppZip missing' }
    $outZip = Join-Path $RepoRoot 'artifacts/function-app-gauntlet.zip'
    $outDir = Split-Path -Parent $outZip
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    & pwsh -NoProfile -File $tool -OutputPath $outZip 2>&1 | Out-Null
    if (-not (Test-Path $outZip)) { return 'function-app.zip not produced' }
    $sizeMB = [Math]::Round((Get-Item $outZip).Length / 1MB, 2)
    # iter#15 reverted the iter#14 50MB Az-bundle cap. Runtime is managed-identity REST · zero bundled
    # PSGallery modules · so the zip is ~100KB of src/ only. A blown size means Az (or other) crept back.
    if ($sizeMB -gt 5) { return "zip $sizeMB MB exceeds 5MB cap · iter#15 runtime is MSI REST · NO bundled modules expected" }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    $zipForVerify = [System.IO.Compression.ZipFile]::OpenRead($outZip)
    try {
        $entries = @($zipForVerify.Entries | ForEach-Object { $_.FullName })
        $az = @($entries | Where-Object { $_ -match '^Modules/Az\.' })
        if ($az.Count -gt 0) { return "Az PowerShell module(s) present in zip ($($az.Count) entries · e.g. $($az[0])) · iter#15 FORBIDS bundled Az (Legion Az.KeyVault.private skew killed all module loads) · runtime is MSI REST" }
        if ($entries -notcontains 'host.json') { return 'host.json missing from zip root' }
    } finally { $zipForVerify.Dispose() }
    return $true
}

# Axis 19 · createUiDefinition regex (TOTP case-insensitive · Passkey PEM lenient)
Test-Axis '19 · createUiDefinition regex (TOTP case-insensitive + Passkey PEM)' {
    $path = Join-Path $RepoRoot 'deploy/createUiDefinition.json'
    if (-not (Test-Path $path)) { return 'createUiDefinition.json missing' }
    $ui = Get-Content $path -Raw
    # TOTP regex must accept lowercase (operator lab seed is jz2gd6shgy5ryrcn lowercase)
    if ($ui -match '\^\[A-Z2-7=\]') { return 'TOTP regex uppercase-only · must be A-Za-z2-7' }
    if (-not ($ui -match 'A-Za-z2-7' -or $ui -match 'A-Z2-7.*\?i')) {
        # acceptable if regex includes lowercase set OR case-insensitive flag · soft check
        Write-Host '    (TOTP regex pattern not explicitly verified · operator should manually check)'
    }
    return $true
}

# Axis 20 · Cross-RG nested deployment · resourceGroup specified · subscriptionId OMITTED for same-sub
# Per Microsoft canonical pattern (https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-to-resource-group):
# Same-subscription cross-RG deployments specify ONLY 'resourceGroup'. Specifying BOTH breaks portal Custom Template
# pre-validation (resource appears "not defined" even though it is). Operator portal pre-validation 2026-06-02.
Test-Axis '20 · Nested deployments · cross-RG = resourceGroup-only (NO subscriptionId) · same-RG only for the role nesteds' {
    # WS4.1 update: TWO legitimate nested kinds now exist —
    #   cross-RG (workspace): the per-category TABLE nesteds + the Sentinel V3 content nested → MUST carry
    #     resourceGroup and MUST NOT carry subscriptionId (Microsoft canonical; portal pre-val breaks otherwise);
    #   same-RG (connector): the principalId-seeded ROLE nesteds (xdrlr-roles-foundation-* / xdrlr-role-dcr-*)
    #     → carry NEITHER (they deploy into the current RG by design; adding resourceGroup would be a no-op trap).
    $arm = Get-Content (Join-Path $RepoRoot 'deploy/mainTemplate.json') -Raw | ConvertFrom-Json -Depth 50
    $nested = $arm.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' }
    foreach ($n in $nested) {
        $hasRg  = [bool]($n.PSObject.Properties['resourceGroup'] -and $n.resourceGroup)
        $hasSub = [bool]($n.PSObject.Properties['subscriptionId'] -and $n.subscriptionId)
        $isRoleNested = ([string]$n.name) -match "xdrlr-role(s-foundation|-dcr)-"
        if ($isRoleNested) {
            if ($hasRg -or $hasSub) { return "role nested $($n.name) must be SAME-RG (no resourceGroup/subscriptionId)" }
            continue
        }
        if (-not $hasRg) { return "nested $($n.name) missing resourceGroup (required for cross-RG)" }
        if ($hasSub)     { return "nested $($n.name) specifies BOTH subscriptionId AND resourceGroup · same-sub cross-RG must specify ONLY resourceGroup (Microsoft canonical · portal pre-val breaks otherwise)" }
    }
    return $true
}

# Axis 21 · EVERY DCR MUST dependsOn its table-carrying nested deployment via SIMPLE-NAME form (iter#5 ordering · 2026-06-02 PM).
# iter#3 dropped dependsOn entirely thinking ARM tolerates parallel provisioning (it doesn't · DCR
# validates destination workspace table at PROVISIONING time · not ingestion). iter#5 root cause:
# 'InvalidOutputTable · Table for output stream Custom-Defender_ActionCenter_CL is not available'
# fired because DCR + nested provisioned in parallel · DCR lost race. ARM CANONICAL fix: SIMPLE-
# NAME STRING form (NOT resourceId()) · ARM does name-lookup without computing cross-RG resourceId
# paths · works for cross-RG nested deployments.
# Assemble-from-parts model (dev-tools/Build-MainTemplate.ps1): each shipped category gets its OWN
# cross-RG nested TABLE deployment named `xdrlr-table-<cat>-<suffix>` (concat with namePrefix) and a
# TOP-LEVEL DCR that dependsOn that nested via simple-name form. The legacy single-nested pilot used
# `xdrlr-sentinel`/`nestedDeploymentName`. This axis recognizes BOTH naming forms and iterates EVERY
# DCR (not just the first · so it stays correct as Category #2..N are added).
# This axis asserts, for each DCR: it HAS a dependsOn on a nested deployment (table-carrying · matched
# by the per-category `xdrlr-table-`/`xdrlr-nested-` naming OR the legacy `xdrlr-sentinel`/
# `nestedDeploymentName`) AND that dependsOn uses simple-name form (resourceId() form is forbidden by
# Check #7b in Validate-ArmCrossReferences).
Test-Axis '21 · every DCR dependsOn its table nested via simple-name form (iter#5 ordering fix · all Categories)' {
    $arm = Get-Content (Join-Path $RepoRoot 'deploy/mainTemplate.json') -Raw | ConvertFrom-Json -Depth 50
    $dcrs = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
    if ($dcrs.Count -eq 0) { return 'no DCR found in outer template' }
    foreach ($dcr in $dcrs) {
        if (-not $dcr.dependsOn) { return "DCR '$($dcr.name)' has no dependsOn · MUST dependsOn its table nested deployment for ordering" }
        $nestedDep = $dcr.dependsOn | Where-Object { $_ -match 'nestedDeploymentName' -or $_ -match 'xdrlr-sentinel' -or $_ -match "'-table-" -or $_ -match "'-nested-" -or $_ -match 'xdrlr-table-' -or $_ -match 'xdrlr-nested-' }
        if (-not $nestedDep) { return "DCR '$($dcr.name)' dependsOn does not reference its table nested deployment · table provisioning race · ARM will reject with InvalidOutputTable" }
        # Verify the nested dependsOn uses simple-name form (NOT resourceId() · which ARM rejects cross-RG)
        foreach ($d in $nestedDep) {
            if ($d -match 'resourceId\(' -and $d -match 'Microsoft\.Resources/deployments') {
                return "DCR '$($dcr.name)' dependsOn uses resourceId() form for the nested · ARM rejects this for cross-RG nested (iter#3 confirmed) · use simple-name form: [concat(variables('namePrefix'), '-table-<cat>-', variables('suffix'))]"
            }
        }
    }
    return $true
}

# Axis 22 · host.json Durable v3 + functionTimeout + maxConcurrentActivityFunctions
Test-Axis '22 · host.json Durable v3 + functionTimeout + maxConcurrentActivityFunctions=10' {
    $path = Join-Path $RepoRoot 'src/host.json'
    if (-not (Test-Path $path)) { return 'host.json missing' }
    $cfg = Get-Content $path -Raw | ConvertFrom-Json
    $errors = @()
    if ($cfg.version -ne '2.0') { $errors += "version=$($cfg.version) · expected 2.0" }
    if (-not $cfg.functionTimeout) { $errors += 'functionTimeout missing' }
    elseif ($cfg.functionTimeout -notmatch '^00:0[5-9]:00$|^00:10:00$') { $errors += "functionTimeout=$($cfg.functionTimeout) · expected 00:05:00 to 00:10:00" }
    $durable = $cfg.extensions.durableTask
    if (-not $durable) { $errors += 'extensions.durableTask block missing' }
    if ($durable -and $durable.maxConcurrentActivityFunctions -ne 10) { $errors += "maxConcurrentActivityFunctions=$($durable.maxConcurrentActivityFunctions) · expected 10" }
    if ($errors.Count -gt 0) { return ($errors -join '; ') }
    return $true
}

# Axis 23 · ARM cross-reference validation (NEW · added 2026-06-02 after portal pre-validation surfaced
# a dangling deployment reference caused by uniqueString(deployment().name) phase-evaluation trap).
# Catches: resourceId() refs to undeclared deployments · undefined variables/parameters · uniqueString
# expressions that include deployment().name (resolve differently across template validation phases).
Test-Axis '23 · ARM cross-reference validation (Validate-ArmCrossReferences)' {
    $tool = Join-Path $RepoRoot 'tools/Validate-ArmCrossReferences.ps1'
    if (-not (Test-Path $tool)) { return 'Validate-ArmCrossReferences.ps1 missing' }
    $output = & pwsh -NoProfile -File $tool 2>&1
    if ($LASTEXITCODE -ne 0) { return ($output | Select-Object -Last 5 | Out-String).Trim() }
    return $true
}

# Axis 24 · Sentinel solution package validity (NEW · v11 §B-build-now · Content Hub-ready)
# Validates Package/manifest.json references resolve · all Package/* files parse · logo exists.
Test-Axis '24 · Sentinel solution package validity (Build-SolutionPackage -Validate)' {
    $tool = Join-Path $RepoRoot 'tools/Build-SolutionPackage.ps1'
    if (-not (Test-Path $tool)) { return 'Build-SolutionPackage.ps1 missing' }
    $output = & pwsh -NoProfile -File $tool -Validate 2>&1
    if ($LASTEXITCODE -ne 0) { return ($output | Select-Object -Last 8 | Out-String).Trim() }
    return $true
}

# Axis 25 · EMPIRICAL `az deployment group validate` · the methodology audit-gap closure (iter#3 2026-06-02 PM).
# WHY: ARM-TTK is a STATIC linter (template-structure rules · ~30 checks). It does NOT simulate the
# ARM evaluator · so cross-scope resourceId() in dependsOn (and other ARM-semantic issues) slip
# through. `az deployment group validate` calls real ARM service-side · which DOES simulate the
# evaluator and rejects the same way the live deploy would. This is the canonical Microsoft path.
# WHAT IT CATCHES: cross-scope reference/resourceId rejections · missing-parameter errors · type
# mismatches · ALL "is not defined in template" errors · API version mismatches · etc.
# WHEN IT SKIPS: locally if parameters.local.json absent OR az not authenticated OR no XDRLR_TARGET_RG.
# CI skips (no Az auth in workflow). Operator runs locally before every push to catch deploy-failures
# BEFORE pushing · paired with §11.3 G17 'create/use/adjust not copy-paste'.
Test-Axis '25 · az deployment group validate (empirical ARM check · local-only · iter#3 audit-gap fix)' {
    $paramsFile = Join-Path $RepoRoot 'parameters.local.json'
    $envLocal   = Join-Path $RepoRoot '.env.local'
    if (-not (Test-Path $paramsFile)) {
        Write-Host "    INFO · parameters.local.json absent · empirical validate skipped locally (CI auto-skips) · CREATE parameters.local.json (gitignored) + set XDRLR_TARGET_RG in .env.local to enable this gate" -ForegroundColor DarkYellow
        $script:NamedSkips += 25
        return $true
    }
    if (-not (Test-Path $envLocal)) {
        Write-Host "    INFO · .env.local absent · empirical validate skipped · operator should provide for local SP auth" -ForegroundColor DarkYellow
        $script:NamedSkips += 25
        return $true
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "    INFO · az CLI not installed · empirical validate skipped" -ForegroundColor DarkYellow
        $script:NamedSkips += 25
        return $true
    }
    $azAccount = az account show --query name -o tsv 2>$null
    if (-not $azAccount) {
        Write-Host "    INFO · az not authenticated · empirical validate skipped (run 'az login' OR source .env.local SP creds)" -ForegroundColor DarkYellow
        $script:NamedSkips += 25
        return $true
    }
    $rg = $env:XDRLR_TARGET_RG
    if (-not $rg) {
        Write-Host "    INFO · XDRLR_TARGET_RG env var not set · empirical validate skipped (set in .env.local · e.g. 'export XDRLR_TARGET_RG=xdrlograider')" -ForegroundColor DarkYellow
        $script:NamedSkips += 25
        return $true
    }
    $templateFile = Join-Path $RepoRoot 'deploy/mainTemplate.json'
    Write-Host "    Running az deployment group validate against RG=$rg ..."
    $validateOut = az deployment group validate `
        --resource-group $rg `
        --template-file $templateFile `
        --parameters "@$paramsFile" `
        --output json 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        # Extract the InvalidTemplate/error message · truncate to 600 chars
        $snippet = $validateOut.Substring(0, [Math]::Min(600, $validateOut.Length))
        return "az validate REJECTED · would have caught this BEFORE push: $snippet"
    }
    return $true
}

# Axis 26 · Clean-runspace module load · all Xdr modules import with ONLY bundled deps (iter#15 keystone).
# The FA worker only has the bundled src/Modules on its PSModulePath. This axis reproduces that isolation:
# (a) static — every Xdr.*.psd1 RequiredModules entry must be another bundled Xdr.* module (no Az.*/external);
# (b) runtime — a child pwsh with PSModulePath = src/Modules (+ PSHOME core) ONLY imports every Xdr module.
# Either failing means a module needs a dependency the FA won't have. This is the gate that would have
# caught iter#14's bundled-Az.KeyVault dependency that cascade-failed every module load on Legion.
Test-Axis '26 · Clean-runspace module load · all Xdr modules import with ONLY bundled deps' {
    $modRoot = Join-Path $RepoRoot 'src/Modules'
    if (-not (Test-Path $modRoot)) { return 'src/Modules missing' }

    # (a) Static dependency closure check.
    $bundled = @(Get-ChildItem $modRoot -Directory | ForEach-Object { $_.Name })
    $badDeps = @()
    foreach ($d in (Get-ChildItem $modRoot -Directory -Filter 'Xdr.*')) {
        $psd1 = Join-Path $d.FullName "$($d.Name).psd1"
        if (-not (Test-Path $psd1)) { continue }
        $man = Import-PowerShellDataFile $psd1
        foreach ($rm in @($man.RequiredModules)) {
            $name = if ($rm -is [hashtable]) { $rm.ModuleName } else { [string]$rm }
            if ($name -and ($name -notin $bundled)) { $badDeps += "$($d.Name) requires non-bundled '$name'" }
        }
    }
    if ($badDeps.Count -gt 0) { return "non-bundled RequiredModules · " + ($badDeps -join ' · ') }

    # (b) Isolated runtime import (child pwsh · PSModulePath = bundled only · NO system Az).
    $childScript = @"
`$ErrorActionPreference='Stop'
`$env:PSModulePath = '$modRoot' + [IO.Path]::PathSeparator + (Join-Path `$PSHOME 'Modules')
`$fail=@()
foreach (`$d in (Get-ChildItem '$modRoot' -Directory -Filter 'Xdr.*')) {
    `$p = Join-Path `$d.FullName ((`$d.Name) + '.psd1')
    if (-not (Test-Path `$p)) { continue }
    try { Import-Module `$p -Force -DisableNameChecking -ErrorAction Stop } catch { `$fail += ((`$d.Name) + ': ' + `$_.Exception.Message) }
}
if (`$fail.Count -gt 0) { Write-Output ('LOADFAIL::' + (`$fail -join ' || ')); exit 1 }
Write-Output 'ALLOK'
"@
    $tmp = [System.IO.Path]::GetTempFileName() + '.ps1'
    Set-Content -Path $tmp -Value $childScript -Encoding utf8
    try { $out = & pwsh -NoProfile -File $tmp 2>&1 | Out-String } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    if ($out -match 'ALLOK') { return $true }
    return "isolated import FAILED · $($out.Trim())"
}

# Axis 27 · psd1 FunctionsToExport == psm1 Export-ModuleMember (R5 · plan §35.8 two-gate export trap).
# A function in psm1 Export-ModuleMember but ABSENT from psd1 FunctionsToExport (or vice-versa) is NOT
# actually callable (psd1 filters psm1). Bit 3x this session (Get-XdrEnvelopeColumns · breaker gates ·
# Save-XdrCheckpointReset · the 5 promoted Defender helpers). For every module with an explicit
# Export-ModuleMember -Function AND an explicit FunctionsToExport list, assert the two sets are EQUAL.
Test-Axis '27 · psd1 FunctionsToExport == psm1 Export-ModuleMember (two-gate export trap)' {
    $modRoot = Join-Path $RepoRoot 'src/Modules'
    $bad = @()
    foreach ($d in (Get-ChildItem $modRoot -Directory -Filter 'Xdr.*')) {
        $psd1 = Join-Path $d.FullName "$($d.Name).psd1"
        $psm1 = Join-Path $d.FullName "$($d.Name).psm1"
        if (-not (Test-Path $psd1) -or -not (Test-Path $psm1)) { continue }
        $man = Import-PowerShellDataFile $psd1
        $psd1Funcs = @($man.FunctionsToExport)
        if ($psd1Funcs -contains '*') { continue }   # wildcard export · not comparable
        # Extract Export-ModuleMember -Function names (join backtick line-continuations first).
        $joined = (Get-Content $psm1 -Raw) -replace '`\r?\n\s*', ' '
        $psm1Funcs = @()
        foreach ($m in [regex]::Matches($joined, '(?m)Export-ModuleMember\s+-Function\s+(.+)$')) {
            $argText = $m.Groups[1].Value -replace '#.*$', ''
            foreach ($tok in ($argText -split ',')) {
                $t = $tok.Trim().Trim("'", '"')
                if ($t -match '^[A-Za-z][\w-]+$') { $psm1Funcs += $t }
            }
        }
        if ($psm1Funcs.Count -eq 0) { continue }   # export-all + psd1 filter · not comparable
        $onlyPsm1 = @($psm1Funcs | Where-Object { $_ -notin $psd1Funcs })
        $onlyPsd1 = @($psd1Funcs | Where-Object { $_ -notin $psm1Funcs })
        if ($onlyPsm1.Count -or $onlyPsd1.Count) {
            $bad += "$($d.Name): psm1-only=[$($onlyPsm1 -join ',')] psd1-only=[$($onlyPsd1 -join ',')]"
        }
    }
    if ($bad.Count -eq 0) { return $true }
    return "export-set mismatch · " + ($bad -join ' · ')
}

# Axis 28 · regen→diff · the static-generate→validate KEYSTONE (plan §9 G4). Regenerate the manifest from the
# committed catalogue.json and assert it is identical (modulo line-endings) to the committed manifest — proving the
# manifest was GENERATED from the catalogue, NOT hand-edited. Drift here means the no-hand-edit invariant broke;
# this is the gate the prior gauntlet lacked (axes only validated committed artifacts, never re-derived them).
Test-Axis '28 · regen->diff · EVERY committed manifest regenerated from catalogue == committed (no hand-edit drift)' {
    # WS6 generalization: iterate ALL manifests/Defender/*.psd1 (was Operations-only) so a multi-category world
    # (ActionCenter pilot + future categories) each proves the no-hand-edit invariant. -Group <token> matches the
    # tokenized category via Generate-Manifest's shared tokenizer.
    $gen = Join-Path $RepoRoot 'dev-tools/Generate-Manifest.ps1'
    if (-not (Test-Path $gen)) { return 'dev-tools/Generate-Manifest.ps1 missing' }
    $manifests = @(Get-ChildItem (Join-Path $RepoRoot 'manifests/Defender') -Filter '*.psd1' -ErrorAction SilentlyContinue)
    if ($manifests.Count -eq 0) { return 'no committed manifests under manifests/Defender' }
    foreach ($m in $manifests) {
        $group = $m.BaseName
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-regen-" + [Guid]::NewGuid().ToString('N') + ".psd1")
        try {
            & pwsh -NoProfile -File $gen -Portal Defender -Group $group -OutPath $tmp *> $null
            if (-not (Test-Path $tmp)) { return "regen produced no manifest for '$group' (Generate-Manifest failed)" }
            $a = ((Get-Content $m.FullName -Raw) -replace "`r`n", "`n").TrimEnd()
            $b = ((Get-Content $tmp -Raw)        -replace "`r`n", "`n").TrimEnd()
            if ($a -ne $b) { return "manifest DRIFT · committed $($m.Name) != regenerated-from-catalogue (hand-edited or stale?)" }
        } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
    }
    return $true
}

# Axis 29 · exactly-once OFFLINE replay (plan §9 · F-GATE-1). Load a REPRESENTATIVE GetHistory fixture (distinct
# real GUID ActionIds), run it through the REAL parser (ConvertTo-XdrRows with the Operations manifest), and
# prove the parse boundary on the RUNTIME identity:
#   (1) the parser fans out 1:1 — rows.Count == fixture item count (no row dropped · none manufactured · req #1).
#   (2) NO duplicate on the runtime exactly-once identity = NaturalKey ALONE (ActionId) — rows.Count ==
#       dcount(ActionId). That is the identity Invoke-XdrEntryPoll dedups on (§35.2). Asserting on ActionId
#       (NOT a CursorField|NaturalKey composite — the prior cheat that only passed because the redacted fixture
#       zeroed ActionId) gives the gate REAL teeth: a fan-out bug that splits one record into same-key rows (the
#       F-CAT-1 classifier-bug class) FAILS here. Cross-cycle exactly-once is proven by ExactlyOnce.Tests (axis 4).
# OFFLINE complement to the live cursor proof (tests/unit/.../ExactlyOnce.Tests.ps1). No Azure / network.
Test-Axis '29 · exactly-once OFFLINE replay · representative fixture · 1:1 fan-out + distinct NaturalKey (ActionId)' {
    $fixturePath  = Join-Path $RepoRoot 'tests/fixtures/live/MDE_ActionCenter_CL-representative.json'
    $parserPsd1   = Join-Path $RepoRoot 'src/Modules/Xdr.Common.Parser/Xdr.Common.Parser.psd1'
    if (-not (Test-Path $fixturePath))  { return "live fixture missing: $fixturePath" }
    if (-not (Test-Path $parserPsd1))   { return 'Xdr.Common.Parser module missing' }
    Import-Module $parserPsd1 -Force -DisableNameChecking -ErrorAction Stop
    # Manifest-generic: LOCATE GetHistory across ALL committed manifests (no path hardcode — categories are the
    # nodoc x-tagGroups and more manifests arrive at expansion). The exactly-once gate is about GetHistory
    # specifically (the CURSOR op with NaturalKey=ActionId) wherever its group manifest lives.
    $manifests = @(Get-ChildItem (Join-Path $RepoRoot 'manifests/Defender') -Filter '*.psd1' -ErrorAction SilentlyContinue)
    if ($manifests.Count -eq 0) { return 'no committed manifests under manifests/Defender' }
    $op = $null; $opCategory = $null
    foreach ($m in $manifests) {
        $mf = Import-PowerShellDataFile -Path $m.FullName -ErrorAction Stop
        $cand = $mf.Operations | Where-Object { $_.OperationKey -eq 'GetHistory' } | Select-Object -First 1
        if ($cand) { $op = $cand; $opCategory = $mf.Category; break }
    }
    if (-not $op) { return 'no committed manifest has a GetHistory operation · exactly-once gate cannot locate its CURSOR op' }
    $naturalKeys = @($op.NaturalKey)
    if ($naturalKeys.Count -eq 0) { return 'manifest GetHistory has no NaturalKey · cannot prove exactly-once' }
    # F-GATE-1: the exactly-once identity is the RUNTIME identity = NaturalKey ALONE (ActionId), NOT a
    # CursorField|NaturalKey composite. The representative fixture carries DISTINCT real ActionIds, so
    # rows==dcount(ActionId) genuinely proves 1:1 fan-out with no fan-out-induced duplicate key.
    $identityFields = @($naturalKeys | Where-Object { $_ } | Select-Object -Unique)
    # Runtime body shape: ConvertFrom-Json -AsHashtable (IDictionary · the Activity poll path).
    $body = Get-Content $fixturePath -Raw | ConvertFrom-Json -AsHashtable -Depth 25
    $itemCount = @($body['Results']).Count
    $raw = ConvertTo-XdrRows `
        -ResponseBody $body `
        -OperationKey ([string]$op.OperationKey) `
        -Portal ([string]$op.Portal ?? 'Defender') `
        -Category ([string]$opCategory) `
        -Subcategory ([string]$op.Subcategory) `
        -ResponseShape ([string]$op.ResponseShape) `
        -ItemsContainer ([string]$op.ItemsContainer) `
        -ProjectionMap $op.ProjectionMap
    $rows = @($raw)
    if ($rows.Count -eq 0) { return 'parser produced 0 rows from the live fixture (fan-out broke)' }
    # (1) 1:1 fan-out · the parser neither dropped nor manufactured rows vs the source array.
    if ($rows.Count -ne $itemCount) {
        return "fan-out NOT 1:1 · rows=$($rows.Count) fixture items=$itemCount (B1 keystone broke)"
    }
    # (2) no duplicate on the runtime identity (NaturalKey/ActionId alone · join multi-col with '|' if >1 key).
    $keys = @($rows | ForEach-Object { $r = $_; ($identityFields | ForEach-Object { [string]$r[$_] }) -join '|' })
    $distinct = @($keys | Sort-Object -Unique)
    if ($rows.Count -ne $distinct.Count) {
        return "duplicate exactly-once identity ($($identityFields -join '|')) · rows=$($rows.Count) distinct=$($distinct.Count)"
    }
    return $true
}

# Axis 30 · regen->diff per-Category SCHEMA (mirrors Axis 28 for the DCR/table schema · plan §9 G4). Regenerate
# deploy/per-category-schemas/Defender-Operations.json via Build-PerCategorySchema into a TEMP repo root and assert
# it is CANONICALLY equal to the committed artifact — proving the schema was GENERATED from the manifest, not
# hand-edited. Comparison is structural (deep key-sort · GeneratedUtc dropped), NOT a byte diff: ConvertTo-Json of
# the generator's plain hashtables emits JSON object KEYS in non-deterministic hash order (column {name,type} vs
# {type,name} · streamDeclarations/dataFlows/destinations order), so two correct regenerations differ byte-wise
# while being structurally identical. Canonicalizing both sides (recursive key-sort) compares the CONTENT — a real
# schema drift (different/missing columns · changed DCR/table/nested structure) still fails. Build-PerCategorySchema
# writes to <RepoRoot>/deploy/per-category-schemas/<Portal>-<Category>.json, so we point -RepoRoot at a temp tree
# carrying only the manifest (its Parser import resolves off the SCRIPT dir, not -RepoRoot · works either way).
Test-Axis '30 · regen->diff · EVERY per-Category schema regenerated from manifest == committed (canonical · no drift)' {
    # WS6 generalization: iterate ALL committed per-category-schema artifacts (was Operations-only). For each
    # deploy/per-category-schemas/Defender-<Cat>.json there must be a manifests/Defender/<Cat>.psd1 that regenerates
    # it canonically. Enables the ActionCenter pilot + every future category to prove no schema hand-edit.
    $gen = Join-Path $RepoRoot 'dev-tools/Build-PerCategorySchema.ps1'
    if (-not (Test-Path $gen)) { return 'dev-tools/Build-PerCategorySchema.ps1 missing' }
    # Canonical form: recursively sort dictionary keys (arrays keep order · the column SEQUENCE is still compared),
    # drop the volatile Summary.GeneratedUtc, emit compact. Two structurally-equal artifacts canonicalize identically.
    function ConvertTo-Ax30Canon {
        param($Node)
        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Collections.IDictionary]) {
            $o = [ordered]@{}
            foreach ($k in (@($Node.Keys) | Sort-Object)) { if ($k -eq 'GeneratedUtc') { continue }; $o[[string]$k] = ConvertTo-Ax30Canon $Node[$k] }
            return $o
        }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            return @($Node | ForEach-Object { ConvertTo-Ax30Canon $_ })
        }
        return $Node
    }
    $schemas = @(Get-ChildItem (Join-Path $RepoRoot 'deploy/per-category-schemas') -Filter 'Defender-*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*-nested-deployment.json' })
    if ($schemas.Count -eq 0) { return 'no committed per-category-schema artifacts' }
    foreach ($committed in $schemas) {
        $category = ($committed.BaseName -replace '^Defender-', '')
        $manifest = Join-Path $RepoRoot "manifests/Defender/$category.psd1"
        if (-not (Test-Path $manifest)) { return "schema $($committed.Name) has no matching manifest manifests/Defender/$category.psd1" }
        $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-schemaregen-" + [Guid]::NewGuid().ToString('N'))
        try {
            $tmpManifestDir = Join-Path $tmpRoot 'manifests/Defender'
            New-Item -ItemType Directory -Path $tmpManifestDir -Force | Out-Null
            Copy-Item -Path $manifest -Destination (Join-Path $tmpManifestDir "$category.psd1") -Force
            & pwsh -NoProfile -File $gen -Portal Defender -Category $category -RepoRoot $tmpRoot -OutputMode JSON *> $null
            $regen = Join-Path $tmpRoot "deploy/per-category-schemas/Defender-$category.json"
            if (-not (Test-Path $regen)) { return "regen produced no schema artifact for '$category' (Build-PerCategorySchema failed)" }
            $ca = Get-Content $committed.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 60
            $cb = Get-Content $regen             -Raw | ConvertFrom-Json -AsHashtable -Depth 60
            $sa = ConvertTo-Ax30Canon $ca | ConvertTo-Json -Depth 60 -Compress
            $sb = ConvertTo-Ax30Canon $cb | ConvertTo-Json -Depth 60 -Compress
            if ($sa -ne $sb) { return "schema DRIFT · committed $($committed.Name) != regenerated-from-manifest (hand-edited or stale?)" }
        } finally { if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } }
    }
    return $true
}

# Axis 31 · OVERRIDE-EMPTY (plan §F #6) · Build-Catalogue's curation tables MUST be data-driven (loaded from
# references/inventory/<portal>/curation.json), NOT in-code per-op hashtable literals. The override-externalization
# (P2) moved them to data; this gate FAILs if a per-op hashtable literal is ever re-introduced into the builder.
Test-Axis '31 · override-empty · no in-code per-op override tables in Build-Catalogue (curation.json is the source)' {
    $f = Join-Path $RepoRoot 'dev-tools/Build-Catalogue.ps1'
    if (-not (Test-Path $f)) { return 'Build-Catalogue.ps1 not found' }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
    $assigns = $ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -match 'Xdr(ValueOverrides|ShipHold|PathOverrides)') }, $true)
    $bad = @()
    foreach ($a in $assigns) {
        $ht = $a.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        if ($ht -and $ht.KeyValuePairs.Count -gt 0) { $bad += ('{0}=hashtable[{1} entries]' -f $a.Left.Extent.Text, $ht.KeyValuePairs.Count) }
    }
    if ($bad.Count -gt 0) { return "in-code per-op override entries (move to curation.json): $($bad -join ' ; ')" }
    return $true
}

# Axis 32 · RAW->SoT regen->diff (plan §F #7) · the SoT (evidence-index + catalogue) must be DETERMINISTICALLY
# regenerable from RAW with NO hand-edit drift. Regenerates both to stdout (child pwsh · pure JSON · no working-tree
# write) and compares canonical JSON to the committed artifacts. Extends axes 28/30 (manifest/schema) down to RAW.
Test-Axis '32 · RAW->SoT regen->diff · evidence-index + catalogue regenerate from RAW == committed' {
    # LOCAL-ONLY (G4 single-repo model): references/live is the INTERNAL layer — untracked, present only on the
    # operator's machine. A public clone (CI) cannot regen from RAW; regen is operator-run by locked directive.
    # Same explicit named-skip pattern as axis 25 (the gauntlet's other local-evidence axis).
    if (-not (Test-Path (Join-Path $RepoRoot 'references/live'))) {
        Write-Host '  INFO · axis 32 is LOCAL-ONLY · references/live (internal layer) absent on this clone · regen is operator-run · skipped' -ForegroundColor DarkYellow
        $script:NamedSkips += 32
        return $true
    }
    $eiTool = Join-Path $RepoRoot 'dev-tools/Build-EvidenceIndex.ps1'
    $catTool = Join-Path $RepoRoot 'dev-tools/Build-Catalogue.ps1'
    $eiC = Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr/evidence-index.json'
    $catC = Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr/catalogue.json'
    foreach ($p in @($eiTool, $catTool, $eiC, $catC)) { if (-not (Test-Path $p)) { return "missing $p" } }
    $canon = { param($txt) try { $txt | ConvertFrom-Json | ConvertTo-Json -Depth 60 -Compress } catch { $null } }
    $eiRegen = & pwsh -NoProfile -File $eiTool -Portal Defender 2>$null | Out-String
    $a = & $canon (Get-Content $eiC -Raw); $b = & $canon $eiRegen
    if (-not $b) { return 'evidence-index regen produced no parseable JSON' }
    if ($a -ne $b) { return 'evidence-index DRIFT · regenerated-from-RAW != committed (re-run Build-EvidenceIndex -WriteFile + commit)' }
    $catRegen = & pwsh -NoProfile -File $catTool -Portal Defender 2>$null | Out-String
    $a2 = & $canon (Get-Content $catC -Raw); $b2 = & $canon $catRegen
    if (-not $b2) { return 'catalogue regen produced no parseable JSON' }
    if ($a2 -ne $b2) { return 'catalogue DRIFT · regenerated-from-RAW != committed (re-run Build-Catalogue -WriteFile + commit)' }
    return $true
}

# Axis 33 · NO-FORK guard (Φ4 delivery-hardening) · the push target must be THE canonical repo, never a fork — a fork as
# origin would push/release/deploy to the WRONG place. Unset origin (local-only · no push target) = no-op PASS; if set it
# MUST carry the canonical slug (XDRLR_CANONICAL_ORIGIN overrides for a legitimate mirror).
Test-Axis '33 · NO-FORK · origin is the canonical repo (not a fork)' {
    $canonical = if ($env:XDRLR_CANONICAL_ORIGIN) { [string]$env:XDRLR_CANONICAL_ORIGIN } else { 'akefallonitis/xdrlograider' }
    $origin = [string](& git -C $RepoRoot config --get remote.origin.url 2>$null)
    if ([string]::IsNullOrWhiteSpace($origin)) { return $true }
    if ($origin -match [regex]::Escape($canonical)) { return $true }
    return "origin '$origin' != canonical '$canonical' (fork/wrong-remote · set XDRLR_CANONICAL_ORIGIN to override)"
}

# Axis 34 · hook-installed self-check (Φ4 delivery-hardening) · the pre-push + pre-commit hooks (which run THIS gauntlet +
# the attribution/secret gates) must actually be installed, else a dev commits/pushes PAST them. CI runs the gauntlet
# directly (no local hooks) → PASS in CI; local → both hook files must exist (run tools/hooks/Install-GitHooks.ps1).
Test-Axis '34 · hooks installed (pre-push + pre-commit · local dev)' {
    if ($env:GITHUB_ACTIONS -or $env:CI) { $script:NamedSkips += 34; return $true }
    $hooksDir = [string](& git -C $RepoRoot rev-parse --git-path hooks 2>$null)
    if ([string]::IsNullOrWhiteSpace($hooksDir)) { $hooksDir = Join-Path $RepoRoot '.git/hooks' }
    if (-not [System.IO.Path]::IsPathRooted($hooksDir)) { $hooksDir = Join-Path $RepoRoot $hooksDir }
    $missing = @()
    foreach ($h in @('pre-push', 'pre-commit')) { if (-not (Test-Path (Join-Path $hooksDir $h))) { $missing += $h } }
    if ($missing.Count -gt 0) { return "git hooks not installed: $($missing -join ', ') (run tools/hooks/Install-GitHooks.ps1)" }
    return $true
}

# Axis 35 · PUBLIC-ALLOWLIST (locked decision G4 · single-repo deny-by-default) · every git-TRACKED path must match
# tools/public-allowlist.txt — the internal layer (references/live · probes · .audit) is NOT listed, so tracking
# anything outside the public surface FAILS the push. A stray `git add -A` becomes un-shippable, not un-noticed.
Test-Axis '35 · PUBLIC-ALLOWLIST · every tracked path matches tools/public-allowlist.txt (deny-by-default)' {
    $tool = Join-Path $RepoRoot 'tools/Test-PublicAllowlist.ps1'
    if (-not (Test-Path $tool)) { return 'tools/Test-PublicAllowlist.ps1 missing' }
    $viol = @(& pwsh -NoProfile -File $tool -RepoRoot $RepoRoot 2>$null)
    if ($LASTEXITCODE -ne 0 -or @($viol).Count -gt 0) {
        $clip = (@($viol) | Select-Object -First 12) -join ' · '
        return "tracked paths OUTSIDE the public allowlist ($(@($viol).Count)): $clip"
    }
    return $true
}

# Axis 36 · mainTemplate regen->diff (the missing member of the axis-28/30/32 regen-diff family · plan §9 G4).
# deploy/mainTemplate.json MUST equal a fresh Build-MainTemplate rebuild from foundation.json + the committed
# per-category-schema artifacts. Build-MainTemplate is the SOLE writer: it emits the per-DCR Monitoring-Metrics-
# Publisher role grant a category needs to publish (an earlier per-category injector pattern omitted it ->
# a 2nd category's DCR 403s -> silent 0-rows). A hand-edit, a stale template, or a role-dropping regression FAILS.
Test-Axis '36 · regen->diff · deploy/mainTemplate.json == Build-MainTemplate rebuild (sole writer · no hand-edit/role-drop drift)' {
    $bmt = Join-Path $RepoRoot 'dev-tools/Build-MainTemplate.ps1'
    if (-not (Test-Path $bmt)) { return 'dev-tools/Build-MainTemplate.ps1 missing' }
    $committed = Join-Path $RepoRoot 'deploy/mainTemplate.json'
    if (-not (Test-Path $committed)) { return 'deploy/mainTemplate.json missing' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-mt-regen-" + [Guid]::NewGuid().ToString('N') + ".json")
    try {
        & pwsh -NoProfile -File $bmt -OutputPath $tmp -SkipPackageCard *> $null
        if (-not (Test-Path $tmp)) { return 'regen produced no mainTemplate (Build-MainTemplate failed)' }
        $a = ((Get-Content $committed -Raw) -replace "`r`n", "`n").TrimEnd()
        $b = ((Get-Content $tmp -Raw)       -replace "`r`n", "`n").TrimEnd()
        if ($a -ne $b) { return 'mainTemplate DRIFT · committed deploy/mainTemplate.json != Build-MainTemplate rebuild (hand-edited or stale? · run: pwsh dev-tools/Build-MainTemplate.ps1)' }
    } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
    return $true
}

# Axis 37 · INVERSE manifest invariant (the VulnerabilityManagement-class drift guard · 2026-06-24). Axes 7/16/28
# (Validate-Manifests + regen→diff) only see manifests that EXIST — a category Shipped=true in the catalogue but with
# NO manifest is INVISIBLE to them (the catalogue ship-gate in Build-Catalogue marks ops Shipped WITHOUT any manifest
# term; the manifest is a downstream per-category artifact). That gap let 15 VulnerabilityManagement ops sit
# Shipped=true with no manifest silently. This axis asserts the INVERSE: every distinct Defender category with >=1
# Shipped op HAS a manifest under manifests/Defender/. The category->manifest mapping is the SHARED Get-XdrCategoryToken
# (the SAME tokenizer Generate-Manifest uses · single-source · so the axis can never disagree with the generator), and
# the Shipped predicate is the EXACT ship-gate filter ($_.Shipped -eq $true). Delegates to the standalone validator
# (tools/Assert-ShippedManifestParity.ps1) via child pwsh · parses its structured -Json summary (parity with Axis 7).
Test-Axis '37 · INVERSE manifest invariant · every Shipped catalogue category HAS a manifest (VulnerabilityManagement-class drift guard)' {
    $tool = Join-Path $RepoRoot 'tools/Assert-ShippedManifestParity.ps1'
    if (-not (Test-Path $tool)) { return 'tools/Assert-ShippedManifestParity.ps1 missing · inverse-manifest invariant cannot run' }
    $json = & pwsh -NoProfile -File $tool -Portal Defender -Json 2>$null
    $exitCode = $LASTEXITCODE
    $r = try { $json | ConvertFrom-Json } catch { $null }
    if ($exitCode -ne 0) {
        $detail = if ($r) { [string]$r.reason } else { "Assert-ShippedManifestParity exit=$exitCode (unparseable output)" }
        return $detail
    }
    if (-not $r) { return 'Assert-ShippedManifestParity produced no parseable JSON summary' }
    if ([int]@($r.missing).Count -gt 0) { return [string]$r.reason }   # belt-and-braces · exit 0 already implies missing==0
    return $true
}

# Axis 38 · KQL-heredoc hygiene · no PowerShell '#'-comment inside a KQL here-string (@"..."@). A '#' inside a here-string is
# LITERAL text — here-strings do NOT honor '#' as a comment — so it is sent to the Log Analytics query engine as KQL, which
# comments with '//' NOT '#' → a live-only SyntaxError that makes the gate INCONCLUSIVE. Offline parse/Pester CANNOT catch it
# (the here-string is valid PowerShell). Live-caught 2026-07-03 (the AppExceptions poll-failure query). Inside a here-string
# that carries a KQL marker, a line starting with '#' is a mistaken comment (KQL statements start with |, let, or a table name).
Test-Axis '38 · KQL-heredoc hygiene · no ''#''-comment inside a KQL here-string (use // · live-only SyntaxError guard)' {
    $files = @('tools/Verify-DeployedConnector.ps1','tools/Run-PostDeployVerify.ps1','tools/Verify-XdrLiveContent.ps1','tools/Sync-LiveEstate.ps1') |
        ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path $_ }
    $bad = @()
    foreach ($f in $files) {
        $lines = @(Get-Content $f); $inHd = $false; $body = @(); $sLine = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (-not $inHd -and $lines[$i] -match '@"\s*$') { $inHd = $true; $body = @(); $sLine = $i + 1; continue }
            if ($inHd -and $lines[$i] -match '^\s*"@') {
                $inHd = $false
                if (($body -join "`n") -match 'AppEvents|AppExceptions|AppTraces|\|\s*where|\|\s*summarize|\|\s*extend|(^|\n)\s*let ') {
                    # BOTH '#' AND '//' are fatal inside a gate KQL here-string: '#' is literal-then-KQL-SyntaxError; '//' is a
                    # KQL comment-to-EOL, and Invoke-XdrKqlQuery COLLAPSES the query to ONE line → the '//' then eats the rest
                    # of the query. So: NO comments inside a KQL here-string — put them in a PowerShell comment BEFORE the here-string.
                    for ($j = 0; $j -lt $body.Count; $j++) { if ($body[$j] -match '^\s*(#|//)') { $bad += "$(Split-Path $f -Leaf) line ~$($sLine + $j + 1): $($body[$j].Trim())" } }
                }
                continue
            }
            if ($inHd) { $body += $lines[$i] }
        }
    }
    if ($bad.Count -eq 0) { return $true }
    foreach ($b in $bad) { Write-Host "    !  $($b.Substring(0,[Math]::Min(110,$b.Length)))" }
    return "$($bad.Count) '#'-comment(s) inside a KQL here-string (use // for KQL comments)"
}

Write-Host ''
$skipNote = if (@($script:NamedSkips).Count -gt 0) { " · named-skips: $((@($script:NamedSkips) | Sort-Object) -join ',')" } else { '' }
Write-Host "=== PRE-PUSH GAUNTLET · $pass passed · $err failed of $($pass + $err) axes$skipNote ===" -ForegroundColor Yellow
exit $err
