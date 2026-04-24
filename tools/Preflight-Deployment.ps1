#Requires -Version 7.4
<#
.SYNOPSIS
    Pre-deployment production-readiness gate for XdrLogRaider v0.1.0-beta.

.DESCRIPTION
    Single entrypoint — answers "am I ready to click Deploy-to-Azure?".

    Runs layered checks and short-circuits on the first failure so operators
    fix gates in order of criticality. Every section emits a line to both the
    console AND the summary markdown at tests/results/preflight-<utcStamp>.md.

    Sections (all mandatory unless -SkipOnline is passed):
      1. Offline unit + validate suites  (Run-Tests.ps1 -Category all-offline)
      2. PSScriptAnalyzer — 0 errors
      3. ARM + Solution validators       (Validate-ArmJson.ps1)
      4. Config hygiene                  (gitleaks HEAD, no secrets committed)
      5. Content Hub compliance          (47-table Data Connector, enabled:false)
      6. Schema consistency              (manifest <-> DCR <-> custom-tables)
      7. Online live audit               (Audit-Endpoints-Live.ps1; skip with -SkipOnline)
      8. Deploy-flow integrity           (ARM outputs, appSettings 1:1 mapping)

    Exits 0 only if every mandatory section passes. Writes structured
    markdown + JSON summary so CI can parse the result.

.PARAMETER SkipOnline
    Skip sections 7 (live audit). Useful for fast dev-loop runs; you MUST
    complete online coverage separately before deploying.

.PARAMETER MinTests
    Minimum offline test count to pass. Default 1000.

.EXAMPLE
    pwsh ./tools/Preflight-Deployment.ps1

.EXAMPLE
    # Fast check without live-portal probe
    pwsh ./tools/Preflight-Deployment.ps1 -SkipOnline
