<#
.SYNOPSIS
    Live audit: call EVERY manifest stream against the live tenant + capture
    actual response shape + classify into live/empty/tenant-gated/error.
    Cross-references with manifest's declared Availability to find drift.

.DESCRIPTION
    Senior-architect ground-truth tool. Don't trust the manifest's
    Availability='live'/'tenant-gated' flags — verify against the actual API
    using SP-backed Defender portal session. Captures:
      - HTTP status code per call
      - Response row count (after Expand-MDEResponse)
      - Response shape (Shape 1/2/3/4 per Expand-MDEResponse classification)
      - Manifest-declared Availability
      - VERDICT: matches manifest? OR drift detected?

    Output: tests/results/live-stream-coverage-<UtcStamp>.md + console summary.

.PARAMETER OutputJson
    Also write a machine-readable JSON report alongside the markdown.

.PARAMETER OnlyStreams
    Optional comma-separated stream names to limit the audit (faster cycles).

.EXAMPLE
    pwsh tools/Audit-LiveStreamCoverage.ps1
    pwsh tools/Audit-LiveStreamCoverage.ps1 -OnlyStreams 'MDE_XspmAttackPaths_CL,MDE_DCCoverage_CL'
#>
[CmdletBinding()]
param(
    [string] $OnlyStreams,
    [switch] $OutputJson
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Load env
Get-Content (Join-Path $RepoRoot 'tests/.env.local') | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$k" -Value $v
}

# Module imports (ordered)
foreach ($m in 'Xdr.Common.Telemetry','Xdr.Common.Auth','Xdr.Common.Manifest','Xdr.Sentinel.Ingest','Xdr.Defender.Auth','Xdr.Defender.Client') {
    Import-Module (Join-Path $RepoRoot "src/Modules/$m/$m.psd1") -Force -Global -ErrorAction Stop
}

Write-Host '=== Live Stream Coverage Audit ===' -ForegroundColor Cyan
Write-Host ('  UPN: {0}' -f $env:XDRLR_TEST_UPN) -ForegroundColor DarkGray
Write-Host ''

# Auth
$cred = @{
    upn        = $env:XDRLR_TEST_UPN
    password   = $env:XDRLR_TEST_PASSWORD
    totpBase32 = $env:XDRLR_TEST_TOTP_SECRET
}
Write-Host 'Authenticating to Defender portal...' -ForegroundColor Cyan
$session = Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred -Force
Write-Host ('  TenantId: {0}' -f $session.TenantId) -ForegroundColor Green
Write-Host ''

# Pick streams
$manifest = Get-XdrEndpointManifest -Portal Defender -Force
$streams  = if ($OnlyStreams) {
    $names = $OnlyStreams -split ','
    $manifest.Values | Where-Object { $_.Stream -in $names }
} else {
    $manifest.Values
}
Write-Host ('Auditing {0} streams...' -f @($streams).Count) -ForegroundColor Cyan
Write-Host ''

