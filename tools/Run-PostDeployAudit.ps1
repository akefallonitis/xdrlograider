#Requires -Version 7.4
<#
.SYNOPSIS
The reproducible, per-category §4.B POSTDEPLOY AUDIT — runs the B1-B11 axis checklist MECHANICALLY so the
postdeploy re-prove CONFIRMS, never DISCOVERS (the hand-run §4.B harness, made re-runnable). Composes the
existing gates (Verify-XdrLiveContent + Verify-DeployedConnector + Save-XdrCheckpointReset) and adds the new
B9-B11 steady-state queries (tools/lib/Xdr.PostDeployAudit.ps1 pure decisions). Emits a structured per-axis
verdict (PASS/INCONCLUSIVE/FAIL) + a summary line + an exit code (0 all-pass, 2 any-fail).

.DESCRIPTION
B4-compliant: this WIRES existing checks + adds the three NEW gate functions the SSOT §4.B locks (B9 error-rate,
B10 dup-accumulation, B11 fail-open) — it does NOT add a defensive runtime layer. The composed verifiers keep
their own exit contracts; B9-B11 are evaluated here against the deployed FA's Log Analytics workspace.

Axis map (SSOT §4.B):
  B1  boot-confirm-through-ingest  · delegated to Verify-DeployedVersion (via Run-PostDeployVerify version stage); -WaitMinutes
  B3  cold-emit discipline         · Save-XdrCheckpointReset -Apply (unless -SkipReset) so SNAPSHOT ops re-emit
  B6  D-GATES (the automatic core)  · Verify-XdrLiveContent -AllOps -VerdictOut  THEN  Verify-DeployedConnector -AllOps -LiveSourceVerdicts
  B9  AppTraces error/warning-RATE  · NEW · genuine-error rate per Entry.Poll.Succeeded over a steady-state window
  B10 steady-state dup-accumulation · NEW · rows/distinct-RecordId per SNAPSHOT op over 24h, artifact-discriminated by reset+skip-fraction
  B11 fail-open detection           · NEW · Entry.FailOpen sustained recurrence + un-recovered Breaker.Opened
(B2 handover-drain · B4 landing-confirm · B5 query-honesty · B7 no-regression · B8 reserved-column are enforced
 inside the composed verifiers / Run-PostDeployVerify / the schema chain — this driver focuses on the per-category
 mechanical B-axes plus the three NEW B9-B11 gates that previously lived only in the hand-run §4.B harness.)

CRITICAL · KQL HYGIENE (the silent-false-negative class):
  - SINGLE-quote every KQL string literal in az --analytics-query (az.cmd STRIPS double-quotes → SemanticError →
    silent false-negative). All queries here use '...' literals.
  - The _CL op column is 'Operation' (the legacy 'Operation'+'Name' concatenation is WRONG). AppEvents op identity is tostring(Properties.OperationKey).
  - B5 QUERY-HONESTY: a null/empty/errored query is INCONCLUSIVE, never 0 (the pure fns return Inconclusive on -QueryOk:$false).

LOCAL-ONLY by inheritance (the content stage refuses CI). Run autonomously post-deploy.

.EXAMPLE
pwsh tools/Run-PostDeployAudit.ps1 -Category Exposure -WorkspaceResourceId /subscriptions/.../workspaces/ws -ResourceGroup xdrlograider
pwsh tools/Run-PostDeployAudit.ps1 -Category Operations -SkipReset   # steady-state B9-B11 only (no cold-emit reset)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Category,
    [ValidateSet('Defender','Entra','Intune','Purview','SecurityCopilot')] [string] $Portal = 'Defender',
    [string] $WorkspaceResourceId,          # ARM full resource id · ← .env.local XDRLR_WORKSPACE_RESOURCE_ID if omitted (also resolves the customerId GUID)
    [string] $WorkspaceId,                  # customerId GUID · ← .env.local XDRLR_WORKSPACE_ID if omitted, else resolved from -WorkspaceResourceId
    [string] $ResourceGroup,                # ← .env.local XDRLR_CONNECTOR_RG if omitted
    [string] $FunctionApp,                  # ← .env.local XDRLR_FUNCTION_APP if omitted
    [string] $StorageAccount,               # ← .env.local XDRLR_STORAGE_ACCOUNT if omitted (B3 reset target)
    [switch] $SkipReset,                     # skip the B3 cold-emit reset (steady-state B9-B11 over the existing window)
    [int]    $B9WindowHours = 6,            # B9 steady-state error-rate window
    [int]    $B10WindowHours = 24,          # B10 dup-accumulation window
    [int]    $B11WindowHours = 6,           # B11 fail-open window
    [int]    $ColdEmitWaitMinutes = 25,     # B3→B6 cold-emit landing wait (exceeds the slowest staggered cadence)
    [string] $DeployedSinceUtc,             # absolute cutover floor forwarded to the composed connector window
    [switch] $RunDGates                      # also run the B6 D-gates (Run-PostDeployVerify) — heavier; default off so B9-B11 are quick to re-run
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