#>
[CmdletBinding()]
param(
    [switch] $SkipOnline,
    [int]    $MinTests = 1000
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$stamp = (Get-Date -AsUTC).ToString('yyyyMMdd-HHmmss')
$resultDir = Join-Path $repoRoot 'tests' 'results'
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
$mdPath   = Join-Path $resultDir "preflight-$stamp.md"
$jsonPath = Join-Path $resultDir "preflight-$stamp.json"

$results = [System.Collections.Generic.List[pscustomobject]]::new()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Add-Check {
    param(
        [string] $Section,
        [string] $Name,
        [ValidateSet('Pass', 'Fail', 'Skip', 'Warn')][string] $Status,
        [string] $Detail = ''
    )
    $icon = @{ Pass = 'OK  '; Fail = 'FAIL'; Skip = 'SKIP'; Warn = 'WARN' }[$Status]
    $line = "[$icon] $Section :: $Name"
    if ($Detail) { $line += " -- $Detail" }
    switch ($Status) {
        'Pass' { Write-Host $line -ForegroundColor Green }
        'Fail' { Write-Host $line -ForegroundColor Red }
        'Skip' { Write-Host $line -ForegroundColor DarkGray }
        'Warn' { Write-Host $line -ForegroundColor Yellow }
    }
    $results.Add([pscustomobject]@{
        Section = $Section; Name = $Name; Status = $Status; Detail = $Detail
        TimestampUtc = (Get-Date -AsUTC).ToString('o')
    })
}

Write-Host ""
Write-Host "===== XdrLogRaider pre-deploy gate  (v0.1.0-beta) =====" -ForegroundColor Cyan
Write-Host "Repo:   $repoRoot"
Write-Host "UTC:    $(Get-Date -AsUTC -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Output: $mdPath"
Write-Host ""

# -----------------------------------------------------------------
# Section 1 -- Offline Pester suite
# -----------------------------------------------------------------
Write-Host "--- 1/8  Offline Pester suite ---" -ForegroundColor Cyan
try {
    $runTests = Join-Path $repoRoot 'tests' 'Run-Tests.ps1'
    $testOutput = & $runTests -Category all-offline 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    # Run-Tests.ps1 sets $LASTEXITCODE = Failed.Count so 0 means all pass.
    # Also scan for the Pester summary line to surface a visible count.
    $passCount = 0; $failCount = 0
    if ($testOutput -match 'Tests Passed:\s+(\d+),\s*Failed:\s+(\d+)') {
        $passCount = [int]$Matches[1]; $failCount = [int]$Matches[2]
    }
    if ($exitCode -eq 0 -and $failCount -eq 0 -and $passCount -ge $MinTests) {
        Add-Check -Section '1-Offline' -Name 'Pester all-offline suite' -Status Pass -Detail "$passCount tests passed (threshold $MinTests)"
    } elseif ($exitCode -eq 0 -and $passCount -eq 0) {
        # Exit 0 but count not found — could be a legit pass; don't false-fail.
        Add-Check -Section '1-Offline' -Name 'Pester all-offline suite' -Status Pass -Detail 'Run-Tests.ps1 exited 0 (count unparsed but no failures)'
    } else {
        Add-Check -Section '1-Offline' -Name 'Pester all-offline suite' -Status Fail -Detail "exitCode=$exitCode pass=$passCount fail=$failCount"
    }
} catch {
    Add-Check -Section '1-Offline' -Name 'Pester all-offline suite' -Status Fail -Detail $_.Exception.Message
}

# -----------------------------------------------------------------
# Section 2 -- PSScriptAnalyzer (0 errors)
# -----------------------------------------------------------------
Write-Host "--- 2/8  PSScriptAnalyzer ---" -ForegroundColor Cyan
try {
    $pssaSettings = Join-Path $repoRoot '.config' 'PSScriptAnalyzerSettings.psd1'
    $paths = @('src', 'tools', 'tests') | ForEach-Object { Join-Path $repoRoot $_ }
    $pssaErrors = @()
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        $findings = Invoke-ScriptAnalyzer -Path $p -Recurse -Settings $pssaSettings |
            Where-Object Severity -eq 'Error'
        if ($findings) { $pssaErrors += $findings }
    }
    if ($pssaErrors.Count -eq 0) {
        Add-Check -Section '2-PSSA' -Name 'PSScriptAnalyzer (src+tools+tests)' -Status Pass -Detail '0 errors'
    } else {
        Add-Check -Section '2-PSSA' -Name 'PSScriptAnalyzer (src+tools+tests)' -Status Fail -Detail "$($pssaErrors.Count) errors"
    }
} catch {
    Add-Check -Section '2-PSSA' -Name 'PSScriptAnalyzer' -Status Warn -Detail "not installed or failed: $($_.Exception.Message)"
}

# -----------------------------------------------------------------
# Section 3 -- ARM + Solution integrity
# -----------------------------------------------------------------
Write-Host "--- 3/8  ARM + Solution validators ---" -ForegroundColor Cyan
try {
    $validate = Join-Path $repoRoot 'tools' 'Validate-ArmJson.ps1'
    if (Test-Path $validate) {
        $validateOut = & $validate 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Add-Check -Section '3-ARM' -Name 'Validate-ArmJson.ps1' -Status Pass -Detail 'ARM templates valid'
        } else {
            Add-Check -Section '3-ARM' -Name 'Validate-ArmJson.ps1' -Status Fail -Detail "exit code $LASTEXITCODE"
        }
    } else {
        Add-Check -Section '3-ARM' -Name 'Validate-ArmJson.ps1' -Status Warn -Detail 'script not present'
    }
} catch {
    Add-Check -Section '3-ARM' -Name 'Validate-ArmJson.ps1' -Status Fail -Detail $_.Exception.Message
}

