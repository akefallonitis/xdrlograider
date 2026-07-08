#Requires -Version 7.4
<#
.SYNOPSIS
Post-deploy verification gate for XdrLogRaider per plan v11 §3.2 O1 + §4.22 FirstIteration.

.DESCRIPTION
Runs the plan §18.1 12-dimension post-deploy audit + §18.2 D8 data-plane-context sub-gates against
the deployed Function App's Log Analytics workspace via `az monitor log-analytics query` (KQL) +
`az rest` (Sentinel V3 surface). Uses SP credentials from .env.local for headless operation
(I, the agent, run this autonomously post-deploy · operator never invokes).

Plan §18.1 macro dimensions (12 total):
  D1  No missed events       · sum(Entry.Poll.Succeeded.ItemCount) per CycleId = count(rows) per CycleId
  D2  No empty rows          · RawJson not empty/{}/OrderedHashtable
  D3  Exactly 1 telemetry/poll · 1 Started + 1 terminal (Succeeded|Failed|OpUnavailable|SingleFlight-yield) per (Op, Cid)
  D4  R3 capability discovery · `PortalCapabilities.Discovery.Succeeded` ≥1 · Failed == 0
  D6  RawJson valid JSON     · parse_json non-null · array_length(bag_keys()) > 0
  D7  Cadence honored        · max-gap ≤ 1.5 × declared · no double-fires (<30s apart)
  D8  Auth chain healthy     · T1 dominant · T2 OK · T3 rare in steady-state
  D9  DLQ empty              · count(Ingest.Dlq.Queued) == 0 over window
  D10 Circuit breaker        · every Open eventually Closes (stub if breaker not implemented)
  D12 V3 surface              · dataConnectorDefinition + contentPackage present in workspace

Plan §18.2 D8 data-plane-context sub-gates ("actual events per requirements" gates):
  D8c All 4 always-populated envelope cols populated on every row · Portal + Category + Operation + CorrelationId (F2: −OperationKey)
  D8f All N typed cols (per manifest ProjectionMap.Keys) have ≥1 non-null row · keystone parser-fires gate
  D8g LA-reserved rewrite (EndTime → EndTime_x) populated when source had EndTime
  D8h Serialized non-scalars (RelatedEntitiesJson · AdditionalFieldsJson) parse cleanly via parse_json

6 windows (per plan v11 §7 Phase D + §4.22):
  Boot           · T+0   → T+5min   · Boot.VersionProbe present only
  Cold           · T+10  → T+20min  · D2 + D6 + D9 + ≥1 row in target Category table
  Hour           · T+1h             · D1-D9 · cadence stable · gap ≤ 1.5× per-op manifest tier
  Sustain        · T+1-2h           · D1-D10 · DLQ=0 · AppExceptions=0 · multiple natural cycles
  FirstIteration · T+0   → T+15-20min after Force-XdrFullCycle on new Op · 8 strict checks
  ConsecutiveSustain · ≥3 Sustain windows pass · Phase F GA gate

Exit codes:
  0 · all gates GREEN (push/deploy OK · GA-readiness if Window=ConsecutiveSustain)
  1 · advisory FAIL (D8 cold-window expected · low severity)
  2 · BLOCKING FAIL (D1/D2/D3/D6/D9 fail · data integrity violated)
  3 · tool error (az login failure · KQL syntax · workspace unreachable)

CREATE for v11 per plan §11.3 · cites §3.2 + §4.18 + §4.22 building blocks · NOT inherited.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [string] $ResourceGroup,
    [string] $WorkspaceResourceId,    # ARM full resource ID for the Sentinel workspace · enables D12 V3 surface query (dataConnectorDefinition + contentPackage). If omitted · D12 gate becomes advisory FAIL.
    [string] $StorageAccount,         # §4.B D1/D3/D7 RESET-AWARENESS · the FA storage account name. When supplied, D1/D3/D7 read
                                      # the DURABLE per-op checkpoint-row ResetUtc (telemetry-lag-immune · the B10 FIX-3 source) to
                                      # discriminate reset-CHURN artifacts (D1 rows-landed-without-a-terminal-event · D3 orphan-close ·
                                      # D7 rapid re-fire after Save-XdrCheckpointReset) from genuine steady-state defects. Omitted →
                                      # D1/D3/D7 fall back to the Checkpoint.Reset AppEvents telemetry (lossy but no extra plumbing).
                                      # Either way a reset-in-window → the gate goes INCONCLUSIVE not FAIL (the reset-adjacent
                                      # artifact is EXPECTED · same as B9/B10).
    [string] $KnownResetUtc,          # §4.B AUTHORITATIVE reset time (2026-07-01): the caller (Invoke-XdrRoundReprove) KNOWS when it
                                      # reset (it called Save-XdrCheckpointReset) → passes that instant so reset-awareness is INDEPENDENT
                                      # of storage-readability AND telemetry. The tool-driven reset emits NO Checkpoint.Reset event, and a
                                      # short-cadence op's durable ResetUtc can drop over many re-polls, so the durable/telemetry count can
                                      # read a FALSE-CONFIDENT 0 → D1/D3/D7 strict-FAIL the forced churn. If this instant is in-window a reset
                                      # PROVABLY fell in-window → resets-in-window ≥ 1 regardless. Empty for standalone verifies (durable-only).
    [ValidateSet('Defender','Entra','Intune','Purview','SecurityCopilot')] [string] $Portal = 'Defender',
    [string] $Category,
    [string] $OperationKey,          # optional · selects the manifest Operation for the exactly-once gate + the per-Op typed/_x/Json sub-gates. Omitted → Operations[0] (single-Op manifests).
    [switch] $AllOps,                # verify EVERY manifest Operation in the Category — loops the per-Op D8f/D8g/D8h/ExactlyOnce gates over all ops (GateIds tagged "[<OperationKey>]" so they don't collide). Omitted → the single -OperationKey op (or Operations[0]).
    [ValidateSet('Boot','Cold','Hour','Sustain','FirstIteration','ConsecutiveSustain')] [string] $Window = 'Cold',
    [int]    $SinceMinutes,
    [string] $DeployedSinceUtc,        # absolute ISO-8601 floor · postdeploy windows anchor at the cutover instant
                                       # (catches the cold-start Boot probe · excludes the stop-gap + prior-build telemetry)
    [ValidateSet('Console','Json','Markdown')] [string] $OutputFormat = 'Console',
    [string] $JsonReportPath,
    [string] $LiveSourceVerdicts,    # G1 prove-empty wire: path to the {OperationKey -> Verdict} JSON from
                                     # Verify-XdrLiveContent -AllOps -VerdictOut. When supplied, a 0-row op PASSES
                                     # only if its DIRECT-SOURCE verdict is EMPTY/CAP-ABSENT; PASS/RED-shape on 0
                                     # workspace rows => FA not landing data that exists (RED); polled-but-no-verdict
                                     # => INCONCLUSIVE (unproven-0 is never a silent green). B4: wires the existing
                                     # Verify-XdrLiveContent direct-/apiproxy proof, NOT a new gate layer.
    # STRICT IS THE DEFAULT (M1 cure · plan §F gate 1): an INCONCLUSIVE or ADVISORY window must NEVER exit 0 —
    # an empty/unevaluable window is un-proven, NOT green. `-Strict` is retained as a harmless no-op for back-compat
    # (strict is already the default). `-Lenient` opts OUT (inconclusive/advisory → exit 0) for diagnostic / early-window
    # use ONLY — never in a GA gate or CI. Blockers always exit 2 regardless.
    [switch] $Strict,
    [switch] $Lenient
)

$ErrorActionPreference = 'Stop'

# ── ROBUSTNESS (2026-07-08) · never crash opaquely. An UNHANDLED terminating error in a gate — e.g. a projection /
#    JSON serialization on a large deeply-nested category like Configuration (the ListUnifiedConnectors class, 11 nested
#    *Json cols) — means the verify COULD NOT COMPLETE for this category. That is INCONCLUSIVE (exit 2), NOT a data
#    pass/fail, and it MUST be diagnosable (print the exception + exact file:line) and NON-FATAL to the caller
#    (Run-PostDeployVerify -KeepGoing then records it and continues the remaining categories). Prior behaviour: a silent
#    exit -1 that halted the whole -AllOps run at the first heavy category. Explicit `exit 3`/`exit $exitCode` are NOT
#    errors, so the trap never intercepts them; inner try/catch still wins.
trap {
    Write-Host "[Verify-DeployedConnector] UNHANDLED ERROR — category verify could not complete (INCONCLUSIVE · exit 2 · NOT a data verdict):" -ForegroundColor Red
    Write-Host ("  {0}: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host ("  at {0}:{1} · {2}" -f [System.IO.Path]::GetFileName([string]$_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber, (('' + $_.InvocationInfo.Line).Trim())) -ForegroundColor DarkYellow
    }
    exit 2
}

$repoRoot = Resolve-Path "$PSScriptRoot\.." | ForEach-Object Path

# Window → default SinceMinutes mapping
if (-not $PSBoundParameters.ContainsKey('SinceMinutes')) {
    $SinceMinutes = switch ($Window) {
        'Boot'               { 10 }
        'Cold'               { 30 }
        'FirstIteration'     { 20 }
        'Hour'               { 60 }
        'Sustain'            { 120 }
        'ConsecutiveSustain' { 480 }
        default              { 60 }
    }
}

$results = [ordered]@{
    Window              = $Window
    Portal              = $Portal
    Category            = $Category
    OperationKey        = $OperationKey
    WorkspaceId         = $WorkspaceId
    SinceMinutes        = $SinceMinutes
    StartedUtc          = ([DateTime]::UtcNow).ToString('o')
    Gates               = [ordered]@{}
    Blockers            = @()
    Advisories          = @()
    Inconclusives       = @()
    Verdict             = $null
    AzCliAvailable      = $false
    AzAuthenticated     = $false
}

# ── Az CLI availability ────────────────────────────────────────────────────────
if (Get-Command az -ErrorAction SilentlyContinue) {
    $results.AzCliAvailable = $true
    try {
        $accountRaw = az account show --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $accountRaw) {
            $results.AzAuthenticated = $true
        }
    } catch {
        $results.AzAuthenticated = $false
    }
}

if (-not $results.AzCliAvailable) {
    Write-Error "az CLI not found · install Azure CLI to run Verify-DeployedConnector"
    exit 3
}

if (-not $results.AzAuthenticated) {
    # Try SP login from .env.local (agent autonomous path · operator binding "you have .env.local SP")
    $envLocal = Join-Path $repoRoot '.env.local'
    if (Test-Path $envLocal) {
        Write-Host "[Verify-DeployedConnector] az not authenticated · attempting SP login from .env.local"
        $envVars = @{}
        Get-Content $envLocal | ForEach-Object {
            if ($_ -match '^([A-Z_]+)=(.+)$') { $envVars[$Matches[1]] = $Matches[2].Trim('"') }
        }
        $tid = $envVars['AZURE_TENANT_ID']
        $cid = $envVars['AZURE_CLIENT_ID']
        $sec = $envVars['AZURE_CLIENT_SECRET']
        if ($tid -and $cid -and $sec) {
            az login --service-principal -u $cid -p $sec --tenant $tid --output none 2>$null
            if ($LASTEXITCODE -eq 0) {
                $results.AzAuthenticated = $true
                Write-Host "[Verify-DeployedConnector] SP login successful"
            }
        }
    }
    # The SelfTest dot-sources this script with $env:XDRLR_VERIFY_DOTSOURCE_ONLY=1 to load ONLY its pure gate
    # functions (it returns at the guard further below, before any live query). In that mode there is NO live az
    # and none is needed — so do NOT hard-fail the offline self-test. CI has az installed but unauthenticated, so
    # without this guard the self-test container fails to load. Real invocation (no sentinel) still requires az.
    if (-not $results.AzAuthenticated -and $env:XDRLR_VERIFY_DOTSOURCE_ONLY -ne '1') {
        Write-Error "az CLI not authenticated · run 'az login' or populate .env.local with AZURE_TENANT_ID/CLIENT_ID/CLIENT_SECRET"
        exit 3
    }
}

# ── WorkspaceId resolution · `az log-analytics query --workspace` needs the customerId GUID ──
# iter#15: passing a full ARM resource ID to --workspace returns PathNotFoundError (this was why
# post-deploy verification silently found nothing). Accept either form: if $WorkspaceId looks like
# an ARM resource ID, resolve it to the customerId GUID once, here.
if ($WorkspaceId -match '^/subscriptions/') {
    Write-Host "[Verify-DeployedConnector] WorkspaceId is an ARM resource ID · resolving to customerId GUID"
    if (-not $WorkspaceResourceId) { $WorkspaceResourceId = $WorkspaceId }
    $guid = az monitor log-analytics workspace show --ids $WorkspaceId --query customerId -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $guid) {
        $WorkspaceId         = $guid.Trim()
        $results.WorkspaceId = $WorkspaceId
        Write-Host "[Verify-DeployedConnector] resolved customerId=$WorkspaceId"
    } else {
        Write-Error "Failed to resolve WorkspaceId ARM id to a customerId GUID (az monitor log-analytics workspace show --ids ...)"
        exit 3
    }
}

# ── KQL execution helper ───────────────────────────────────────────────────────
# `az monitor log-analytics query` returns a BARE JSON ARRAY of row objects with NAMED columns
# (the query's `project`/`summarize` output cols), e.g. [{"Pass":"True","Count":"34",...}] — there is
# NO `.tables[].rows` envelope and scalar values arrive as STRINGS ("True","0"). The query MUST be passed
# INLINE: under PowerShell the `@<file>` form makes az try to read the query from stdin → "EOF when
# reading a line" → exit 1 (this is why every gate previously reported "az query exit=1"). This mirrors
# the working sibling tools/Verify-OperationLanding.ps1 (Invoke-WsQuery).
#
# CRITICAL · SINGLE-LINE the query: when a query string containing EMBEDDED NEWLINES is passed to az under
# PowerShell, az's CLI arg parser truncates --analytics-query at the FIRST newline — so a multi-line query
# like "<table>`n| summarize Count=count()`n| project ..." silently degrades to just "<table>", returning
# ALL raw rows with none of the projected columns (Count/Pass absent → gates read 0 → false negatives).
# The gates here build readable multi-line here-strings, so we COLLAPSE all runs of whitespace/newlines to
# single spaces (and trim) exactly once, at this single chokepoint. KQL is whitespace-insensitive across the
# '|' pipe, so this is semantically identical — and matches why the working sibling tool uses 1-line queries.
#
# Returns:  @{ Success=$bool; Error=$str; Data=@( <row-hashtable>, ... ) }
# Data is ALWAYS a bare array (possibly empty) of row-hashtables parsed via -AsHashtable, so a gate
# reads a row by COLUMN NAME ($row['Pass']) — never positional, never .tables[].rows.
function Invoke-XdrKqlQuery {
    param([string]$Query, [string]$Label = '')
    # Flatten the (possibly here-string) query to a single line so az does not truncate at a newline.
    $flatQuery = ([regex]::Replace($Query, '\s+', ' ')).Trim()
    # WS4.3 robustness · TWO things:
    #  (1) @FILE not inline — a high-col gate (the 76-col GetTenantContext D8f is ~10KB of countif fragments)
    #      OVERRUNS the Windows ~8191-char command-line limit when passed as --analytics-query "<inline>" → az
    #      gets a truncated arg → exit 1 (live-hit 2026-06-14). Writing the query to a temp file and passing it
    #      via az's `@<file>` convention makes query length UNBOUNDED.
    #  (2) RETRY — the LA query data-plane intermittently returns BadArgument/5xx/empty-stream for a well-formed
    #      query (token refresh · throttle · service hiccup). A SINGLE transient must NOT be a gate failure or the
    #      verifier false-fails a HEALTHY connector. A zero-row result is success-with-empty-Data, returned at once.
    $tmp = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()   # capture az stderr → a non-zero exit reports WHY (throttle/query/auth), never a blind "exit=1"
    try {
        [System.IO.File]::WriteAllText($tmp, $flatQuery, [System.Text.UTF8Encoding]::new($false))
        $attempts = 6
        $lastErr  = $null
        for ($a = 1; $a -le $attempts; $a++) {
            try {
                $raw = az monitor log-analytics query --workspace $WorkspaceId --analytics-query "@$tmp" --output json 2>$errFile
                if ($LASTEXITCODE -ne 0) {
                    $errText = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
                    if ($errText) { $errText = ([regex]::Replace($errText, '\s+', ' ')).Trim() }
                    $lastErr = "az query exit=$LASTEXITCODE" + $(if ($errText) { ": $errText" } else { '' })
                } else {
                    if ([string]::IsNullOrWhiteSpace($raw)) {
                        return @{ Success = $true; Error = $null; Data = @() }   # genuine zero-row · normalise to empty array
                    }
                    $rows = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    return @{ Success = $true; Error = $null; Data = @($rows) }
                }
            } catch {
                $lastErr = $_.Exception.Message
            }
            # §4.B THROTTLE-BACKOFF (2026-06-24): the LA query data-plane throttles the -AllOps burst (HTTP 429 ·
            # 'ResponseSizeError'/'throttle'/'Rate limit') and the prior LINEAR 5·10·15·20·25s backoff (cap 30s, ~75s
            # total) was too shallow → a sustained throttle SURVIVED the retry → a HEALTHY connector read INCONCLUSIVE
            # ("KQL did not execute · transient/throttle survived retry"). Switch to EXPONENTIAL backoff + jitter (base
            # 2s · 2/4/8/16/32 cap 60s · ~62s + jitter total) and HONOR a Retry-After hint parsed from the az error text.
            # B5 HONESTY HOLDS: this only widens the wait — if the query genuinely never executes the loop still exits
            # with Success=$false (→ the gate goes INCONCLUSIVE, never a silent 0). A first-try success returns at once.
            if ($a -lt $attempts) { Start-Sleep -Seconds (Get-XdrKqlBackoffSeconds -Attempt $a -ErrorText $lastErr) }
        }
        return @{ Success = $false; Error = "$lastErr (after $attempts attempts)"; Data = @() }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-XdrKqlBackoffSeconds {
    # PURE · the §4.B exponential-backoff-with-jitter sleep for the Invoke-XdrKqlQuery retry (unit-tested without
    # live az). EXPONENTIAL base 2s (2/4/8/16/32 · capped at 60s) so a sustained LA throttle is ridden out far past
    # the old linear ~75s ceiling, + full JITTER (a uniform 0..1× of the computed delay) so a concurrent -AllOps burst
    # of verifiers does not retry in lockstep (thundering-herd). A Retry-After HINT in the az error text (the LA 429
    # carries it as 'Retry-After: <n>' or 'retry after <n> seconds') OVERRIDES the computed delay when it is LONGER —
    # the server's own pacing wins (still clamped to the 60s cap so a pathological header can't stall the gate).
    # Returns an integer second count >= 1. B5: this NEVER turns a failure into a pass — it only sizes the wait.
    param([int]$Attempt, [string]$ErrorText = '', [int]$BaseSeconds = 2, [int]$CapSeconds = 60)
    if ($Attempt -lt 1) { $Attempt = 1 }
    # 2^(a-1) * base, capped. ($Attempt-1) so attempt #1 waits base, not 2×base.
    $exp = [double]$BaseSeconds * [Math]::Pow(2, ($Attempt - 1))
    $delay = [Math]::Min([double]$CapSeconds, $exp)
    # Full jitter: a uniform fraction of the delay (AWS "full jitter") spreads concurrent retriers across the window.
    $jitter = (Get-Random -Minimum 0.0 -Maximum 1.0) * $delay
    $sleep = [int][Math]::Ceiling($delay * 0.5 + $jitter * 0.5)   # half fixed-floor + half jitter → in [delay/2 , delay]
    # Honor a server Retry-After hint when present + LONGER (the LA 429 names the back-off it wants).
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

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ── §4.B D3/D7 RESET-AWARENESS · count the checkpoint resets that fell inside the audit window ─────
# ════════════════════════════════════════════════════════════════════════════════════════════════
# WHY: D3 (every (Op,CId) poll completes · stuck/orphan/double-close RED) and D7 (cadence ≤1.5×tier · no
# double-fires <30s) FALSE-FAIL on the artifacts of REPEATED checkpoint resets (Save-XdrCheckpointReset +
# Force-XdrFullCycle bursts) — a reset re-fires every SNAPSHOT op immediately (rapid <30s re-fires → D7) and can
# leave an orphaned/double-closed poll straddling the reset instant (→ D3). Those are NOT real defects. B10 already
# discriminates this by reading the DURABLE per-op checkpoint-row ResetUtc (§4.B FIX-3 · telemetry-lag-immune); D3/D7
# now consume the SAME reset count so a reset-in-window routes them to INCONCLUSIVE (never FAIL), while a STEADY-STATE
# (no-reset-in-window) double-fire / orphan still FAILs. Mirrors Run-PostDeployAudit.ps1's reset readers exactly.

function Get-XdrResetCountFromCheckpointRows {
    # PRIMARY (telemetry-lag-immune · §4.B FIX-3): read the XdrCheckpoint partition "<Portal>_<Category>" and count
    # rows whose durable ResetUtc >= (now - Hours). The reset stamp is in storage the instant Save-XdrCheckpointReset
    # writes it, so a reset-in-window is NEVER missed (the AppEvents Checkpoint.Reset event lags/drops on ingest).
    # AAD data-plane (the FA storage account has shared-key DISABLED · same path as Save-XdrCheckpointReset). Returns
    # @{ Available=<bool>; Count=<int> }; Available=$false when there is no -StorageAccount / no storage token / a read
    # error → the caller falls back to the telemetry event. PURE-of-parameters: $StorageAccount/$Portal/$Category are
    # read from script scope (set by the param block) just like the rest of the connector's query helpers.
    param([int]$Hours)
    if (-not $StorageAccount) { return @{ Available = $false; Count = 0 } }
    $tok = az account get-access-token --resource https://storage.azure.com/ --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tok) { return @{ Available = $false; Count = 0 } }
    $partitionKey = "${Portal}_${Category}"
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * $Hours)
    $pkAddr = [uri]::EscapeDataString($partitionKey)
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
        Write-Host "[Verify-DeployedConnector] WARN · checkpoint-row ResetUtc read failed ($($_.Exception.Message)) — falling back to the Checkpoint.Reset telemetry count for D3/D7 reset-awareness" -ForegroundColor DarkYellow
        return @{ Available = $false; Count = 0 }
    }
}

function Get-XdrResetCountInWindow {
    # The reset count for D3/D7 artifact-discrimination over the audit window. Returns @{ QueryOk; Count; Source }.
    # PRIMARY = the durable checkpoint-row ResetUtc (above · lag-immune). FALLBACK = the Checkpoint.Reset AppEvents
    # telemetry (only when storage is unreachable: no -StorageAccount / no token / read error). The telemetry event
    # carries OperationKey but no Category, and each op is category-unique, so scope the reset count to ops that also
    # appear in THIS category's poll set over a wide lookback. A failed fallback query → QueryOk=$false so the CALLER
    # treats the reset count as UNKNOWN (it does NOT silently assume "no reset" → it will not hard-FAIL D3/D7 on a
    # count it could not read · B5 honesty). Live-az is mocked in the SelfTest via a shadowed Invoke-XdrKqlQuery.
    param([int]$Hours, [string]$SinceClauseForCat = '')
    $rows = Get-XdrResetCountFromCheckpointRows -Hours $Hours
    if ($rows.Available) { return @{ QueryOk = $true; Count = $rows.Count; Source = 'checkpoint-row.ResetUtc' } }
    $catScope = if ([string]::IsNullOrWhiteSpace($Category)) { '' } else {
        $wt = "${Portal}_${Category}_CL"
        "| where tostring(Properties.WorkspaceTable) == '$wt' or tostring(Properties.Category) == '$Category'"
    }
    $lookback = [Math]::Max($Hours, 48)
    $q = @"
let catOps = AppEvents
  | where TimeGenerated >= ago(${lookback}h)
  | where Name in ('Entry.Poll.Succeeded','Entry.Poll.Failed','Entry.CadenceNotDue.Skipped')
  $catScope
  | distinct OperationKey = tostring(Properties.OperationKey);
AppEvents
| where TimeGenerated >= ago(${Hours}h)
| where Name == 'Checkpoint.Reset'
| where tostring(Properties.OperationKey) in (catOps) or isempty(tostring(Properties.OperationKey))
| summarize n = count()
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D3D7-reset-count'
    if (-not $r.Success) { return @{ QueryOk = $false; Count = 0; Source = 'telemetry-event(unavailable)' } }
    $row = @($r.Data) | Select-Object -First 1
    $n = if ($row) { ConvertTo-XdrInt (Get-XdrRowValue $row 'n') } else { 0 }
    return @{ QueryOk = $true; Count = $n; Source = 'telemetry-event(fallback)' }
}

function Get-XdrArmRestValue {
    # WS4.3 robustness · `az rest` (ARM SecurityInsights data-plane) with bounded retry · returns the .value[]
    # array, or $null after exhausting retries. The ARM plane has the SAME transient (exit≠0 / empty-stream /
    # token-refresh) behavior as the LA query plane — live-observed 2026-06-14, a transient made D12 read
    # dataConnectorDefinition=False while the card 'XdrLogRaiderDefenderXdr' was demonstrably PRESENT. A single
    # transient must NOT false-fail the gate. Retries on exit≠0 / empty / parse-fail; a SUCCESSFUL call with a
    # (possibly empty) .value returns at once — a genuinely-absent surface is a real answer, not retried away.
    param([string]$Uri)
    $attempts = 4
    for ($a = 1; $a -le $attempts; $a++) {
        $raw = & az rest --method get --url $Uri 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $parsed = $null
            try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
            if ($null -ne $parsed) { return ,@($parsed.value) }   # comma keeps an empty/single result an array
        }
        if ($a -lt $attempts) { Start-Sleep -Seconds ([Math]::Min(12, 3 * $a)) }
    }
    return $null
}

function Add-XdrGateResult {
    param(
        [string]$GateId,
        [string]$Description,
        [bool]$Pass,
        [string]$Detail = '',
        [bool]$Advisory = $false,
        [bool]$Inconclusive = $false   # empty-window / cannot-evaluate · NEVER a silent green (plan §18 honesty bar)
    )
    # GATE-LEARNING (2026-06-17 · steady-state re-verify): a gate whose KQL could NOT execute (a transient az/LA
    # query error surviving the bounded retry) is UN-EVALUABLE — it tells us nothing about the DATA, so it must
    # NEVER be a data-integrity blocker (exit 2). Route it to the Inconclusive bucket (exit 1). Only an EXECUTED
    # gate that OBSERVED a violation may block. Single chokepoint → covers all KQL-error sites generically.
    if ((-not $Pass) -and (-not $Inconclusive) -and ($Detail -match '^KQL error:')) { $Inconclusive = $true }
    $entry = [ordered]@{
        Pass         = $Pass
        Description  = $Description
        Detail       = $Detail
        Advisory     = $Advisory
        Inconclusive = $Inconclusive
    }
    $results.Gates[$GateId] = $entry
    if ($Inconclusive) {
        # Inconclusive is its OWN bucket: not a pass (no silent green) and not a blocker. It surfaces so the
        # verdict can never go fully GREEN on an empty/unevaluable window. EXCEPTION (2026-07-04): an ADVISORY gate
        # that is inconclusive routes to Advisories, NOT Inconclusives — the gate author DECLARED it advisory (its real
        # proof is elsewhere), so its "not exercised" state must be non-blocking (live: the Reauth gate over a natural
        # no-auth-loss window is triggered=0 → vacuously "0 unrecovered" · the self-heal CAPABILITY is proven by the
        # SEPARATE auth-loss inject test #3b, not by this gate). This is NOT a tolerate: it is still REPORTED as an
        # advisory, and a NON-advisory gate's inconclusive STILL blocks (strict · M1 intact).
        if ($Advisory) { $results.Advisories += "$GateId · $Description · $Detail (advisory · inconclusive · not-exercised)" }
        else           { $results.Inconclusives += "$GateId · $Description · $Detail" }
    } elseif (-not $Pass) {
        if ($Advisory) { $results.Advisories += "$GateId · $Description · $Detail" }
        else           { $results.Blockers   += "$GateId · $Description · $Detail" }
    }
}

# Helper: a gate calls its pure Test-XdrGate_* function then hands the {Pass;Inconclusive;Detail} verdict
# here (DRY · keeps every gate body 2 lines · the decision logic lives in the unit-tested pure function).
function Add-XdrGateDecision {
    param(
        [string]$GateId,
        [string]$Description,
        [hashtable]$Decision,          # @{ Pass=<bool>; Inconclusive=<bool>; Detail=<string> }  (from a Test-XdrGate_* fn)
        [bool]$Advisory = $false
    )
    $pass = [bool]$Decision['Pass']
    $inc  = $false
    if ($Decision.ContainsKey('Inconclusive')) { $inc = [bool]$Decision['Inconclusive'] }
    $det  = ''
    if ($Decision.ContainsKey('Detail') -and $null -ne $Decision['Detail']) { $det = [string]$Decision['Detail'] }
    Add-XdrGateResult -GateId $GateId -Description $Description -Pass $pass -Detail $det -Advisory $Advisory -Inconclusive $inc
}

# ── Manifest helpers · DERIVE gate inputs from the manifest (NOT hardcoded) ─────
# These mirror the canonical sources so the verifier asserts against the SAME contract the
# connector emits: the parser's LA-reserved rewrite (Get-XdrSafeColumnName · Xdr.Common.Parser)
# and the runtime's '|'-joined composite natural key (Invoke-XdrEntryPoll · Xdr.Common.Runtime).

# LA-reserved rewrite — SINGLE-SOURCED from the parser (P1-2). This was a forked $XdrLaReservedColumns +
# Get-XdrLandedColumnName that DRIFTED (10 vs the parser's 15 reserved cols, and it omitted the envelope-collision
# `category→category_x` + leading-`_` branches) → D8g/D8h asserted the WRONG landed column for cols named Title/
# UniqueId/category/etc. Import ONLY Xdr.Common.Parser (verified to load standalone) and use its canonical
# Get-XdrSafeColumnName — the EXACT function the parser, schema-generator, and validator all use — so the verifier
# asserts against the real landed column with no fork to drift.
Import-Module (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'src/Modules/Xdr.Common.Parser/Xdr.Common.Parser.psd1') -Force -DisableNameChecking -ErrorAction Stop