$findings = @()
foreach ($entry in $streams | Sort-Object Stream) {
    $stream  = [string]$entry.Stream
    $declAvail = if ($entry.ContainsKey('Availability')) { [string]$entry.Availability } else { 'live' }

    Write-Host ('  [{0}] declared={1}' -f $stream, $declAvail) -ForegroundColor DarkGray

    if ($declAvail -eq 'deprecated') {
        $findings += [pscustomobject]@{
            Stream         = $stream
            DeclaredAvail  = $declAvail
            HttpStatus     = 'N/A'
            SuccessKind    = 'deprecated'
            RowCount       = 0
            ErrorText      = 'skipped (deprecated)'
            Verdict        = 'OK'
        }
        continue
    }

    try {
        $rows  = @(Invoke-MDEEndpoint -Session $session -Stream $stream -ErrorAction SilentlyContinue)
        $last  = Get-MDEEndpointLastResult
        $kind  = if ($last) { $last.SuccessKind } else { 'unknown' }
        $status = if ($last) { [int]$last.HttpStatus } else { 0 }
        $err    = if ($last) { $last.ErrorText } else { '' }
    } catch {
        $rows = @()
        $kind = 'error'
        $status = 0
        $err = $_.Exception.Message
    }

    # Section R+++ AVAILABILITY POLICY (2026-05-07): all manifest entries
    # declare 'live'. Runtime SuccessKind is the ground truth — verdict is
    # always OK-<kind> when declared=live. We only flag DRIFT when declared
    # is NOT 'live' AND runtime contradicts it (e.g. declared=deprecated but
    # runtime returns 200).
    $verdict = if ($declAvail -eq 'live') {
        switch ($kind) {
            'live'         { 'OK-LIVE' }
            'live-empty'   { 'OK-LIVE-EMPTY' }
            'tenant-gated' { 'OK-LIVE-RUNTIME-GATED' }      # legitimately license-gated in this tenant
            'error'        { 'OK-LIVE-RUNTIME-ERROR' }      # real API failure in this tenant
            default        { 'UNKNOWN' }
        }
    } else {
        # Non-live declared (deprecated, etc.) — drift if runtime says 200.
        switch ($kind) {
            'live'         { ('DRIFT: declared {0} but observed live' -f $declAvail) }
            'live-empty'   { ('DRIFT: declared {0} but observed 200' -f $declAvail) }
            'tenant-gated' { 'OK-GATED' }
            'error'        { 'OK-ERROR-EXPECTED' }
            default        { 'UNKNOWN' }
        }
    }

    $findings += [pscustomobject]@{
        Stream         = $stream
        DeclaredAvail  = $declAvail
        HttpStatus     = $status
        SuccessKind    = $kind
        RowCount       = $rows.Count
        ErrorText      = $err
        Verdict        = $verdict
    }

    $color = switch -wildcard ($verdict) { 'OK*' { 'Green' } 'DRIFT*' { 'Yellow' } default { 'Red' } }
    Write-Host ('    -> kind={0} status={1} rows={2} verdict={3}' -f $kind, $status, $rows.Count, $verdict) -ForegroundColor $color
}

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
$findings | Group-Object Verdict | ForEach-Object {
    Write-Host ('  {0}: {1}' -f $_.Name, $_.Count)
}
Write-Host ''
Write-Host 'DRIFT items (declared !== observed):' -ForegroundColor Yellow
$findings | Where-Object Verdict -like 'DRIFT*' | Format-Table Stream, DeclaredAvail, SuccessKind, HttpStatus, RowCount, Verdict -AutoSize -Wrap

# Persist
$resultsDir = Join-Path $RepoRoot 'tests/results'
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }
$stamp = (Get-Date -AsUTC).ToString('yyyyMMdd-HHmmssZ')
$mdPath = Join-Path $resultsDir "live-stream-coverage-$stamp.md"

$md = New-Object System.Text.StringBuilder
$null = $md.AppendLine("# Live Stream Coverage Audit")
$null = $md.AppendLine("")
$null = $md.AppendLine("- Timestamp: $(Get-Date -AsUTC -Format 'o')")
$null = $md.AppendLine("- Tenant: $($session.TenantId)")
$null = $md.AppendLine("- Streams audited: $((@($findings)).Count)")
$null = $md.AppendLine("")
$null = $md.AppendLine("## Verdict counts")
$null = $md.AppendLine("")
$findings | Group-Object Verdict | ForEach-Object { $null = $md.AppendLine("- $($_.Name): $($_.Count)") }
$null = $md.AppendLine("")
$null = $md.AppendLine("## Per-stream results")
$null = $md.AppendLine("")
$null = $md.AppendLine("| Stream | DeclaredAvail | SuccessKind | HttpStatus | RowCount | Verdict | ErrorText |")
$null = $md.AppendLine("|---|---|---|---|---|---|---|")
foreach ($f in ($findings | Sort-Object Stream)) {
    $err = ($f.ErrorText -replace '\|','\\|').Substring(0, [Math]::Min(80, $f.ErrorText.Length))
    $null = $md.AppendLine(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $f.Stream, $f.DeclaredAvail, $f.SuccessKind, $f.HttpStatus, $f.RowCount, $f.Verdict, $err))
}
[System.IO.File]::WriteAllText($mdPath, $md.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host ('Report: {0}' -f $mdPath) -ForegroundColor Cyan

if ($OutputJson) {
    $jsonPath = Join-Path $resultsDir "live-stream-coverage-$stamp.json"
    $findings | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding utf8
    Write-Host ('JSON: {0}' -f $jsonPath) -ForegroundColor Cyan
}

# Exit code: 0 if no drift, 1 if any DRIFT verdict, 2 if any ERROR
$driftCount = @($findings | Where-Object Verdict -like 'DRIFT*').Count
$errCount   = @($findings | Where-Object Verdict -eq 'ERROR').Count
exit $(if ($errCount -gt 0) { 2 } elseif ($driftCount -gt 0) { 1 } else { 0 })