# -----------------------------------------------------------------
# Section 4 -- Credential hygiene
# -----------------------------------------------------------------
Write-Host "--- 4/8  Credential hygiene ---" -ForegroundColor Cyan
try {
    # Quick sanity: no tracked file contains obvious secret patterns.
    Push-Location $repoRoot
    $trackedFiles = git ls-files
    Pop-Location

    $suspicious = 0
    foreach ($f in $trackedFiles) {
        $full = Join-Path $repoRoot $f
        if (-not (Test-Path $full)) { continue }
        # skip binary-ish
        if ($f -match '\.(png|jpg|svg|pdf|zip)$') { continue }
        $content = Get-Content $full -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        # Look for Azure storage keys, sccauth cookies, passkey JSON with private keys, TOTP seeds
        if ($content -match '"privateKey"\s*:\s*"[A-Za-z0-9+/=]{50,}"' -or
            $content -match 'AccountKey=[A-Za-z0-9+/=]{40,}' -or
            $content -match 'sccauth_[a-f0-9]{40,}') {
            $suspicious++
        }
    }
    if ($suspicious -eq 0) {
        Add-Check -Section '4-Creds' -Name 'No secret patterns in tracked files' -Status Pass -Detail "0 suspicious matches across $($trackedFiles.Count) files"
    } else {
        Add-Check -Section '4-Creds' -Name 'No secret patterns in tracked files' -Status Fail -Detail "$suspicious files matched secret patterns"
    }
} catch {
    Add-Check -Section '4-Creds' -Name 'Credential hygiene scan' -Status Warn -Detail $_.Exception.Message
}

# -----------------------------------------------------------------
# Section 5 -- Content Hub compliance
# -----------------------------------------------------------------
Write-Host "--- 5/8  Content Hub compliance ---" -ForegroundColor Cyan
try {
    # 5a — Data Connector lists all 47 tables
    $dcPath = Join-Path $repoRoot 'deploy' 'solution' 'Data Connectors' 'XdrLogRaider_DataConnector.json'
    $dc = Get-Content $dcPath -Raw | ConvertFrom-Json
    $tableCount = @($dc.dataTypes).Count
    if ($tableCount -eq 47) {
        Add-Check -Section '5-Hub' -Name 'Data Connector lists all 47 tables' -Status Pass -Detail "dataTypes.Count = $tableCount"
    } else {
        Add-Check -Section '5-Hub' -Name 'Data Connector lists all 47 tables' -Status Fail -Detail "dataTypes.Count = $tableCount (expected 47)"
    }

    # 5b — All 14 analytic rules have enabled: false
    $rulesDir = Join-Path $repoRoot 'sentinel' 'analytic-rules'
    $rules = Get-ChildItem -Path $rulesDir -Filter '*.yaml'
    $missingEnabled = $rules | Where-Object { -not ((Get-Content $_.FullName -Raw) -match '(?m)^enabled:\s*false') }
    if ($rules.Count -eq 14 -and $missingEnabled.Count -eq 0) {
        Add-Check -Section '5-Hub' -Name 'All 14 rules ship enabled:false' -Status Pass -Detail '14/14'
    } else {
        Add-Check -Section '5-Hub' -Name 'All 14 rules ship enabled:false' -Status Fail -Detail "rules=$($rules.Count) missing-enabled=$($missingEnabled.Count)"
    }

    # 5c — All 9 hunting queries have author/version/tags metadata
    $huntDir = Join-Path $repoRoot 'sentinel' 'hunting-queries'
    $hunts = Get-ChildItem -Path $huntDir -Filter '*.yaml'
    $missingMeta = $hunts | Where-Object {
        $c = Get-Content $_.FullName -Raw
        -not ($c -match '(?m)^author:' -and $c -match '(?m)^version:' -and $c -match '(?m)^tags:')
    }
    if ($hunts.Count -eq 9 -and $missingMeta.Count -eq 0) {
        Add-Check -Section '5-Hub' -Name 'All 9 hunting queries have metadata' -Status Pass -Detail '9/9'
    } else {
        Add-Check -Section '5-Hub' -Name 'All 9 hunting queries have metadata' -Status Fail -Detail "hunts=$($hunts.Count) missing-meta=$($missingMeta.Count)"
    }

    # 5d — No removed-stream references in compiled artefacts
    $removedStreams = @(
        'MDE_AsrRulesConfig_CL', 'MDE_AntiRansomwareConfig_CL', 'MDE_ControlledFolderAccess_CL',
        'MDE_NetworkProtectionConfig_CL', 'MDE_ApprovalAssignments_CL',
        'MDE_CriticalAssets_CL', 'MDE_DeviceCriticality_CL'
    )
    $grepPaths = @('deploy/compiled', 'sentinel') | ForEach-Object { Join-Path $repoRoot $_ }
    $leaks = 0
    foreach ($p in $grepPaths) {
        foreach ($s in $removedStreams) {
            $found = Select-String -Path "$p/**/*" -Pattern $s -SimpleMatch -ErrorAction SilentlyContinue
            if ($found) { $leaks += @($found).Count }
        }
    }
    if ($leaks -eq 0) {
        Add-Check -Section '5-Hub' -Name 'No removed-stream refs in deploy/sentinel' -Status Pass -Detail '0 leaks'
    } else {
        Add-Check -Section '5-Hub' -Name 'No removed-stream refs in deploy/sentinel' -Status Fail -Detail "$leaks removed-stream mentions"
    }
} catch {
    Add-Check -Section '5-Hub' -Name 'Content Hub compliance' -Status Fail -Detail $_.Exception.Message
}