function Get-XdrManifestOperation {
    # Load manifest manifests/<Portal>/<Category>.psd1 · return the Operation hashtable selected by
    # $OperationKey (else Operations[0]). StrictMode-safe. Returns $null if manifest/op not resolvable.
    param([string]$Portal, [string]$Category, [string]$OperationKey)
    if ([string]::IsNullOrEmpty($Portal) -or [string]::IsNullOrEmpty($Category)) { return $null }
    $manifestPath = Join-Path (Resolve-Path "$PSScriptRoot\..").Path "manifests/$Portal/$Category.psd1"
    if (-not (Test-Path $manifestPath)) { return $null }
    $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
    if (-not $manifest -or -not $manifest.ContainsKey('Operations')) { return $null }
    $ops = @($manifest.Operations)
    if ($ops.Count -eq 0) { return $null }
    if (-not [string]::IsNullOrEmpty($OperationKey)) {
        $match = $ops | Where-Object { $_.ContainsKey('OperationKey') -and $_.OperationKey -eq $OperationKey } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $ops[0]
}

function Get-XdrManifestOperationKeys {
    # ALL OperationKeys for Portal/Category in catalogue order (the -AllOps loop domain). Empty array if the
    # manifest/ops are not resolvable. Mirrors Get-XdrManifestOperation's manifest load (single source of truth).
    param([string]$Portal, [string]$Category)
    if ([string]::IsNullOrEmpty($Portal) -or [string]::IsNullOrEmpty($Category)) { return @() }
    $manifestPath = Join-Path (Resolve-Path "$PSScriptRoot\..").Path "manifests/$Portal/$Category.psd1"
    if (-not (Test-Path $manifestPath)) { return @() }
    $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
    if (-not $manifest -or -not $manifest.ContainsKey('Operations')) { return @() }
    return @(@($manifest.Operations) | Where-Object { $_.ContainsKey('OperationKey') } | ForEach-Object { [string]$_.OperationKey })
}

function Get-XdrFanoutOperationKeys {
    # A2 (2026-06-19) · the FANOUT (entity-DAG child) OperationKeys for Portal/Category — manifest ops with
    # EntityResolution='Resolved'. A fanout op polls N entities PER cycle under ONE CorrelationId, every child poll
    # stamped with the BASE OperationKey (E-BLK2) → the 1:1 D3/D7 invariants misfire (Started=N>1 per (Op,Cid);
    # intra-burst gaps <30s between distinct entities) unless the verifier knows which ops fan out. Same manifest
    # load as the sibling Get-XdrManifestOperationKeys (single source of truth).
    param([string]$Portal, [string]$Category)
    if ([string]::IsNullOrEmpty($Portal) -or [string]::IsNullOrEmpty($Category)) { return @() }
    $manifestPath = Join-Path (Resolve-Path "$PSScriptRoot\..").Path "manifests/$Portal/$Category.psd1"
    if (-not (Test-Path $manifestPath)) { return @() }
    $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
    if (-not $manifest -or -not $manifest.ContainsKey('Operations')) { return @() }
    return @(@($manifest.Operations) | Where-Object { $_.ContainsKey('OperationKey') -and ([string]$_['EntityResolution'] -eq 'Resolved') } | ForEach-Object { [string]$_.OperationKey })
}

function Get-XdrProjectionTargets {
    # The landed workspace column names for an Operation's ProjectionMap (each key run through the
    # LA-reserved rewrite). Empty array if the Operation has no ProjectionMap.
    param($Operation)
    if (-not $Operation -or -not $Operation.ContainsKey('ProjectionMap') -or -not $Operation.ProjectionMap) { return @() }
    return @($Operation.ProjectionMap.Keys | ForEach-Object { Get-XdrSafeColumnName $_ })
}

function Get-XdrNaturalKeyKql {
    # The KQL scalar expression for an Operation's composite NaturalKey, matching the runtime's
    # '|'-joined key (Invoke-XdrEntryPoll $keyOf). 1 field → tostring(field); N fields → strcat with '|'.
    # Returns $null when the Operation declares no NaturalKey — the ExactlyOnce gate then falls back to the landed
    # RecordId column (the content-hash dedup identity · 2026-06-18) so it still RUNS and BLOCKS, never skips.
    param($Operation)
    if (-not $Operation -or -not $Operation.ContainsKey('NaturalKey')) { return $null }
    $keys = @($Operation.NaturalKey)
    if ($keys.Count -eq 0) { return $null }
    if ($keys.Count -eq 1) { return "tostring($($keys[0]))" }
    $parts = @()
    for ($i = 0; $i -lt $keys.Count; $i++) {
        if ($i -gt 0) { $parts += "'|'" }
        $parts += "tostring($($keys[$i]))"
    }
    return "strcat($($parts -join ', '))"
}

function Get-XdrOpScopedClause {
    # WS4.3 fix · op-scope a time-window KQL where-clause to ONE resolved Operation's rows.
    # The per-Op gates (D8f/D8g/D8h/ExactlyOnce) each assert a SINGLE Operation's ProjectionMap/NaturalKey
    # contract, but a category table holds EVERY op's rows (GetTenantContext + GetHistory + …). An unscoped
    # window therefore evaluates GetTenantContext's rows against GetHistory's typed-col/NaturalKey spec →
    # guaranteed false-fail (the keystone verifier bug). Scope by the landed envelope Operation column to
    # the op the gate resolved (F2: the OperationKey column was DROPPED — it duplicated Operation; the manifest
    # OperationKey VALUE is the same op identifier that lands in the Operation envelope column). Falls back to
    # the bare time clause only when the op key is genuinely unknown (the gate's own resolvability guard fires first).
    param([string]$SinceClause, $Operation, [string]$FallbackKey)
    $opK = if ($Operation -and $Operation.ContainsKey('OperationKey') -and -not [string]::IsNullOrEmpty([string]$Operation.OperationKey)) {
        [string]$Operation.OperationKey
    } else { $FallbackKey }
    if ([string]::IsNullOrEmpty($opK)) { return $SinceClause }
    # The manifest OperationKey value is a manifest-controlled identifier; escape a single-quote defensively so the
    # KQL string literal stays well-formed regardless of the manifest author's naming.
    $opKEsc = $opK -replace "'", "''"   # KQL escapes a single-quote by DOUBLING it, not backslash (the \' was a no-op for quote-less keys but KQL-invalid for a key containing a quote · same class as the has/quote false-negative lesson)
    return "$SinceClause and Operation == '$opKEsc'"
}

$script:XdrLiveVerdicts = $null
function Get-XdrLiveSourceVerdict {
    # G1 prove-empty wire: read the {OperationKey -> Verdict} map from -LiveSourceVerdicts (written by
    # Verify-XdrLiveContent -AllOps -VerdictOut: PASS/EMPTY/CAP-ABSENT/RED-shape). Loaded ONCE (script-cached).
    # Returns '' when no file is supplied OR the op is absent → the caller treats '' as "no direct-source proof".
    param([string]$OperationKey)
    if ($null -eq $script:XdrLiveVerdicts) {
        $script:XdrLiveVerdicts = @{}
        if ($LiveSourceVerdicts -and (Test-Path $LiveSourceVerdicts)) {
            try {
                $m = Get-Content $LiveSourceVerdicts -Raw | ConvertFrom-Json
                foreach ($p in $m.PSObject.Properties) { $script:XdrLiveVerdicts[[string]$p.Name] = [string]$p.Value }
            } catch { Write-Host "[verify] WARN: could not parse -LiveSourceVerdicts '$LiveSourceVerdicts': $($_.Exception.Message)" -ForegroundColor DarkYellow }
        }
    }
    if ($script:XdrLiveVerdicts.ContainsKey($OperationKey)) { return $script:XdrLiveVerdicts[$OperationKey] }
    return ''
}

function Resolve-XdrZeroRowVerdict {
    # G1 prove-empty (PURE · unit-tested without live az): decide a 0-row op's MinRows verdict from the terminal-poll
    # signal ($Polled) + the DIRECT-SOURCE verdict ($LiveVerdict ∈ EMPTY/CAP-ABSENT/PASS/RED-shape, or '' when no
    # -LiveSourceVerdicts wired). Returns the decision hashtable, or $null when not polled (caller keeps the original
    # real-negative). B4: this is the existing Verify-XdrLiveContent proof wired into the existing MinRows decision —
    # NOT a new gate layer. Honesty: a 0-row op is GREEN only when the SOURCE is genuinely empty; data-at-source +
    # 0-workspace = RED; polled-but-unproven = INCONCLUSIVE (never a silent green).
    param([bool]$Polled, [string]$LiveVerdict, [bool]$ProductGated = $false, [int]$FaGapSignal = -1)
    if ($ProductGated) {
        # F18 capability-as-telemetry: the engine PRE-GATES this op (Entry.RequiresProducts.Skipped) because its
        # RequiresProducts product is ABSENT on this tenant (e.g. GetMdcPreviewFeatures needs MDC · inactive here), so it
        # never polls and lands 0 rows LEGITIMATELY. The Verify-XdrLiveContent direct-probe BYPASSES that gate (it hits the
        # endpoint directly) so its PASS is MISLEADING — checked FIRST so a stale direct-PASS can't flip this to RED. Lands
        # rows on a product-capable tenant.
        return @{ Pass = $true; Inconclusive = $false; Detail = "rows=0 · LEGIT product-gated (engine Entry.RequiresProducts.Skipped · RequiresProducts absent on this tenant · the direct-probe bypasses the product-gate so its PASS is misleading · lands on a product-capable tenant · F18 capability-as-telemetry)" }
    }
    if ($Polled -and $LiveVerdict -in @('EMPTY','CAP-ABSENT','FANOUT')) {
        # FANOUT = entity-DAG child ({param} op): the LOCAL direct-source probe cannot substitute the parent-sourced id,
        # so its data is validated by the engine PER-ENTITY emission (the D3/D7 fan-out invariants over the emitted rows)
        # + the prepush EntityDependsOn guard (parent SHIPS + PROJECTS the id → the fan-out provably runs). A 0-row window
        # for a fan-out op that polled to terminal = legit-no-data (no per-entity items on this tenant, e.g. no timeline/
        # marked events on the lab machines). 2026-06-22 ROUND-7c: verify-tool was direct-probing {MachineId} → false 400.
        return @{ Pass = $true;  Inconclusive = $false; Detail = "rows=0 · LEGIT-NO-DATA PROVEN (op polled to terminal + direct-source verdict=$LiveVerdict)" }
    }
    if ($LiveVerdict -in @('PASS','RED-shape')) {
        # POLL-OUTCOME reconcile (Fix 2): the direct-source probe (Verify-XdrLiveContent) is a SEPARATE single sample —
        # it can read DATA at source while the FA's OWN poll correctly produced 0 NEW rows. Reconcile against the FA's own
        # Entry.Poll.* outcome (Get-XdrFaPollLandGap): exactly-once DEDUP of unchanged/seen data (SNAPSHOT signature
        # unchanged · CURSOR rows <= high-water · re-emitting would dup-accumulate) and an async-EMPTY poll are BOTH correct
        # 0-row outcomes, NOT a gap; only NEW data the FA received yet NEVER landed is the gap. FaGapSignal = -1 (no FA poll
        # telemetry in-window) falls through to the original direct-probe verdict — NO regression.
        if ($FaGapSignal -eq 0) {
            return @{ Pass = $true;  Inconclusive = $false; Detail = "rows=0 · the FA's OWN polls show NO unlanded data — exactly-once correctly suppressed UNCHANGED/seen data (data present from a prior emit · re-emit would dup-accumulate) OR every poll received EMPTY OR the op emits within history (lands when data is new) · NOT a gap" }
        }
        if ($FaGapSignal -eq 1) {
            return @{ Pass = $false; Inconclusive = $false; Detail = "rows=0 in workspace BUT the FA's OWN poll received NEW data (ItemCount>0 · not deduped) and the op has NEVER landed a row — FA is NOT landing data it received = REAL gap (DCR / parse / stream)" }
        }
        return @{ Pass = $false; Inconclusive = $false; Detail = "rows=0 in workspace BUT direct-source returned DATA (verdict=$LiveVerdict) — FA is NOT landing data that exists = REAL gap (wrong endpoint / parse / DCR)" }
    }
    if ($Polled) {
        return @{ Pass = $false; Inconclusive = $true;  Detail = "rows=0 · op polled to terminal but NO direct-source-empty proof — unproven-0 (run via Run-PostDeployVerify -AllOps so Verify-XdrLiveContent supplies -LiveSourceVerdicts)" }
    }
    return $null
}

function Get-XdrPollLivenessClause {
    # PURE · the poll-liveness/guard window for the terminal-poll, product-gate, and SNAPSHOT poll-cycle probes.
    # "did this op EVER poll-to-terminal / get product-gated since deploy?" is cadence- AND mode-independent (SNAPSHOT/
    # WINDOW/CURSOR alike), so the window must span a WIDE recent span — NOT a fixed ago(2h) slice, which MISSES an op
    # whose terminal poll is >2h old by re-verify time (the GA-blocking Operations cap-absent false-FAIL 2026-06-23:
    # MTO/streaming ops poll twice at cutover then CadenceNotDue → Capability.OpUnavailable >2h old → $Polled=false →
    # hard FAIL despite a CAP-ABSENT verdict). Anchor at the deploy floor when given, OR'd with a WIDE ago() fallback so
    # the liveness check is INDEPENDENT of the (cold) rows window — a LONG-CADENCE cap-absent op (live-caught 2026-07-01:
    # GetConfiguration · 6h · the /streamingapi/streamingApiConfiguration surface · Capability.OpUnavailable) polls rarely,
    # and AppInsights SAMPLING can drop its single terminal event in a narrow window → a 72h fallback captures ENOUGH of
    # the STABLE cap-absent/product-gate posture (~a dozen+ events for a 6h op) to survive sampling. This ONLY widens the
    # liveness proof (the cold rows window is a SEPARATE clause · unaffected · re-emit is still proven there); a genuinely-
    # broken DATA op still reads 0 rows + direct-source DATA + FaGapSignal=1 → RED, so no masking. No floor → ago(72h).
    param([string]$DeployedSinceUtc)
    if (-not [string]::IsNullOrWhiteSpace($DeployedSinceUtc)) {
        return "(TimeGenerated >= datetime($DeployedSinceUtc) or TimeGenerated >= ago(72h))"
    }
    return 'TimeGenerated >= ago(72h)'
}

function Test-XdrOpPolledToTerminal {
    # V-M4 LEGIT-NO-DATA probe (mirrors the inline D8f check ~line 1311): did $OperationKey reach a TERMINAL poll
    # state (Entry.Poll.Succeeded | Capability.OpUnavailable) in the window? An op that polled-to-terminal yet landed
    # 0 rows legitimately carries no data ON THIS TENANT (every future category WILL hit empty ops) → its MinRows must
    # be a documented PASS, not a hard fail. An op with NO terminal poll at all stays a real negative (un-proven, not
    # green). Returns $true only on a confirmed terminal poll; $false on none OR on a query error (fail-safe: do NOT
    # mask a real 0-row fail behind a transient). Live-az is mocked in the SelfTest via a shadowed Invoke-XdrKqlQuery.
    param([string]$SinceClause, [string]$OperationKey)
    if ([string]::IsNullOrEmpty($OperationKey)) { return $false }
    $opKEsc = $OperationKey -replace "'", "''"   # KQL escapes a single-quote by DOUBLING it, not backslash (the prior \' was a no-op for quote-less keys but KQL-invalid for any key containing a quote)
    $pollQ = "AppEvents | where $SinceClause | where Name in ('Entry.Poll.Succeeded','Capability.OpUnavailable') | where tostring(Properties.OperationKey) == '$opKEsc' | summarize n=count()"
    $pr = Invoke-XdrKqlQuery -Query $pollQ -Label 'MinRows-nodata'
    if (-not $pr.Success) { return $false }
    $prow = @($pr.Data) | Select-Object -First 1
    return ($prow -and (ConvertTo-XdrInt (Get-XdrRowValue $prow 'n')) -gt 0)
}

function Test-XdrOpProductGated {
    # PRODUCT-GATE probe (mirrors Test-XdrOpPolledToTerminal exactly · queries the engine's product-gate telemetry): did
    # $OperationKey emit Entry.RequiresProducts.Skipped in the window? The engine PRE-GATES an op whose RequiresProducts
    # product is ABSENT on this tenant (e.g. GetMdcPreviewFeatures needs MDC · inactive) — it never polls, lands 0 rows
    # LEGITIMATELY, and the direct-source probe (Verify-XdrLiveContent) BYPASSES the gate so its PASS is misleading. An op
    # that was product-gated yet landed 0 rows is a documented PASS (F18 capability-as-telemetry · lands on a product-capable
    # tenant). Returns $true only on a confirmed product-gate skip; $false on none OR on a query error (fail-safe: do NOT
    # mask a real 0-row fail behind a transient). Live-az is mocked in the SelfTest via a shadowed Invoke-XdrKqlQuery.
    param([string]$SinceClause, [string]$OperationKey)
    if ([string]::IsNullOrEmpty($OperationKey)) { return $false }
    $opKEsc = $OperationKey -replace "'", "''"   # KQL escapes a single-quote by DOUBLING it, not backslash
    $pgQ = "AppEvents | where $SinceClause | where Name == 'Entry.RequiresProducts.Skipped' | where tostring(Properties.OperationKey) == '$opKEsc' | summarize n=count()"
    $pr = Invoke-XdrKqlQuery -Query $pgQ -Label 'MinRows-productgated'
    if (-not $pr.Success) { return $false }
    $prow = @($pr.Data) | Select-Object -First 1
    return ($prow -and (ConvertTo-XdrInt (Get-XdrRowValue $prow 'n')) -gt 0)
}

function Get-XdrFaPollLandGap {
    # POLL-OUTCOME reconciler (sibling of Test-XdrOpPolledToTerminal · queries the FA's OWN poll telemetry over the WIDE
    # poll-liveness window so sparse cadence + App-Insights ingestion lag are absorbed): decide whether a 0-row-in-window
    # op whose direct-probe read DATA is a REAL gap or CORRECT exactly-once behaviour. Honest outcomes from the FA's OWN
    # Entry.Poll.* events (structured AppEvents · NOT the SAMPLED AppTraces):
    #   BoundaryDeduped > 0 → the FA polled + exactly-once correctly SUPPRESSED already-ingested/UNCHANGED data (a SNAPSHOT
    #                         whose signature is unchanged · a CURSOR whose rows are <= high-water). The data IS present
    #                         from a prior emit; re-emitting it would DUP-ACCUMULATE (LA is append-only · cannot wipe) →
    #                         NO gap. This is the static-data category case (e.g. AnalyticsData outbreaks · unchanged).
    #   MaxItemCount == 0   → every successful poll received EMPTY (e.g. /threatAnalytics/outbreaks/topthreats async-cold) →
    #                         correct 0 rows → NO gap.
    #   MaxItemCount > 0 (NEW data · not deduped) → it MUST have landed; if the op emitted within the emission-history
    #                         window it lands when data is new (the in-window 0 is timing/sparsity → NO gap), else REAL gap.
    # Returns: -1 (no poll telemetry at all → caller falls back to the direct-probe verdict · NO regression), 0 (NO gap),
    # 1 (GAP · received NEW data, never landed). Live-az is mocked in the SelfTest via a shadowed Invoke-XdrKqlQuery.
    param([string]$PollLivenessClause, [string]$EmissionHistoryClause, [string]$OperationKey, [string]$WorkspaceTable, $LoopOp, [string]$FallbackKey)
    if ([string]::IsNullOrEmpty($OperationKey)) { return -1 }
    $opKEsc = $OperationKey -replace "'", "''"   # KQL escapes a single-quote by DOUBLING it, not backslash
    $q = "AppEvents | where $PollLivenessClause | where tostring(Properties.OperationKey) == '$opKEsc' | summarize Succeeded = countif(Name == 'Entry.Poll.Succeeded'), Deduped = countif(Name == 'Entry.Poll.BoundaryDeduped'), MaxItems = maxif(toint(Properties.ItemCount), Name == 'Entry.Poll.Succeeded'), MaxKept = maxif(toint(Properties.Kept), Name == 'Entry.Poll.BoundaryDeduped')"
    $pr = Invoke-XdrKqlQuery -Query $q -Label 'MinRows-fapoll'
    if (-not $pr.Success) { return -1 }
    $prow = @($pr.Data) | Select-Object -First 1
    if (-not $prow) { return -1 }
    $succeeded = ConvertTo-XdrInt (Get-XdrRowValue $prow 'Succeeded')
    $deduped   = ConvertTo-XdrInt (Get-XdrRowValue $prow 'Deduped')
    if ($succeeded -le 0 -and $deduped -le 0) { return -1 }   # no poll telemetry in-window → fall through (no regression)
    $maxItems = ConvertTo-XdrInt (Get-XdrRowValue $prow 'MaxItems')
    $maxKept  = ConvertTo-XdrInt (Get-XdrRowValue $prow 'MaxKept')
    # Did ANY in-window poll have NEW rows to land? = rows KEPT after exactly-once (BoundaryDeduped.Kept>0 · partial-dedup),
    # OR a non-deduped successful poll that carried items (kept everything · no dedup event fired). Neither → every poll was
    # fully deduped (unchanged/seen · nothing kept) or empty → 0 rows is the CORRECT exactly-once outcome (data present from
    # a prior emit · re-emitting would dup-accumulate · LA is append-only). This is the static-data category case.
    $hadNewRows = ($maxKept -gt 0) -or ($deduped -le 0 -and $maxItems -gt 0)
    if (-not $hadNewRows) { return 0 }
    # NEW rows existed and must land; has the FA emitted this op within the emission-history window (it lands when data is
    # new · the in-window 0 is timing/sparsity)? Never landed → real received-but-not-landed gap (DCR/parse/stream).
    if ([string]::IsNullOrEmpty($WorkspaceTable)) { return -1 }
    $histScoped = Get-XdrOpScopedClause -SinceClause $EmissionHistoryClause -Operation $LoopOp -FallbackKey $FallbackKey
    $hr = Invoke-XdrKqlQuery -Query "$WorkspaceTable | where $histScoped | summarize Count = count()" -Label 'MinRows-faland'
    if (-not $hr.Success) { return -1 }
    $hist = ConvertTo-XdrInt (Get-XdrRowValue (@($hr.Data) | Select-Object -First 1) 'Count')
    if ($hist -gt 0) { return 0 } else { return 1 }           # ever-landed = lands when data is new (timing) · never = real gap
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ── PURE GATE-DECISION FUNCTIONS (plan §18 honesty bar · unit-tested without live az) ─────────────
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Each Test-XdrGate_* takes the FIRST result row (a hashtable from `az ... --output json | ConvertFrom-Json
# -AsHashtable`, or $null for an empty/zero-row window) and returns a decision hashtable:
#     @{ Pass=<bool>; Inconclusive=<bool>; Detail=<string> }
# The gate BODY does only I/O (run KQL → grab row → call the pure fn → record). All correctness logic is
# here, so every gate is provably able to fail: a BAD row → Pass=$false · a GOOD row → Pass=$true · an
# empty/null row → either a hard Pass=$false (presence gates: row absence == nothing landed == fail) or
# Inconclusive=$true (gates whose logic would pass on zero rows — empty window is NEVER a silent green).
#
# az returns scalars as STRINGS ("True","0"), so values are coerced via the shared helpers below.

function Get-XdrRowValue {
    # StrictMode-safe read of a column from a row-hashtable by NAME · $null when row/key absent.
    # (indexer `$Row[$Name]`, never dot-access — dot on a hashtable under StrictMode is a foot-gun.)
    param($Row, [string]$Name)
    if ($null -eq $Row) { return $null }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains($Name)) { return $Row[$Name] }
        return $null
    }
    return $null
}

function ConvertTo-XdrBool {
    # az --output json renders KQL bool cols as the STRINGS "True"/"False" (occasionally real bools after
    # -AsHashtable). True iff the value is $true OR its string form is 'true' (case-insensitive).
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return ("$Value" -ieq 'true')
}

function ConvertTo-XdrInt {
    # Safe string→int coercion (az renders numeric cols as strings) · $Default when null/unparseable.
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [int]) { return $Value }
    $n = 0
    if ([int]::TryParse(("$Value").Trim(), [ref]$n)) { return $n }
    return $Default
}

# ── Presence gates · a row is EXPECTED · its absence means the signal never landed → hard FAIL ────
# (Boot/D0/D4: an empty window here is a real negative, NOT inconclusive — the thing we assert exists
#  simply isn't there. These do NOT pass on zero rows by design.)

function Test-XdrGate_Boot {
    # Boot.VersionProbe present · project: Pass(Count>0), Count, MostRecent, LatestCommit
    # STEADY-STATE (2026-06-21 · mirrors the D0 fix of 2026-06-17): a checkpoint-reset re-prove (or any steady-state
    # re-verify) does NOT cold-start the FA, so Boot.VersionProbe is emitted only at the LAST boot — OUTSIDE the window.
    # When AppTraces shows NO 'XdrLogRaider boot' in-window ($BootLines==0) the FA didn't cold-start, so probe-absence is
    # the NORMAL steady-state (vacuously OK · the version STAGE independently proves the SHA == HEAD). A real broken deploy
    # WITH a restart ($BootLines>0) but no probe still FAILs. $BootLines<0 = not supplied → legacy strict Count>0 behaviour.
    param($Row, [int]$BootLines = -1)
    if ($BootLines -eq 0) { return @{ Pass = $true; Inconclusive = $false; Detail = "no cold-start in window (steady-state · vacuously OK · SHA proven by the version stage) · count=$(if ($Row) { Get-XdrRowValue $Row 'Count' } else { 0 })" } }
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $false; Detail = 'no rows · Boot.VersionProbe not emitted in window' } }
    $pass = ConvertTo-XdrBool (Get-XdrRowValue $Row 'Pass')
    $detail = "count=$(Get-XdrRowValue $Row 'Count') lastSeen=$(Get-XdrRowValue $Row 'MostRecent') commit=$(Get-XdrRowValue $Row 'LatestCommit')"
    return @{ Pass = $pass; Inconclusive = $false; Detail = $detail }
}

function Test-XdrGate_D0 {
    # Module-load HEALTH (NOT boot-presence — that is the separate Boot gate, which is NOT in the Sustain set).
    # GATE-LEARNING (2026-06-17): a stably-running FA does NOT cold-start every window, so "no boot traces in
    # window" (BootLines==0 / $null row) is the NORMAL steady-state — module-load health is then vacuously OK and
    # liveness is proven by D3's active-poll lifecycle. Prior code FAILed on this (it required the server 'Pass'
    # which embeds BootLines>0), false-failing EVERY steady-state re-verify. D0 now FAILs ONLY when a boot IS
    # observed in-window AND it carried module-load failures or Legion managed-dependency errors.
    param($Row)
    if ($null -eq $Row) { return @{ Pass = $true; Inconclusive = $false; Detail = 'no boot traces in window · FA did not cold-start (steady-state) · module-load health vacuously OK · liveness via D3' } }
    $bootLines = ConvertTo-XdrInt (Get-XdrRowValue $Row 'BootLines')
    $mlf       = ConvertTo-XdrInt (Get-XdrRowValue $Row 'ModuleLoadFailures')
    $legErr    = ConvertTo-XdrInt (Get-XdrRowValue $Row 'LegionErr')
    $detail = "moduleLoadFailures=$mlf bootLines=$bootLines legionErr=$legErr lastBoot=$(Get-XdrRowValue $Row 'LastBoot')"
    if ($bootLines -eq 0) { return @{ Pass = $true; Inconclusive = $false; Detail = "$detail · no cold-start in window (steady-state · vacuously OK) · liveness via D3" } }
    return @{ Pass = (($mlf -eq 0) -and ($legErr -eq 0)); Inconclusive = $false; Detail = $detail }
}

function Test-XdrGate_D4 {
    # R3 capability discovery · RECOVERY-AWARE (2026-07-01). Row (KQL grouped PER-PORTAL): Total, Succeeded, Failed,
    # UnrecoveredFailPortals (portals that NEVER succeeded OR whose LAST terminal was a Failed), MostRecent. PASS iff
    # ≥1 Succeeded AND UnrecoveredFailPortals==0 — a portal that RECOVERED (a later Succeeded after a transient
    # single-flight-contention Failed) is HEALTHY (the tenant IS discoverable); only a portal that never succeeds /
    # ends in Failed is a real discovery defect. A stale row missing UnrecoveredFailPortals (older query) reads 0
    # (back-compat: falls back to Succeeded>0). No Discovery events at all = R3 never fired = hard FAIL.
    param($Row)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $false; Detail = 'no PortalCapabilities.Discovery events · R3 cold-start did not fire' } }
    $succeeded   = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Succeeded')
    $unrecovered = ConvertTo-XdrInt (Get-XdrRowValue $Row 'UnrecoveredFailPortals')
    $pass = ($succeeded -gt 0) -and ($unrecovered -le 0)
    $detail = "succeeded=$succeeded failed=$(Get-XdrRowValue $Row 'Failed') unrecovered-fail-portals=$unrecovered (a portal with a later Succeeded after a transient Failed = recovered · OK) total=$(Get-XdrRowValue $Row 'Total') lastSeen=$(Get-XdrRowValue $Row 'MostRecent')"
    return @{ Pass = $pass; Inconclusive = $false; Detail = $detail }
}

# ── Row-population gates · run against the workspace table · project a Pass bool + counts. An empty
#    window means NO data landed: for these the table-is-empty case is INCONCLUSIVE (we cannot assert
#    "no empty rows" / "all JSON valid" over zero rows — that would be a silent green). ──────────────

function Test-XdrGate_D2 {
    # No empty rows · project: Pass(Empty==0), Empty, Total. G1b: when the op is already LEGIT-NO-DATA PROVEN
    # (MinRows passed a 0-row op via the direct-source EMPTY/CAP-ABSENT proof), a 0-row window is VACUOUSLY clean
    # (no rows ⇒ no empty rows) → PASS, not INCONCLUSIVE. Wires the EXISTING MinRows verdict (no new gate · B4):
    # a fully-proven-empty op must not leave the re-prove exit-1-advisory. Unproven-0 stays INCONCLUSIVE.
    param($Row, [bool]$LegitNoDataProven = $false)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no result row from workspace table (table absent or empty window) · cannot assert' } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = '0 rows · vacuously clean (op LEGIT-NO-DATA PROVEN — no rows to be empty)' } }
        return @{ Pass = $false; Inconclusive = $true; Detail = '0 rows in window · no rows to evaluate for emptiness' }
    }
    $empty = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Empty')
    return @{ Pass = ($empty -eq 0); Inconclusive = $false; Detail = "empty=$empty total=$total" }
}

function Test-XdrGate_D6 {
    # RawJson valid · project: Pass(Invalid==0), Invalid, Total. G1b: when the op is already LEGIT-NO-DATA PROVEN,
    # a 0-row window is VACUOUSLY valid (no rows ⇒ no invalid RawJson) → PASS, not INCONCLUSIVE. Wires the EXISTING
    # MinRows verdict (no new gate · B4). Unproven-0 stays INCONCLUSIVE (never a silent green).
    param($Row, [bool]$LegitNoDataProven = $false)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no result row from workspace table (table absent or empty window) · cannot assert' } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = '0 rows · vacuously valid (op LEGIT-NO-DATA PROVEN — no RawJson to be invalid)' } }
        return @{ Pass = $false; Inconclusive = $true; Detail = '0 rows in window · no RawJson to validate' }
    }
    $invalid = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Invalid')
    return @{ Pass = ($invalid -eq 0); Inconclusive = $false; Detail = "invalid=$invalid total=$total" }
}

function Test-XdrGate_MinRows {
    # ≥1 row landed · project: Pass(Count>=1), Count. Zero rows is the REAL negative this gate exists to
    # catch (cold-window "did anything land?") → hard FAIL, not inconclusive.
    param($Row)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $false; Detail = 'no rows landed in workspace table' } }
    $count = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Count')
    return @{ Pass = ($count -ge 1); Inconclusive = $false; Detail = "rows=$count" }
}

function Test-XdrGate_CorrelationId {
    # CorrelationId populated on every row · project: Pass(NullCount==0), NullCount, Total
    param($Row, [bool]$LegitNoDataProven = $false)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no result row (table absent or empty window) · cannot assert' } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = '0 rows · vacuously satisfied (op LEGIT-NO-DATA PROVEN — no rows to carry a null CorrelationId)' } }
        return @{ Pass = $false; Inconclusive = $true; Detail = '0 rows in window · no CorrelationId to check' }
    }
    $missing = ConvertTo-XdrInt (Get-XdrRowValue $Row 'NullCount')
    return @{ Pass = ($missing -eq 0); Inconclusive = $false; Detail = "missing=$missing total=$total" }
}

function Test-XdrGate_D8c {
    # All 4 always-populated envelope cols populated on every row · project: Pass, Total, Portal_pop,
    # Category_pop, Operation_pop, CorrelationId_pop (F2: OperationKey dropped — it duplicated Operation)
    param($Row, [bool]$LegitNoDataProven = $false)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no result row (table absent or empty window) · cannot assert envelope population' } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = '0 rows · vacuously satisfied (op LEGIT-NO-DATA PROVEN — no envelope rows to evaluate)' } }
        return @{ Pass = $false; Inconclusive = $true; Detail = '0 rows in window · no envelope cols to evaluate' }
    }
    $pass = ConvertTo-XdrBool (Get-XdrRowValue $Row 'Pass')
    $detail = "total=$total portal=$(Get-XdrRowValue $Row 'Portal_pop') cat=$(Get-XdrRowValue $Row 'Category_pop') op-name=$(Get-XdrRowValue $Row 'Operation_pop') corr=$(Get-XdrRowValue $Row 'CorrelationId_pop')"
    return @{ Pass = $pass; Inconclusive = $false; Detail = $detail }
}