. (Join-Path $PSScriptRoot 'lib/Xdr.PostDeployAudit.ps1')

# ── CI refusal (the reset + the composed content verifier auth as the service account · creds never in CI) ──
if ($env:CI -or $env:GITHUB_ACTIONS) {
    Write-Warning 'Run-PostDeployAudit is LOCAL-ONLY (it can reset checkpoints + the composed content verify auths the service account). Refusing under CI.'
    exit 2
}

# ── .env.local fill (the established estate source · a public tool bakes in nothing) ───────────────
$envLocal = Join-Path $repoRoot '.env.local'; $ev = @{}
if (Test-Path $envLocal) { Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*([A-Za-z_]\w*)\s*=\s*(.+)$') { $ev[$Matches[1]] = $Matches[2].Trim().Trim('"') } } }
if (-not $ResourceGroup)  { $ResourceGroup  = $ev['XDRLR_CONNECTOR_RG'] }
if (-not $FunctionApp)    { $FunctionApp    = $ev['XDRLR_FUNCTION_APP'] }
if (-not $StorageAccount) { $StorageAccount = $ev['XDRLR_STORAGE_ACCOUNT'] }
if (-not $WorkspaceResourceId) { $WorkspaceResourceId = $ev['XDRLR_WORKSPACE_RESOURCE_ID'] }
if (-not $WorkspaceId)         { $WorkspaceId         = $ev['XDRLR_WORKSPACE_ID'] }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error 'az CLI not found · install Azure CLI'; exit 3 }
# SP login from .env.local if not already authenticated (autonomous path).
az account show -o json *> $null
if ($LASTEXITCODE -ne 0 -and $ev['AZURE_CLIENT_ID']) {
    az login --service-principal -u $ev['AZURE_CLIENT_ID'] -p $ev['AZURE_CLIENT_SECRET'] --tenant $ev['AZURE_TENANT_ID'] --only-show-errors *> $null
    if ($ev['XDRLR_SUBSCRIPTION_ID']) { az account set --subscription $ev['XDRLR_SUBSCRIPTION_ID'] --only-show-errors }
}

# ── resolve the customerId GUID (B9-B11 query via `az monitor log-analytics query --workspace <guid>`) ──
if (-not $WorkspaceId) {
    if (-not $WorkspaceResourceId) { Write-Error 'Pass -WorkspaceId (customerId GUID) or -WorkspaceResourceId (ARM id) — neither resolvable from .env.local'; exit 3 }
    $WorkspaceId = (az monitor log-analytics workspace show --ids $WorkspaceResourceId --query customerId -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $WorkspaceId) { Write-Error "Could not resolve customerId from $WorkspaceResourceId"; exit 3 }
    $WorkspaceId = $WorkspaceId.Trim()
}
$workspaceTable = "${Portal}_${Category}_CL"
$partitionKey   = "${Portal}_${Category}"
Write-Host "[postdeploy-audit] Category=$Category · Portal=$Portal · table=$workspaceTable · ws=$WorkspaceId · SkipReset=$($SkipReset.IsPresent)" -ForegroundColor Cyan