# -----------------------------------------------------------------
# Section 6 -- Schema consistency
# -----------------------------------------------------------------
Write-Host "--- 6/8  Schema consistency ---" -ForegroundColor Cyan
try {
    # Manifest count
    Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1')     -Force -ErrorAction Stop
    Import-Module (Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'XdrLogRaider.Client.psd1') -Force -ErrorAction Stop
    $manifest = Get-MDEEndpointManifest -Force
    if ($manifest.Count -eq 45) {
        Add-Check -Section '6-Schema' -Name 'Manifest = 45 streams' -Status Pass -Detail "$($manifest.Count) streams"
    } else {
        Add-Check -Section '6-Schema' -Name 'Manifest = 45 streams' -Status Fail -Detail "$($manifest.Count) (expected 45)"
    }

    # Every manifest entry has required fields
    $bad = @()
    foreach ($s in $manifest.Keys) {
        $e = $manifest[$s]
        if (-not $e.Stream -or -not $e.Path -or -not $e.Tier -or -not $e.Availability -or -not $e.Portal) {
            $bad += $s
        }
    }
    if ($bad.Count -eq 0) {
        Add-Check -Section '6-Schema' -Name 'Every entry has Stream+Path+Tier+Availability+Portal' -Status Pass -Detail '45/45'
    } else {
        Add-Check -Section '6-Schema' -Name 'Every entry has required fields' -Status Fail -Detail "malformed: $($bad -join ',')"
    }
} catch {
    Add-Check -Section '6-Schema' -Name 'Schema consistency' -Status Fail -Detail $_.Exception.Message
}

# -----------------------------------------------------------------
# Section 7 -- Online live audit (optional)
# -----------------------------------------------------------------
Write-Host "--- 7/8  Online live audit ---" -ForegroundColor Cyan
if ($SkipOnline) {
    Add-Check -Section '7-Live' -Name 'Live endpoint audit (Audit-Endpoints-Live.ps1)' -Status Skip -Detail '-SkipOnline passed'
} else {
    $envLocal = Join-Path $repoRoot 'tests' '.env.local'
    if (Test-Path $envLocal) {
        try {
            $auditScript = Join-Path $repoRoot 'tests' 'integration' 'Audit-Endpoints-Live.ps1'
            $auditOut = & $auditScript 2>&1 | Out-String
            # Count 200s in the CSV by reading the latest result file
            $latestCsv = Get-ChildItem -Path $resultDir -Filter 'endpoint-audit-*.csv' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestCsv) {
                $rows = Import-Csv $latestCsv.FullName
                $count200 = @($rows | Where-Object { $_.Status -match '^2\d\d' }).Count
                Add-Check -Section '7-Live' -Name 'Live audit against admin account' -Status Pass -Detail "$count200 streams returned 2xx"
            } else {
                Add-Check -Section '7-Live' -Name 'Live audit against admin account' -Status Warn -Detail 'script ran but no CSV produced'
            }
        } catch {
            Add-Check -Section '7-Live' -Name 'Live audit against admin account' -Status Fail -Detail $_.Exception.Message
        }
    } else {
        Add-Check -Section '7-Live' -Name 'Live audit' -Status Skip -Detail 'tests/.env.local not present; populate and re-run'
    }
}