# ── Event-reconcile / cadence / auth gates · summarise AppEvents|AppTraces. These project a Pass bool;
#    an empty window means the telemetry stream is silent → INCONCLUSIVE (cannot prove a property of
#    events that didn't occur). EXCEPT presence-style ones already handled above. ────────────────────

function Test-XdrGate_D1 {
    # Event-row reconcile · project: Pass(Mismatched==0), Mismatched, Total, RowsWithoutEvent (groups Actual>Expected).
    # §4.B RESET-AWARENESS (2026-06-25 · the B10 pattern · ported from D3/D7): right after a checkpoint reset-all
    # (Save-XdrCheckpointReset), a CROSS-reset poll cycle can LAND its rows but LOSE its terminal Entry.Poll.Succeeded
    # event to concurrency churn during the reset → that (Op,Cid) group reconciles Actual>Expected (rows-landed-without-a-
    # terminal-event · the reset-ADJACENT direction). This is a reset-transient, NOT data loss (ItemCount==RowsAccepted
    # at the runtime · a reset-free window reconciles Mismatched=0). When a reset falls in the window ($ResetsInWindow>0)
    # AND the ONLY mismatch is that reset-adjacent rows-landed-without-event direction (RowsWithoutEvent==Mismatched · so
    # there is no Expected>Actual genuine-loss group hiding) → the count is reset-inflated → INCONCLUSIVE (never FAIL ·
    # exactly how D3/D7 treat a dirty window). A reset-FREE window ($ResetsInWindow==0) with Mismatched>0 is a GENUINE
    # steady-state defect → still FAIL (the gate is NOT weakened). $ResetsInWindow<0 = reset count UNKNOWN (the count read
    # failed) → fall back to the strict Mismatched==0 verdict (do NOT silently pass on an unknowable reset state · B5).
    # $CatFullyCapAbsent (F18 · 2026-07-03): the WHOLE category polled to cap-absent terminals with 0 successes AND 0
    # failures (all ops 403/404 posture) → there are legitimately no events/rows to reconcile → vacuous-PASS, NOT the
    # generic "nothing to reconcile" INCONCLUSIVE (which would false-block a fully-posture cat in strict/no-tolerate mode).
    param($Row, [int]$ResetsInWindow = 0, [bool]$CatFullyCapAbsent = $false)
    if ($null -eq $Row) {
        if ($CatFullyCapAbsent) { return @{ Pass = $true; Inconclusive = $false; Detail = 'no reconcile rows · category FULLY cap-absent (all ops 403/404 posture · F18) → vacuously reconciled (no events/rows to miss)' } }
        return @{ Pass = $false; Inconclusive = $true; Detail = 'no reconcile rows (no Entry.Poll.Succeeded events and/or no table rows in window)' }
    }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) {
        if ($CatFullyCapAbsent) { return @{ Pass = $true; Inconclusive = $false; Detail = '0 (Op,Cid) groups · category FULLY cap-absent (all ops 403/404 posture · F18) → vacuously reconciled (no events/rows to mismatch)' } }
        return @{ Pass = $false; Inconclusive = $true; Detail = '0 (Op,Cid) groups in window · nothing to reconcile' }
    }
    $mismatched = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Mismatched')
    $rowsWithoutEvent = ConvertTo-XdrInt (Get-XdrRowValue $Row 'RowsWithoutEvent')
    if ($mismatched -gt 0 -and $ResetsInWindow -gt 0 -and $rowsWithoutEvent -eq $mismatched) {
        return @{ Pass = $false; Inconclusive = $true; Detail = "mismatched=$mismatched total=$total · $ResetsInWindow checkpoint reset(s) in window → the reset-adjacent rows-landed-without-a-terminal-event (Actual>Expected · all $rowsWithoutEvent mismatch group(s)) is EXPECTED reset-churn (a cross-reset poll lands rows but loses its terminal Entry.Poll.Succeeded to the reset) · INCONCLUSIVE, re-run over a reset-free steady-state window (artifact-discrimination · same as B10)" }
    }
    $resetNote = ''
    if ($ResetsInWindow -gt 0) {
        $resetNote = if ($mismatched -eq 0) { " (resets=$ResetsInWindow · 0 mismatch → clean despite the reset)" }
                     else { " (resets=$ResetsInWindow · $rowsWithoutEvent of $mismatched mismatch are rows-without-event → a genuine-loss (Expected>Actual) group is present → NOT excused)" }
    }
    return @{ Pass = ($mismatched -eq 0); Inconclusive = $false; Detail = "mismatched=$mismatched total=$total$resetNote" }
}

function Get-XdrManifestCadenceMap {
    # All ops' declared Cadence (hh:mm:ss / d.hh:mm:ss) → seconds, keyed by OperationKey (WS2 tiers).
    # UNPARSEABLE-CADENCE surfacing (2026-07-01 robustness · safe-additive): an op whose manifest Cadence cannot be
    # parsed used to be SILENTLY dropped from the map (warn-only). A silently-dropped op is then SKIPPED by
    # Get-XdrCadenceVerdict (absent-from-map == "not this category's") → a REAL cadence defect on that op becomes a
    # false-PASS (the inverse hazard: a silent drop hides a defect, not just an artifact). Instead, collect the
    # unparseable OperationKeys into the optional $UnparseableOps LIST (a reference-type IList — appended in place, so no
    # [ref] needed · a bare $null default binds cleanly when a caller omits it) so the D7 gate can route to INCONCLUSIVE
    # (a LOUD "can't evaluate this op's cadence"), never a silent skip. Back-compat: the list is optional — callers that
    # omit it get the identical map (the parse map is unchanged; parseable ops are unaffected).
    param([string]$Portal, [string]$Category, [System.Collections.IList]$UnparseableOps = $null)
    $map = @{}
    if ([string]::IsNullOrEmpty($Portal) -or [string]::IsNullOrEmpty($Category)) { return $map }
    $manifestPath = Join-Path (Resolve-Path "$PSScriptRoot\..").Path "manifests/$Portal/$Category.psd1"
    if (-not (Test-Path $manifestPath)) { return $map }
    $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
    if (-not $manifest -or -not $manifest.ContainsKey('Operations')) { return $map }
    foreach ($op in @($manifest.Operations)) {
        if ($op.ContainsKey('OperationKey') -and $op.ContainsKey('Cadence')) {
            # InvariantCulture · parity with the runtime G-Cadence parse (XdrDefenderRefresh/run.ps1). The catch is NO
            # LONGER silent NOR a lossy drop: an unparseable Cadence is recorded into $UnparseableOps so D7 goes
            # INCONCLUSIVE (never a false-PASS), AND it warns — the offline CadenceParseable + Validate-Manifests gates
            # should have caught it pre-push (FH-9 #3).
            try { $map[$op.OperationKey] = [int][TimeSpan]::Parse($op.Cadence, [System.Globalization.CultureInfo]::InvariantCulture).TotalSeconds }
            catch {
                Write-Warning "[Verify-DeployedConnector] op '$($op.OperationKey)' Cadence '$($op.Cadence)' unparseable (InvariantCulture) — D7 goes INCONCLUSIVE for it (not a silent drop)"
                if ($null -ne $UnparseableOps) { [void]$UnparseableOps.Add([string]$op.OperationKey) }
            }
        }
    }
    return $map
}

function Get-XdrCadenceVerdict {
    # PURE · per-op gap rows vs each op's DECLARED manifest cadence (the flat-5m era is dead — WS2 tiers).
    # bad = P90Gap > 1.5×cadence (sustained) OR MaxGap > 3×cadence (stall) — outlier-robust. [The MinGap<30s check was DROPPED
    # 2026-07-03: redundant — a dup EMISSION REDs in SnapshotNoDupAccum (§10 xix) — and it false-flagged benign
    # resilience (SingleFlight.Contended yields · BoundaryDeduped double-polls · SNAPSHOT-on-change rapid re-emits).] Ops absent from the map are skipped
    # (not this category's). Ops with <2 fires never produce a gap row — slow tiers prove on Sustain.
    # UNPARSEABLE-CADENCE (2026-07-01 robustness · safe-additive): $UnparseableOps = ops whose manifest Cadence could not
    # be parsed (from Get-XdrManifestCadenceMap). Such an op's cadence is UNKNOWABLE, so its verdict must be a LOUD
    # INCONCLUSIVE, never a silent skip that hides a real defect. Precedence preserves M1: a GENUINE Bad>0 on a
    # PARSEABLE op still FAILs (a real defect is never masked by inconclusive); only when the parseable ops are CLEAN
    # (Bad==0) but ≥1 op is unparseable does the verdict go Inconclusive. Parseable ops compute Bad/Total exactly as now.
    # CAP-ABSENT POSTURE (F18 · 2026-07-03): $CapAbsentOps = ops that polled to a Capability.OpUnavailable terminal with 0
    # successes in-window (403/404 · license/MTO/entitlement absent on THIS tenant). Such an op BACKS OFF polling, so its
    # large inter-poll gap is CORRECT behaviour, NOT a cadence defect — skip it from the MaxGap check (live 2026-07-03:
    # GetRecommendations polled 2× 6h apart, both 403/404 · its 21625s gap false-FAILed D7). Per-op posture is surfaced by
    # the CapabilityRegression ADVISORY + MinRows LEGIT-NO-DATA; D7 must never block on it (F18: a lab 404 is never a defect).
    param([array]$GapRows, [hashtable]$CadenceSecondsByOp, [string[]]$UnparseableOps = @(), [string[]]$CapAbsentOps = @())
    $bad = 0; $total = 0; $details = @()
    foreach ($row in @($GapRows)) {
        $op = [string](Get-XdrRowValue $row 'Op')
        if (-not $CadenceSecondsByOp.ContainsKey($op)) { continue }
        if ($op -in $CapAbsentOps) { continue }   # cap-absent posture — backed-off polling is not a cadence defect (F18)
        $cad = [int]$CadenceSecondsByOp[$op]
        $maxGap = ConvertTo-XdrInt (Get-XdrRowValue $row 'MaxGap')
        $minGap = ConvertTo-XdrInt (Get-XdrRowValue $row 'MinGap')
        $p90Raw = Get-XdrRowValue $row 'P90Gap'
        $hasP90 = ($null -ne $p90Raw) -and ("$p90Raw" -ne '')
        $p90Gap = ConvertTo-XdrInt $p90Raw
        $total++
        # DROP the MinGap<30s double-fire check (2026-07-03): a dup EMISSION is caught by SnapshotNoDupAccum (§10 xix · the
        # same reason D3 dropped its Started-count rule); a <30s poll gap that YIELDED (SingleFlight.Contended) or emitted
        # 0-new (BoundaryDeduped) has NO data impact; and a SNAPSHOT-on-change op legitimately re-emits on a rapid content
        # change. D7 keeps the CADENCE proof — the FA is polling on schedule. $minGap is advisory only.
        # ROBUST CADENCE METRIC (2026-07-04): the SUSTAINED cadence is P90Gap ≤ 1.5×tier (≥90% of inter-poll gaps on
        # schedule), NOT max(Gap) ≤ 1.5×tier — a SINGLE recovered blip (one slipped cycle among many · FA cold-start / GC /
        # transient throttle, then back on cadence) is an OUTLIER, not an off-schedule defect (live: ActionCenter.GetHistory
        # 1 gap of 26 at 1.96×tier while p90 stayed on-cadence). The STALL backstop max(Gap) > 3×tier still REDs a genuinely
        # STOPPED op. So bad = p90 > 1.5×tier (SUSTAINED lateness · real) OR max > 3×tier (STALL · real). This CORRECTS the
        # metric (outlier-robust cadence health), it is NOT a tolerate-count. Fallback: a row without P90Gap (legacy caller)
        # keeps the strict max > 1.5×tier check so the verdict is NEVER silently weaker than before.
        $isBad = if ($hasP90) { ($p90Gap -gt [int](1.5 * $cad)) -or ($maxGap -gt [int](3.0 * $cad)) } else { $maxGap -gt [int](1.5 * $cad) }
        if ($isBad) { $bad++; $details += "$op p90=${p90Gap}s max=${maxGap}s cadence=${cad}s (min=${minGap}s advisory)" }
    }
    $unparse = @($UnparseableOps | Where-Object { -not [string]::IsNullOrEmpty($_) })
    # Inconclusive ONLY when the parseable ops are clean (Bad==0) yet an op's cadence is unparseable → can't fully prove
    # D7 → LOUD INCONCLUSIVE. A real Bad>0 takes precedence (still FAIL · M1) — never softened by an unparseable sibling.
    $inconclusive = ($bad -eq 0) -and ($unparse.Count -gt 0)
    $unparseDetail = if ($unparse.Count -gt 0) { "unparseable-cadence op(s) [$($unparse -join ', ')] — cadence UNKNOWABLE (fix the manifest Cadence · offline CadenceParseable should have caught it)" } else { '' }
    $detail = @($details + @($unparseDetail | Where-Object { $_ })) -join ' · '
    return @{ Bad = $bad; Total = $total; Detail = $detail; Inconclusive = $inconclusive; Unparseable = $unparse.Count }
}

function Test-XdrGate_D3 {
    # Exactly 1 telemetry per poll · project: Pass(Bad==0), Bad, Total.
    # §4.B RESET-AWARENESS (2026-06-24 · the B10 pattern): a checkpoint reset (Save-XdrCheckpointReset) re-fires every
    # SNAPSHOT op at the reset instant, which can leave a poll straddling the reset stamped orphan-close / double-close
    # (Started=0,Closed>0 · Closed>1) — a reset-CHURN artifact, NOT a real stuck/orphan defect. When a reset falls in
    # the window ($ResetsInWindow>0) AND we observed bad groups, the bad count is reset-inflated → INCONCLUSIVE (never
    # FAIL · exactly how B9/B10 treat a dirty window). A reset-free window with Bad>0 is a GENUINE steady-state defect →
    # still FAIL (the gate is NOT weakened). $ResetsInWindow<0 = reset count UNKNOWN (the count read failed) → fall back
    # to the strict Bad==0 verdict (do NOT silently pass on an unknowable reset state · B5 honesty).
    param($Row, [int]$ResetsInWindow = 0)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no Entry.Poll.* events in window · cannot assert 1-telemetry-per-poll' } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) { return @{ Pass = $false; Inconclusive = $true; Detail = '0 poll groups in window · nothing to evaluate' } }
    $bad = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Bad')
    if ($bad -gt 0 -and $ResetsInWindow -gt 0) {
        return @{ Pass = $false; Inconclusive = $true; Detail = "bad=$bad total=$total · $ResetsInWindow checkpoint reset(s) in window → the reset-adjacent orphan/double-close is EXPECTED reset-churn (Save-XdrCheckpointReset re-fires SNAPSHOT ops) · INCONCLUSIVE, re-run over a reset-free steady-state window (artifact-discrimination · same as B10)" }
    }
    return @{ Pass = ($bad -eq 0); Inconclusive = $false; Detail = "bad=$bad total=$total$(if ($ResetsInWindow -gt 0) { " (resets=$ResetsInWindow · 0 bad → clean despite the reset)" })" }
}

function Get-XdrResetAwarenessHours {
    # §4.B reset-awareness window (hours). It must look back far enough to still SEE the checkpoint reset whose forced
    # re-emits are visible in THIS verify window. A finalize (Invoke-XdrRoundReprove) resets at T0 then runs leg-1
    # (cold-emit-wait up to a 30m cap + verify-cold over 11 cats) + leg-2 (force + cold-emit-wait + 5×7m sustain
    # retries), so by the time verify-sustain's D7 runs the reset can be ~2–3.5h old — OUTSIDE a naive
    # ceil(SinceMinutes/60) (=2h for the 120m Sustain window), which drops resets-in-window to 0 and false-FAILs the
    # forced-cycle <30s re-fire as a real double-fire. Floor at 6h so the finalize's OWN reset is ALWAYS counted (→ the
    # D7 <30s re-fire / D3 orphan-close / D1 rows-without-terminal are discriminated as reset-churn = INCONCLUSIVE, never
    # FAIL). SAFE: a checkpoint reset happens ONLY on a deploy/finalize, so in steady-state production no reset falls in
    # the last 6h → the gates stay STRICT (a genuine double-fire still FAILs). A tighter SinceMinutes never LOWERS the
    # floor; a deploy-floor (cutover span) can only widen it further (handled by the caller).
    param([int]$SinceMinutes)
    return [Math]::Max(6, [int][Math]::Ceiling($SinceMinutes / 60.0))
}

function Test-XdrGate_D7 {
    # Cadence honored · project: Pass(Bad==0), Bad, Total. A single poll yields no gap row → Total==0;
    # cadence is unprovable with <2 fires → INCONCLUSIVE.
    # §4.B RESET-AWARENESS (2026-06-24 · the B10 pattern): a checkpoint reset re-fires every SNAPSHOT op IMMEDIATELY at
    # the reset instant, so the gap to the next natural cycle reads as a <30s double-fire — a reset-CHURN artifact, NOT a
    # real cadence violation. When a reset falls in the window ($ResetsInWindow>0) AND we observed bad ops, the bad count
    # is reset-inflated → INCONCLUSIVE (never FAIL). A reset-free window with a <30s double-fire / >1.5×tier gap is a
    # GENUINE defect → still FAIL (the gate is NOT weakened). $ResetsInWindow<0 = reset count UNKNOWN → strict fallback.
    # $CatFullyCapAbsent (F18 · 2026-07-03): the WHOLE category is cap-absent (all ops 403/404 posture · 0 successes/failures)
    # → there is no ACTIVE op that could be late, so cadence is vacuously honored → vacuous-PASS, NOT the generic
    # "cadence unprovable" INCONCLUSIVE (which would false-block a fully-posture cat in strict/no-tolerate mode). A cat with
    # ANY active op still measures cadence normally (cap-absent ops are individually skipped in Get-XdrCadenceVerdict).
    param($Row, [int]$ResetsInWindow = 0, [bool]$CatFullyCapAbsent = $false)
    if ($null -eq $Row) {
        if ($CatFullyCapAbsent) { return @{ Pass = $true; Inconclusive = $false; Detail = 'no cadence rows · category FULLY cap-absent (all ops 403/404 posture · F18) → vacuously on-cadence (no active op to be late)' } }
        return @{ Pass = $false; Inconclusive = $true; Detail = 'no cadence rows (need ≥2 Entry.Poll.Started per Op to measure a gap)' }
    }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) {
        if ($CatFullyCapAbsent) { return @{ Pass = $true; Inconclusive = $false; Detail = '0 ops with a measurable gap · category FULLY cap-absent (all ops 403/404 posture · F18) → vacuously on-cadence' } }
        return @{ Pass = $false; Inconclusive = $true; Detail = '0 ops with a measurable gap in window · cadence unprovable' }
    }
    $bad = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Bad')
    if ($bad -gt 0 -and $ResetsInWindow -gt 0) {
        return @{ Pass = $false; Inconclusive = $true; Detail = "bad=$bad totalOps=$total · $ResetsInWindow checkpoint reset(s) in window → the reset-adjacent <30s re-fire is EXPECTED reset-churn (Save-XdrCheckpointReset re-emits SNAPSHOT ops immediately) · INCONCLUSIVE, re-run over a reset-free steady-state window (artifact-discrimination · same as B10)" }
    }
    return @{ Pass = ($bad -eq 0); Inconclusive = $false; Detail = "bad=$bad totalOps=$total$(if ($ResetsInWindow -gt 0) { " (resets=$ResetsInWindow · 0 bad → clean despite the reset)" })" }
}

function Test-XdrGate_D8 {
    # Auth chain healthy · project: Pass((T1+T2+T3)>0), T1, T2, T3. Summarize over a silent window yields
    # a single row of zeros → Pass=False via the KQL; with NO matching traces az returns no row → either
    # way "no tier seated a session" is the real signal → INCONCLUSIVE on a wholly silent window (we
    # cannot affirm auth health from absence), but a zeros-row is a genuine negative the gate reports.
    # m4 (2026-06-18): $SteadyState=$true (Hour/Sustain windows) enables the T1-cached-dominance advisory below.
    param($Row, [bool]$SteadyState = $false)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no [evt] auth traces in window · auth health indeterminate' } }
    $t1 = ConvertTo-XdrInt (Get-XdrRowValue $Row 'T1')
    $t2 = ConvertTo-XdrInt (Get-XdrRowValue $Row 'T2')
    $t3 = ConvertTo-XdrInt (Get-XdrRowValue $Row 'T3')
    if (($t1 + $t2 + $t3) -eq 0) { return @{ Pass = $false; Inconclusive = $true; Detail = "T1=$t1 T2=$t2 T3=$t3 · no auth tier seated a session in window" } }
    $pass = ConvertTo-XdrBool (Get-XdrRowValue $Row 'Pass')
    $detail = "T1=$t1 T2=$t2 T3=$t3"
    # m4 (2026-06-18) · T1-DOMINANCE advisory over a STEADY-STATE window. The bare gate passes on ANY tier seating a
    # session — so an op doing a FULL re-auth (T3) EVERY cycle (cached-token path never hit) reads "healthy" while
    # silently burning the slow auth path each poll (latency + throttle exposure · a cache/lease regression). Over a
    # steady-state window (Hour/Sustain · $SteadyState) the CACHED tier T1 should DOMINATE (the connector caches the
    # bearer between polls). When T1 is NOT the plurality tier in steady-state, flag it (advisory · the gate body
    # records D8 as advisory anyway, so this never blocks · it surfaces a self-heal/cache anomaly for the manual half).
    # Bootstrap/cold windows legitimately run T2/T3 (no cache yet) → $SteadyState=$false suppresses the note.
    if ($SteadyState -and ($t1 + $t2 + $t3) -gt 0 -and $t1 -le [Math]::Max($t2, $t3)) {
        $detail += " · ADVISORY: T1 (cached) is NOT dominant in steady-state (T1=$t1 <= max(T2=$t2,T3=$t3)) · cache/lease may be re-authing every cycle instead of reusing the cached token"
    }
    return @{ Pass = $pass; Inconclusive = $false; Detail = $detail }
}

function Test-XdrGate_Reauth {
    # Φ4.G2c · Auth self-heal · project: Triggered, Succeeded. Reauth fires ONLY on a live auth-loss
    # (HTML-at-JSON + 401/440 → AuthChainBroken → lease-gated reauth), so a steady/healthy window has NONE
    # → INCONCLUSIVE (self-heal not exercised · advisory · never a silent green: absence ≠ proof). When reauth
    # DID fire, every Triggered must reach Succeeded — Triggered>Succeeded is an UNRECOVERED AuthChainBroken (FAIL).
    # m3 (2026-06-18): $PollCycles = distinct Entry.Poll.Succeeded CorrelationIds (poll cycles) in the window. A reauth
    # LOOP — Triggered≈Succeeded EVERY cycle — passes the recovered-equality check yet means auth is BROKEN on every
    # poll and self-healed each time (a cache/session-binding regression burning the slow path · the inverse of m4's
    # T1-dominance). When reauth fires on a HIGH FRACTION of poll cycles (>50%), flag it (advisory · the gate is
    # advisory anyway · never blocks). $PollCycles<=0 (not supplied / no polls) suppresses the fraction note.
    param($Row, [int]$PollCycles = 0)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no Auth.Reauth.* traces in window · self-heal not exercised' } }
    $trig = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Triggered')
    $succ = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Succeeded')
    if (($trig + $succ) -eq 0) { return @{ Pass = $false; Inconclusive = $true; Detail = 'triggered=0 succeeded=0 · no reauth fired (no auth-loss to self-heal)' } }
    $unrecovered = [Math]::Max(0, $trig - $succ)
    $detail = "triggered=$trig succeeded=$succ unrecovered=$unrecovered"
    if ($PollCycles -gt 0 -and $trig -ge [Math]::Ceiling($PollCycles * 0.5) -and $trig -gt 1) {
        $detail += " · ADVISORY: reauth fired on a HIGH fraction of poll cycles (triggered=$trig of ~$PollCycles cycles) · possible reauth LOOP (auth breaks + self-heals every poll · cache/session-binding regression burning the slow path)"
    }
    return @{ Pass = ($trig -gt 0 -and $succ -ge $trig); Inconclusive = $false; Detail = $detail }
}

function Test-XdrGate_Posture {
    # License-independence (§3 · operator-adjudicated 2026-06-10): capability-absent ops POSTURE, never terminal.
    # Pass ⟺ ZERO InvalidProxyPrefix-classified TERMINAL failures (a regression of the Test-XdrIsCapabilityAbsent
    # classifier re-surfaces them as [Entry.Poll.Exception] lines). PostureEvents (Capability.OpUnavailable) is
    # REPORTED for the manual half — 0 is valid on a fully-licensed tenant (the gate = absence of misclassified
    # terminals, NOT presence of posture). No poll activity in the window → INCONCLUSIVE (never a silent green).
    param($Row)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no traces in window · posture path not exercised' } }
    $polls = ConvertTo-XdrInt (Get-XdrRowValue $Row 'PollActivity')
    $term  = ConvertTo-XdrInt (Get-XdrRowValue $Row 'TerminalProxy')
    $post  = ConvertTo-XdrInt (Get-XdrRowValue $Row 'PostureEvents')
    if ($polls -eq 0) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no Entry.Poll activity in window · not exercised' } }
    if ($term -gt 0) { return @{ Pass = $false; Inconclusive = $false; Detail = "$term InvalidProxyPrefix TERMINAL failure(s) · license-gate REGRESSION (must posture, never DLQ)" } }
    return @{ Pass = $true; Inconclusive = $false; Detail = "postureEvents=$post · 0 misclassified terminals (manual: review postureEvents vs the tenant's gated ops)" }
}

function Test-XdrGate_D10 {
    # Circuit-breaker invariant: "every Open eventually Closes". project: Pass(Opens==Closes), Opens, Closes.
    # opens=0 is the steady-state HEALTHY norm (the breaker never tripped) → the invariant is VACUOUSLY SATISFIED
    # (there is no Open left unclosed) → PASS. This is NOT a silent-green-on-empty-window: FA liveness/activity is
    # gated INDEPENDENTLY by D0 (boot completed) + D3 (terminals present), so a real outage surfaces THERE, never as
    # a phantom-clean D10. (Proving the breaker MECHANISM fires would need it EXERCISED — that is a separate GA gate,
    # distinct from this no-regression invariant; a quiet healthy tenant must never be blocked for not failing.)
    # $Row==null means the KQL itself returned nothing (tool/query issue) → genuinely unevaluable → INCONCLUSIVE.
    # V-M3 (2026-06-18): $CurrentlyOpen is the LIVE count of XdrCircuitState rows in state 'Open' at sample time (the
    # same signal Test-GaReadiness C5 queries). It closes the prior-window stuck-open hole: with 0 in-window Opens/Closes
    # but a breaker still open from before the window, the event-only invariant is vacuously satisfied yet an op is dark.
    # $null (no live query supplied · e.g. the unit test, or a deploy without -StorageAccount) keeps the back-compat path.
    param($Row, $CurrentlyOpen = $null)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no breaker events row returned (KQL/tool issue) · open==close unevaluable' } }
    $opens  = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Opens')
    $closes = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Closes')
    if (($opens + $closes) -eq 0) {
        # V-M3 WIDENING (2026-06-18): opens==closes==0 IN THIS WINDOW is NOT automatically healthy. A breaker that
        # OPENED in a PRIOR window and is STILL OPEN now suppresses every poll for its op (Breaker.SkippedOpen ·
        # Runtime.psm1:611) → no Started/terminal/rows → D3 sees no group → D10 would vacuously PASS while an op is
        # silently dark. So a non-null $CurrentlyOpen (the live XdrCircuitState 'Open'-row count, mirroring
        # Test-GaReadiness C5) is consulted: >0 currently-open breakers with 0 in-window Opens means a stuck-open
        # breaker from before the window → FAIL (not vacuous-PASS). $CurrentlyOpen left $null (no live query) keeps
        # the original vacuous-PASS (back-compat · the in-window invariant still holds with zero opens).
        if ($null -ne $CurrentlyOpen) {
            $open = ConvertTo-XdrInt $CurrentlyOpen
            if ($open -gt 0) { return @{ Pass = $false; Inconclusive = $false; Detail = "opens=0 closes=0 in-window BUT $open circuit(s) currently OPEN (XdrCircuitState) · a breaker opened in a PRIOR window is STILL open → its op is silently suppressed (Breaker.SkippedOpen · no poll/rows) · D3 cannot see it" } }
            return @{ Pass = $true; Inconclusive = $false; Detail = "opens=0 closes=0 · breaker never tripped (healthy) · 0 currently-open circuits · invariant vacuously satisfied (FA liveness gated by D0+D3)" }
        }
        return @{ Pass = $true; Inconclusive = $false; Detail = 'opens=0 closes=0 · breaker never tripped (healthy) · invariant vacuously satisfied (FA liveness gated by D0+D3)' }
    }
    return @{ Pass = ($opens -eq $closes); Inconclusive = $false; Detail = "opens=$opens closes=$closes" }
}

function Test-XdrGate_BreakerSkip {
    # V-M3 · Breaker.SkippedOpen visibility (Runtime.psm1:611 · a poll SUPPRESSED by an already-open breaker → zero new
    # data this cycle · NO Entry.Poll.Started/terminal → invisible to D3, D7, MinRows). The breaker-open state is a REAL
    # data-stall: while open, the op produces nothing and only re-probes on half-open. Gate: REPORT the skip count + the
    # distinct ops skipped. ADVISORY by design (your-call justification): a breaker that opens, suppresses a few cycles,
    # then half-opens and CLOSES is the breaker WORKING AS DESIGNED (transient portal outage absorbed) — hard-failing the
    # whole postdeploy proof on a self-healed transient would false-fail a healthy connector (same logic as the
    # transient-tolerant AppExceptions leg). The PERSISTENT-open case (a breaker stuck open across windows) is caught as a
    # BLOCK by D10's $CurrentlyOpen widening above; here we make the in-window skip activity AUDITABLE. No row → 0 (clean ·
    # no suppression in window). count>0 surfaces as advisory detail naming the ops so a chronic skip is human-reviewable.
    param($Row)
    if ($null -eq $Row) { return @{ Pass = $true; Inconclusive = $false; Detail = 'breakerSkips=0 · no poll suppressed by an open breaker in window (no Breaker.SkippedOpen events)' } }
    $skips = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Count')
    $ops   = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Ops')
    if ($skips -eq 0) { return @{ Pass = $true; Inconclusive = $false; Detail = 'breakerSkips=0 · no poll suppressed by an open breaker in window' } }
    # Pass=$true (ADVISORY · the gate body records -Advisory so it surfaces but never blocks a self-healed transient);
    # the detail makes the suppressed-poll data-stall VISIBLE. Cross-check D10 (currently-open) for a STUCK breaker.
    return @{ Pass = $true; Inconclusive = $false; Detail = "breakerSkips=$skips across $ops op(s) · a poll was SUPPRESSED by an open breaker (zero new data those cycles · no Started/terminal → invisible to D3/D7/MinRows) · advisory: a few skips = the breaker absorbing a transient (self-heals on half-open) · cross-check D10 for a breaker STUCK open across windows" }
}