# ── KQL helper (SINGLE-quote literals · @file to dodge the Windows cmdline cap · bounded retry · B5 honesty) ──
# Mirrors Verify-DeployedConnector.ps1's Invoke-XdrKqlQuery: returns @{ Success; Error; Data=@(<row-hashtable>...) }.
# A genuine zero-row result is Success=$true with empty Data; a transient that survives retry is Success=$false
# (→ the pure B-fns receive -QueryOk:$false → INCONCLUSIVE, never a silent 0).
function Get-XdrAuditKqlBackoffSeconds {
    # PURE · §4.B THROTTLE-BACKOFF (2026-06-24) · the exponential-backoff-with-jitter sleep for the Invoke-XdrAuditKql
    # retry, IDENTICAL to Verify-DeployedConnector.ps1's Get-XdrKqlBackoffSeconds (kept in-file so this driver process is
    # self-contained). EXPONENTIAL base 2s (2/4/8/16 · capped 60s) rides out a sustained LA query throttle (HTTP 429 ·
    # 'ResponseSizeError'/'throttle'/'Rate limit') far past the old LINEAR 5·10·15·20s (~50s) ceiling that let a throttle
    # SURVIVE the retry → the audit FALSE-read INCONCLUSIVE ("transient/throttle survived retry"). FULL JITTER (uniform
    # 0..1× of the delay) de-syncs the concurrent B9/B10/B11 query burst; a Retry-After hint in the az error text
    # OVERRIDES when LONGER (the server's own pacing). B5 HONESTY HOLDS: this only sizes the wait — an unexecutable query
    # still exhausts the loop → Success=$false → the pure B-fn marks the axis INCONCLUSIVE, never a silent 0.
    param([int]$Attempt, [string]$ErrorText = '', [int]$BaseSeconds = 2, [int]$CapSeconds = 60)
    if ($Attempt -lt 1) { $Attempt = 1 }
    $exp = [double]$BaseSeconds * [Math]::Pow(2, ($Attempt - 1))
    $delay = [Math]::Min([double]$CapSeconds, $exp)
    $jitter = (Get-Random -Minimum 0.0 -Maximum 1.0) * $delay
    $sleep = [int][Math]::Ceiling($delay * 0.5 + $jitter * 0.5)
    if (-not [string]::IsNullOrEmpty($ErrorText)) {
        $m = [regex]::Match($ErrorText, '(?i)retry[\s-]?after[:\s]+(\d+)')
        if ($m.Success) {
            $ra = 0
            if ([int]::TryParse($m.Groups[1].Value, [ref]$ra) -and $ra -gt $sleep) { $sleep = [Math]::Min($CapSeconds, $ra) }
        }
    }
    if ($sleep -lt 1) { $sleep = 1 }
    return $sleep
}