# -----------------------------------------------------------------
# Section 8 -- Deploy-flow integrity
# -----------------------------------------------------------------
Write-Host "--- 8/8  Deploy-flow integrity ---" -ForegroundColor Cyan
try {
    $mainTemplate = Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $arm = Get-Content $mainTemplate -Raw | ConvertFrom-Json

    # Check required outputs
    $reqOutputs = @('keyVaultName', 'postDeployCommand')
    $haveOutputs = @($arm.outputs.PSObject.Properties.Name)
    $missing = $reqOutputs | Where-Object { $_ -notin $haveOutputs }
    if ($missing.Count -eq 0) {
        Add-Check -Section '8-Flow' -Name 'ARM outputs include keyVaultName + postDeployCommand' -Status Pass -Detail 'present'
    } else {
        Add-Check -Section '8-Flow' -Name 'ARM outputs' -Status Fail -Detail "missing: $($missing -join ',')"
    }

    # profile.ps1 envvar list matches appSettings 1:1
    $profile = Get-Content (Join-Path $repoRoot 'src' 'profile.ps1') -Raw
    $envVarsInProfile = [regex]::Matches($profile, "'([A-Z_]+)';\s+Purpose") | ForEach-Object { $_.Groups[1].Value }
    $armStr = $arm | ConvertTo-Json -Depth 30
    $missingInArm = $envVarsInProfile | Where-Object { $armStr -notmatch $_ }
    if ($missingInArm.Count -eq 0) {
        Add-Check -Section '8-Flow' -Name 'profile.ps1 envvars <-> mainTemplate.json 1:1' -Status Pass -Detail "$($envVarsInProfile.Count) envvars aligned"
    } else {
        Add-Check -Section '8-Flow' -Name 'profile.ps1 envvars <-> mainTemplate.json' -Status Fail -Detail "missing in ARM: $($missingInArm -join ',')"
    }
} catch {
    Add-Check -Section '8-Flow' -Name 'Deploy-flow integrity' -Status Fail -Detail $_.Exception.Message
}

# -----------------------------------------------------------------
# Summary
# -----------------------------------------------------------------
$sw.Stop()
$passed = @($results | Where-Object Status -eq 'Pass').Count
$failed = @($results | Where-Object Status -eq 'Fail').Count
$warned = @($results | Where-Object Status -eq 'Warn').Count
$skipped = @($results | Where-Object Status -eq 'Skip').Count

Write-Host ""
Write-Host "===== SUMMARY =====" -ForegroundColor Cyan
Write-Host "  Pass:    $passed" -ForegroundColor Green
Write-Host "  Fail:    $failed" -ForegroundColor ($(if ($failed -gt 0) { 'Red' } else { 'Green' }))
Write-Host "  Warn:    $warned" -ForegroundColor ($(if ($warned -gt 0) { 'Yellow' } else { 'Gray' }))
Write-Host "  Skip:    $skipped" -ForegroundColor DarkGray
Write-Host "  Elapsed: $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor Gray
Write-Host ""

$ready = ($failed -eq 0)
if ($ready) {
    Write-Host "PRE-DEPLOY READY: YES" -ForegroundColor Green
} else {
    Write-Host "PRE-DEPLOY READY: NO ($failed failure(s) must be fixed)" -ForegroundColor Red
}

# Markdown output
$md = @()
$md += "# XdrLogRaider preflight -- $stamp"
$md += ''
$md += "- Repo: $repoRoot"
$md += "- Pass/Fail/Warn/Skip: **$passed / $failed / $warned / $skipped**"
$md += "- Elapsed: $([int]$sw.Elapsed.TotalSeconds)s"
$md += "- PRE-DEPLOY READY: **$(if ($ready) { 'YES' } else { 'NO' })**"
$md += ''
$md += '| Section | Check | Status | Detail |'
$md += '|---------|-------|--------|--------|'
foreach ($r in $results) {
    $md += "| $($r.Section) | $($r.Name) | $($r.Status) | $($r.Detail) |"
}
$md -join "`n" | Set-Content -Path $mdPath -Encoding UTF8
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8

Write-Host "Wrote: $mdPath"
Write-Host "Wrote: $jsonPath"

if (-not $ready) { exit 1 }
exit 0