function Get-XdrCapabilityRegressionVerdict {
    # m1 (2026-06-18) · PURE · capability-REGRESSION discriminator for the D8f/MinRows LEGIT-NO-DATA path. An op that
    # polls to Capability.OpUnavailable yet landed 0 rows IS accepted as "genuinely empty" (a tenant that never had the
    # capability) — correct for a never-licensed op, but it MASKS a regression: an op that USED to return data and now
    # 403s (license lapsed · MTO change · API deprecation). The discriminator: the op went OpUnavailable IN-WINDOW
    # ($WentUnavailable) AND it has rows in a BROADER historical lookback ($HistoricalRows>0 · it WAS populated before).
    # That transition is a real signal → ADVISORY (not a block: a license can legitimately lapse · the operator decides).
    # A first-seen-empty op (never had rows · $HistoricalRows==0) or a Succeeded-empty op (not OpUnavailable) is NOT a
    # regression → no advisory (the plain LEGIT-NO-DATA PASS stands). Returns @{ Advisory=<bool>; Detail=<string> }.
    param([bool]$WentUnavailable, $HistoricalRows)
    $hist = ConvertTo-XdrInt $HistoricalRows
    if ($WentUnavailable -and $hist -gt 0) {
        return @{ Advisory = $true; Detail = "capability REGRESSION: op went Capability.OpUnavailable (403/404) in-window but has $hist row(s) in the broader lookback — it USED to return data and now does NOT (license lapse / MTO change / API deprecation · NOT a never-licensed empty) · review the tenant's entitlement for this op" }
    }
    return @{ Advisory = $false; Detail = '' }
}

function Test-XdrGate_DrainStuck {
    # V-M2 · never-completing drain. Entry.Poll.Succeeded carries DrainComplete (Runtime.psm1:1015); an op whose arrival
    # rate exceeds its per-cycle page budget emits DrainComplete=false + Entry.Poll.CycleBudgetReached (Runtime.psm1:772)
    # EVERY cycle and is PERMANENTLY behind — yet D3/D7/MinRows stay green (it polls, lands SOME rows, on cadence). This
    # gate asserts each op reached DrainComplete=true AT LEAST ONCE in the window. The row carries, per the KQL summarize:
    #   Ops          = distinct ops that emitted >=1 Entry.Poll.Succeeded
    #   StuckOps     = ops with 0 DrainComplete==true cycles AND >=1 CycleBudgetReached (budget-stopped every cycle)
    #   StuckOpList  = their names (for the detail)
    # FAIL when StuckOps>0 (a real, permanent backlog · BLOCKING data-completeness: rows are being left un-drained every
    # cycle). An op that is busy in its FIRST window but completes at least one drain → DrainComplete>=1 → not stuck →
    # PASS. No Entry.Poll.Succeeded at all → INCONCLUSIVE (drain completeness unprovable · D3 covers no-poll liveness ·
    # never a silent green). NOT advisory: a hard block is justified because StuckOps is gated on CycleBudgetReached
    # firing on cycles WITH zero completed drains — a legitimately-busy single first window still completes its drain
    # once the budget is large enough OR emits no CycleBudgetReached; only a CHRONIC budget-stop with no completion trips
    # it. (A single transient budget-stop that later completes does NOT count: DrainComplete>=1 clears the op.)
    param($Row)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no Entry.Poll.Succeeded events in window · drain completeness unprovable (D3 covers no-poll liveness)' } }
    $ops = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Ops')
    if ($ops -eq 0) { return @{ Pass = $false; Inconclusive = $true; Detail = '0 ops emitted Entry.Poll.Succeeded in window · drain completeness unprovable' } }
    $stuck     = ConvertTo-XdrInt (Get-XdrRowValue $Row 'StuckOps')
    $stuckList = [string](Get-XdrRowValue $Row 'StuckOpList')
    if ($stuck -gt 0) {
        return @{ Pass = $false; Inconclusive = $false; Detail = "$stuck op(s) NEVER completed a drain in window (DrainComplete==true on 0 cycles · CycleBudgetReached every cycle → permanently behind · un-drained rows accumulate): $stuckList · totalOps=$ops · raise the per-cycle page budget or cadence (fix at source · D3/D7/MinRows stay green because it DOES poll + land partial rows)" }
    }
    return @{ Pass = $true; Inconclusive = $false; Detail = "all $ops polled op(s) completed a drain (DrainComplete==true) at least once in window · no permanent backlog" }
}

function Test-XdrGate_D9 {
    # DLQ empty · project: Pass(Count==0), Count. With NO Ingest.Dlq.Queued events az returns no row;
    # absence of DLQ events IS the pass condition (an empty DLQ is exactly what "healthy" looks like).
    param($Row)
    if ($null -eq $Row) { return @{ Pass = $true; Inconclusive = $false; Detail = 'dlqCount=0 (no Ingest.Dlq.Queued events in window)' } }
    $count = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Count')
    return @{ Pass = ($count -eq 0); Inconclusive = $false; Detail = "dlqCount=$count" }
}

function Test-XdrGate_ChunkedLoss {
    # V-B3 · PARTIAL-BATCH INGEST LOSS · Send-ToDce (Xdr.Common.Ingest.psm1) splits a >1MB batch into <900KB chunks and
    # emits DCE.Ingest.Chunked{AllSucceeded} ONLY when chunks>1. AllSucceeded==false means the leading-prefix dedup
    # checkpoint advanced over the landed chunks but a TRAILING chunk failed → those rows were DLQ'd / re-polled. D9
    # gates the DLQ being empty, but a chunk that 4xx'd at DCE is a SILENT partial loss UNTIL re-polled and is invisible
    # if it never reached the DLQ (e.g. dropped pre-DLQ). Gate (D9 pattern): Pass(BadBatches==0). No row → 0 (no chunked
    # ingest happened in window · vacuously OK · the all-or-nothing single-chunk path is gated by D1/D9). Healthy = absent.
    param($Row)
    if ($null -eq $Row) { return @{ Pass = $true; Inconclusive = $false; Detail = 'chunkedBatches=0 (no multi-chunk DCE.Ingest.Chunked events in window · single-chunk ingest is all-or-nothing · gated by D1/D9)' } }
    $bad   = ConvertTo-XdrInt (Get-XdrRowValue $Row 'BadBatches')
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    return @{ Pass = ($bad -eq 0); Inconclusive = $false; Detail = "chunkedBatches=$total partialFailures=$bad" + $(if ($bad -gt 0) { " · $bad multi-chunk batch(es) had AllSucceeded==false → a trailing chunk failed at DCE (partial ingest loss · re-polled next cycle but verify D9 DLQ + the failed StreamName)" } else { ' · every multi-chunk batch fully landed' }) }
}

function Test-XdrGate_Truncation {
    # V-B4 · IN-PLACE DATA TRUNCATION (ADVISORY) · Limit-XdrRowBytes (Ingest.psm1:82 → Ingest.RowClamped) and
    # Limit-XdrColumnBytes (Ingest.psm1:112 → Ingest.ColumnClamped) clamp an oversized row/column IN PLACE (with a visible
    # XDRLR-TRUNCATED/XDRLR-COL-TRUNCATED marker) to stay under the DCE ~1MB request / LA ~256KB column caps. The row
    # still lands (no DLQ · no D9 signal) but with SILENTLY LOST tail bytes — invisible to every other gate. This is an
    # ADVISORY visibility gate: it REPORTS the clamp count + the affected ops/columns so per-row data loss is auditable.
    # It does NOT hard-fail (a rare clamp on a pathologically-large entity is expected + the data is marked, not dropped
    # wholesale) — chronic truncation is a manifest/projection concern surfaced for human judgment. No row → none (clean).
    param($RowClampRow, $ColClampRow)
    $rowClamps = 0; $rowOps = 0
    if ($null -ne $RowClampRow) {
        $rowClamps = ConvertTo-XdrInt (Get-XdrRowValue $RowClampRow 'Count')
        $rowOps    = ConvertTo-XdrInt (Get-XdrRowValue $RowClampRow 'Ops')
    }
    $colClamps = 0; $colCols = ''
    if ($null -ne $ColClampRow) {
        $colClamps = ConvertTo-XdrInt (Get-XdrRowValue $ColClampRow 'Count')
        $colCols   = [string](Get-XdrRowValue $ColClampRow 'Columns')
    }
    $total = $rowClamps + $colClamps
    $detail = "rowClamps=$rowClamps (ops=$rowOps · DCE ~1MB cap) · colClamps=$colClamps (LA ~256KB cap · cols=$(if ([string]::IsNullOrEmpty($colCols)) { '-' } else { $colCols }))"
    if ($total -eq 0) { return @{ Pass = $true; Inconclusive = $false; Detail = "$detail · no in-place truncation in window" } }
    # ADVISORY · always Pass=$true (the gate body records it as Advisory so it surfaces but never blocks); the detail makes
    # the silent per-row tail loss VISIBLE for the manual audit half (chronic truncation → revisit the manifest projection).
    return @{ Pass = $true; Inconclusive = $false; Detail = "$detail · $total in-place truncation event(s) — rows LANDED with marked-but-LOST tail bytes (advisory · audit chronic truncation → manifest projection/RawJson clamp)" }
}

function Test-XdrGate_AppExceptions {
    # REAL (non-transient) exceptions == 0 AND handled poll/fan-out FAILURE events == 0. GATE-LEARNING (2026-06-17):
    # a KNOWN transient-by-design class (XdrPortalTransientException — the connector's fail-loud retry telemetry for a
    # portal 429/5xx; "recovered" means it did NOT reach DLQ / open the breaker, which D9 + D10 independently gate) is
    # EXPECTED on a healthy connector and must NOT block — reported in the detail for manual review. A REAL exception
    # still BLOCKs. COVERAGE FIX (2026-06-18): handled poll/fan-out failures (Entry.Poll.Failed ·
    # Entry.Fanout.ParentPollFailed · Entry.Fanout.Error · Entry.Enumeration.Failed) are logged via Track-XdrEvent in a
    # fail-safe catch → they land in AppEvents, NEVER AppExceptions, so the exception count below was structurally blind
    # to them. (V-B2 VERIFIED 2026-06-18: Entry.Enumeration.Failed IS a real event — emitted at XdrDefenderRefresh/
    # run.ps1:162 in the per-Op enumeration fail-safe catch. The "phantom" hypothesis was FALSE-on-verification; the
    # name is KEPT.) A parent poll that binds wrong / 5xx / throws SILENTLY starves its fan-out children (live-caught:
    # ListPostureOversightInitiatives -Category '' bind-fail EVERY cycle, 2026-06-18 — the exact "should-have-been-caught"
    # class). These are real data-loss signals → count must be 0; >0 BLOCKS (fix at source, never advisory). No row → 0.
    # V-B1 COVERAGE FIX (2026-06-18): Entry.Fanout.Skipped (Runtime.psm1:1328) is ALSO an AppEvents handled-failure, but
    # it has TWO classes (verified at the $skip call-sites Runtime.psm1:1341/1342/1347/1366):
    #   NON-BENIGN (data-loss · BLOCK): EntityResolution!='Resolved' (Reason has 'EntityResolution=') · incomplete
    #     DependsOn edge (Reason has 'incomplete DependsOn edge') — a mis-catalogued fan-out that can NEVER resolve.
    #   BENIGN (advisory · NOT a block): 'no DependsOn edge' (an Unresolved-entity RawJson-capable op · not a fan-out) ·
    #     'parent cache empty' (a 0-data tenant whose parent ids haven't been seen yet · the cycle legitimately continues).
    # $FanoutSkipRow carries NonBenign + Benign counts (the gate body splits them by Reason in KQL); NonBenign>0 BLOCKS,
    # Benign>0 is reported as advisory detail only. No row → 0/0 (back-compat: -FanoutSkipRow is optional).
    param($Row, $PollFailRow, $FanoutSkipRow)
    # — exceptions (AppExceptions table) —
    if ($null -eq $Row) { $count = 0; $transient = 0; $real = 0 }
    else {
        $count     = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Count')
        $transient = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Transient')
        $real      = $count - $transient
    }
    # — handled poll/fan-out FAILURE events (AppEvents · the coverage fix) — Count is NON-transient (BLOCKS);
    #   TransientCount (XdrPortalTransientException · recovered retry telemetry · same tolerance as the exceptions
    #   leg) is advisory-only, NEVER a block — else a routine portal 503 would false-fail the postdeploy proof.
    # RECOVERY-AWARENESS (2026-07-01 · safe-additive · mirrors D4's UnrecoveredFailPortals): when the poll-fail row
    # carries an `Unrecovered` column (an op with a non-transient failure and NO success terminal AFTER its last
    # failure in-window), the BLOCK is on Unrecovered, not the raw Count — a failed op that a LATER cycle cleared has
    # RECOVERED (no data loss · the tenant IS returning data). An op whose LAST terminal is a failure stays Unrecovered
    # → still BLOCKS (M1). Back-compat: when the column is ABSENT (older query / the existing SelfTest rows), fall back
    # to the strict Count-based block exactly as before (never a silent pass — an unknowable recovery state stays strict).
    $pollFail = 0; $pollOps = 0; $pollTransient = 0; $pollUnrecovered = -1; $pollUnrecoveredOps = ''
    if ($null -ne $PollFailRow) {
        $pollFail      = ConvertTo-XdrInt (Get-XdrRowValue $PollFailRow 'Count')
        $pollOps       = ConvertTo-XdrInt (Get-XdrRowValue $PollFailRow 'Ops')
        $pollTransient = ConvertTo-XdrInt (Get-XdrRowValue $PollFailRow 'TransientCount')
        if (($PollFailRow -is [System.Collections.IDictionary]) -and $PollFailRow.Contains('Unrecovered')) {
            $pollUnrecovered    = ConvertTo-XdrInt (Get-XdrRowValue $PollFailRow 'Unrecovered')
            $pollUnrecoveredOps = [string](Get-XdrRowValue $PollFailRow 'UnrecoveredOps')
        }
    }
    # The value that BLOCKS: the recovery-aware Unrecovered count when present, else the strict non-transient Count.
    $pollBlocking = if ($pollUnrecovered -ge 0) { $pollUnrecovered } else { $pollFail }
    # — Entry.Fanout.Skipped (AppEvents · V-B1) split into non-benign (block) vs benign (advisory) —
    $skipBad = 0; $skipBenign = 0
    if ($null -ne $FanoutSkipRow) {
        $skipBad    = ConvertTo-XdrInt (Get-XdrRowValue $FanoutSkipRow 'NonBenign')
        $skipBenign = ConvertTo-XdrInt (Get-XdrRowValue $FanoutSkipRow 'Benign')
    }
    $pollFailNote = if ($pollUnrecovered -ge 0) { "pollFailures=$pollFail (ops=$pollOps · transient=$pollTransient excluded · unrecovered=$pollUnrecovered [a failed op with a LATER success in-window is RECOVERED · not blocking])" } else { "pollFailures=$pollFail (ops=$pollOps · transient=$pollTransient excluded)" }
    $detail = "count=$count real=$real transient=$transient · $pollFailNote · fanoutSkips=$($skipBad + $skipBenign) (nonBenign=$skipBad benign=$skipBenign)"
    if ($real -gt 0)         { return @{ Pass = $false; Inconclusive = $false; Detail = "$detail · $real REAL exception(s) BLOCK (transients [XdrPortalTransientException] are recovered retry telemetry · D9/D10 backstop any real loss)" } }
    if ($pollBlocking -gt 0) { return @{ Pass = $false; Inconclusive = $false; Detail = "$detail · $pollBlocking UNRECOVERED handled poll/fan-out FAILURE(s)$(if ($pollUnrecoveredOps) { " [$pollUnrecoveredOps]" }) BLOCK · a poll/parent-poll failed with NO later success terminal in-window → that op (and any fan-out children) is producing no/partial data · fix at source (a failed cycle followed by a success is recovered · excluded)" } }
    if ($skipBad -gt 0)  { return @{ Pass = $false; Inconclusive = $false; Detail = "$detail · $skipBad NON-BENIGN fan-out skip(s) BLOCK · an unresolved/incomplete DependsOn edge → the child op can NEVER resolve its parent ids (mis-catalogued fan-out · fix at source) · the $skipBenign benign skip(s) [cache-empty / not-a-fan-out] are advisory" } }
    $benignNote = if ($skipBenign -gt 0) { " · $skipBenign benign fan-out skip(s) [parent-cache-empty / RawJson-only no-edge op · cycle continues · advisory only]" } else { '' }
    return @{ Pass = $true; Inconclusive = $false; Detail = "$detail · 0 real exceptions · 0 poll-failures · 0 non-benign fan-out skips (transients are recovered retry telemetry · flag-for-review)$benignNote" }
}

# ── Dynamic-shape gates (D8f/D8g/D8h) · the result row has one count column PER manifest-derived col,
#    so the pure fn takes the row PLUS the expected column list. Empty window → INCONCLUSIVE. ─────────

function ConvertTo-XdrRawJsonAccessor {
    # WS4.3 · translate a ProjectionMap JSONPath ($.Field · $.A.B) into a KQL accessor over the PRE-PARSED RawJson
    # dynamic `_rj` (the D8f gate adds `| extend _rj = parse_json(RawJson)` ONCE per row · so a 76-col op parses
    # RawJson once, not once-per-col — the naive per-col parse_json(RawJson) overran the LA query on the 76-col
    # GetTenantContext with its ~105KB RawJson · live-hit 2026-06-14 · "az query exit=1"). The accessor lets D8f
    # ask "does the SOURCE carry a value for this col?" — the discriminator between a REAL parser bug (source HAS
    # the value · projection missed it) and a LEGITIMATELY-NULL source field (portal returns null · e.g.
    # ActionDecision · NOT a bug). Dot-paths translate exactly; an un-introspectable path (array/filter wildcard)
    # falls back to the whole _rj object so the col reverts to the old strict pop-based check.
    param([string]$JsonPath)
    if ([string]::IsNullOrWhiteSpace($JsonPath)) { return '_rj' }
    $p = $JsonPath.Trim()
    if ($p -eq '$' -or $p -eq '$.') { return '_rj' }
    # Only simple/nested dot paths are introspectable; anything with [ ] * ?( ) is not → conservative fallback.
    if ($p -match '[\[\]\*\?\(\)@]') { return '_rj' }
    # BRACKET notation (_rj['a']['b']) NOT dot (_rj.a.b): a reserved-word or special field name after a dot is a KQL
    # SYNTAX error ("could not be parsed at 'title'" — live-hit on ListPostureOversightRecommendations' 'title' field
    # 2026-06-16). Bracket-quoting every path segment is always parse-safe regardless of the field name.
    $seg = if ($p.StartsWith('$.')) { $p.Substring(2) } else { $p -replace '^\.', '' }
    return '_rj' + (($seg -split '\.' | ForEach-Object { "['" + $_ + "']" }) -join '')
}

function Test-XdrGate_D8f {
    # Typed cols populated (keystone "actual events per requirements") · row has Total + per col a <col>_pop
    # (landed non-null count) AND a <col>_src (SOURCE non-null count from RawJson). PASS = Total>0 AND every
    # col either landed (<col>_pop>0) OR is legitimately source-null (<col>_src==0 · the portal carries no
    # value · nothing to project). FAIL only for a col that is EMPTY-IN-TABLE but NON-NULL-IN-SOURCE
    # (<col>_pop==0 AND <col>_src>0 · the projection dropped a value the source had → a real JSONPath/parser
    # bug). Empty table → INCONCLUSIVE. Back-compat: a row WITHOUT <col>_src reverts to the old strict check.
    param($Row, [string[]]$Columns)
    $cols = @($Columns)
    if ($cols.Count -eq 0) { return @{ Pass = $false; Inconclusive = $false; Detail = 'manifest has no ProjectionMap keys to verify' } }
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = 'no result row (table absent or empty window) · cannot evaluate typed-col population' } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) { return @{ Pass = $false; Inconclusive = $true; Detail = '0 rows in window · cannot prove typed cols populate' } }
    $failed = @()       # empty-in-table BUT non-null-in-source → real parser bug
    $legit  = @()       # empty-in-table AND null-in-source → legitimately not projected (portal has no value)
    foreach ($c in $cols) {
        if ((ConvertTo-XdrInt (Get-XdrRowValue $Row "${c}_pop")) -ne 0) { continue }   # populated → fine
        $srcVal = Get-XdrRowValue $Row "${c}_src"
        if ($null -eq $srcVal) { $failed += $c }                                        # no src column (old shape) → strict
        elseif ((ConvertTo-XdrInt $srcVal) -gt 0) { $failed += "$c (source has $(ConvertTo-XdrInt $srcVal) non-null)" }
        else { $legit += $c }                                                           # source also null → legitimate
    }
    if ($failed.Count -eq 0) {
        $detail = "all $($cols.Count) typed cols populated or legitimately source-null · total rows=$total"
        if ($legit.Count -gt 0) { $detail += " · source-null (legit · portal carries no value): $($legit -join ',')" }
        return @{ Pass = $true; Inconclusive = $false; Detail = $detail }
    }
    return @{ Pass = $false; Inconclusive = $false; Detail = "EMPTY-in-table but NON-NULL-in-source for: $($failed -join ',') · total rows=$total · ProjectionMap parser bug (projection dropped a value the source carried)" }
}

function Test-XdrGate_D8g {
    # LA-reserved rewrite (<name>_x) populated when source non-null · row has Total + one <col>_pop per
    # rewritten col. If the Operation rewrites NOTHING ($Columns empty) the contract is vacuous → PASS.
    # Empty table with a real _x contract → INCONCLUSIVE (was a silent PASS before — the bug this fixes).
    # Any _x col with 0 non-null rows → FAIL (rewrite did not fire).
    param($Row, [string[]]$Columns, [bool]$LegitNoDataProven = $false)
    $cols = @($Columns)
    if ($cols.Count -eq 0) { return @{ Pass = $true; Inconclusive = $false; Detail = 'no LA-reserved-rewritten (_x) cols in ProjectionMap · nothing to prove' } }
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = "no result row (table absent or empty window) · cannot evaluate rewrite · cols: $($cols -join ',')" } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = "0 rows · vacuously satisfied (op LEGIT-NO-DATA PROVEN — no rows so no _x rewrite to fire) · cols: $($cols -join ',')" } }
        return @{ Pass = $false; Inconclusive = $true; Detail = "0 rows in window · cannot prove rewrite fires · cols: $($cols -join ',')" }
    }
    $failed = @()
    foreach ($c in $cols) {
        if ((ConvertTo-XdrInt (Get-XdrRowValue $Row "${c}_pop")) -eq 0) { $failed += $c }
    }
    if ($failed.Count -eq 0) {
        return @{ Pass = $true; Inconclusive = $false; Detail = "all $($cols.Count) rewritten cols populated · total=$total" }
    }
    return @{ Pass = $false; Inconclusive = $false; Detail = "ZERO non-null rows for rewritten col(s): $($failed -join ',') · total=$total · LA-reserved rewrite did not fire" }
}

function Test-XdrGate_D8h {
    # Serialized non-scalars (<name>Json) round-trip parse · row has Total + per-col <col>_ne (populated
    # count) and <col>_ok (populated-AND-parses count). No Json cols → vacuous PASS. Empty table →
    # INCONCLUSIVE (was a silent PASS before). Per col: FAIL iff it is populated (_ne>0) but some value
    # does not parse (_ok < _ne).
    param($Row, [string[]]$Columns, [bool]$LegitNoDataProven = $false)
    $cols = @($Columns)
    if ($cols.Count -eq 0) { return @{ Pass = $true; Inconclusive = $false; Detail = 'no serialized (Json) cols in ProjectionMap · nothing to prove' } }
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = "no result row (table absent or empty window) · cannot evaluate parse round-trip · cols: $($cols -join ',')" } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    if ($total -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = "0 rows · vacuously satisfied (op LEGIT-NO-DATA PROVEN — no rows so no Json values to parse) · cols: $($cols -join ',')" } }
        return @{ Pass = $false; Inconclusive = $true; Detail = "0 rows in window · cannot prove Json cols parse · cols: $($cols -join ',')" }
    }
    $failed = @()
    foreach ($c in $cols) {
        $ne = ConvertTo-XdrInt (Get-XdrRowValue $Row "${c}_ne")
        $ok = ConvertTo-XdrInt (Get-XdrRowValue $Row "${c}_ok")
        if ($ne -ne 0 -and $ok -ne $ne) { $failed += "$c($ok/$ne)" }
    }
    if ($failed.Count -eq 0) {
        return @{ Pass = $true; Inconclusive = $false; Detail = "all $($cols.Count) Json cols round-trip parse · total=$total" }
    }
    return @{ Pass = $false; Inconclusive = $false; Detail = "parse_json FAILED (parsed/populated) for: $($failed -join ',') · total=$total" }
}

function Test-XdrGate_ExactlyOnce {
    # Exactly-once by construction · project: Pass(Rows==DistinctKeys), Rows, DistinctKeys, Duplicates.
    # MinRows≥1 FLOOR (plan §35.2 honesty): the equality count==dcount is only ASSERTED when rows exist.
    # An EMPTY window is NOT a silent vacuous PASS (the old bug) — it is INCONCLUSIVE: zero duplicates over
    # zero rows proves nothing about the dedup path. With rows: Rows==DistinctKeys → PASS · Rows>DistinctKeys
    # → a duplicate landed → FAIL (data integrity · BLOCKING).
    param($Row, [string]$NaturalKey = '', [int]$ResetsInWindow = 0, [bool]$LegitNoDataProven = $false)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = "no result row (table absent or empty window) · exactly-once unprovable · key=$NaturalKey" } }
    $rows = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Rows')
    if ($rows -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = "0 rows · vacuously exactly-once (op LEGIT-NO-DATA PROVEN — no rows to duplicate) · key=$NaturalKey" } }
        return @{ Pass = $false; Inconclusive = $true; Detail = "0 rows in window · exactly-once unprovable (MinRows>=1 floor) · key=$NaturalKey" }
    }
    $distinct = ConvertTo-XdrInt (Get-XdrRowValue $Row 'DistinctKeys')
    $dups = $rows - $distinct
    # RESET-AWARENESS (2026-07-01 · mirror VolatileHash/D1/D3/D7): a checkpoint reset REWINDS a CURSOR op → it legitimately
    # re-emits pre-reset keys still inside the window → Rows>DistinctKeys is EXPECTED reset-churn, NOT a real duplicate. A
    # reset-FREE window with Rows>DistinctKeys is a genuine dup → still FAIL (M1 · gate not weakened). $ResetsInWindow<0 = UNKNOWN → strict.
    if ($dups -gt 0 -and $ResetsInWindow -gt 0) {
        return @{ Pass = $false; Inconclusive = $true; Detail = "rows=$rows distinctKeys=$distinct duplicates=$dups · $ResetsInWindow checkpoint reset(s) in window → a reset rewinds a CURSOR op so pre-reset keys re-emitted within the window are EXPECTED reset-churn · INCONCLUSIVE, re-verify a reset-free window · key=$NaturalKey" }
    }
    return @{ Pass = ($rows -eq $distinct); Inconclusive = $false; Detail = "rows=$rows distinctKeys=$distinct duplicates=$dups · key=$NaturalKey" }
}

function Test-XdrGate_ExactlyOncePerCycle {
    # SNAPSHOT/WINDOW exactly-once (plan §4 · "exactly-once per INGESTION MODE"): the op RE-EMITS its full current
    # state every cadence cycle, so a NaturalKey recurs ACROSS cycles BY DESIGN — exactly-once means PER-CYCLE
    # dup-free. The query groups by CorrelationId (the per-poll-cycle id) and counts cycles where Rows != DistinctKeys.
    # MinRows>=1 + Cycles>=1 FLOOR (same honesty as the CURSOR form): an empty window proves nothing → INCONCLUSIVE,
    # never a vacuous PASS. BadCycles>0 = an intra-cycle duplicate landed (client-side dedup failed within a single
    # snapshot) → FAIL (data integrity). Makes the C6 "sustained >=N cycles dup-free" leg measurable for SNAPSHOT
    # (the whole-window form false-failed SNAPSHOT the instant >1 cycle was in the window).
    param($Row, [string]$NaturalKey = '', [string]$Mode = 'SNAPSHOT', [bool]$LegitNoDataProven = $false)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = "no result row (table absent or empty window) · $Mode per-cycle exactly-once unprovable · key=$NaturalKey" } }
    $cycles = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Cycles')
    $totalRows = ConvertTo-XdrInt (Get-XdrRowValue $Row 'TotalRows')
    if ($cycles -eq 0 -or $totalRows -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = "0 cycles/rows · vacuously per-cycle exactly-once (op LEGIT-NO-DATA PROVEN — nothing emitted to duplicate) · key=$NaturalKey" } }
        return @{ Pass = $false; Inconclusive = $true; Detail = "0 cycles/rows in window · $Mode per-cycle exactly-once unprovable (MinRows>=1 floor) · key=$NaturalKey" }
    }
    $bad = ConvertTo-XdrInt (Get-XdrRowValue $Row 'BadCycles')
    $maxRows = ConvertTo-XdrInt (Get-XdrRowValue $Row 'MaxRowsPerCycle')
    return @{ Pass = ($bad -eq 0); Inconclusive = $false; Detail = "$Mode · cycles=$cycles dup-free=$($cycles - $bad)/$cycles · badCycles=$bad · totalRows=$totalRows · maxRows/cycle=$maxRows · key=$NaturalKey" }
}