function Invoke-XdrAuditKql {
    param([string]$Query, [string]$Label = '')
    $flat = ([regex]::Replace($Query, '\s+', ' ')).Trim()
    $tmp = [System.IO.Path]::GetTempFileName(); $errFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $flat, [System.Text.UTF8Encoding]::new($false))
        # §4.B: 6 attempts on EXPONENTIAL backoff (was 5 linear) so a sustained LA throttle is ridden out (~62s + jitter
        # vs the old ~50s) before the B5-honest INCONCLUSIVE. A genuine zero-row result still returns on the first try.
        $attempts = 6; $lastErr = $null
        for ($a = 1; $a -le $attempts; $a++) {
            $raw = az monitor log-analytics query --workspace $WorkspaceId --analytics-query "@$tmp" --output json 2>$errFile
            if ($LASTEXITCODE -ne 0) {
                $et = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue); if ($et) { $et = ([regex]::Replace($et, '\s+', ' ')).Trim() }
                $lastErr = "az query exit=$LASTEXITCODE$(if($et){": $et"})"
            } else {
                if ([string]::IsNullOrWhiteSpace($raw)) { return @{ Success = $true; Error = $null; Data = @() } }
                try { return @{ Success = $true; Error = $null; Data = @($raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop) } }
                catch { $lastErr = $_.Exception.Message }
            }
            if ($a -lt $attempts) { Start-Sleep -Seconds (Get-XdrAuditKqlBackoffSeconds -Attempt $a -ErrorText $lastErr) }
        }
        Write-Host "[postdeploy-audit] WARN · KQL '$Label' did not execute after $attempts tries: $lastErr" -ForegroundColor DarkYellow
        return @{ Success = $false; Error = $lastErr; Data = @() }
    } finally {
        Remove-Item $tmp, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# B5 KNOWN-GOOD validation: prove the query mechanism works on a guaranteed-non-empty case before trusting any
# "0". `AppEvents | count` over the window must return a row; if it errors, the workspace/auth is the problem and
# every B9-B11 verdict would be a false INCONCLUSIVE masquerading as a steady-state read — surface it loudly.
$sinceMax = [Math]::Max([Math]::Max($B9WindowHours, $B10WindowHours), $B11WindowHours)
$kgQuery = "AppEvents | where TimeGenerated >= ago(${sinceMax}h) | summarize n = count()"
$kg = Invoke-XdrAuditKql -Query $kgQuery -Label 'known-good'
$queryMechOk = $kg.Success
if (-not $queryMechOk) {
    Write-Host "[postdeploy-audit] B5 known-good probe FAILED (AppEvents|count did not execute) — the workspace/auth is unreachable; B9-B11 cannot be trusted." -ForegroundColor Red
} else {
    $kgN = Get-XdrAuditCount -Result $kg -Column 'n'
    Write-Host "[postdeploy-audit] B5 known-good · AppEvents over ${sinceMax}h = $kgN events (query mechanism live)" -ForegroundColor DarkGray
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Verdict collection
# ════════════════════════════════════════════════════════════════════════════════════════════════
$axes = [ordered]@{}
function Add-Axis { param([string]$Id, [hashtable]$Decision)
    $axes[$Id] = $Decision
    $color = switch ($Decision.Verdict) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("  [{0,-4}] {1,-12} · {2}" -f $Id, $Decision.Verdict, $Decision.Detail) -ForegroundColor $color
}

# ── helper · count checkpoint resets (resetAt) in a window for THIS category's partition ────────────
# A reset re-baselines → B9/B10 raw counts are operator-inflated, so the artifact-discrimination in the pure B9/B10
# fns MUST be able to SEE every reset that fell in the window. §4.B FIX-3 (2026-06-24): the AUTHORITATIVE reset source
# is the DURABLE checkpoint ROW field `ResetUtc` (written by Save-XdrCheckpointReset into XdrCheckpoint · PartitionKey
# "<Portal>_<Category>"), NOT the Checkpoint.Reset TELEMETRY event. The telemetry event lags/drops (AppEvents ingest
# latency · sampling) → the gate reported "NO reset" despite resets having happened today (3 resets unseen → B10
# FALSE-FAILed on reset churn). Reading the row directly is immune to telemetry lag: the reset stamp is in storage the
# instant the reset is written. Primary = a Table data-plane query over the partition counting rows whose ResetUtc is in
# the window; the AppEvents count is kept ONLY as a fallback when storage is unreachable (no -StorageAccount / token).
function Get-XdrResetCountFromCheckpointRows {
    param([int]$Hours)
    # Read the XdrCheckpoint partition for this category and count rows whose durable ResetUtc >= (now - Hours).
    # AAD data-plane (the FA storage account has shared-key DISABLED · same path as Save-XdrCheckpointReset). ADVANCE-
    # IMMUNITY (fixed at source · audit 2026-06-24): Save-XdrCheckpointAtomic now CARRIES the original ResetUtc FORWARD
    # unchanged on every advance (it previously omitted it, so the FIRST advance after a reset ERASED the stamp → this
    # reader false-counted "NO reset" and B10 could FALSE-FAIL on a clean window). A reset therefore stays visible here
    # until it naturally ages past the window. A row carrying ResetUtc='' = no reset has happened (or it aged out). We
    # count a row as reset-in-window iff ResetUtc parses to a DateTime within the window. RowKey may be a composite
    # fanout key ('|').
    if (-not $StorageAccount) { return @{ Available = $false; Count = 0 } }
    $tok = az account get-access-token --resource https://storage.azure.com/ --query accessToken -o tsv 2>$null
    if (-not $tok) { return @{ Available = $false; Count = 0 } }
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * $Hours)
    $pkAddr = [uri]::EscapeDataString($partitionKey)
    # $filter on PartitionKey (server-side); ResetUtc is a free-form string column so we filter the timestamp CLIENT-side
    # (robust to absent/empty/legacy values — a non-parsing ResetUtc is simply not counted). Page through @odata.nextLink.
    $base = "https://$StorageAccount.table.core.windows.net/XdrCheckpoint()?`$filter=PartitionKey%20eq%20'$pkAddr'&`$select=RowKey,ResetUtc"
    $url = $base; $count = 0; $guard = 0
    $hdr = @{ Authorization = "Bearer $tok"; 'x-ms-version' = '2019-02-02'; Accept = 'application/json;odata=nometadata' }
    try {
        while ($url -and $guard -lt 50) {
            $guard++
            $resp = Invoke-WebRequest -Method Get -Uri $url -Headers $hdr -TimeoutSec 60 -ErrorAction Stop
            $body = $resp.Content | ConvertFrom-Json
            foreach ($e in @($body.value)) {
                $rv = [string]$e.ResetUtc
                if ([string]::IsNullOrWhiteSpace($rv)) { continue }
                $dt = [DateTime]::MinValue
                if ([DateTime]::TryParse($rv, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$dt) -and $dt -ge $cutoff) { $count++ }
            }
            # Continuation: x-ms-continuation-NextPartitionKey/RowKey headers (Table service). Re-issue with them.
            $npk = $resp.Headers['x-ms-continuation-NextPartitionKey']
            $nrk = $resp.Headers['x-ms-continuation-NextRowKey']
            if ($npk) {
                $cont = "&NextPartitionKey=$([uri]::EscapeDataString([string]$npk))"
                if ($nrk) { $cont += "&NextRowKey=$([uri]::EscapeDataString([string]$nrk))" }
                $url = $base + $cont
            } else { $url = $null }
        }
        return @{ Available = $true; Count = $count }
    } catch {
        Write-Host "[postdeploy-audit] WARN · checkpoint-row ResetUtc read failed ($($_.Exception.Message)) — falling back to the Checkpoint.Reset telemetry count" -ForegroundColor DarkYellow
        return @{ Available = $false; Count = 0 }
    }
}
function Get-XdrResetCountInWindow {
    param([int]$Hours)
    # PRIMARY · the durable checkpoint-row ResetUtc (telemetry-lag-immune · §4.B FIX-3). A reset is visible the instant
    # it is written to storage, so a reset-in-window is NEVER missed — the artifact-discrimination fires correctly and
    # B9/B10 no longer FALSE-FAIL on reset churn whose Checkpoint.Reset event has not yet landed in AppEvents.
    $rows = Get-XdrResetCountFromCheckpointRows -Hours $Hours
    if ($rows.Available) { return @{ QueryOk = $true; Count = $rows.Count; Source = 'checkpoint-row.ResetUtc' } }
    # FALLBACK · the Checkpoint.Reset telemetry event (only when storage is unreachable: no -StorageAccount / no token).
    # The Checkpoint.Reset event has no Category property, but each op is category-unique. Count resets whose
    # OperationKey also appears in this category's Entry.Poll.Succeeded|Failed set over a WIDE lookback.
    $q = @"
let catOps = AppEvents
  | where TimeGenerated >= ago($([Math]::Max($Hours,48))h)
  | where Name in ('Entry.Poll.Succeeded','Entry.Poll.Failed','Entry.CadenceNotDue.Skipped')
  | where tostring(Properties.WorkspaceTable) == '$workspaceTable' or tostring(Properties.Category) == '$Category'
  | distinct OperationKey = tostring(Properties.OperationKey);
AppEvents
| where TimeGenerated >= ago(${Hours}h)
| where Name == 'Checkpoint.Reset'
| where tostring(Properties.OperationKey) in (catOps) or isempty(tostring(Properties.OperationKey))
| summarize n = count()
"@
    $r = Invoke-XdrAuditKql -Query $q -Label 'reset-count'
    if (-not $r.Success) { return @{ QueryOk = $false; Count = 0; Source = 'telemetry-event(unavailable)' } }
    $row = @($r.Data) | Select-Object -First 1
    $n = if ($row) { ConvertTo-XdrAuditInt (Get-XdrAuditRowValue $row 'n') } else { 0 }
    return @{ QueryOk = $true; Count = $n; Source = 'telemetry-event(fallback)' }
}

# (Get-XdrAuditCount lives in tools/lib/Xdr.PostDeployAudit.ps1 — dot-sourced above — so it is defined before its
# first use at the B5 known-good probe. A script-level function must precede its first call; keeping it in the lib
# next to ConvertTo-XdrAuditInt + Get-XdrAuditRowValue (which it composes) removes the execution-order hazard.)

# ════════════════════════════════════════════════════════════════════════════════════════════════
# B3 · COLD-EMIT discipline — explicit checkpoint reset so SNAPSHOT ops re-emit (unless -SkipReset)
# ════════════════════════════════════════════════════════════════════════════════════════════════
if (-not $SkipReset) {
    if (-not $StorageAccount) {
        Add-Axis 'B3' @{ Verdict = 'INCONCLUSIVE'; Pass = $false; Inconclusive = $true; Detail = 'B3 cold-emit reset requested but no -StorageAccount (and XDRLR_STORAGE_ACCOUNT not in .env.local) — cannot reset; pass -SkipReset to audit the existing window only' }
    } else {
        Write-Host "[postdeploy-audit] B3 · Save-XdrCheckpointReset -Category $Category -Apply (cold-emit · SNAPSHOT re-emit · NEW-and-existing cats both need this)" -ForegroundColor Cyan
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Save-XdrCheckpointReset.ps1') -Portal $Portal -Category $Category -ResourceGroup $ResourceGroup -StorageAccount $StorageAccount -Reason 'operator-override' -Apply | Out-Host
        $rcReset = $LASTEXITCODE
        if ($rcReset -ne 0) {
            Add-Axis 'B3' @{ Verdict = 'FAIL'; Pass = $false; Inconclusive = $false; Detail = "B3 Save-XdrCheckpointReset exited $rcReset — cold-emit not established" }
        } else {
            Add-Axis 'B3' @{ Verdict = 'PASS'; Pass = $true; Inconclusive = $false; Detail = "B3 checkpoint reset applied for $partitionKey — SNAPSHOT ops will re-emit the cold baseline" }
            # Bounded landing wait so B6 / B10 see the cold-emit (NOT a blind sleep): poll the _CL table until rows land.
            $resetSince = (Get-Date).ToUniversalTime().AddSeconds(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $deadline = (Get-Date).AddMinutes($ColdEmitWaitMinutes); $prev = -1; $stable = 0
            Write-Host "[postdeploy-audit] B3 · waiting up to ${ColdEmitWaitMinutes}m for the cold-emit to land in $workspaceTable ..." -ForegroundColor DarkCyan
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 40
                $wq = "$workspaceTable | where TimeGenerated >= datetime('$resetSince') | summarize n = count()"
                $wr = Invoke-XdrAuditKql -Query $wq -Label 'cold-emit-wait'
                $cur = if ($wr.Success -and @($wr.Data).Count) { ConvertTo-XdrAuditInt (Get-XdrAuditRowValue (@($wr.Data)[0]) 'n') } else { -1 }
                if ($cur -gt 0 -and $cur -eq $prev) { $stable++ } else { $stable = 0 }
                Write-Host "[postdeploy-audit] B3 · cold-emit rows=$cur (stable x$stable · cap ${ColdEmitWaitMinutes}m)" -ForegroundColor DarkGray
                if ($cur -gt 0 -and $stable -ge 2) { Write-Host '[postdeploy-audit] B3 · cold-emit landed + settled.' -ForegroundColor Green; break }
                $prev = $cur
            }
        }
    }
} else {
    Add-Axis 'B3' @{ Verdict = 'PASS'; Pass = $true; Inconclusive = $false; Detail = 'B3 skipped (-SkipReset) — auditing the EXISTING steady-state window (B9-B11 will reset-discriminate via Checkpoint.Reset count)' }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# B6 · D-GATES (the automatic core) — composed verifiers (heavier · opt-in -RunDGates)
# ════════════════════════════════════════════════════════════════════════════════════════════════
if ($RunDGates) {
    if (-not $WorkspaceResourceId) {
        Add-Axis 'B6' @{ Verdict = 'INCONCLUSIVE'; Pass = $false; Inconclusive = $true; Detail = 'B6 D-gates requested but no -WorkspaceResourceId for Run-PostDeployVerify' }
    } else {
        Write-Host "[postdeploy-audit] B6 · Run-PostDeployVerify -AllOps -Category $Category (Verify-XdrLiveContent → Verify-DeployedConnector · G1 0-row wire)" -ForegroundColor Cyan
        $pdvArgs = @('-ResourceGroup', $ResourceGroup, '-WorkspaceId', $WorkspaceId, '-WorkspaceResourceId', $WorkspaceResourceId,
                     '-Window', 'Sustain', '-AllOps', '-Category', $Category)
        if ($FunctionApp)      { $pdvArgs += @('-FunctionApp', $FunctionApp) }
        if ($DeployedSinceUtc) { $pdvArgs += @('-DeployedSinceUtc', $DeployedSinceUtc) }
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Run-PostDeployVerify.ps1') @pdvArgs | Out-Host
        $rcD = $LASTEXITCODE
        $v = if ($rcD -eq 0) { 'PASS' } elseif ($rcD -eq 1) { 'INCONCLUSIVE' } else { 'FAIL' }
        Add-Axis 'B6' @{ Verdict = $v; Pass = ($rcD -eq 0); Inconclusive = ($rcD -eq 1); Detail = "B6 Run-PostDeployVerify exit=$rcD (D-gates: MinRows · ExactlyOnce · cadence · DLQ · typed-populated · G1 prove-empty)" }
    }
} else {
    Add-Axis 'B6' @{ Verdict = 'INCONCLUSIVE'; Pass = $false; Inconclusive = $true; Detail = 'B6 D-gates not run this pass (pass -RunDGates to chain Run-PostDeployVerify) — B9-B11 steady-state gates below' }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# B9 · AppTraces error/warning-RATE over the steady-state window
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Genuine-error signals: Entry.Poll.Failed carrying a HARD ErrorClass (cosmetic capability classes EXCLUDED) +
# AppExceptions; normalized per Entry.Poll.Succeeded. Un-recovered hard class = a Breaker.Opened with no later
# Breaker.Closed. All KQL single-quoted; op identity = tostring(Properties.OperationKey); category scoped via the
# WorkspaceTable/Category property the poll events carry.
$catScope = "(tostring(Properties.WorkspaceTable) == '$workspaceTable' or tostring(Properties.Category) == '$Category')"
# Cosmetic ErrorClasses to EXCLUDE (capability-absent posture is recorded as Capability.OpUnavailable, NOT a Failed
# event, but a stale/transient class can still appear — exclude the enumerated transient/capability classes so B9
# classifies by GENUINE hard error, not raw count).
$cosmeticClasses = @('XdrPortalTransientException','XdrCapabilityAbsentException','XdrSingleFlightYield')
$cosmeticList = ($cosmeticClasses | ForEach-Object { "'$_'" }) -join ', '

$b9FailQ = @"
AppEvents
| where TimeGenerated >= ago(${B9WindowHours}h)
| where Name == 'Entry.Poll.Failed'
| where $catScope
| where isnotempty(tostring(Properties.ErrorClass)) and tostring(Properties.ErrorClass) !in ($cosmeticList)
| summarize n = count()
"@
$b9SuccQ = @"
AppEvents
| where TimeGenerated >= ago(${B9WindowHours}h)
| where Name == 'Entry.Poll.Succeeded'
| where $catScope
| summarize n = count()
"@
$b9ExcQ = @"
AppExceptions
| where TimeGenerated >= ago(${B9WindowHours}h)
| summarize n = count()
"@
# un-recovered breaker: Opened ops minus Closed ops in the window (a breaker still OPEN at window end = un-recovered)
$b9BreakerQ = @"
let opened = AppEvents | where TimeGenerated >= ago(${B9WindowHours}h) | where Name == 'Breaker.Opened' | distinct OperationKey = tostring(Properties.OperationKey);
let closed = AppEvents | where TimeGenerated >= ago(${B9WindowHours}h) | where Name == 'Breaker.Closed' | distinct OperationKey = tostring(Properties.OperationKey);
opened | join kind=leftanti closed on OperationKey | summarize n = count()
"@
$rFail    = Invoke-XdrAuditKql -Query $b9FailQ    -Label 'B9-failed'
$rSucc    = Invoke-XdrAuditKql -Query $b9SuccQ    -Label 'B9-succeeded'
$rExc     = Invoke-XdrAuditKql -Query $b9ExcQ     -Label 'B9-exceptions'
$rBreaker = Invoke-XdrAuditKql -Query $b9BreakerQ -Label 'B9-breaker'
$resetB9  = Get-XdrResetCountInWindow -Hours $B9WindowHours
$b9Ok = $queryMechOk -and $rFail.Success -and $rSucc.Success
$b9Failed     = Get-XdrAuditCount -Result $rFail    -Column 'n'
$b9Succeeded  = Get-XdrAuditCount -Result $rSucc    -Column 'n'
$b9Exceptions = Get-XdrAuditCount -Result $rExc     -Column 'n'
$b9Breakers   = Get-XdrAuditCount -Result $rBreaker -Column 'n'
$decB9 = Test-XdrB9_ErrorRate -Failed $b9Failed -Succeeded $b9Succeeded -AppExceptions $b9Exceptions `
    -UnrecoveredBreakers $b9Breakers -ResetsInWindow $resetB9.Count -QueryOk $b9Ok
Add-Axis 'B9' $decB9

# ════════════════════════════════════════════════════════════════════════════════════════════════
# B10 · steady-state dup-accumulation (24h, artifact-discriminated)
# ════════════════════════════════════════════════════════════════════════════════════════════════
# rows / distinct-RecordId in the _CL table (the SNAPSHOT accumulation signal · _CL op column is 'Operation',
# RecordId is the composite NaturalKey content-identity). Outcome ratio from the poll events: skip = CadenceNotDue
# + BoundaryDeduped; total = skip + Succeeded.
$b10RowsQ = @"
$workspaceTable
| where TimeGenerated >= ago(${B10WindowHours}h)
| summarize Rows = count(), Distinct = dcount(RecordId)
"@
$b10SuccQ = @"
AppEvents
| where TimeGenerated >= ago(${B10WindowHours}h)
| where Name == 'Entry.Poll.Succeeded'
| where $catScope
| summarize n = count()
"@
$b10SkipQ = @"
AppEvents
| where TimeGenerated >= ago(${B10WindowHours}h)
| where Name == 'Entry.CadenceNotDue.Skipped'
| where $catScope
| summarize n = count()
"@
$b10DedupQ = @"
AppEvents
| where TimeGenerated >= ago(${B10WindowHours}h)
| where Name == 'Entry.Poll.BoundaryDeduped'
| where $catScope
| summarize n = count()
"@
$rRows  = Invoke-XdrAuditKql -Query $b10RowsQ  -Label 'B10-rows'
$rSucc2 = Invoke-XdrAuditKql -Query $b10SuccQ  -Label 'B10-succeeded'
$rSkip  = Invoke-XdrAuditKql -Query $b10SkipQ  -Label 'B10-skipped'
$rDedup = Invoke-XdrAuditKql -Query $b10DedupQ -Label 'B10-deduped'
$resetB10 = Get-XdrResetCountInWindow -Hours $B10WindowHours
$b10Ok = $queryMechOk -and $rRows.Success
$b10Rows     = Get-XdrAuditCount -Result $rRows  -Column 'Rows'
$b10Distinct = Get-XdrAuditCount -Result $rRows  -Column 'Distinct'
$b10Succ     = Get-XdrAuditCount -Result $rSucc2 -Column 'n'
$b10Skip     = Get-XdrAuditCount -Result $rSkip  -Column 'n'
$b10Dedup    = Get-XdrAuditCount -Result $rDedup -Column 'n'
$decB10 = Test-XdrB10_DupAccumulation -Rows $b10Rows -DistinctRecordId $b10Distinct `
    -Succeeded $b10Succ -Skipped $b10Skip -BoundaryDeduped $b10Dedup -ResetsInWindow $resetB10.Count -QueryOk $b10Ok
Add-Axis 'B10' $decB10

# ════════════════════════════════════════════════════════════════════════════════════════════════
# B11 · fail-open detection (Entry.FailOpen sustained + un-recovered breaker)
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Entry.FailOpen is the operator's promotion of the silent Write-Warning fail-open sites. EventPresent = ANY such
# event exists anywhere (proves the wiring). SUSTAINED = same OperationKey across >=2 distinct CorrelationIds in
# the window. A single transient = advisory. If the event isn't emitted yet → INCONCLUSIVE (never a false pass),
# but an un-recovered breaker still FAILS.
$b11PresentQ = "AppEvents | where Name == 'Entry.FailOpen' | summarize n = count()"
$b11SustainedQ = @"
AppEvents
| where TimeGenerated >= ago(${B11WindowHours}h)
| where Name == 'Entry.FailOpen'
| where $catScope
| summarize cids = dcount(tostring(Properties.CorrelationId)) by op = tostring(Properties.OperationKey)
| where cids >= 2
| summarize n = count()
"@
$b11TransientQ = @"
AppEvents
| where TimeGenerated >= ago(${B11WindowHours}h)
| where Name == 'Entry.FailOpen'
| where $catScope
| summarize cids = dcount(tostring(Properties.CorrelationId)) by op = tostring(Properties.OperationKey)
| where cids == 1
| summarize n = count()
"@
$b11BreakerQ = @"
let opened = AppEvents | where TimeGenerated >= ago(${B11WindowHours}h) | where Name == 'Breaker.Opened' | distinct OperationKey = tostring(Properties.OperationKey);
let closed = AppEvents | where TimeGenerated >= ago(${B11WindowHours}h) | where Name == 'Breaker.Closed' | distinct OperationKey = tostring(Properties.OperationKey);
opened | join kind=leftanti closed on OperationKey | summarize n = count()
"@
$rPresent   = Invoke-XdrAuditKql -Query $b11PresentQ   -Label 'B11-present'
$rSustained = Invoke-XdrAuditKql -Query $b11SustainedQ -Label 'B11-sustained'
$rTransient = Invoke-XdrAuditKql -Query $b11TransientQ -Label 'B11-transient'
$rBreaker11 = Invoke-XdrAuditKql -Query $b11BreakerQ   -Label 'B11-breaker'
$eventPresent = ((Get-XdrAuditCount -Result $rPresent -Column 'n') -gt 0)
# QueryOk for B11 requires the present-probe AND the breaker-probe to have executed (the two always-evaluable inputs).
$b11Ok = $queryMechOk -and $rPresent.Success -and $rBreaker11.Success
$b11Sustained = Get-XdrAuditCount -Result $rSustained -Column 'n'
$b11Transient = Get-XdrAuditCount -Result $rTransient -Column 'n'
$b11Breakers  = Get-XdrAuditCount -Result $rBreaker11 -Column 'n'
$decB11 = Test-XdrB11_FailOpen -EventPresent $eventPresent -SustainedCount $b11Sustained `
    -TransientCount $b11Transient -UnrecoveredBreakers $b11Breakers -QueryOk $b11Ok
Add-Axis 'B11' $decB11

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Summary + exit (0 all-pass · 2 any-fail · 1 inconclusive-but-no-fail)
# ════════════════════════════════════════════════════════════════════════════════════════════════
$failCount = @($axes.Values | Where-Object { $_.Verdict -eq 'FAIL' }).Count
$incCount  = @($axes.Values | Where-Object { $_.Verdict -eq 'INCONCLUSIVE' }).Count
$passCount = @($axes.Values | Where-Object { $_.Verdict -eq 'PASS' }).Count
$summary = "[postdeploy-audit] $Category · PASS=$passCount INCONCLUSIVE=$incCount FAIL=$failCount of $($axes.Count) axes (B3/B6/B9/B10/B11)"
Write-Host ''
if ($failCount -gt 0) {
    Write-Host "$summary → FAIL" -ForegroundColor Red
    exit 2
}
if ($incCount -gt 0) {
    Write-Host "$summary → INCONCLUSIVE (no FAIL · some axes un-evaluable — never a silent green · exit 1)" -ForegroundColor Yellow
    exit 1
}
Write-Host "$summary → ALL PASS" -ForegroundColor Green
exit 0