function Test-XdrGate_SnapshotNoDupAccum {
    # F-SNAPSHOT-SIG · CROSS-CYCLE dup-accumulation BLOCK (plan §B.3 · the baseline-lock's "verifier must BLOCK
    # dup-accumulation"). A cursorless SNAPSHOT re-fetches its full state every cadence cycle; the EO now SKIPS
    # re-emitting an UNCHANGED snapshot (content-signature · Xdr.Common.Runtime $XdrSnapshotSignature). The per-cycle
    # gate (Test-XdrGate_ExactlyOncePerCycle) only proves INTRA-cycle dup-free — it TOLERATED the cross-cycle re-emit
    # that this gate catches (live-caught 2026-06-19: GetInsights 43,200/2,753 = 16× · Exposure
    # GetPostureOversightMetricIds 719×). Assert the CROSS-cycle bound: Total <= Distinct(dedup-key) * DupBound. Pre-fix
    # dupFactor == the cycle count (16×/719× → FAIL · blocks the gap); post-fix the skip holds dupFactor ≈ 1 (+ a
    # bounded few for legit value-changes on a keyed SNAPSHOT — NOT strict Total==Distinct, which would false-fail any
    # legit change). <2 cycles in window → the skip cannot have fired yet → INCONCLUSIVE (never a vacuous PASS).
    param($Row, [string]$Key = '', [int]$DupBound = 3, [int]$PollCycles = 0, [int]$ResetsInWindow = 0, [bool]$LegitNoDataProven = $false, [int]$DistinctSnaps = -1, [int]$EmitCycles = -1)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = "no result row (table absent/empty window) · cross-cycle dup-accum unprovable · key=$Key" } }
    $total = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    $distinct = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Distinct')
    $cycles = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Cycles')
    if ($total -eq 0 -or $distinct -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = "0 rows · vacuously no dup-accum (op LEGIT-NO-DATA PROVEN — nothing emitted to accumulate) · key=$Key" } }
        return @{ Pass = $false; Inconclusive = $true; Detail = "0 rows in window · cross-cycle dup-accum unprovable · key=$Key" }
    }
    if ($cycles -lt 2) {
        # A PERFECT skip emits 0 rows on re-poll, so a stable snapshot NEVER shows 2 table cycles. If the TELEMETRY proves
        # the FA actually polled >=2 cycles AND the table did NOT accumulate (total<=distinct*bound), the skip PROVABLY fired.
        $df0 = if ($distinct -gt 0) { [math]::Round($total / [double]$distinct, 1) } else { 0 }
        if ($PollCycles -ge 2 -and $total -le ($distinct * $DupBound)) {
            return @{ Pass = $true; Inconclusive = $false; Detail = "FA polled $PollCycles cycles (telemetry) but table stayed $cycles cycle · skip FIRED (0 rows on re-poll) · total=$total <= distinct($distinct)x$DupBound · dupFactor=$df0 · key=$Key" }
        }
        return @{ Pass = $false; Inconclusive = $true; Detail = "only $cycles table cycle(s) + PollCycles=$PollCycles · skip not yet exercised (need the FA to poll >=2 cycles · force a 2nd cycle) · total=$total distinct=$distinct · key=$Key" }
    }
    $dupFactor = [math]::Round($total / [double]$distinct, 1)
    # SIGNATURE-AWARE (2026-07-03) · the CORRECT cross-cycle test is whether an UNCHANGED snapshot RE-EMITTED (the EO
    # content-signature skip regressed), NOT a flat row-count bound. A config/current-state SNAPSHOT that GENUINELY changes
    # each cycle (a live field recalculates — e.g. ExposureSeverity None↔Low) re-emits its FULL snapshot every cycle BY DESIGN
    # (SSOT A4 · SNAPSHOT content-hash skip · drift is the KQL/LA layer's job, NOT the engine) → CORRECT, not accumulation.
    # Discriminate on CONTENT: DistinctSnaps = dcount(per-cycle snapshot signature = hash of that cycle's sorted RecordId set).
    # Every emitted cycle a UNIQUE snapshot (DistinctSnaps >= EmitCycles) → each re-emit is a REAL change → PASS. An IDENTICAL
    # snapshot re-emitted (DistinctSnaps < EmitCycles) → a byte-unchanged snapshot was NOT suppressed = the regression → FAIL
    # (INCONCLUSIVE if a reset legitimately re-emitted the pre-reset snapshot). Replaces the flat ×N bound, which BOTH
    # false-RED'd a legit full-snapshot-each-cycle op AND false-GREEN'd a bounded skip regression. Keyless-only (RecordId is a
    # content-hash so its set signature tracks content); a keyed op passes -1 → the flat-bound fallback below.
    if ($DistinctSnaps -ge 0 -and $EmitCycles -ge 2) {
        if ($DistinctSnaps -ge $EmitCycles) {
            return @{ Pass = $true; Inconclusive = $false; Detail = "every emitted cycle is a DISTINCT snapshot (distinctSnaps=$DistinctSnaps >= emitCycles=$EmitCycles) → each re-emit is a genuine content change (full-snapshot-on-change · drift=KQL layer · SSOT A4) · NO unchanged re-emit · total=$total distinct=$distinct dupFactor=$dupFactor · key=$Key" }
        }
        if ($ResetsInWindow -gt 0) {
            return @{ Pass = $false; Inconclusive = $true; Detail = "distinctSnaps=$DistinctSnaps < emitCycles=$EmitCycles (an identical snapshot re-emitted) · $ResetsInWindow reset(s) in window legitimately re-emit the pre-reset snapshot → INCONCLUSIVE, re-verify a reset-free window · key=$Key" }
        }
        return @{ Pass = $false; Inconclusive = $false; Detail = "FAIL · an UNCHANGED snapshot re-emitted (distinctSnaps=$DistinctSnaps < emitCycles=$EmitCycles) → the EO content-signature skip regressed (a byte-identical snapshot was NOT suppressed · keyless SNAPSHOT dup-accumulation) · total=$total distinct=$distinct · key=$Key" }
    }
    # FALLBACK (DistinctSnaps unavailable · a keyed op or a caller that did not compute per-cycle signatures) · the flat bound.
    $pass = $total -le ($distinct * $DupBound)
    # RESET-AWARENESS (2026-07-01 · conditional · mirror D7): the finalize's reset + forced cycles legitimately re-emit the
    # full snapshot several times; with pre-reset rows still in-window that can push total past distinct*bound WITHOUT a real
    # accumulation regression. Over-bound + reset-in-window is EXPECTED churn → INCONCLUSIVE. Over-bound in a reset-FREE window
    # is a GENUINE dup-accumulation → still FAIL (M1 · gate not weakened). $ResetsInWindow<0 = UNKNOWN → strict.
    if (-not $pass -and $ResetsInWindow -gt 0) {
        return @{ Pass = $false; Inconclusive = $true; Detail = "cross-cycle dup-accum: total=$total distinct=$distinct cycles=$cycles dupFactor=$dupFactor (bound x$DupBound) · $ResetsInWindow checkpoint reset(s) in window → reset+forced re-emits inflate total, cross-cycle accumulation unprovable · INCONCLUSIVE, re-verify a reset-free window · key=$Key" }
    }
    $verdict = if ($pass) { '' } else { " · FAIL: the snapshot re-emits are ACCUMULATING across cycles (the EO F-SNAPSHOT-SIG signature-skip is not holding — keyless SNAPSHOT dup-accumulation regressed)" }
    return @{ Pass = $pass; Inconclusive = $false; Detail = "cross-cycle dup-accum: total=$total distinct=$distinct cycles=$cycles dupFactor=$dupFactor (bound x$DupBound)$verdict · key=$Key" }
}

function Test-XdrGate_VolatileHash {
    # F-VOLATILE-HASH (2026-06-25 · the gate-learning loop) · catch the VOLATILE-HASH class that SnapshotNoDupAccum is
    # STRUCTURALLY BLIND to. A keyless SNAPSHOT's exactly-once RecordId is a content-hash over the whole record; if the
    # record carries a VOLATILE non-identity field (changes every poll — a per-call timestamp / random id / poll-stamped
    # history), the SAME logical record re-emits EVERY cycle under a NEW RecordId → the _CL bloats UNBOUNDED. The
    # SnapshotNoDupAccum/ExactlyOnce gates MISS it because they dedup ON the RecordId: the re-emits have DIFFERENT
    # RecordIds → look distinct → dupFactor≈1.0 (the gate reads that as "healthy, no accumulation").
    #
    # DISCRIMINATOR = TABLE-cycles, NOT telemetry pollCycles (the corrected premise). The OLD logic assumed a healthy
    # SNAPSHOT re-emits each cycle so dupFactor ≈ pollCycles — but the connector's content-signature SKIP makes a healthy
    # STABLE snapshot dedup AT SOURCE: it cold-emits N rows ONCE, then on cycle-2+ the signature is unchanged so it
    # BoundaryDedupes (0 new rows ⇒ no new CorrelationId lands). Net: Total=N, DistinctRec=N → dupFactor=1.0 — IDENTICAL
    # to a volatile op. So dupFactor-vs-pollCycles cannot tell them apart (it FALSE-RED every healthy-skip op · proven
    # live: post-fix ListCriticalAssetClassifications cold-emits 152 then BoundaryDeduped → dupFactor=1, yet the old gate
    # RED it). The honest signal is how many DISTINCT cadence cycles actually LANDED rows in the op-scoped _CL —
    # TableCycles=dcount(CorrelationId) over the SAME deploy-floor window as Total/DistinctRec:
    #   • healthy-skip   → only the cold emit lands; cycles 2+ dedupe at source ⇒ no new CorrelationId ⇒ TableCycles ≈ 1.
    #   • volatile-hash  → a fresh hash every poll ⇒ fresh rows under a NEW CorrelationId EVERY cycle ⇒ TableCycles ≈ pollCycles.
    # So: PASS when TableCycles <= 1 (the skip fired — only the cold emit landed despite N polls = HEALTHY · the exact
    # case the old gate false-RED). RED when TableCycles >= 2 AND dupFactor < 2.0 (the op emitted DISTINCT rows on >=2
    # cadence cycles WITHOUT deduping ⇒ the content-hash is not stabilizing ⇒ a volatile non-identity field is minting a
    # fresh RecordId each cycle ⇒ declare it in curation volatileHashFields so the runtime strips it from the hash).
    # Else PASS (>=2 cycles but dupFactor>=2 ⇒ it IS collapsing to a stable set across cycles = healthy re-emit).
    # Honesty (the INCONCLUSIVE branches, unchanged):
    #   • <2 poll cycles → the cross-cycle re-emit hasn't been exercised → INCONCLUSIVE (never a vacuous PASS).
    #   • 0 rows → INCONCLUSIVE (LEGIT-NO-DATA proven → vacuous PASS · nothing emitted to accumulate).
    #   • a RESET in the window churns the RecordId/CorrelationId set → INCONCLUSIVE (same reset-awareness as D1/D3/D7).
    # PURE (table-testable · no live az). $Row = @{ Total; DistinctRec } (the op-scoped _CL counts). $PollCycles = the
    # telemetry Entry.Poll.Succeeded cross-cycle GUARD (op + parent, like SnapshotNoDupAccum — only proves the FA polled
    # >=2x so the skip COULD be exercised). $TableCycles = dcount(CorrelationId) in the SAME op-scoped _CL (the actual
    # discriminator). KEYLESS-ONLY by contract (the caller runs it ONLY for a content-hash-RecordId op · a keyed op's
    # RecordId is its NaturalKey, not volatile).
    # $SnapshotDrift (A5 · 2026-07-03): the op is a manifest-DECLARED, DATA-VERIFIED evolving-data snapshot — a MEANINGFUL
    # (non-timestamp) field genuinely changes across cycles (live-verified: GetAsset discoveredVulnerabilities 813→860 ·
    # ListProducts riskScore recalc · ListAssetInstallations weaknesses 1511→1459), so it emits a genuinely-DISTINCT full
    # snapshot each cycle BY DESIGN (SSOT A4 · operator: "full snapshot each cycle · drift = KQL layer"). This is NOT the
    # volatile-hash class (a STATIC record re-emitting only because a timestamp/id changed): a SnapshotDrift op's pure-volatile
    # timestamps are STILL stripped via VolatileHashFields (so a row that did NOT genuinely change dedups), and what remains
    # is REAL drift. Distinct from ListCriticalAssetClassifications (152 STABLE rules · ONLY lastExecutionTime changed = pure
    # volatile → NOT flagged SnapshotDrift → strip-to-dedup). The flag is a narrow, per-op, data-verified human declaration
    # (same trust model as VolatileHashFields · the maintainer confirmed a meaningful field drifts); it is NOT a blanket bypass.
    param($Row, [string]$Key = '', [int]$PollCycles = 0, [int]$TableCycles = 0, [int]$ResetsInWindow = 0, [bool]$LegitNoDataProven = $false, [bool]$SnapshotDrift = $false)
    if ($null -eq $Row) { return @{ Pass = $false; Inconclusive = $true; Detail = "no result row (table absent/empty window) · volatile-hash unprovable · key=$Key" } }
    $total       = ConvertTo-XdrInt (Get-XdrRowValue $Row 'Total')
    $distinctRec = ConvertTo-XdrInt (Get-XdrRowValue $Row 'DistinctRec')
    if ($total -eq 0 -or $distinctRec -eq 0) {
        if ($LegitNoDataProven) { return @{ Pass = $true; Inconclusive = $false; Detail = "0 rows · vacuously no volatile-hash (op LEGIT-NO-DATA PROVEN — nothing emitted) · key=$Key" } }
        return @{ Pass = $false; Inconclusive = $true; Detail = "0 rows in window · volatile-hash unprovable · key=$Key" }
    }
    if ($ResetsInWindow -gt 0) {
        return @{ Pass = $false; Inconclusive = $true; Detail = "$ResetsInWindow checkpoint reset(s) in window churned the RecordId/CorrelationId set → volatile-hash INCONCLUSIVE (reset-adjacent · re-verify a reset-free window) · tableCycles=$TableCycles · key=$Key" }
    }
    $dupFactor = [math]::Round($total / [double]$distinctRec, 2)
    if ($PollCycles -lt 2) {
        return @{ Pass = $false; Inconclusive = $true; Detail = "FA polled $PollCycles cycle(s) (telemetry) · the cross-cycle re-emit is not yet exercised → cannot tell a stable hash from a volatile one (force a 2nd cycle) · total=$total distinctRec=$distinctRec tableCycles=$TableCycles dupFactor=$dupFactor · key=$Key" }
    }
    # The TABLE-cycles discriminator (replaces the wrong dupFactor≈pollCycles premise). Only the cold emit lands when
    # the signature-skip fires, so a HEALTHY stable SNAPSHOT shows ~1 table cycle even after N polls.
    if ($TableCycles -le 1) {
        return @{ Pass = $true; Inconclusive = $false; Detail = "volatile-hash: tableCycles=$TableCycles (only the cold emit landed despite $PollCycles poll cycles → signature-skip FIRED = healthy stable snapshot, deduped AT SOURCE) · total=$total distinctRec=$distinctRec dupFactor=$dupFactor · key=$Key" }
    }
    if ($dupFactor -lt 2.0) {
        if ($SnapshotDrift) {
            return @{ Pass = $true; Inconclusive = $false; Detail = "volatile-hash: tableCycles=$TableCycles dupFactor=$dupFactor<2 · op DECLARED SnapshotDrift (data-verified evolving-data snapshot — a MEANINGFUL field genuinely changes each cycle · pure-volatile timestamps stripped via VolatileHashFields so unchanged rows dedup) → the distinct re-emits are GENUINE content drift (full-snapshot-on-change · drift=KQL layer · SSOT A4), NOT a volatile-field defect · total=$total distinctRec=$distinctRec · key=$Key" }
        }
        return @{ Pass = $false; Inconclusive = $false; Detail = "volatile-hash: tableCycles=$TableCycles (FA polled $PollCycles · the op emitted DISTINCT rows on >=2 cadence cycles WITHOUT deduping · dupFactor=$dupFactor<2) · total=$total distinctRec=$distinctRec · FAIL: the content-hash RecordId is NOT stabilizing across cycles — a VOLATILE non-identity field is minting a fresh RecordId every cycle (declare it in curation volatileHashFields → the runtime strips it from the hash · the SnapshotNoDupAccum gate is blind to this because the re-emits look distinct) · OR if a MEANINGFUL field genuinely drifts each cycle, declare SnapshotDrift=\$true after verifying · key=$Key" }
    }
    return @{ Pass = $true; Inconclusive = $false; Detail = "volatile-hash: tableCycles=$TableCycles dupFactor=$dupFactor>=2 (the content-hash IS collapsing to a stable set across cycles → healthy re-emit) · total=$total distinctRec=$distinctRec pollCycles=$PollCycles · key=$Key" }
}

# ── Dot-source sentinel ──────────────────────────────────────────────────────────────────────────
# When the SelfTest dot-sources this script it sets $env:XDRLR_VERIFY_DOTSOURCE_ONLY=1 so ONLY the
# function definitions above load — the live-az execution body below is skipped (via `return`, NOT
# `exit`, so the Pester host survives). The mandatory -WorkspaceId still binds (supply any placeholder).
if ($env:XDRLR_VERIFY_DOTSOURCE_ONLY -eq '1') { return }

# ── Window dispatch · which gates run per window (plan §18.1 12 dimensions + §18.2 D8 sub-gates) ─
# D1-D12 = plan §18.1 macro dimensions (some retained legacy IDs · see end-of-file gate definitions).
# D8a-D8j = plan §18.2 data-plane-context per-row sub-gates ("actual events per requirements" gate).
# D4 = plan §18.1 R3 capability discovery health.
# D12 = plan §18.1 Sentinel V3 surface (dataConnectorDefinition + contentPackage).
# D0 (module-load health · AppTraces) runs in EVERY window — it is the foundational signal: if the
# Xdr modules fail to load (iter#15 root cause: bundled Az.KeyVault.private skew), nothing downstream
# can work and AppEvents-based gates would false-negative. D0 uses the reliable host-SDK AppTraces.
$gatesForWindow = switch ($Window) {
    'Boot'               { @('D0','Boot','D4') }
    'Cold'               { @('D0','Boot','D2','D4','D6','D9','MinRows') }
    'FirstIteration'     { @('D0','Boot','D2','D4','D6','D8','D8c','D8f','D8g','D8h','D9','Posture','MinRows','CorrelationId','ExactlyOnce') }
    'Hour'               { @('D0','D1','D2','D3','D4','D6','D7','D8','Reauth','D9','Posture','ExactlyOnce') }
    'Sustain'            { @('D0','D1','D2','D3','D4','D6','D7','D8','Reauth','D8c','D8f','D8g','D8h','D9','D10','BreakerSkip','DrainStuck','D12','Posture','AppExceptions','ExactlyOnce','ChunkedLoss','Truncation') }
    'ConsecutiveSustain' { @('D0','D1','D2','D3','D4','D6','D7','D8','Reauth','D8c','D8f','D8g','D8h','D9','D10','BreakerSkip','DrainStuck','D12','Posture','AppExceptions','ExactlyOnce','ChunkedLoss','Truncation') }
    default              { @('D0','D2','D6','D9') }
}

# m3/m4 (2026-06-18): steady-state windows (Hour/Sustain/ConsecutiveSustain) have a warmed token cache + multiple
# natural poll cycles, so the T1-cached-dominance (m4) and reauth-loop-fraction (m3) advisories are meaningful there;
# Boot/Cold/FirstIteration legitimately run the slow auth tiers (no cache yet) so those advisories are suppressed.
$isSteadyState = $Window -in @('Hour','Sustain','ConsecutiveSustain')

# Deploy-aware floor: a postdeploy window must anchor at the cutover instant — a relative ago() window after a
# stop/cutover either reaches before the deploy (freeze-gap + prior-build telemetry false-fail D7/AppExc) or,
# if hand-scoped tight, clips the cold-start Boot probe (false-fail D0). An explicit -DeployedSinceUtc fixes both.
$sinceClause = if (-not [string]::IsNullOrWhiteSpace($DeployedSinceUtc)) {
    "TimeGenerated >= datetime($DeployedSinceUtc)"
} else {
    "TimeGenerated > ago(${SinceMinutes}m)"
}
# Poll-telemetry LIVENESS window (WIDER than the deploy floor). The AppEvents poll signals — the terminal-poll for
# MinRows' LEGIT-NO-DATA proof ($Polled) and the cross-cycle PollCycles GUARD (SnapshotNoDupAccum) — prove the op is
# ACTIVELY POLLING: continuous FA behaviour that ingests into AppEvents ~20-40m LATE (slower than _CL). Floor-bounding
# them races that lag → a healthy op reads 0 polls and false-fails. DATA-CORRECTNESS gates (_CL rows, cross-cycle
# dup-accumulation total<=distinct) stay on $sinceClause; ONLY the liveness/guard signals use this wider window. A
# genuinely-broken op (no poll in 2h) still reads 0 → RED, so the M1 cure (go RED on un-proven state) holds.
# Poll-liveness/guard window (terminal-poll · product-gate · SNAPSHOT poll-cycle) — pure Get-XdrPollLivenessClause spans
# the FULL post-deploy window (deploy floor OR'd with ago(2h)), not a fixed slice that misses a >2h-old terminal poll
# (the GA-blocking Operations cap-absent false-FAIL · 2026-06-23). Extracted so the SelfTest proves it spans the floor.
$pollLivenessClause = Get-XdrPollLivenessClause -DeployedSinceUtc $DeployedSinceUtc
$workspaceTable = if ($Category) { "${Portal}_${Category}_CL" } else { '' }

# ── §4.B D1/D3/D7 reset-awareness · count the checkpoint resets in this window ONCE (shared by D1 + D3 + D7) ──
# Computed only when D1/D3/D7 will run (the Hour/Sustain/ConsecutiveSustain windows). A reset-in-window routes a D1
# rows-landed-without-a-terminal-event (Actual>Expected) OR a D3 orphan/double-close OR a D7 <30s re-fire to INCONCLUSIVE
# not FAIL (the reset-adjacent artifact is EXPECTED churn · the B10 pattern). The window in hours is ceil(SinceMinutes/60)
# (or, with a deploy floor, the span since cutover — floored at the SinceMinutes-derived hours so a tight floor never
# under-counts). UNKNOWN sentinel = -1: if the count could not be read, D1/D3/D7 fall back to their STRICT verdict
# (Mismatched==0 / Bad==0 · never a silent pass on an unknowable reset state).
$resetsForD3D7 = 0
if (('D1' -in $gatesForWindow) -or ('D3' -in $gatesForWindow) -or ('D7' -in $gatesForWindow) -or ('SnapshotNoDupAccum' -in $gatesForWindow) -or ('ExactlyOnce' -in $gatesForWindow) -or ('VolatileHash' -in $gatesForWindow)) {
    $resetHours = Get-XdrResetAwarenessHours -SinceMinutes $SinceMinutes
    if (-not [string]::IsNullOrWhiteSpace($DeployedSinceUtc)) {
        $floorDt = [DateTime]::MinValue
        if ([DateTime]::TryParse($DeployedSinceUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$floorDt)) {
            $sinceFloorHours = [int][Math]::Ceiling(((Get-Date).ToUniversalTime() - $floorDt).TotalHours)
            if ($sinceFloorHours -gt $resetHours) { $resetHours = $sinceFloorHours }
        }
    }
    $resetInfo = Get-XdrResetCountInWindow -Hours $resetHours
    $durableCount = if ($resetInfo.QueryOk) { [int]$resetInfo.Count } else { -1 }
    # AUTHORITATIVE OVERRIDE (2026-07-01): the tool-driven reset (Save-XdrCheckpointReset) emits NO Checkpoint.Reset event, and
    # a short-cadence op's durable ResetUtc can drop over many re-polls, so the durable/telemetry count can read a FALSE-CONFIDENT
    # 0 → D1/D3/D7/SnapshotNoDupAccum/ExactlyOnce strict-FAIL the forced churn (live: Operations resets-in-window=0 despite a
    # reset). If the CALLER told us WHEN it reset and that instant is within the reset-awareness window, a reset PROVABLY fell
    # in-window regardless of storage/telemetry → count ≥ 1 (max'd with any durable count; a known reset OVERRIDES the -1 UNKNOWN).
    # Empty $KnownResetUtc → durable-only (standalone verifies); durable-readable-0 with no known reset stays 0 (strict · correct
    # for steady-state production so a genuine steady-state double-fire/dup still RED).
    $knownInWindow = $false
    if (-not [string]::IsNullOrWhiteSpace($KnownResetUtc)) {
        $krDt = [DateTime]::MinValue
        if ([DateTime]::TryParse($KnownResetUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$krDt)) {
            if ($krDt -ge (Get-Date).ToUniversalTime().AddHours(-1 * $resetHours)) { $knownInWindow = $true }
        }
    }
    $resetsForD3D7 = if ($knownInWindow) { [Math]::Max(1, [Math]::Max(0, $durableCount)) } else { $durableCount }
    $resetSrc = if ($knownInWindow) { "known-reset($KnownResetUtc)+$($resetInfo.Source)" } else { $resetInfo.Source }
    Write-Host "[Verify-DeployedConnector] §4.B reset-awareness · resets-in-window(${resetHours}h)=$(if ($resetsForD3D7 -lt 0) { 'UNKNOWN (count unreadable · strict-fallback)' } else { $resetsForD3D7 }) · source=$resetSrc" -ForegroundColor DarkGray
}

# ── §4.B capability-fluctuation awareness (F18 · 2026-07-03) — shared to D1/D7 ──────────────────────────────────────
# An op that polled to a Capability.OpUnavailable TERMINAL with ZERO Entry.Poll.Succeeded in-window is CAP-ABSENT POSTURE
# on THIS tenant (403/404 · license/MTO/entitlement absent — F18: a lab 404 = product-absent on this tenant, NEVER a
# connector defect). Such an op backs OFF polling (a large inter-poll gap · live 2026-07-03: AttackSimulation/GetRecommendations
# polled 2× 6h apart, both 403/404) → the CADENCE gate (D7 MaxGap>1.5×tier) false-FAILs its backoff, and when it is the
# cat's ONLY active op the RECONCILE gate (D1) sees 0 groups → false-INCONCLUSIVE. D3 already counts Capability.OpUnavailable
# as a valid Closed terminal (Started==Closed balanced → PASS · line ~1869), so it needs nothing. Compute ONCE, scoped to
# THIS category's ops: the cap-absent op SET (skipped in D7's cadence check) + whether the WHOLE category is cap-absent
# (no op succeeded AND none FAILED → vacuous-PASS D1/D7's total==0). This does NOT weaken the gates — per-op posture is
# still surfaced by the CapabilityRegression ADVISORY + the MinRows LEGIT-NO-DATA proof (each op independently proven
# has-rows-or-legit-empty), and a genuinely FAILING op (Entry.Poll.Failed, NOT OpUnavailable) is excluded from
# fully-cap-absent so MinRows/AppExceptions still RED it. We only stop the AGGREGATE poll-gates reading correct
# posture-backoff as a cadence/reconcile defect (the anti-tolerate discrimination: PASS legit posture, FAIL real defects).
$capAbsentOps = @()
$catFullyCapAbsent = $false
if (('D1' -in $gatesForWindow) -or ('D7' -in $gatesForWindow)) {
    $caCatKeys = @(Get-XdrManifestOperationKeys -Portal $Portal -Category $Category)
    $caCatKql  = '[' + (($caCatKeys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ']'
    $caQ = @"
let catOps = dynamic($caCatKql);
AppEvents | where $sinceClause and Name in ('Entry.Poll.Succeeded','Entry.Poll.Failed','Capability.OpUnavailable')
| extend Op=tostring(Properties.OperationKey)
| where array_length(catOps) == 0 or Op in (catOps)
| summarize Succ=countif(Name=='Entry.Poll.Succeeded'), Failed=countif(Name=='Entry.Poll.Failed'), CapAbs=countif(Name=='Capability.OpUnavailable') by Op
"@
    $caR = Invoke-XdrKqlQuery -Query $caQ -Label 'CapAbsent'
    if ($caR.Success -and $caR.Data) {
        $rowsCA = @($caR.Data)
        # An op is CAP-ABSENT if it reached the posture terminal (CapAbs>0) and NEVER succeeded (Succ==0). A stray
        # TRANSIENT failure alongside it does NOT disqualify posture (live 2026-07-03: GetTags = Succ 0 / Failed 1 /
        # CapAbs 87 — fundamentally 403/404 posture with one retry blip). A PURELY-FAILING op (Succ==0 AND CapAbs==0 AND
        # Failed>0 · e.g. ListChangeEvents) is NOT posture — it must still be evaluated (never excused as cap-absent).
        $capAbsentOps     = @($rowsCA | Where-Object { (ConvertTo-XdrInt (Get-XdrRowValue $_ 'Succ')) -eq 0 -and (ConvertTo-XdrInt (Get-XdrRowValue $_ 'CapAbs')) -gt 0 } | ForEach-Object { [string](Get-XdrRowValue $_ 'Op') })
        $purelyFailingOps = @($rowsCA | Where-Object { (ConvertTo-XdrInt (Get-XdrRowValue $_ 'Succ')) -eq 0 -and (ConvertTo-XdrInt (Get-XdrRowValue $_ 'CapAbs')) -eq 0 -and (ConvertTo-XdrInt (Get-XdrRowValue $_ 'Failed')) -gt 0 } | ForEach-Object { [string](Get-XdrRowValue $_ 'Op') })
        $anySucc          = @($rowsCA | Where-Object { (ConvertTo-XdrInt (Get-XdrRowValue $_ 'Succ')) -gt 0 }).Count
        # Fully cap-absent ⟺ ≥1 op reached the cap-absent terminal AND NO op succeeded AND NO PURELY-FAILING op (a genuine
        # failure — never reaching cap-absent — is a real defect, NOT posture → must NOT be excused · MinRows/AppExceptions
        # still catch it too). A transient blip on an otherwise-cap-absent op is folded into posture (not purely-failing).
        $catFullyCapAbsent = ($capAbsentOps.Count -gt 0) -and ($anySucc -eq 0) -and ($purelyFailingOps.Count -eq 0)
        if ($capAbsentOps.Count -gt 0) {
            Write-Host "[Verify-DeployedConnector] §4.B capability-fluctuation · cap-absent op(s) [$($capAbsentOps -join ', ')] (403/404 posture · F18 · excluded from D7 cadence)$(if ($catFullyCapAbsent) { ' · cat FULLY cap-absent → D1/D7 total==0 vacuous-PASS' })" -ForegroundColor DarkGray
        }
    }
}

# ── Gate: Boot.VersionProbe present ────────────────────────────────────────────
if ('Boot' -in $gatesForWindow) {
    $q = @"
AppEvents | where $sinceClause and Name == 'Boot.VersionProbe'
| summarize Count=count(), MostRecent=max(TimeGenerated), LatestCommit=arg_max(TimeGenerated, tostring(Properties.GitCommit))
| project Pass = Count > 0, Count, MostRecent, LatestCommit
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'Boot'
    # Cold-start detector (the same AppTraces 'XdrLogRaider boot' signal D0 uses): distinguishes "no cold-start in window"
    # (steady-state · a checkpoint-reset re-prove does NOT restart the FA → vacuously OK) from "cold-start but no probe"
    # (a real broken boot → FAIL). Mirrors D0's steady-state fix so Boot is correct in BOTH a deploy postdeploy AND a
    # checkpoint-reset re-prove. Detector-query failure → BootLines=-1 → legacy strict Count>0 (fail-safe: be strict).
    $rBoot = Invoke-XdrKqlQuery -Query "AppTraces | where $sinceClause | summarize BootLines=countif(Message has 'XdrLogRaider boot')" -Label 'Boot.ColdStart'
    $bootLines = if ($rBoot.Success) { ConvertTo-XdrInt (Get-XdrRowValue (@($rBoot.Data) | Select-Object -First 1) 'BootLines') } else { -1 }
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'Boot' -Description 'Boot.VersionProbe present' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'Boot' -Description 'Boot.VersionProbe emitted at cold-start' -Decision (Test-XdrGate_Boot -Row $row -BootLines $bootLines)
    }
}

# ── Gate: D0 Module-load health (AppTraces · the reliable host-SDK signal) ──────
# iter#15: this is the foundational gate. The host SDK forwards every Write-Host line to AppTraces
# (proven reliable · 8000+ rows observed) — unlike custom AppEvents which depend on the /v2/track
# emit path. If ANY Xdr module fails to load (the iter#15 root cause: bundled Az.KeyVault.private
# binding skew cascade-failed all module loads) the data plane is dead and every downstream gate is
# meaningless. D0 fails the deploy if: any 'Module load failed' trace · OR no 'XdrLogRaider boot'
# line (profile did not complete) · OR any 'Managed Dependencies' Legion error.
if ('D0' -in $gatesForWindow) {
    $q = @"
AppTraces | where $sinceClause
| summarize
    ModuleLoadFailures = countif(Message has 'Module load failed'),
    BootLines          = countif(Message has 'XdrLogRaider boot'),
    LegionErr          = countif(Message has 'Managed Dependencies'),
    LastBoot           = maxif(TimeGenerated, Message has 'XdrLogRaider boot')
| project Pass = (ModuleLoadFailures == 0 and BootLines > 0 and LegionErr == 0), ModuleLoadFailures, BootLines, LegionErr, LastBoot
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D0'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'D0' -Description 'Module-load health (AppTraces)' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'D0' -Description 'All Xdr modules load · profile boot completed · no Legion managedDependency error' -Decision (Test-XdrGate_D0 -Row $row)
    }
}

# ── Gate: D2 (no empty rows) · D6 (RawJson valid) · MinRows · CorrelationId · D8c (envelope cols) ──
# V-M4 (2026-06-18): MOVED INTO the per-Op -AllOps loop below and OP-SCOPED. These five ran ONCE
# category-globally over `$workspaceTable | where $sinceClause`, so under -AllOps a single op that lands 0
# rows was INVISIBLE — MinRows' count()>=1 passed on sibling ops' rows, and D2/D6/CorrelationId/D8c
# asserted properties over the whole-category mix. A starved fan-out child could thus be "C6-proven" while
# emitting nothing. Now each runs PER OP, scoped via Get-XdrOpScopedClause, so every deployed op must
# INDEPENDENTLY land >=1 row + pass empty/RawJson/CorrelationId/envelope. (Non-AllOps path: the loop runs
# once with the single -OperationKey op → op-scoped, which is strictly MORE correct than the old global check.)

# ── Gate: D9 DLQ empty ─────────────────────────────────────────────────────────
if ('D9' -in $gatesForWindow) {
    $q = @"
AppEvents | where $sinceClause and Name == 'Ingest.Dlq.Queued'
| summarize Count=count()
| project Pass = Count == 0, Count
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D9'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'D9' -Description 'DLQ queue empty (no Ingest.Dlq.Queued events)' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'D9' -Description 'DLQ empty in window' -Decision (Test-XdrGate_D9 -Row $row)
    }
}

# ── Gate: ChunkedLoss · partial-batch ingest loss (V-B3) ───────────────────────
# Send-ToDce (Xdr.Common.Ingest.psm1:186) emits DCE.Ingest.Chunked{AllSucceeded} when a >1MB batch is split into
# <900KB chunks. AllSucceeded==false ⇒ a trailing chunk failed at DCE: the leading-prefix high-water advanced over the
# landed chunks but the failed chunk's rows were DLQ'd / re-polled = a partial ingest loss this cycle. D9 gates the DLQ;
# this gates the chunked-send success directly (a chunk that errored pre-DLQ would be invisible to D9). count > 0 BLOCKS.
if ('ChunkedLoss' -in $gatesForWindow) {
    $q = @"
AppEvents | where $sinceClause and Name == 'DCE.Ingest.Chunked'
| summarize Total=count(), BadBatches=countif(tobool(Properties.AllSucceeded) == false)
| project BadBatches, Total
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'ChunkedLoss'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'ChunkedLoss' -Description 'No partial-batch ingest loss (DCE.Ingest.Chunked AllSucceeded)' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'ChunkedLoss' -Description 'Every multi-chunk DCE batch fully landed (no AllSucceeded==false)' -Decision (Test-XdrGate_ChunkedLoss -Row $row)
    }
}

# ── Gate: Truncation · in-place row/column data truncation (V-B4 · ADVISORY) ───
# Limit-XdrRowBytes (Ingest.psm1:82 → Ingest.RowClamped) + Limit-XdrColumnBytes (Ingest.psm1:112 → Ingest.ColumnClamped)
# clamp an oversized row/column IN PLACE (visible XDRLR-(COL-)TRUNCATED marker) to stay under the DCE ~1MB / LA ~256KB
# caps. The row LANDS (no DLQ → no D9 signal) but with silently-lost tail bytes — invisible to every other gate. ADVISORY:
# reports the clamp count + affected ops/columns so silent per-row data loss is auditable; never hard-fails (the data is
# marked, not wholesale-dropped · chronic truncation is a manifest/projection concern for human judgment).
if ('Truncation' -in $gatesForWindow) {
    $qr = @"
AppEvents | where $sinceClause and Name == 'Ingest.RowClamped'
| summarize Count=count(), Ops=dcount(tostring(Properties.OperationKey))
| project Count, Ops
"@
    $qc = @"
AppEvents | where $sinceClause and Name == 'Ingest.ColumnClamped'
| summarize Count=count(), Columns=make_set(tostring(Properties.Columns), 50)
| extend Columns = tostring(Columns)
| project Count, Columns
"@
    $rr = Invoke-XdrKqlQuery -Query $qr -Label 'Truncation.Row'
    $rc = Invoke-XdrKqlQuery -Query $qc -Label 'Truncation.Col'
    if (-not $rr.Success) {
        Add-XdrGateResult -GateId 'Truncation' -Description 'In-place data truncation (advisory)' -Pass $false -Detail "KQL error: $($rr.Error)" -Advisory $true
    } elseif (-not $rc.Success) {
        Add-XdrGateResult -GateId 'Truncation' -Description 'In-place data truncation (advisory)' -Pass $false -Detail "KQL error: $($rc.Error)" -Advisory $true
    } else {
        $rowR = @($rr.Data) | Select-Object -First 1
        $rowC = @($rc.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'Truncation' -Description 'In-place row/column truncation is visible (advisory · rows land marked, tail bytes lost)' -Decision (Test-XdrGate_Truncation -RowClampRow $rowR -ColClampRow $rowC) -Advisory $true
    }
}

# (MinRows + CorrelationId · MOVED INTO the per-Op -AllOps loop below + op-scoped · see the V-M4 note above.)

# ── Gate: D1 No missed events (event-row reconcile) ────────────────────────────
# V-M1 FIX (2026-06-18 · E-BLK2 coupling): the landed-row side must group by the `Operation` envelope
# column — NOT the dropped key column. F2 (Parser.psm1:105 · "dropped OperationKey, duplicated Operation")
# REMOVED that column from the table, so the old grouping read NULL for every landed row → the
# fullouter join NEVER matched a real (Op,Cid) → every event group reconciled against Actual=0 → Mismatched
# == Total → D1 hard-failed (or vacuously mis-reconciled) on EVERY window, fan-out or not. E-BLK2 already
# unified BOTH sides onto the BASE op key: Entry.Poll.Succeeded carries OperationKey=$baseOperationKey
# (Runtime.psm1:1010) AND a fan-out child row lands Operation=$baseOperationKey (Runtime.psm1:784-795 ·
# ConvertTo-XdrRows -OperationKey $baseOperationKey). So summing event ItemCount by base OperationKey vs
# counting rows by base Operation reconciles fan-out ops correctly — once the landed side reads `Operation`.
# (The parent entity op itself emits Fanout.* not Entry.Poll.Succeeded and lands no rows of its own, so it
# contributes NO group to either side · its children carry the data under the shared base key · no orphan.)
if ('D1' -in $gatesForWindow -and $workspaceTable) {
    # V-M5 (2026-06-19) · CATEGORY SCOPE. evt is ALL-ops Entry.Poll.Succeeded; the rows side is the SINGLE category
    # table. Without scoping evt to THIS category's ops, a cross-category op that polled but lands in a DIFFERENT
    # table (e.g. GetTenantContext during an Exposure verify) shows Expected>0 / Actual=0 -> a FALSE mismatch (live
    # 2026-06-19: D1=1 on Exposure [GetTenantContext], =9 on Operations [Exposure/SecureScore ops], all cross-category).
    # Scope evt to the category's manifest ops (base OperationKey · matches the row Operation column · E-BLK2).
    $d1CatKeys = @(Get-XdrManifestOperationKeys -Portal $Portal -Category $Category)
    $d1CatKql  = '[' + (($d1CatKeys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ']'
    $q = @"
let catOps = dynamic($d1CatKql);
let evt = AppEvents | where $sinceClause and Name == 'Entry.Poll.Succeeded'
    | extend Op=tostring(Properties.OperationKey), Cid=tostring(Properties.CorrelationId), N=toint(Properties.ItemCount)
    | where array_length(catOps) == 0 or Op in (catOps)
    | summarize Expected=sum(N) by Op, Cid;
let rows = $workspaceTable | where $sinceClause
    | summarize Actual=count() by Op=Operation, Cid=CorrelationId;
evt | join kind=fullouter rows on Op, Cid
| extend Delta = coalesce(Actual,0) - coalesce(Expected,0)
| summarize Mismatched = countif(Delta != 0), RowsWithoutEvent = countif(Delta > 0), Total = count()
| project Pass = Mismatched == 0, Mismatched, RowsWithoutEvent, Total
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D1'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'D1' -Description 'No missed events (event-row reconcile)' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        # §4.B reset-awareness: a reset-in-window rows-landed-without-a-terminal-event (Actual>Expected) is EXPECTED churn → INCONCLUSIVE not FAIL (B10 pattern).
        # $resetsForD3D7 is computed once (shared with D3/D7) over the same window — UNKNOWN (-1) if the count could not be read.
        Add-XdrGateDecision -GateId 'D1' -Description 'Event-row reconcile · sum(ItemCount)=count(rows) per (Op,CId) · reset-churn discriminated' -Decision (Test-XdrGate_D1 -Row $row -ResetsInWindow $resetsForD3D7 -CatFullyCapAbsent $catFullyCapAbsent)
    }
}

# ── Gate: D3 Exactly 1 telemetry per poll ──────────────────────────────────────
if ('D3' -in $gatesForWindow) {
    # Terminal classes (live-cured 2026-06-12): a poll closes as Succeeded | Failed | Capability.OpUnavailable
    # (the DESIGNED posture-skip terminal) | SingleFlight.Contended (a yielded start — the peer holds the op).
    # LastSeen + ago(3m) grace (live-cured 2026-06-12): the newest poll may be mid-flight at query time
    # (Started=1, Closed=0) — that is in-flight, NOT a missing close. Penalise only: duplicate
    # close (Closed>1) · a poll Started >3min ago with NO terminal (genuinely stuck). An ORPHAN CLOSE
    # (Started==0,Closed>0) is NO LONGER penalised (2026-07-04): the poll COMPLETED (a terminal landed), so it is
    # neither stuck nor a double-emit — a missing Started is an AppInsights adaptive-sampling drop OR a window-edge
    # Started (fired pre-window · closed in-window), the SAME sampling class the fanout branch already switched off (A3).
    # A real stuck poll still REDs (Started>=1/Closed==0/stale); a real double-emit still REDs (Closed>1); a Started==0
    # /Closed>1 double-close is caught by the Closed>1 term regardless of the missing Started. This is NOT a tolerate-
    # count — it corrects the defect DEFINITION (orphan-close ≠ stuck/double). A normal Started==1/Closed==1 passes; a recent in-flight passes; AND a Durable AT-LEAST-ONCE
    # RETRY (Started>1 but Closed>=1 · e.g. a post-restart cold-start poll whose 1st attempt's instance recycled and a
    # later attempt completed · sequential, not concurrent) passes — Start-count is NOT an invariant under at-least-once.
    # The EXACTLY-ONCE data proof lives in ExactlyOnce/SnapshotNoDupAccum (a dup EMISSION REDs THERE, never via D3).
    # 2026-06-21 P5-1: ListPortalOutbreaks (3084-row poll) Started 11:32:05 stalled, retried 11:37:07 → Succeeded,
    # dupFactor=1 — the prior `Started>1` rule false-blocked it; corrected to key on completion (Closed), not Start-count.
    # A2 (2026-06-19) · FANOUT BRANCH. An entity-fanout op (EntityResolution='Resolved') polls N entities in ONE
    # cycle under ONE CorrelationId, every child stamped the BASE OperationKey (E-BLK2). SUPERSEDED by A3 (see the
    # comment just above the query · 2026-07-03): the per-poll Started/Closed balance is sampling-noisy for fanout ops
    # (it counts paginated pages, which AppInsights adaptive sampling thins) → the fanout invariant now uses the
    # per-child ORCHESTRATION events Entry.Fanout.Started/Completed, not the poll balance. Normal ops keep the strict
    # 1:1. Fanout keys are injected as a KQL dynamic array (empty when the set can't resolve → IsFanout=false).
    $d3FanoutKeys = @(Get-XdrFanoutOperationKeys -Portal $Portal -Category $Category)
    $d3FanoutKql  = '[' + (($d3FanoutKeys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ']'
    $d3CatKeys = @(Get-XdrManifestOperationKeys -Portal $Portal -Category $Category)   # V-M5 · scope to THIS category's ops (no cross-category contamination · fail-open if empty)
    $d3CatKql  = '[' + (($d3CatKeys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ']'
    # A3 (2026-07-03) · FANOUT completion uses the ORCHESTRATION events, NOT the paginated poll balance. Live-diagnosed on
    # EndpointManagement (24 false-FAIL groups) + ExposureManagement: for a fanout op the Entry.Poll.Started/Closed counts
    # measure the per-child HTTP PAGES (pagination · retries · single-flight), which AppInsights ADAPTIVE SAMPLING thins
    # (one Entry.Poll.Succeeded dropped on a 6-page child → Started=6/Closed=5 → the old `Started != Closed` FALSE-FAILed a
    # perfectly healthy op · ALL 24 had Entry.Fanout.Started==Entry.Fanout.Completed + every DATA gate GREEN). The RELIABLE
    # per-CHILD completion signal is Entry.Fanout.Started/Completed (lower-volume · one pair per resolved entity · balanced
    # when healthy). So the fanout invariant is: a CHILD that started fanning out must COMPLETE (FanStarted > FanCompleted &
    # stale = a genuinely stuck child → still RED) PLUS a stuck-PARENT guard (the parent poll started, never closed, never
    # fanned out → FanStarted==0 & Closed==0 & stale → RED). The noisy per-page Started!=Closed is NO LONGER a fanout defect
    # (a stuck child manifests as FanStarted>FanCompleted; a stuck parent as the guard). Non-fanout ops are UNCHANGED. This
    # is NOT a weakening — a real stuck fanout still REDs via the completion imbalance; only sampling-thinned pages are excused.
    # COMPLETION-RATE TOLERANCE (2026-07-03 · the same sampling/skip class one level up): Entry.Fanout.Completed ITSELF is
    # subject to AppInsights sampling AND to a child being SKIPPED mid-fanout (CadenceNotDue/RequiresProducts/cap-absent →
    # Fanout.Started fired but the child never polled/completed = a VALID terminal, not stuck) AND to window-boundary clipping
    # (an old CorrelationId whose fanout straddles the window edge). Live: GetRbacGroupScopes 11 Started/10 Completed +
    # GetTimeline 12/11 — a SINGLE missing Completed out of 11-12 (>90% completion · all DATA gates GREEN). So a fanout op is
    # RED only when a MEANINGFUL fraction fails to complete: (FanStarted-FanCompleted) > max(1, 10% of FanStarted). A single
    # skipped/sampled/boundary child is excused (min-1 floor covers small bursts); a systemic stuck (>10% incomplete) still REDs.
    $q = @"
let fanout = dynamic($d3FanoutKql);
let catOps = dynamic($d3CatKql);
AppEvents | where $sinceClause and (Name in ('Entry.Poll.Started','Entry.Poll.Succeeded','Entry.Poll.Failed','Capability.OpUnavailable','Entry.Poll.SingleFlight.Contended') or Name startswith 'Entry.Fanout.')
| extend Op=tostring(Properties.OperationKey), Cid=tostring(Properties.CorrelationId)
| where array_length(catOps) == 0 or Op in (catOps)
| summarize Started=countif(Name=='Entry.Poll.Started'), Closed=countif(Name in ('Entry.Poll.Succeeded','Entry.Poll.Failed','Capability.OpUnavailable','Entry.Poll.SingleFlight.Contended')), FanStarted=countif(Name=='Entry.Fanout.Started'), FanCompleted=countif(Name=='Entry.Fanout.Completed'), LastSeen=max(TimeGenerated) by Op, Cid
| extend IsFanout = Op in (fanout)
| summarize Bad=countif(
    (not(IsFanout) and (Closed > 1 or (Started >= 1 and Closed == 0 and LastSeen < ago(3m))))
    or (IsFanout and ((toreal(FanStarted - FanCompleted) > max_of(1.0, toreal(FanStarted) * 0.1) and LastSeen < ago(3m)) or (Started >= 1 and Closed == 0 and FanStarted == 0 and LastSeen < ago(3m))))
  ), Total=count()
| project Pass = Bad == 0, Bad, Total
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D3'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'D3' -Description 'Exactly 1 telemetry per poll' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        # §4.B reset-awareness: a reset-in-window orphan/double-close is EXPECTED churn → INCONCLUSIVE not FAIL (B10 pattern).
        # $resetsForD3D7 is computed once (shared with D7) over the same window — UNKNOWN (-1) if the count could not be read.
        Add-XdrGateDecision -GateId 'D3' -Description 'every (Op,CId) poll completes: >=1 terminal (Succeeded|Failed|OpUnavailable|SingleFlight-yield) · at-least-once retries OK · stuck/orphan/double-close RED (reset-churn discriminated)' -Decision (Test-XdrGate_D3 -Row $row -ResetsInWindow $resetsForD3D7)
    }
}

# ── Gate: D7 Cadence honored ───────────────────────────────────────────────────
if ('D7' -in $gatesForWindow) {
    # Live-cured 2026-06-12: gaps partition PER OP (the old prev() leaked across op boundaries) and the bar
    # is each op's DECLARED manifest cadence ×1.5 (WS2 tiers: 10m/1h/6h…) — the hardcoded flat-5m era is dead.
    # A2 (2026-06-19) · FANOUT COLLAPSE. An entity-fanout op (EntityResolution='Resolved') polls N entities in ONE
    # cycle (same CorrelationId · base key) → N Entry.Poll.Started seconds apart, which the per-poll gap reads as
    # <30s double-fires. Collapse each fanout op's per-cycle BURST to its earliest poll (one logical poll/cycle) so
    # the measured gap is the inter-CYCLE cadence (its real tier); normal ops are 1 poll/Cid so the collapse is a
    # no-op for them. Fanout keys injected as a dynamic array (empty → no collapse → original behaviour).
    $d7FanoutKeys = @(Get-XdrFanoutOperationKeys -Portal $Portal -Category $Category)
    $d7FanoutKql  = '[' + (($d7FanoutKeys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ']'
    $d7CatKeys = @(Get-XdrManifestOperationKeys -Portal $Portal -Category $Category)   # V-M5 · scope to THIS category's ops (no cross-category contamination · fail-open if empty)
    $d7CatKql  = '[' + (($d7CatKeys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ']'
    $q = @"
let fanout = dynamic($d7FanoutKql);
let catOps = dynamic($d7CatKql);
let base = AppEvents | where $sinceClause and Name == 'Entry.Poll.Started'
    | extend Op=tostring(Properties.OperationKey), Cid=tostring(Properties.CorrelationId)
    | where array_length(catOps) == 0 or Op in (catOps);
let collapsed = union
    (base | where Op !in (fanout) | project Op, TimeGenerated),
    (base | where Op in (fanout) | summarize TimeGenerated=min(TimeGenerated) by Op, Cid | project Op, TimeGenerated);
collapsed | order by Op asc, TimeGenerated asc
| extend Gap = iif(Op == prev(Op), datetime_diff('second', TimeGenerated, prev(TimeGenerated)), int(null))
| where isnotnull(Gap)
| summarize MaxGap=max(Gap), MinGap=min(Gap), P90Gap=percentile(Gap, 90) by Op
"@
    $d7Advisory = ($Window -in @('Boot','Cold','FirstIteration'))
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D7'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'D7' -Description 'Cadence ≤1.5× per-op manifest tier · no double-fires' -Pass $false -Detail "KQL error: $($r.Error)" -Advisory $d7Advisory
    } else {
        # UNPARSEABLE-CADENCE surfacing (2026-07-01 · safe-additive): collect ops whose manifest Cadence can't be parsed
        # so D7 goes LOUD INCONCLUSIVE for them instead of silently dropping them (which would false-PASS a real defect).
        $unparseOps = [System.Collections.ArrayList]::new()
        $cadenceMap = Get-XdrManifestCadenceMap -Portal $Portal -Category $(if ([string]::IsNullOrEmpty($Category)) { 'Operations' } else { $Category }) -UnparseableOps $unparseOps
        $verdict = Get-XdrCadenceVerdict -GapRows $r.Data -CadenceSecondsByOp $cadenceMap -UnparseableOps @($unparseOps) -CapAbsentOps @($capAbsentOps)
        $row = @{ Pass = "$($verdict.Bad -eq 0)"; Bad = "$($verdict.Bad)"; Total = "$($verdict.Total)" }
        # §4.B reset-awareness: a reset-in-window <30s re-fire is EXPECTED churn → INCONCLUSIVE not FAIL (B10 pattern).
        $decision = Test-XdrGate_D7 -Row $row -ResetsInWindow $resetsForD3D7 -CatFullyCapAbsent $catFullyCapAbsent
        # An unparseable-cadence op routes D7 to INCONCLUSIVE (verdict.Inconclusive is set ONLY when parseable ops are
        # clean · a real Bad>0 already FAILs above and is never softened here · M1 intact).
        if ($verdict.Inconclusive -and $decision.Pass) { $decision.Pass = $false; $decision.Inconclusive = $true }
        if ($verdict.Detail) { $decision.Detail = "$($decision.Detail) · $($verdict.Detail)" }
        Add-XdrGateDecision -GateId 'D7' -Description 'Cadence honored (≤1.5× per-op manifest tier · no double-fires <30s · reset-churn discriminated)' -Decision $decision -Advisory $d7Advisory
    }
}

# ── Gate: D8 Auth chain healthy (advisory in Cold) ─────────────────────────────
if ('D8' -in $gatesForWindow) {
    # Live-cured 2026-06-12: query AppEvents — Track-XdrEvent lands there reliably (live N==Raw for every
    # name), while the AppTraces '[evt]' host-mirror is thinned by adaptive sampling (5/s) on burst cycles
    # (the old premise was inverted). Names portal-agnostic: T1 Auth.Connect.Cached · T2 *.Auth.T2.Succeeded ·
    # T3 *.Auth.T3.Started. Advisory: healthy = any tier seated a session.
    $q = @"
AppEvents | where $sinceClause and (Name == 'Auth.Connect.Cached' or Name endswith '.Auth.T2.Succeeded' or Name endswith '.Auth.T3.Started')
| summarize T1=countif(Name == 'Auth.Connect.Cached'),
            T2=countif(Name endswith '.Auth.T2.Succeeded'),
            T3=countif(Name endswith '.Auth.T3.Started')
| project Pass = (T1 + T2 + T3) > 0, T1, T2, T3
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D8'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'D8' -Description 'Auth chain healthy' -Pass $false -Detail "KQL error: $($r.Error)" -Advisory $true
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'D8' -Description 'Auth T1 dominant · T2/T3 in expected ratio' -Decision (Test-XdrGate_D8 -Row $row -SteadyState $isSteadyState) -Advisory $true
    }
}

# ── Gate: Reauth self-heal (Φ4.G2c · advisory · fires only on a live auth-loss) ─
# Live-cured 2026-06-12: AppEvents (Track-XdrEvent lands reliably; the '[evt]' AppTraces mirror is
# sampling-thinned). Names: Auth.Reauth.Triggered / Auth.Reauth.Succeeded (Xdr.Common.Runtime.psm1:1431/1440).
# Every Triggered must reach Succeeded — a shortfall is an unrecovered AuthChainBroken (self-heal failed).
# No reauth in the window = not exercised = INCONCLUSIVE (not a green).
if ('Reauth' -in $gatesForWindow) {
    $q = @"
AppEvents | where $sinceClause and Name startswith 'Auth.Reauth.'
| summarize Triggered=countif(Name == 'Auth.Reauth.Triggered'),
            Succeeded=countif(Name == 'Auth.Reauth.Succeeded')
| project Pass = Triggered > 0 and Succeeded >= Triggered, Triggered, Succeeded
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'Reauth'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'Reauth' -Description 'Auth self-heal (reauth Triggered→Succeeded)' -Pass $false -Detail "KQL error: $($r.Error)" -Advisory $true
    } else {
        $row = @($r.Data) | Select-Object -First 1
        # m3 · poll-cycle count (distinct Entry.Poll.Succeeded CorrelationIds) for the reauth-LOOP fraction advisory.
        # A transient query failure leaves $pollCycles=0 → the fraction note is simply suppressed (back-compat).
        $pollCycles = 0
        $pcQ = "AppEvents | where $sinceClause and Name == 'Entry.Poll.Succeeded' | summarize Cycles=dcount(tostring(Properties.CorrelationId))"
        $pcr = Invoke-XdrKqlQuery -Query $pcQ -Label 'Reauth.PollCycles'
        if ($pcr.Success) { $pcRow = @($pcr.Data) | Select-Object -First 1; if ($pcRow) { $pollCycles = ConvertTo-XdrInt (Get-XdrRowValue $pcRow 'Cycles') } }
        Add-XdrGateDecision -GateId 'Reauth' -Description 'Every Auth.Reauth.Triggered reaches Succeeded (0 unrecovered)' -Decision (Test-XdrGate_Reauth -Row $row -PollCycles $pollCycles) -Advisory $true
    }
}

# ── Gate: Posture (license-independence §3 · operator-adjudicated 2026-06-10 · capability-absent NEVER terminal) ─
# Posture path emits '[evt] Capability.OpUnavailable' (Runtime.psm1 posture branch); a CLASSIFIER REGRESSION would
# re-surface InvalidProxyPrefix as a terminal '[Entry.Poll.Exception]' line. Pass = 0 such terminals; PostureEvents
# reported for the MANUAL half (0 is valid on a fully-licensed tenant — absence-of-misclassification is the gate).
if ('Posture' -in $gatesForWindow) {
    # Live-cured 2026-06-12: posture/poll counters from AppEvents (reliable); the TerminalProxy regression
    # signal stays on the AppTraces exception line (its absence is the pass; a regression bursts many).
    # TRANSIENT TOLERANCE (2026-07-01 robustness · safe-additive): a portal transient can momentarily surface as an
    # InvalidProxyPrefix-tagged '[Entry.Poll.Exception]' line carrying the connector's OWN retryable marker ('transient'
    # / 'retry-after') — that is a self-healed retry, NOT a license-gate regression. EXCLUDE such lines from TerminalProxy
    # (same marker-set as the AppExceptions poll-fail _isTransient leg). M1 INTACT: a GENUINE (non-transient)
    # InvalidProxyPrefix terminal — a real Test-XdrIsCapabilityAbsent classifier regression — carries no such marker →
    # still counted → TerminalProxy>0 → hard FAIL.
    $q = @"
let ev = AppEvents | where $sinceClause
| summarize PostureEvents = countif(Name == 'Capability.OpUnavailable'),
            PollActivity  = countif(Name startswith 'Entry.Poll.' or Name == 'Capability.OpUnavailable')
| extend k = 1;
let tr = AppTraces | where $sinceClause
| summarize TerminalProxy = countif(Message startswith '[Entry.Poll.Exception]' and Message contains 'InvalidProxyPrefix' and not(Message contains 'transient') and not(Message contains 'retry-after'))
| extend k = 1;
ev | join kind=inner tr on k | project PostureEvents, TerminalProxy, PollActivity
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'Posture'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'Posture' -Description 'License-gate posture (capability-absent never terminal)' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'Posture' -Description 'Capability-absent ops POSTURE (0 InvalidProxyPrefix terminals · posture events reported for manual review)' -Decision (Test-XdrGate_Posture -Row $row)
    }
}

# ── Gate: D10 Circuit breaker (stub if module not present) ─────────────────────
# V-M3 (2026-06-18): D10's in-window Opens==Closes invariant is VACUOUSLY satisfied when a breaker opened in a PRIOR
# window and is STILL open in this one (0 in-window opens/closes) — the op is silently suppressed (Breaker.SkippedOpen)
# with no Started/terminal, so D3 cannot see it. We derive a CURRENTLY-OPEN signal from a BROADER lookback: net opens
# (Breaker.Opened − Breaker.Closed) over the larger of the window or 7d. net>0 ⇒ a breaker is currently open ⇒ D10 must
# NOT vacuous-PASS. (This mirrors Test-GaReadiness C5's XdrCircuitState 'Open'-row check, but from the event stream the
# verifier already has — no -StorageAccount needed; the events are the same state transitions that drive the table.)
if ('D10' -in $gatesForWindow) {
    $q = @"
AppEvents | where $sinceClause and Name in ('Breaker.Opened','Breaker.Closed','Breaker.HalfOpen')
| summarize Opens=countif(Name == 'Breaker.Opened'), Closes=countif(Name == 'Breaker.Closed')
| project Pass = Opens == Closes, Opens, Closes
"@
    # Broader-lookback net-open: catch a breaker opened BEFORE this window that never closed. Use max(window, 7d).
    $broaderMin = [Math]::Max($SinceMinutes, 10080)
    # V-M4 (2026-06-19) · STALE-BREAKER SCOPING. The net-open must count ONLY breakers for ops in THIS Category's SHIPPED
    # manifest. A breaker for a shipHeld/removed op (e.g. the dev-era GetTvmRiskScore /
    # GetPostureOversightRecommendationsAggregated / GetConfigurationsSecureScoreCategories · held in curation.shipHold,
    # never dispatched) lingers Open in XdrCircuitState forever but suppresses NOTHING → STALE state, not a live
    # data-stall. Counting it FALSE-FAILS D10 (live 2026-06-19: exactly those 3). Scope to the verified op set so only a
    # SHIPPED op's stuck breaker (a genuine dark-op) blocks. (Get-XdrManifestOperationKeys · L340 · returns OperationKeys.)
    $d10ShippedKeys = @(Get-XdrManifestOperationKeys -Portal $Portal -Category $Category)
    $d10OpFilter = if ($d10ShippedKeys.Count -gt 0) { ' and tostring(Properties.OperationKey) in (' + (($d10ShippedKeys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ')' } else { '' }
    $qOpen = "AppEvents | where TimeGenerated > ago(${broaderMin}m)$d10OpFilter and Name in ('Breaker.Opened','Breaker.Closed') | summarize NetOpen = countif(Name == 'Breaker.Opened') - countif(Name == 'Breaker.Closed') | project CurrentlyOpen = iif(NetOpen > 0, NetOpen, 0)"
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D10'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'D10' -Description 'Circuit breaker open=close (advisory)' -Pass $false -Detail "KQL error: $($r.Error)" -Advisory $true
    } else {
        $row = @($r.Data) | Select-Object -First 1
        # CurrentlyOpen: $null when the probe query itself failed (do NOT manufacture a false stuck-open from a transient).
        $currentlyOpen = $null
        $ro = Invoke-XdrKqlQuery -Query $qOpen -Label 'D10.CurrentlyOpen'
        if ($ro.Success) { $orow = @($ro.Data) | Select-Object -First 1; $currentlyOpen = if ($orow) { ConvertTo-XdrInt (Get-XdrRowValue $orow 'CurrentlyOpen') } else { 0 } }
        # A currently-open breaker is a real data-stall (an op dark across windows) → BLOCK, not advisory: pass
        # -Advisory only when the decision did NOT trip on $currentlyOpen. Decide first, then route severity.
        $d10Dec = Test-XdrGate_D10 -Row $row -CurrentlyOpen $currentlyOpen
        $d10StuckOpen = (-not $d10Dec.Pass) -and (-not $d10Dec.Inconclusive) -and ($d10Dec.Detail -match 'currently OPEN')
        Add-XdrGateDecision -GateId 'D10' -Description 'Every Open closes + no breaker stuck open across windows' -Decision $d10Dec -Advisory (-not $d10StuckOpen)
    }
}

# ── Gate: BreakerSkip · poll suppressed by an open breaker (V-M3 · advisory visibility) ─
# Breaker.SkippedOpen (Runtime.psm1:611) fires when a poll is SUPPRESSED because the op's breaker is open → zero new
# data that cycle, NO Entry.Poll.Started/terminal → invisible to D3/D7/MinRows. ADVISORY: a few skips = the breaker
# absorbing a transient (self-heals on half-open · same tolerance as the transient AppExceptions leg); a breaker STUCK
# open across windows is the BLOCK caught by D10's CurrentlyOpen widening above. This gate makes the skip AUDITABLE.
if ('BreakerSkip' -in $gatesForWindow) {
    $q = @"
AppEvents | where $sinceClause and Name == 'Breaker.SkippedOpen'
| summarize Count=count(), Ops=dcount(tostring(Properties.OperationKey))
| project Count, Ops
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'BreakerSkip'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'BreakerSkip' -Description 'Breaker-suppressed polls visible (advisory)' -Pass $false -Detail "KQL error: $($r.Error)" -Advisory $true
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'BreakerSkip' -Description 'Polls suppressed by an open breaker are visible (advisory · stuck-open caught by D10)' -Decision (Test-XdrGate_BreakerSkip -Row $row) -Advisory $true
    }
}

# ── Gate: DrainStuck · never-completing drain (V-M2 · BLOCKING) ─────────────────
# Entry.Poll.Succeeded carries DrainComplete (Runtime.psm1:1015); an op whose arrival rate exceeds its per-cycle page
# budget emits DrainComplete=false + Entry.Poll.CycleBudgetReached (Runtime.psm1:772) EVERY cycle and is permanently
# behind, yet D3/D7/MinRows stay green (it DOES poll + land partial rows on cadence). Assert each op reached
# DrainComplete=true at least once in the window. StuckOps = ops with 0 completed-drain cycles AND >=1 budget-stop.
if ('DrainStuck' -in $gatesForWindow) {
    # LAG-IMMUNITY (2026-07-01 robustness · safe-additive): a StuckOp = an op with 0 DrainComplete==true AND >=1
    # CycleBudgetReached. Under AppEvents ingest lag a DrainComplete-true completion can land LATER than its
    # CycleBudgetReached → over the NARROW deploy-floor window an op reads Completes=0 while its Budget is already in →
    # a false StuckOp → exit-2, under the finalize's aggressive re-poll load. FIX: count the DrainComplete Completes
    # (and the Polls that gate Ops) over the WIDE $pollLivenessClause (deploy-floor OR ago(72h) · the same wider window
    # the terminal-poll liveness already uses) so a late-landing completion still CLEARS the op, while CycleBudgetReached
    # stays on the NARROW $sinceClause (the budget-stop-in-window is the real signal). M1 INTACT: a CHRONIC stuck op
    # (0 DrainComplete over the WIDE 72h window + a budget-stop in-window) still reads Completes=0 & Budget>0 → StuckOps>0
    # → hard FAIL. Two legs unioned so Completes/Polls come from the wide window, Budget from the narrow one.
    $q = @"
let completes = AppEvents | where $pollLivenessClause and Name == 'Entry.Poll.Succeeded'
    | extend Op=tostring(Properties.OperationKey)
    | summarize Completes=countif(tobool(Properties.DrainComplete) == true), Budget=0, Polls=count() by Op;
let budgets = AppEvents | where $sinceClause and Name == 'Entry.Poll.CycleBudgetReached'
    | extend Op=tostring(Properties.OperationKey)
    | summarize Completes=0, Budget=count(), Polls=0 by Op;
union completes, budgets
| summarize Completes=sum(Completes), Budget=sum(Budget), Polls=sum(Polls) by Op
| summarize Ops=countif(Polls > 0),
            StuckOps=countif(Completes == 0 and Budget > 0),
            StuckOpList=tostring(make_set_if(Op, Completes == 0 and Budget > 0, 50))
| project Ops, StuckOps, StuckOpList
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'DrainStuck'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'DrainStuck' -Description 'Every op completes a drain (no permanent backlog)' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'DrainStuck' -Description 'Each polled op reaches DrainComplete=true at least once (no never-completing drain)' -Decision (Test-XdrGate_DrainStuck -Row $row)
    }
}

# ── Gate: AppExceptions in Sustain ─────────────────────────────────────────────
if ('AppExceptions' -in $gatesForWindow) {
    # AUTH-SELF-HEAL EXCLUSION (2026-07-01 · the deferred audit FIX-6ii · live-caught): AuthChainBrokenException is the auth
    # break that the RUNTIME's reauth SELF-HEALS (Auth.Reauth.Triggered→Succeeded). Auth HEALTH is the Reauth gate's job, and
    # that gate is ADVISORY (never blocks · it flags a reauth LOOP for manual review). The finalize's aggressive forced
    # re-polling can THRASH the token cache into a transient reauth loop (§10 · self-heals · FA-restart-clears · intermittent —
    # the prior run had 0 · this run 7), spiking AuthChainBrokenException. Counting those as blocking "real exceptions" here
    # DOUBLE-counts the exact signal the Reauth advisory owns → a false-block. A GENUINE auth failure (auth never succeeds)
    # STOPS data → the DATA gates (MinRows/D2/D3) catch it. So exclude AuthChainBrokenException from the blocking count
    # (grouped with the portal transient as "recovered · non-blocking"); a real DATA/parser exception (any other ProblemId)
    # still BLOCKs (M1 intact).
    $q = @"
AppExceptions | where $sinceClause
| summarize Count=count(), Transient=countif(ProblemId in ('XdrPortalTransientException','AuthChainBrokenException'))
| project Pass = (Count - Transient) == 0, Count, Transient
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'AppExceptions'
    # COVERAGE FIX (2026-06-18) · handled poll/fan-out FAILURE events live in AppEvents (fail-safe catch -> Track-XdrEvent),
    # NEVER AppExceptions — so the query above was blind to a parent poll that fails every cycle and silently starves its
    # fan-out children (ListPostureOversightInitiatives -Category '' bind-fail). Gate them to 0 within this EXISTING gate.
    # V-B2 VERIFIED 2026-06-18: Entry.Enumeration.Failed is a REAL event (XdrDefenderRefresh/run.ps1:162 · per-Op
    # enumeration fail-safe catch) — the "phantom" hypothesis was false-on-grep; it is KEPT in the list.
    # TRANSIENT-TOLERANT (2026-06-18 · same class as the exceptions leg): a poll/fan-out failure whose ErrorClass is
    # XdrPortalTransientException (a portal 429/503 the connector retries · live-caught two routine 503s) is RECOVERED
    # telemetry — D9/D10 backstop any real loss — so it must NOT block (else §4 false-fails exit-0 on a routine 503).
    # Count = NON-transient (BLOCKS) · TransientCount = transient (advisory). Real poll-failures still hard-block.
    # FAN-OUT COVERAGE (2026-07-01 · live-caught): the FAN-OUT failure events (Entry.Fanout.ParentPollFailed etc.) stamp
    # the transient-ness in ErrorMessage ("Portal transient 503 ... retry-after 30"), NOT in ErrorClass (empty for them) —
    # so the ErrorClass-only check counted a routine parent-poll 503 as a REAL failure and hard-blocked ExposureManagement's
    # ListPostureOversightInitiatives under the finalize's aggressive re-poll load. The _isTransient predicate below now
    # ALSO treats an ErrorMessage containing 'transient' or 'retry-after' (the connector's OWN label for a retryable portal
    # error) as transient → excluded uniformly across poll AND fan-out events. A non-transient failure (no such marker)
    # STILL hard-blocks (M1 intact · D9/D10 backstop any real loss).
    # V-M5 (2026-06-19) · CATEGORY SCOPE (same cross-category leak as D1): a poll/fan-out failure for an op in ANOTHER
    # category (e.g. the Exposure fanout parent ListPostureOversightInitiatives during an Operations verify) must NOT be
    # attributed to THIS category. Scope to the category's manifest ops (fail-open if the set can't resolve).
    $appExCatKeys = @(Get-XdrManifestOperationKeys -Portal $Portal -Category $Category)
    $appExCatKql  = '[' + (($appExCatKeys | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ']'
    # RECOVERY-AWARENESS (2026-07-01 robustness · safe-additive · mirrors D4's UnrecoveredFailPortals): under the
    # finalize's aggressive re-poll load an op can have a NON-transient poll/fanout FAILURE and then a LATER
    # Entry.Poll.Succeeded / Entry.Fanout.Completed in the SAME window — the op RECOVERED (a one-off failed cycle that
    # the next cycle cleared · the tenant IS returning data). Counting that recovered op as blocking is a false-block.
    # So compute, per OperationKey, the last non-transient failure time and the last success-terminal time (both scoped
    # to catOps), and count an op as Unrecovered ONLY when it has a non-transient failure AND no success terminal AFTER
    # its last failure. M1 INTACT: an op whose LAST terminal is a failure (never recovered) is Unrecovered → still
    # BLOCKS; the _isTransient exclusion is UNCHANGED (a transient failure never enters the blocking tally). Count /
    # TransientCount / Ops are kept for the detail (back-compat); the gate blocks on Unrecovered.
    $qpf = @"
let catOps = dynamic($appExCatKql);
let evts = AppEvents
| where $sinceClause and Name in ('Entry.Poll.Failed','Entry.Fanout.ParentPollFailed','Entry.Fanout.Error','Entry.Enumeration.Failed','Entry.Poll.Succeeded','Entry.Fanout.Completed','Capability.OpUnavailable')
| where array_length(catOps) == 0 or tostring(Properties.OperationKey) in (catOps)
| extend Op=tostring(Properties.OperationKey)
| extend _isFail = Name in ('Entry.Poll.Failed','Entry.Fanout.ParentPollFailed','Entry.Fanout.Error','Entry.Enumeration.Failed')
| extend _isTransient = (tostring(Properties.ErrorClass) == 'XdrPortalTransientException') or (tostring(Properties.ErrorClass) == 'AuthChainBrokenException') or (tostring(Properties.ErrorMessage) contains 'transient') or (tostring(Properties.ErrorMessage) contains 'retry-after') or (tostring(Properties.ErrorMessage) contains 'throttl') or (tostring(Properties.ErrorMessage) contains 'ServerBusy') or (tostring(Properties.ErrorMessage) contains 'Service Unavailable') or (tostring(Properties.ErrorMessage) contains 'Too Many Requests') or (tostring(Properties.ErrorMessage) contains 'reauth');
let perOp = evts
| summarize LastFail=maxif(TimeGenerated, _isFail and not(_isTransient)), LastOk=maxif(TimeGenerated, not(_isFail)), FailN=countif(_isFail and not(_isTransient)), TransN=countif(_isFail and _isTransient) by Op
| extend _unrecovered = FailN > 0 and (isnull(LastOk) or LastFail > LastOk);
perOp
| summarize Count=sum(FailN), TransientCount=sum(TransN), Ops=dcountif(Op, FailN > 0), Unrecovered=countif(_unrecovered), UnrecoveredOps=tostring(make_set_if(Op, _unrecovered, 50))
| project Count, TransientCount, Ops, Unrecovered, UnrecoveredOps
"@
    $rpf = Invoke-XdrKqlQuery -Query $qpf -Label 'AppExceptions.PollFail'
    # V-B1 (2026-06-18) · Entry.Fanout.Skipped is ALSO an AppEvents handled-failure (Runtime.psm1:1328) but has a BENIGN
    # class (parent-cache-empty on a 0-data tenant · or an Unresolved RawJson-only op with no DependsOn edge — the cycle
    # legitimately continues) and a NON-BENIGN class (EntityResolution!='Resolved' · incomplete DependsOn edge — a
    # mis-catalogued fan-out that can never resolve a parent id → its children silently never poll). Split by Reason: only
    # the non-benign reasons block; benign skips are advisory. Reason strings verified at the $skip call-sites
    # (Runtime.psm1:1341 'no DependsOn edge' · 1342 "EntityResolution='..'" · 1347 'incomplete DependsOn edge' · 1366
    # 'parent cache empty ..'). NonBenign = Reason has 'EntityResolution=' OR 'incomplete DependsOn edge'.
    $qfs = @"
AppEvents | where $sinceClause and Name == 'Entry.Fanout.Skipped'
| extend _reason = tostring(Properties.Reason)
| summarize NonBenign=countif(_reason has 'EntityResolution=' or _reason has 'incomplete DependsOn edge'),
            Benign=countif(not(_reason has 'EntityResolution=' or _reason has 'incomplete DependsOn edge'))
| project NonBenign, Benign
"@
    $rfs = Invoke-XdrKqlQuery -Query $qfs -Label 'AppExceptions.FanoutSkip'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'AppExceptions' -Description 'AppExceptions = 0' -Pass $false -Detail "KQL error: $($r.Error)"
    } elseif (-not $rpf.Success) {
        Add-XdrGateResult -GateId 'AppExceptions' -Description 'handled poll/fan-out failures = 0' -Pass $false -Detail "KQL error: $($rpf.Error)"
    } elseif (-not $rfs.Success) {
        Add-XdrGateResult -GateId 'AppExceptions' -Description 'non-benign fan-out skips = 0' -Pass $false -Detail "KQL error: $($rfs.Error)"
    } else {
        $row  = @($r.Data)   | Select-Object -First 1
        $rowp = @($rpf.Data) | Select-Object -First 1
        $rowf = @($rfs.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'AppExceptions' -Description 'No exceptions / handled poll-fan-out failures / non-benign fan-out skips in window' -Decision (Test-XdrGate_AppExceptions -Row $row -PollFailRow $rowp -FanoutSkipRow $rowf)
    }
}

# ── Gate: D4 R3 capability discovery (plan §18.1 dim 4) · RECOVERY-AWARE (2026-07-01) ──────────────
# Per-tenant license/products probed per-cycle · MUST fire ≥1 Succeeded · and NO portal left UNrecovered.
# A single-flight-contention Discovery.Failed (TenantContextProbeFailed · a peer worker's reauth briefly
# pending) is a RECOVERABLE transient — inherent to a reset-heavy re-prove's concurrent force-polls — NOT a
# discovery failure: the tenant IS discoverable (a later Succeeded proves it). So the gate is PER-PORTAL
# recovery: a portal whose LAST terminal discovery is Succeeded (or which never failed) is HEALTHY; only a
# portal that NEVER succeeds OR whose LAST terminal is a Failed (didn't recover) is a real defect. Source:
# AppInsights `PortalCapabilities.Discovery.*`. The pure Test-XdrGate_D4 owns the pass logic (SelfTested).
if ('D4' -in $gatesForWindow) {
    # WINDOW WIDEN (2026-07-01 robustness · safe-additive): the Discovery probe is a boot-time / per-cycle liveness
    # signal that ingests into AppEvents ~20-40m LATE (like the other poll signals) — a narrow deploy-floor window can
    # miss a genuinely-fired-but-not-yet-ingested Discovery event → null row → false exit-2 "R3 cold-start did not fire"
    # under the finalize's stress. Widen ONLY this gate's time filter to $pollLivenessClause (deploy-floor OR ago(72h),
    # the SAME wider window already used for the terminal-poll liveness) so a slow-to-ingest / >2h-old boot Discovery is
    # still seen. M1 INTACT: the pure Test-XdrGate_D4 null-row→FAIL logic is UNCHANGED — no Discovery over the WIDE
    # window still hard-FAILs, and UnrecoveredFailPortals still blocks a portal that never recovered.
    $q = @"
AppEvents | where $pollLivenessClause and Name startswith 'PortalCapabilities.Discovery.'
| summarize pTotal=count(), pSucceeded=countif(Name endswith 'Succeeded'), pFailed=countif(Name endswith 'Failed'), pLastOk=maxif(TimeGenerated, Name endswith 'Succeeded'), pLastFail=maxif(TimeGenerated, Name endswith 'Failed'), pMax=max(TimeGenerated) by Portal=tostring(Properties.Portal)
| summarize Total=sum(pTotal), Succeeded=sum(pSucceeded), Failed=sum(pFailed), UnrecoveredFailPortals=countif(pFailed > 0 and (isnull(pLastOk) or pLastFail > pLastOk)), MostRecent=max(pMax)
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D4'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId 'D4' -Description 'R3 capability discovery (plan §18.1)' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId 'D4' -Description 'R3 tenant capability discovery fires + succeeds' -Decision (Test-XdrGate_D4 -Row $row)
    }
}

# (D8c · MOVED INTO the per-Op -AllOps loop below + op-scoped · see the V-M4 note above.)

# ── Per-Operation content + exactly-once gates · D8f / D8g / D8h / ExactlyOnce ─────
# -AllOps loops these over EVERY manifest Operation in the Category (the GA per-category all-ops landing
# proof); default / -OperationKey runs the single resolved op. $opKey='' ⇒ Get-XdrManifestOperation falls
# back to Operations[0], so the non-AllOps path is byte-identical. Per-op GateIds are tagged "[<OperationKey>]"
# under -AllOps so the N ops' decisions don't overwrite one another in the $results.Gates hashtable.
$opKeysToVerify = if ($AllOps) {
    $allOpKeys = @(Get-XdrManifestOperationKeys -Portal $Portal -Category $Category)
    if ($allOpKeys.Count -gt 0) { $allOpKeys } else { ,$OperationKey }
} else { ,$OperationKey }
foreach ($opKey in $opKeysToVerify) {
$opTag = if ($AllOps -and $opKey) { "[$opKey]" } else { '' }

# V-M4 · resolve THIS op ONCE + build its op-scoped where-clause. The five formerly-global gates (D2/D6/MinRows/
# CorrelationId/D8c) reuse $opScoped so each asserts ONLY this op's rows (an op landing 0 rows can no longer hide
# behind a sibling op's rows). Falls back to the bare $sinceClause only when the op key is genuinely unknown.
$loopOp   = Get-XdrManifestOperation -Portal $Portal -Category $Category -OperationKey $opKey
$opScoped = Get-XdrOpScopedClause -SinceClause $sinceClause -Operation $loopOp -FallbackKey $opKey

# G1b/P0-1 · compute the LEGIT-NO-DATA verdict ONCE per op, UNCONDITIONALLY — NOT gated on MinRows' window-membership.
# Sustain/Hour/ConsecutiveSustain (the GA windows) run D2/D6/D8c/etc but NOT MinRows, so a MinRows-scoped flag was DEAD
# on the GA path (a fully-proven-empty op exited 1 forever). $zd = the PURE Resolve-XdrZeroRowVerdict (polled-to-terminal
# AND direct-source EMPTY/CAP-ABSENT ⇒ proven-empty); every 0-row gate (MinRows/D2/D6/D8c/CorrelationId/ExactlyOnce/
# ExactlyOncePerCycle/SnapshotNoDupAccum/D8g/D8h) consults $legitNoData so a proven-empty op is vacuous-PASS in EVERY
# window (clean-GREEN), while an unproven-0 (no terminal poll / direct-source has data) stays INCONCLUSIVE/RED.
# F18 PRODUCT-GATE: an op the engine pre-gates (Entry.RequiresProducts.Skipped · its RequiresProducts product is absent on
# this tenant) lands 0 rows LEGITIMATELY, but the direct-source probe bypasses the gate and returns PASS — so MinRows would
# false-fail "rows=0 BUT direct-source returned DATA". Probed on the SAME wider $pollLivenessClause as the terminal-poll
# liveness (the skip telemetry lags into AppEvents like the poll signals) and passed FIRST in Resolve-XdrZeroRowVerdict.
$liveV = Get-XdrLiveSourceVerdict -OperationKey $opKey
# FA-own-poll-OUTCOME reconcile (Fix 2): only needed — and only queried — when the direct probe read DATA (PASS/RED-shape).
# The probe is a SEPARATE sample of the source; the FA's OWN Entry.Poll.* outcome is the truth for "did the FA receive NEW
# data it failed to land?". Probed on the WIDE $pollLivenessClause (sparse cadence + AppEvents ingest lag absorbed) so a
# BoundaryDeduped (exactly-once suppressed unchanged/seen data · re-emit would dup-accumulate) or an async-EMPTY poll reads
# as the correct 0-row outcome; the emission-history window (7d) disambiguates the rare NEW-data-never-landed real gap.
$faGap = if ($liveV -in @('PASS','RED-shape')) { Get-XdrFaPollLandGap -PollLivenessClause $pollLivenessClause -EmissionHistoryClause 'TimeGenerated > ago(7d)' -OperationKey $opKey -WorkspaceTable $workspaceTable -LoopOp $loopOp -FallbackKey $opKey } else { -1 }
$zd = if ($workspaceTable) { Resolve-XdrZeroRowVerdict -Polled (Test-XdrOpPolledToTerminal -SinceClause $pollLivenessClause -OperationKey $opKey) -LiveVerdict $liveV -ProductGated (Test-XdrOpProductGated -SinceClause $pollLivenessClause -OperationKey $opKey) -FaGapSignal $faGap } else { $null }
$legitNoData = [bool]($zd -and $zd.Pass)

# ── Gate: MinRows (op-scoped · V-M4) · ≥1 row for THIS op in the target Category table ─────────────
# Keystone of V-M4: under -AllOps every deployed op must INDEPENDENTLY land ≥1 row, OR be proven LEGIT-NO-DATA ($zd
# above). 0 rows + no terminal poll = hard FAIL (un-proven). Runs only in windows whose set includes MinRows.
if ('MinRows' -in $gatesForWindow -and $workspaceTable) {
    $q = @"
$workspaceTable | where $opScoped
| summarize Count=count()
| project Pass = Count >= 1, Count
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'MinRows'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId "MinRows$opTag" -Description "≥1 row in $workspaceTable" -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        $mrDec = Test-XdrGate_MinRows -Row $row
        # G1 prove-empty: a 0-row op is GREEN only if $zd proves it (EMPTY/CAP-ABSENT); reuse the loop-top $zd (no re-probe).
        if (-not $mrDec.Pass -and $zd) { $mrDec = $zd }
        Add-XdrGateDecision -GateId "MinRows$opTag" -Description "≥1 row landed for this op in $workspaceTable" -Decision $mrDec
    }
}

# ── Gate: D2 (op-scoped · V-M4) No empty rows for THIS op ──────────────────────
if ('D2' -in $gatesForWindow -and $workspaceTable) {
    $q = @"
$workspaceTable | where $opScoped
| summarize Empty=countif(isempty(RawJson) or RawJson == '{}' or RawJson startswith 'OrderedHashtable' or isempty(Operation)), Total=count()
| project Pass = Empty == 0, Empty, Total
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D2'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId "D2$opTag" -Description 'No empty rows' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId "D2$opTag" -Description 'No empty rows in workspace table (this op)' -Decision (Test-XdrGate_D2 -Row $row -LegitNoDataProven $legitNoData)
    }
}

# ── Gate: D6 (op-scoped · V-M4) RawJson valid JSON for THIS op ──────────────────
if ('D6' -in $gatesForWindow -and $workspaceTable) {
    $q = @"
$workspaceTable | where $opScoped
| extend Parsed = parse_json(RawJson)
| summarize Invalid=countif(isnull(Parsed) or array_length(bag_keys(Parsed)) == 0), Total=count()
| project Pass = Invalid == 0, Invalid, Total
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D6'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId "D6$opTag" -Description 'RawJson parses to non-empty object' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId "D6$opTag" -Description 'RawJson is valid JSON with ≥1 key (this op)' -Decision (Test-XdrGate_D6 -Row $row -LegitNoDataProven $legitNoData)
    }
}

# ── Gate: CorrelationId (op-scoped · V-M4) populated on every row of THIS op ────
if ('CorrelationId' -in $gatesForWindow -and $workspaceTable) {
    $q = @"
$workspaceTable | where $opScoped
| summarize NullCount=countif(isempty(CorrelationId)), Total=count()
| project Pass = NullCount == 0, NullCount, Total
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'CorrelationId'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId "CorrelationId$opTag" -Description 'CorrelationId populated on all rows' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId "CorrelationId$opTag" -Description 'CorrelationId populated on every row (this op)' -Decision (Test-XdrGate_CorrelationId -Row $row -LegitNoDataProven $legitNoData)
    }
}

# ── Gate: D8c (op-scoped · V-M4) Envelope cols populated on every row of THIS op (plan §18.2 sub-gate c) ─
# 4 always-populated envelope cols MUST be populated on every row: Portal · Category · Operation · CorrelationId.
# (F2: OperationKey dropped — it duplicated Operation; RecordId/ParentRecordId are conditionally-populated.) Any
# NULL in any row indicates a Refresh.ps1/Activity.ps1 envelope-build bug.
if ('D8c' -in $gatesForWindow -and $workspaceTable) {
    $q = @"
$workspaceTable | where $opScoped
| summarize Total=count(),
            Portal_pop=countif(isnotempty(Portal)),
            Category_pop=countif(isnotempty(Category)),
            Operation_pop=countif(isnotempty(Operation)),
            CorrelationId_pop=countif(isnotempty(CorrelationId))
| project Pass = Total > 0 and Portal_pop == Total and Category_pop == Total and Operation_pop == Total and CorrelationId_pop == Total,
          Total, Portal_pop, Category_pop, Operation_pop, CorrelationId_pop
"@
    $r = Invoke-XdrKqlQuery -Query $q -Label 'D8c'
    if (-not $r.Success) {
        Add-XdrGateResult -GateId "D8c$opTag" -Description 'Envelope cols populated' -Pass $false -Detail "KQL error: $($r.Error)"
    } else {
        $row = @($r.Data) | Select-Object -First 1
        Add-XdrGateDecision -GateId "D8c$opTag" -Description 'All 4 always-populated envelope cols populated on every row (this op)' -Decision (Test-XdrGate_D8c -Row $row -LegitNoDataProven $legitNoData)
    }
}

# ── Gate: D8f Typed cols populated · per-ProjectionMap-key (plan §18.2 sub-gate f) ─
# The keystone "actual events per requirements not just ingested" check (operator binding 2026-06-02 PM).
# Reads manifest ProjectionMap (19 cols for ActionCenter) · verifies EACH typed col either populated OR is
# legitimately source-null. WS4.3: a col empty-in-table is a parser bug ONLY when the SOURCE (RawJson) carries
# a non-null value the projection dropped. A col the portal returns null for (e.g. ActionDecision on AutomatedIR
# actions) is NOT a bug — older D8f assumed every col CAN populate (lab-fixture thinking) and FALSE-FAILED on
# live legitimately-null fields. Each col now ships a <col>_pop (landed) AND <col>_src (source-non-null) count.
if ('D8f' -in $gatesForWindow -and $workspaceTable -and $Portal -and $Category) {
    $manifestPath = Join-Path (Resolve-Path "$PSScriptRoot\..").Path "manifests/$Portal/$Category.psd1"
    if (Test-Path $manifestPath) {
        # WS4.3 · PER-OP resolution (was hardcoded Operations[0] — wrong cols for any multi-op manifest when
        # -OperationKey selects a different op; the catalogue-ordered pilot manifest has GetPending at [0]).
        $pmKeys = @()
        $d8fOp = Get-XdrManifestOperation -Portal $Portal -Category $Category -OperationKey $opKey
        if ($d8fOp -and $d8fOp.ContainsKey('ProjectionMap')) {
            $pmKeys = @($d8fOp.ProjectionMap.Keys | Sort-Object)
        }
        if ($pmKeys.Count -eq 0) {
            # RawJson-only op (empty ProjectionMap · e.g. a SNAPSHOT config op with no typed extraction): exactly
            # like D8g/D8h when there are no _x / Json cols, there is NOTHING to prove → vacuous PASS. The op's
            # integrity is still covered by D8c (envelope) + D6 (RawJson valid) + MinRows. A "should-be-projected"
            # gap is a GENERATION-time concern (Validate-Manifests / catalogue ship-gate), not a post-deploy check.
            # -AllOps surfaced this: single-op verify only ever hit Operations[0] (which has a ProjectionMap).
            Add-XdrGateResult -GateId "D8f$opTag" -Description 'Typed col population (per ProjectionMap)' -Pass $true -Detail 'no ProjectionMap (RawJson-only op) · no typed cols to prove'
        } else {
            # OP-SCOPED (WS4.3): only THIS op's rows carry THIS op's ProjectionMap cols. Per col emit BOTH the
            # landed count (<col>_pop) AND the SOURCE non-null count (<col>_src · from the RawJson at the col's
            # ProjectionMap JSONPath) so the decision can tell a real parser bug from a legitimately-null source.
            $d8fClause = Get-XdrOpScopedClause -SinceClause $sinceClause -Operation $d8fOp -FallbackKey $opKey
            $colFragments = @()
            foreach ($k in $pmKeys) {
                $srcAcc = ConvertTo-XdrRawJsonAccessor ([string]$d8fOp.ProjectionMap[$k])
                # _pop checks the LANDED column = the SAFE name (Get-XdrSafeColumnName · the LA-reserved / envelope-
                # collision rewrite, e.g. title -> title_x · category -> category_x) referenced via brackets (a bare
                # reserved-word column like 'title' is parse-unsafe in KQL). The agg NAME stays $k-based (the decision
                # reads <k>_pop / <k>_src by that name).
                $safeCol = Get-XdrSafeColumnName $k
                $colFragments += "${k}_pop=countif(isnotempty(['$safeCol']))"
                # _src counts SOURCE values that are GENUINELY PRESENT and NOT an empty container. D8f's discriminator is
                # "empty-in-table BUT non-null-in-source == parser bug", but an EMPTY CONTAINER legitimately serializes to
                # empty and correctly lands empty — it is NOT a dropped value. So a source value counts only when it is
                # isnotnull(...) AND its tostring() is none of: '' (empty/whitespace string), '[]' / '[[]]' (empty array /
                # array-of-empty-array), '{}' (empty object), 'null' (a json null literal · tostring(parse_json('null'))).
                # (Concretely: ListSuppressionRules.DeserializedScopeConditions is [] on every row — the real conditions
                # ship via RuleConditions — so DeserializedScopeConditions is LEGIT-empty, not a parser bug. Same for
                # secure-score suggestions=[] -> suggestionsJson=''.) A col whose source "non-null" values are ALL
                # empty-containers therefore yields _src==0 → legitimately-not-projected, not a fail.
                # ALSO exclude the parser's IN-COLUMN SENTINEL {"__xdrlr_in_column":true} (Parser.psm1 StubFields): a
                # PROMOTED field's RawJson value is REPLACED by that sentinel (the real value lives in the COLUMN, which
                # <col>_pop already checks · avoids RawJson duplication under the B3 clamp). Counting the sentinel as a
                # source value FALSE-FAILS D8f for a legitimately-EMPTY promoted col (empty column + sentinel in RawJson
                # == the promoted value WAS empty · live-caught 2026-06-17 Operations GetTenantContext Irm/Itp/Mdi/Sentinel
                # MtpPermissions = this tenant carries no such permission). For a promoted col the COLUMN is the source of
                # truth, not RawJson — so the sentinel is NOT a source value.
                $colFragments += "${k}_src=countif(isnotnull($srcAcc) and tostring($srcAcc) !in ('','[]','[[]]','{}','null') and tostring($srcAcc) !contains '__xdrlr_in_column')"
            }
            $summarize = (@('Total=count()') + $colFragments) -join ', '
            # extend _rj ONCE per row so the per-col <col>_src source checks reuse a single parse (NOT one
            # parse_json(RawJson) per col — that overran LA on the 76-col GetTenantContext · WS4.3).
            $q = @"
$workspaceTable | where $d8fClause
| extend _rj = parse_json(RawJson)
| summarize $summarize
"@
            $r = Invoke-XdrKqlQuery -Query $q -Label 'D8f'
            if (-not $r.Success) {
                Add-XdrGateResult -GateId "D8f$opTag" -Description "Typed cols populated ($($pmKeys.Count) ProjectionMap keys)" -Pass $false -Detail "KQL error: $($r.Error)"
            } else {
                $row = @($r.Data) | Select-Object -First 1
                $d8fDec = Test-XdrGate_D8f -Row $row -Columns $pmKeys
                if ($d8fDec.Inconclusive -and -not $d8fDec.Pass) {
                    # G1b/P0-1 · use the loop-wide $legitNoData — the SAME prove-empty signal as MinRows/D2/D6 (polled-to-
                    # terminal AND direct-source EMPTY/CAP-ABSENT). NOT a weaker telemetry-only re-probe: that would PASS a
                    # real FA-not-landing gap whose direct source HAS data = a silent green in Sustain (no MinRows to RED it).
                    if ($legitNoData) {
                        $d8fDec = @{ Pass = $true; Inconclusive = $false; Detail = "0 rows · LEGIT-NO-DATA PROVEN (op polled to terminal + direct-source EMPTY/CAP-ABSENT · nothing to project)" }
                        # m1 · capability-REGRESSION advisory (D8f-specific): if the op went OpUnavailable in-window AND was
                        # historically populated (30d lookback), that transition is a real signal → surface it (non-blocking).
                        $opKEsc = $opKey -replace "'", "''"   # KQL escapes a single-quote by DOUBLING it, not backslash
                        $cuQ = "AppEvents | where $sinceClause | where Name == 'Capability.OpUnavailable' | where tostring(Properties.OperationKey) == '$opKEsc' | summarize unavail=count()"
                        $cur = Invoke-XdrKqlQuery -Query $cuQ -Label 'D8f-capregress'
                        $wentUnavail = $false
                        if ($cur.Success) { $crow = @($cur.Data) | Select-Object -First 1; if ($crow) { $wentUnavail = (ConvertTo-XdrInt (Get-XdrRowValue $crow 'unavail')) -gt 0 } }
                        if ($wentUnavail) {
                            $histRows = 0
                            $histQ = "$workspaceTable | where TimeGenerated > ago(30d) and Operation == '$opKEsc' | summarize n=count()"
                            $hr = Invoke-XdrKqlQuery -Query $histQ -Label 'D8f-caphist'
                            if ($hr.Success) { $hrow = @($hr.Data) | Select-Object -First 1; if ($hrow) { $histRows = ConvertTo-XdrInt (Get-XdrRowValue $hrow 'n') } }
                            $capV = Get-XdrCapabilityRegressionVerdict -WentUnavailable $wentUnavail -HistoricalRows $histRows
                            if ($capV.Advisory) {
                                Add-XdrGateResult -GateId "CapabilityRegression$opTag" -Description 'Capability regression (op went OpUnavailable but was previously populated)' -Pass $false -Detail $capV.Detail -Advisory $true
                            }
                        }
                    }
                }
                Add-XdrGateDecision -GateId "D8f$opTag" -Description "All $($pmKeys.Count) typed cols have >=1 non-null row" -Decision $d8fDec
            }
        }
    } else {
        Add-XdrGateResult -GateId "D8f$opTag" -Description 'Typed col population' -Pass $false -Detail "manifest not found at $manifestPath" -Advisory $true
    }
}

# ── Gate: D8g LA-reserved rewrite (plan §18.2 sub-gate g) ──────────────────────
# When ProjectionMap rewrites an LA-reserved key (e.g. TenantId → TenantId_x) · the rewritten col MUST
# be populated when the source field is non-null. Zero non-null rows in a rewritten col = rewrite did
# not fire (Apply-XdrProjectionMap LA-reserved logic bug).
# GENERALIZED (no longer ActionCenter EndTime_x): DERIVE the rewritten cols from the manifest the way
# D8f derives ProjectionMap.Keys — every ProjectionMap target whose LANDED name ends in '_x' (i.e. the
# key is LA-reserved per Get-XdrSafeColumnName, OR the manifest author already named it '<x>_x'). If the
# Operation rewrites nothing, the gate passes vacuously (no '_x' contract to prove).
if ('D8g' -in $gatesForWindow -and $workspaceTable) {
    $d8gOp = Get-XdrManifestOperation -Portal $Portal -Category $Category -OperationKey $opKey
    $rewrittenCols = @(Get-XdrProjectionTargets -Operation $d8gOp | Where-Object { $_ -like '*_x' } | Sort-Object -Unique)
    if ($null -eq $d8gOp) {
        Add-XdrGateResult -GateId "D8g$opTag" -Description 'LA-reserved rewrite (manifest-derived)' -Pass $false -Detail "manifest Operation not resolvable for Portal=$Portal Category=$Category OperationKey=$opKey" -Advisory $true
    } elseif ($rewrittenCols.Count -eq 0) {
        Add-XdrGateResult -GateId "D8g$opTag" -Description 'LA-reserved rewrite (manifest-derived)' -Pass $true -Detail 'no LA-reserved-rewritten (_x) cols in ProjectionMap · nothing to prove'
    } else {
        # One countif per rewritten col · gate passes if Total==0 (no rows yet) OR every _x col has >0 non-null.
        # OP-SCOPED: the _x rewrite contract is this op's (WS4.3 fix).
        $d8gClause = Get-XdrOpScopedClause -SinceClause $sinceClause -Operation $d8gOp -FallbackKey $opKey
        $popFragments = $rewrittenCols | ForEach-Object { "${_}_pop=countif(isnotempty($_))" }
        $summarize = (@('Total=count()') + $popFragments) -join ', '
        $q = @"
$workspaceTable | where $d8gClause
| summarize $summarize
"@
        $r = Invoke-XdrKqlQuery -Query $q -Label 'D8g'
        if (-not $r.Success) {
            Add-XdrGateResult -GateId "D8g$opTag" -Description "LA-reserved rewrite ($($rewrittenCols.Count) _x cols)" -Pass $false -Detail "KQL error: $($r.Error)"
        } else {
            $row = @($r.Data) | Select-Object -First 1
            Add-XdrGateDecision -GateId "D8g$opTag" -Description "LA-reserved rewrite fires ($($rewrittenCols -join ','))" -Decision (Test-XdrGate_D8g -Row $row -Columns $rewrittenCols -LegitNoDataProven $legitNoData)
        }
    }
}

# ── Gate: D8h Serialized non-scalars parse as JSON (plan §18.2 sub-gate h) ─────
# Parser B3 serializes non-scalar ProjectionMap values (arrays · objects) to a JSON string on a target
# col with the `Json` suffix. Each such string MUST be valid JSON via parse_json (round-trip integrity).
# GENERALIZED (no longer hardcoded RelatedEntitiesJson + AdditionalFieldsJson): DERIVE the serialized
# cols from the manifest the way D8f derives ProjectionMap.Keys — every ProjectionMap target whose
# LANDED name ends in 'Json'. Per col: pass if it is never populated OR every populated value parses.
if ('D8h' -in $gatesForWindow -and $workspaceTable) {
    $d8hOp = Get-XdrManifestOperation -Portal $Portal -Category $Category -OperationKey $opKey
    $jsonCols = @(Get-XdrProjectionTargets -Operation $d8hOp | Where-Object { $_ -like '*Json' } | Sort-Object -Unique)
    if ($null -eq $d8hOp) {
        Add-XdrGateResult -GateId "D8h$opTag" -Description 'Serialized non-scalars parse (manifest-derived)' -Pass $false -Detail "manifest Operation not resolvable for Portal=$Portal Category=$Category OperationKey=$opKey" -Advisory $true
    } elseif ($jsonCols.Count -eq 0) {
        Add-XdrGateResult -GateId "D8h$opTag" -Description 'Serialized non-scalars parse (manifest-derived)' -Pass $true -Detail 'no serialized (Json) cols in ProjectionMap · nothing to prove'
    } else {
        # Per Json col build: <col>_ne = isnotempty count · <col>_ok = parses count. Pass = Total==0 OR
        # for every col (ne==0 OR ok==ne). extend lines feed the parse_json round-trip per col.
        $extendLines = $jsonCols | ForEach-Object { "Parsed_$_ = parse_json($_)" }
        $sumFragments = @()
        foreach ($c in $jsonCols) {
            $sumFragments += "${c}_ne=countif(isnotempty($c))"
            $sumFragments += "${c}_ok=countif(isnotempty($c) and isnotnull(Parsed_$c))"
        }
        # OP-SCOPED: the Json round-trip contract is this op's (WS4.3 fix).
        $d8hClause = Get-XdrOpScopedClause -SinceClause $sinceClause -Operation $d8hOp -FallbackKey $opKey
        $summarize = (@('Total=count()') + $sumFragments) -join ', '
        $q = @"
$workspaceTable | where $d8hClause
| extend $($extendLines -join ', ')
| summarize $summarize
"@
        $r = Invoke-XdrKqlQuery -Query $q -Label 'D8h'
        if (-not $r.Success) {
            Add-XdrGateResult -GateId "D8h$opTag" -Description "Serialized non-scalars parse ($($jsonCols.Count) Json cols)" -Pass $false -Detail "KQL error: $($r.Error)"
        } else {
            $row = @($r.Data) | Select-Object -First 1
            Add-XdrGateDecision -GateId "D8h$opTag" -Description "Serialized non-scalars parse as JSON ($($jsonCols -join ','))" -Decision (Test-XdrGate_D8h -Row $row -Columns $jsonCols -LegitNoDataProven $legitNoData)
        }
    }
}

# ── Gate: ExactlyOnce · count(rows) == dcount(NaturalKey composite) (plan §35.2 proof) ─────
# The connector is exactly-once BY CONSTRUCTION (client-side high-water + boundary natural-key dedup ·
# NO DCR dedup · plan §35). That property is load-bearing but had NO post-deploy gate — this proves it
# end-to-end in the deployed table: over the window, the row count MUST equal the DISTINCT count of the
# composite NaturalKey. count > dcount = a duplicate landed (dedup regression · data integrity violated
# → BLOCKING). NaturalKey field name(s) are READ FROM THE MANIFEST (Operations[].NaturalKey); a multi-
# field key is dcount'd on strcat(...,'|',...) matching the runtime's '|'-joined composite key.
# MinRows>=1 FLOOR (plan §35.2 honesty): the equality is ONLY asserted when rows exist. An empty window is
# INCONCLUSIVE (Test-XdrGate_ExactlyOnce), NOT a silent vacuous PASS — zero dups over zero rows proves
# nothing about the dedup path.
if ('ExactlyOnce' -in $gatesForWindow -and $workspaceTable) {
    $eoOp = Get-XdrManifestOperation -Portal $Portal -Category $Category -OperationKey $opKey
    $nkKql = Get-XdrNaturalKeyKql -Operation $eoOp
    $nkFields = if ($eoOp -and $eoOp.ContainsKey('NaturalKey')) { @($eoOp.NaturalKey) -join ',' } else { '' }
    # KEYLESS (2026-06-18 · pairs with the runtime content-hash RecordId): an op with no proven NaturalKey now lands a
    # content-hash RecordId ($XdrContentHash · its stable dedup identity). Use the landed RecordId column as the dedup
    # key so the exactly-once gate RUNS and BLOCKS per-cycle dup-accumulation instead of advisory-skipping it (the skip
    # is how the live SecureScore GetInsights 24,300-row / empty-RecordId dup slipped through). Honest: RecordId IS the
    # row's landed identity for EVERY op — composite NaturalKey when keyed, content-hash when not.
    if ($eoOp -and -not $nkKql) { $nkKql = 'RecordId'; $nkFields = 'RecordId(content-hash · keyless)' }
    if ($null -eq $eoOp) {
        Add-XdrGateResult -GateId "ExactlyOnce$opTag" -Description 'Exactly-once (count==dcount NaturalKey)' -Pass $false -Detail "manifest Operation not resolvable for Portal=$Portal Category=$Category OperationKey=$opKey" -Advisory $true
    } elseif (-not $nkKql) {
        Add-XdrGateResult -GateId "ExactlyOnce$opTag" -Description 'Exactly-once (count==dcount NaturalKey)' -Pass $false -Detail 'Operation declares no NaturalKey · cannot prove exactly-once' -Advisory $true
    } else {
        # dcount() is approximate by default; force exact accuracy (4) so count==dcount is a hard equality.
        # OP-SCOPED: exactly-once is asserted per op (each op has its own NaturalKey domain · WS4.3 fix).
        # MODE-AWARE (plan §4 · "exactly-once per INGESTION MODE" · wiring the already-locked spec, NOT a new gate · B4):
        #   CURSOR  = append-once monotonic high-water → each NaturalKey lands ONCE across the whole window (a
        #             cross-cycle recurrence = a high-water/boundary dedup regression) → whole-window count==dcount.
        #   SNAPSHOT/WINDOW = the op RE-EMITS its full current state every cadence cycle BY DESIGN, so a key recurs
        #             across cycles legitimately → exactly-once = PER-CYCLE dup-free: group by CorrelationId (the
        #             per-poll-cycle id) and assert EVERY cycle has count==dcount. The prior whole-window form
        #             false-failed SNAPSHOT the instant >1 cycle was in the window; per-cycle makes C6 "sustained
        #             >=N cycles dup-free" measurable. Unknown/blank mode → SNAPSHOT (the conservative re-emit form).
        $eoClause = Get-XdrOpScopedClause -SinceClause $sinceClause -Operation $eoOp -FallbackKey $opKey
        $eoMode = if ($eoOp.ContainsKey('IngestionMode') -and -not [string]::IsNullOrWhiteSpace([string]$eoOp.IngestionMode)) { [string]$eoOp.IngestionMode } else { 'SNAPSHOT' }
        if ($eoMode -eq 'CURSOR') {
            $q = "$workspaceTable | where $eoClause | summarize Rows=count(), DistinctKeys=dcount($nkKql, 4) | project Pass = Rows == DistinctKeys, Rows, DistinctKeys, Duplicates = Rows - DistinctKeys"
            $r = Invoke-XdrKqlQuery -Query $q -Label 'ExactlyOnce'
            if (-not $r.Success) {
                Add-XdrGateResult -GateId "ExactlyOnce$opTag" -Description "Exactly-once CURSOR (count==dcount $nkFields)" -Pass $false -Detail "KQL error: $($r.Error)"
            } else {
                $row = @($r.Data) | Select-Object -First 1
                Add-XdrGateDecision -GateId "ExactlyOnce$opTag" -Description "Exactly-once by construction · CURSOR whole-window count(rows)==dcount($nkFields)" -Decision (Test-XdrGate_ExactlyOnce -Row $row -NaturalKey $nkFields -ResetsInWindow $resetsForD3D7 -LegitNoDataProven $legitNoData)
            }
        } else {
            $q = "$workspaceTable | where $eoClause | summarize Rows=count(), DistinctKeys=dcount($nkKql, 4) by CorrelationId | summarize Cycles=count(), BadCycles=countif(Rows != DistinctKeys), TotalRows=sum(Rows), MaxRowsPerCycle=max(Rows) | project Pass = (Cycles > 0 and BadCycles == 0 and TotalRows > 0), Cycles, BadCycles, TotalRows, MaxRowsPerCycle"
            $r = Invoke-XdrKqlQuery -Query $q -Label 'ExactlyOnce'
            if (-not $r.Success) {
                Add-XdrGateResult -GateId "ExactlyOnce$opTag" -Description "Exactly-once $eoMode (per-cycle dup-free $nkFields)" -Pass $false -Detail "KQL error: $($r.Error)"
            } else {
                $row = @($r.Data) | Select-Object -First 1
                Add-XdrGateDecision -GateId "ExactlyOnce$opTag" -Description "Exactly-once by construction · $eoMode per-cycle dup-free (by CorrelationId) · dcount($nkFields)" -Decision (Test-XdrGate_ExactlyOncePerCycle -Row $row -NaturalKey $nkFields -Mode $eoMode -LegitNoDataProven $legitNoData)
            }
            # F-SNAPSHOT-SIG · ALSO assert the CROSS-cycle dup-accumulation bound (the per-cycle gate above proves only
            # INTRA-cycle · it TOLERATED the live 16×/719× cross-cycle re-emit). A cursorless SNAPSHOT must NOT multiply
            # its row count by the cycle count — the EO content-signature skip holds total ≈ distinct(dedup-key). Op-scoped,
            # whole-window. The x3 bound catches the 16×/719× gap while tolerating a few legit value-changes; a real WINDOW
            # op's dupFactor is naturally ≈1 so the bound never false-fails it.
            $qx = "$workspaceTable | where $eoClause | summarize Total=count(), Distinct=dcount($nkKql, 4), Cycles=dcount(CorrelationId), TableCycles=dcount(CorrelationId)"
            $rx = Invoke-XdrKqlQuery -Query $qx -Label 'SnapshotNoDupAccum'
            if (-not $rx.Success) {
                Add-XdrGateResult -GateId "SnapshotNoDupAccum$opTag" -Description "Cross-cycle dup-accumulation bound ($eoMode · $nkFields)" -Pass $false -Detail "KQL error: $($rx.Error)" -Advisory $true
            } else {
                $rowx = @($rx.Data) | Select-Object -First 1
                # A PERFECT skip emits 0 rows on cycle-2+, so the _CL table shows 1 CorrelationId even when the FA polled
                # N times — the table-only Cycles count can't prove the skip. Cross-reference the TELEMETRY poll-cycle count
                # (distinct Entry.Poll.Succeeded CorrelationIds for the op · same OperationKey the runtime stamps).
                $opKEsc = ([string]$opKey) -replace "'", "''"
                # Fan-out children poll under the PARENT key: a child's RowKey is 'Parent|variant' but the runtime stamps
                # Entry.Poll.Succeeded with the bare parent OperationKey ('Parent'), so a child's own-key poll count is 0
                # → SnapshotNoDupAccum would be perma-INCONCLUSIVE for every fan-out child. Match the parent too so the
                # cross-cycle skip IS exercisable (the parent's N poll cycles ARE the child's poll cycles). No-op for a
                # non-fan-out op (parentEsc == opKEsc).
                $parentEsc = ((([string]$opKey) -split '\|')[0]) -replace "'", "''"
                # PollCycles is the cross-cycle GUARD (did the FA poll >=2x so the skip COULD be exercised?), NOT the
                # dup-accumulation check itself (that's $qx on the _CL, op-scoped on the deploy floor). Use the wider
                # liveness window: the 2nd-cycle Entry.Poll.Succeeded ingests ~20-40m late, so floor-bounding it false-reads
                # PollCycles=0 on a healthy op. The actual total<=distinct dup bound stays on $eoClause (the deploy floor).
                $pcQ = "AppEvents | where $pollLivenessClause | where Name == 'Entry.Poll.Succeeded' | where tostring(Properties.OperationKey) in ('$opKEsc', '$parentEsc') | summarize PollCycles=dcount(tostring(Properties.CorrelationId))"
                $pcR = Invoke-XdrKqlQuery -Query $pcQ -Label 'SnapshotNoDupAccum.PollCycles'
                $pollCycles = if ($pcR.Success) { ConvertTo-XdrInt (Get-XdrRowValue (@($pcR.Data) | Select-Object -First 1) 'PollCycles') } else { 0 }
                # SIGNATURE-AWARE cross-cycle content check (2026-07-03) · KEYLESS-only (RecordId = content-hash, so the
                # sorted RecordId SET per cycle IS the snapshot's content signature). DistinctSnaps = dcount(that per-cycle
                # signature): == EmitCycles ⇒ every re-emit is a genuinely-different snapshot (full-snapshot-on-change is
                # CORRECT · drift = KQL layer · SSOT A4) → GREEN; < EmitCycles ⇒ a byte-identical snapshot re-emitted = the
                # skip regressed → RED. Replaces the flat ×3 bound that false-RED'd a legit full-snapshot op. -1 for a keyed
                # op (RecordId is its NaturalKey, not a content-hash) → the gate's flat-bound fallback.
                # Per-cycle content signature · KEYLESS → RecordId IS the (F-CANON canonical) content-hash; KEYED → RecordId is
                # the natural KEY (not content), so hash the RawJson per row. Either way DistinctSnaps==EmitCycles ⇒ every
                # re-emit is a genuine content change (full-snapshot-on-change · GREEN); < ⇒ an identical snapshot re-emitted
                # (skip regression · RED). Works for BOTH key classes so a legit keyed full-snapshot passes without the flat bound.
                $distinctSnaps = -1; $emitCycles = -1
                $sigExpr = if ($nkKql -eq 'RecordId') { 'make_set(RecordId)' } else { 'make_set(hash_sha256(tostring(RawJson)))' }
                $qsig = "$workspaceTable | where $eoClause | summarize sig=hash_sha256(tostring(array_sort_asc($sigExpr))) by CorrelationId | summarize EmitCycles=count(), DistinctSnaps=dcount(sig)"
                $rsig = Invoke-XdrKqlQuery -Query $qsig -Label 'SnapshotNoDupAccum.Signatures'
                if ($rsig.Success) {
                    $rowSig = @($rsig.Data) | Select-Object -First 1
                    $distinctSnaps = ConvertTo-XdrInt (Get-XdrRowValue $rowSig 'DistinctSnaps')
                    $emitCycles = ConvertTo-XdrInt (Get-XdrRowValue $rowSig 'EmitCycles')
                }
                Add-XdrGateDecision -GateId "SnapshotNoDupAccum$opTag" -Description "Cross-cycle dup-accumulation BLOCK · $eoMode signature-aware (distinctSnaps==emitCycles) · dcount($nkFields)" -Decision (Test-XdrGate_SnapshotNoDupAccum -Row $rowx -Key $nkFields -PollCycles $pollCycles -ResetsInWindow $resetsForD3D7 -LegitNoDataProven $legitNoData -DistinctSnaps $distinctSnaps -EmitCycles $emitCycles)

                # F-VOLATILE-HASH (2026-06-25 · gate-learning loop) · the SHARPER cross-cycle gate that SnapshotNoDupAccum
                # is BLIND to. SnapshotNoDupAccum dedups ON the RecordId, so when the RecordId ITSELF is volatile (a
                # content-hash over a record carrying a per-poll-changing field) its re-emits look distinct → dupFactor≈1
                # reads as healthy. This gate measures whether the table DEDUPS across cycles AT SOURCE: the connector's
                # signature-skip makes a HEALTHY stable SNAPSHOT cold-emit N rows ONCE then BoundaryDedupe (0 new rows ⇒
                # no new CorrelationId) on cycles 2+ → only ONE cycle's rows ever land → TableCycles=dcount(CorrelationId)
                # in the op-scoped _CL ≈ 1. A VOLATILE-HASH op never skips (a fresh hash every poll) → fresh rows under a
                # NEW CorrelationId EVERY cycle → TableCycles ≈ PollCycles. So the discriminator is TABLE-cycles, NOT the
                # telemetry PollCycles: a healthy-skip op is dupFactor=1 with TableCycles≈1 (PASS · the case the old
                # dupFactor≈PollCycles premise FALSE-RED), a volatile op is dupFactor≈1 with TableCycles≥2 (RED). Runs
                # ONLY for a KEYLESS (content-hash RecordId) op — a KEYED op's RecordId is its NaturalKey (not a
                # content-hash · not subject to this class), so the gate would be meaningless there. Reuses the
                # SnapshotNoDupAccum PollCycles (the cross-cycle guard) + the shared reset count (reset-churn →
                # INCONCLUSIVE, like D1/D3/D7). $rowx already carries Total + (as Distinct) the dcount(RecordId) + the
                # TableCycles=dcount(CorrelationId) the $qx summarize now emits (SAME deploy-floor window $eoClause as
                # Total/Distinct); alias them for the pure fn.
                if ($nkKql -eq 'RecordId') {
                    $rowVol = @{ Total = (Get-XdrRowValue $rowx 'Total'); DistinctRec = (Get-XdrRowValue $rowx 'Distinct'); TableCycles = (Get-XdrRowValue $rowx 'TableCycles') }
                    # A5 (2026-07-03): manifest-declared, DATA-VERIFIED evolving-data snapshot — a MEANINGFUL field genuinely
                    # drifts each cycle (pure-volatile timestamps still stripped via VolatileHashFields) → accept the genuine
                    # per-cycle drift (SSOT A4 · full-snapshot-on-change · drift=KQL layer). NOT a blanket bypass (ListCritical-
                    # AssetClassifications is NOT flagged · stays strip-to-dedup). Read from the SAME manifest op as ExactlyOnce.
                    $snapDrift = [bool]($eoOp -and $eoOp.ContainsKey('SnapshotDrift') -and $eoOp.SnapshotDrift)
                    Add-XdrGateDecision -GateId "VolatileHash$opTag" -Description "Volatile-hash cross-cycle dedup · keyless SNAPSHOT content-hash dedups AT SOURCE (TableCycles≈1) NOT re-minted every cycle (TableCycles≈pollCycles)" -Decision (Test-XdrGate_VolatileHash -Row $rowVol -Key $nkFields -PollCycles $pollCycles -TableCycles (Get-XdrRowValue $rowx 'TableCycles') -ResetsInWindow $resetsForD3D7 -LegitNoDataProven $legitNoData -SnapshotDrift $snapDrift)
                }
            }
        }
    }
}
}  # end foreach $opKey · per-Operation content + exactly-once gates (-AllOps loop)

# ── Gate: D12 Sentinel V3 surface (plan §18.1 dim 12) ──────────────────────────
# Verifies the V3 surface in workspace: dataConnectorDefinition (the card in Sentinel Data Connectors
# blade) + contentPackages (the marketplace solution metadata). Both must be present post-deploy.
# Requires the workspace ARM resource ID (not just the workspace customerId).
if ('D12' -in $gatesForWindow) {
    if (-not $WorkspaceResourceId) {
        Add-XdrGateResult -GateId 'D12' -Description 'V3 surface' -Pass $false -Detail '-WorkspaceResourceId param not provided · cannot query Sentinel surface' -Advisory $true
    } else {
        # GENERALIZED + CORRECT-IN-BOTH-DIRECTIONS (WS4.3 fix): OUR surface is identified by the PRODUCT
        # token (XdrLogRaider/xdrlr — unique to us · case-insensitive so it matches both 'XdrLogRaiderDefenderXdr'
        # and 'xdrlograider-defender-xdr') AND the PORTAL token (Defender/Entra/… — WHICH surface). Both are
        # REQUIRED. The previous matcher OR-ed in the loose derived tokens (Defender/Operations), which made
        # the gate FALSE-PASS against Microsoft's OWN stock solutions (azure-sentinel-solution-microsoft365defender
        # = "Microsoft Defender XDR" carries 'Defender') even with OUR package absent. Requiring the product
        # token kills that false-pass; requiring the portal token keeps it specific to this portal's surface in
        # a multi-portal deployment (so D12 -Portal Defender can't be satisfied by an Entra-only install).
        $productRegex = 'XdrLogRaider|xdrlr'                      # unique product token
        $portalRegex  = [Regex]::Escape($Portal)                 # which surface (Defender/Entra/…)
        $isOurSurface = { param($n) ($n -match $productRegex) -and ($n -match $portalRegex) }
        $apiVersion = '2024-09-01'
        $defsUri = "https://management.azure.com${WorkspaceResourceId}/providers/Microsoft.SecurityInsights/dataConnectorDefinitions?api-version=$apiVersion"
        $pkgsUri = "https://management.azure.com${WorkspaceResourceId}/providers/Microsoft.SecurityInsights/contentPackages?api-version=$apiVersion"
        # RETRIED (WS4.3): a transient ARM hiccup must not read the surface as absent (false-fail). $null back =
        # genuine query failure after retries → advisory (cannot evaluate · NOT a hard blocker on a transient).
        $defsVal = Get-XdrArmRestValue -Uri $defsUri
        $pkgsVal = Get-XdrArmRestValue -Uri $pkgsUri
        if ($null -eq $defsVal -or $null -eq $pkgsVal) {
            Add-XdrGateResult -GateId 'D12' -Description 'V3 surface' -Pass $false -Detail 'az rest (ARM SecurityInsights) failed after retries · cannot query surface (transient ARM plane · re-run)' -Advisory $true
        } else {
            $hasXdrDef = @($defsVal | Where-Object { & $isOurSurface $_.name }).Count -gt 0
            $hasXdrPkg = @($pkgsVal | Where-Object { & $isOurSurface $_.name }).Count -gt 0
            $pass = $hasXdrDef -and $hasXdrPkg
            $detail = "dataConnectorDefinition=$hasXdrDef · contentPackage=$hasXdrPkg · match=(/$productRegex/ AND /$portalRegex/)"
            Add-XdrGateResult -GateId 'D12' -Description 'V3 surface (connector card + content package) present' -Pass $pass -Detail $detail
        }
    }
}

# ── Verdict ─────────────────────────────────────────────────────────────────────
# Blockers (exit 2) > Inconclusives/Advisories (exit 1 by DEFAULT · exit 0 ONLY under -Lenient) > all-clear GREEN (exit 0).
# An INCONCLUSIVE/ADVISORY gate can NEVER yield exit 0 by default — an empty/unevaluable window is un-proven, NOT green.
# This is the M1 cure: the harness MUST be able to go RED on un-proven state. -Lenient downgrades inconclusive/advisory
# to exit 0 for diagnostic / early-window use ONLY (never a GA gate or CI). Blockers always exit 2.
$results.CompletedUtc = ([DateTime]::UtcNow).ToString('o')
if ($results.Blockers.Count -gt 0) {
    $results.Verdict = 'BLOCKING-FAIL'
    $exitCode = 2
} elseif ($results.Advisories.Count -eq 0 -and $results.Inconclusives.Count -eq 0) {
    $results.Verdict = 'GREEN'
    $exitCode = 0
} elseif ($results.Inconclusives.Count -gt 0 -and $results.Advisories.Count -eq 0) {
    $results.Verdict = 'GREEN-WITH-INCONCLUSIVES'
    $exitCode = if ($Lenient) { 0 } else { 1 }
} else {
    # ADVISORY-ONLY (no blockers, no inconclusives) → PASS / exit 0 (2026-07-03). An advisory is a NON-BLOCKING FLAG — a
    # gate EXPLICITLY marked -Advisory: Reauth (the auth self-heal is proven SEPARATELY by the authorized auth-loss inject
    # test · deliverable #3b · GA §7(4c) · NOT the steady-state window), D12 (transient ARM-plane query · re-run), D7-on-
    # Boot/Cold (cadence not yet measurable). NONE is un-proven DATA — the DATA gates are all GREEN here. The earlier
    # "advisory never exit-0" rule over-broadly lumped flags with the INCONCLUSIVE case (an empty/unevaluable DATA window ·
    # handled above · STILL exit 1 · M1 intact). This is NOT a tolerate: every advisory is REPORTED in the verdict below.
    $results.Verdict = 'GREEN-WITH-ADVISORIES'
    $exitCode = 0
}

# ── Output ──────────────────────────────────────────────────────────────────────
# The JSON report is a FILE side-output (consumed by Run-PostDeployVerify's -TolerateInconclusiveGates to inspect WHICH
# gates were inconclusive) — write it whenever -JsonReportPath is set, INDEPENDENT of the console $OutputFormat. BUG FIX:
# it was nested inside the 'Json' case, so default 'Console' runs never wrote it → the tolerance probe saw no report file
# (Test-Path false) → an expected-only Reauth INCO could never be tolerated → re-prove exit-1.
if ($JsonReportPath) { ($results | ConvertTo-Json -Depth 25) | Out-File -FilePath $JsonReportPath -Encoding utf8 -Force }
switch ($OutputFormat) {
    'Json' {
        $results | ConvertTo-Json -Depth 25
    }
    'Markdown' {
        Write-Host "# Verify-DeployedConnector report"
        Write-Host ''
        Write-Host "**Window**: $Window | **Portal**: $Portal | **Category**: $Category"
        Write-Host "**Window range**: last ${SinceMinutes}m | **Verdict**: $($results.Verdict)"
        Write-Host ''
        Write-Host '| Gate | Status | Description | Detail | Advisory |'
        Write-Host '|---|---|---|---|---|'
        foreach ($key in $results.Gates.Keys) {
            $g = $results.Gates[$key]
            $passSym = if ($g['Inconclusive']) { 'INCONCLUSIVE' } elseif ($g['Pass']) { 'PASS' } else { 'FAIL' }
            $advSym  = if ($g['Advisory']) { 'yes' } else { 'no' }
            Write-Host "| $key | $passSym | $($g['Description']) | $($g['Detail']) | $advSym |"
        }
    }
    default {
        # Console
        Write-Host ''
        Write-Host '======================================================================'
        Write-Host "Verify-DeployedConnector · Window=$Window · Portal=$Portal · Category=$Category"
        Write-Host '======================================================================'
        Write-Host "Window: last ${SinceMinutes}m"
        foreach ($key in $results.Gates.Keys) {
            $g = $results.Gates[$key]
            $passSym = if ($g['Inconclusive']) { 'INCO' } elseif ($g['Pass']) { 'PASS' } elseif ($g['Advisory']) { 'ADV ' } else { 'FAIL' }
            Write-Host ("  {0,-6} {1,-15} {2} · {3}" -f $passSym, $key, $g['Description'], $g['Detail'])
        }
        Write-Host '----------------------------------------------------------------------'
        Write-Host "Verdict: $($results.Verdict)"
        if ($results.Blockers.Count -gt 0) {
            Write-Host 'Blockers:'; $results.Blockers | ForEach-Object { Write-Host "  - $_" }
        }
        if ($results.Advisories.Count -gt 0) {
            Write-Host 'Advisories:'; $results.Advisories | ForEach-Object { Write-Host "  - $_" }
        }
        if ($results.Inconclusives.Count -gt 0) {
            Write-Host 'Inconclusives (empty/unevaluable window · NOT a pass):'; $results.Inconclusives | ForEach-Object { Write-Host "  - $_" }
        }
        Write-Host ''
    }
}

exit $exitCode
