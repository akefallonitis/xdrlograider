# Xdr-Poll/run.ps1 — TimerTrigger every 5 min (v0.1.0 full chain · Plan §0l).
#
# Full pipeline (Plan §3.1 layer L6):
#   Telemetry → Auth → Discovery → Filter → Request (R-B) → Projection (R-A)
#   → Send → Heartbeat (R-B/C cols)
#
# Modules chained (no new functions added · existing exports only):
#   Xdr.Common.Telemetry  → Set-XdrCorrelationId, Get-XdrCorrelationId
#   Xdr.Auth              → Get-XdrAuthFromKeyVault, Connect-DefenderPortal
#   Xdr.Poll              → Discover-XdrPortalCapabilities, Test-XdrEndpointAllowedByCapabilities,
#                           Invoke-DefenderApiproxy, AuthChainBrokenException
#   Xdr.Parser            → Apply-XdrProjectionMap
#   Xdr.Ingest            → Send-ToDce, Write-Heartbeat
#
# Row schema (Plan §3.3): TimeGenerated · Portal · SubArea · Slug · Endpoint ·
#   SuccessKind · StatusCode · LicenseHint · IngestionMode · ConnectorVersion ·
#   CorrelationId · ProjectedData (dynamic · R-A primary) · RawJson (64KB capped · debug)
#
# SuccessKind enum (Plan §3.6 · D-13): live | live-empty | rate-limited | error
# Status enum (Plan §3.6): OK | AuthFatal | Error | Degraded | Capability
#
# Env vars (set by ARM mainTemplate):
#   KEYVAULT_NAME · DCE_ENDPOINT · DCR_IMMUTABLE_ID · MANIFEST_PATH · CONNECTOR_VERSION

param($Timer)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Env validation ───────────────────────────────────────────────────────────
$kvName = $env:KEYVAULT_NAME
$dce    = $env:DCE_ENDPOINT
$dcrId  = $env:DCR_IMMUTABLE_ID
$mfPath = $env:MANIFEST_PATH
$ver    = $env:CONNECTOR_VERSION
if (-not $kvName) { throw 'KEYVAULT_NAME app setting not set' }
if (-not $dce)    { throw 'DCE_ENDPOINT app setting not set' }
if (-not $dcrId)  { throw 'DCR_IMMUTABLE_ID app setting not set' }
if (-not $mfPath) { $mfPath = Join-Path $PSScriptRoot '..\..\manifests\defender.psd1' }
if (-not $ver)    { $ver = '0.1.0' }

# ── P4 · Workspace-context PathParam 5-tuple (parse workspaceResourceId once) ──
# Lifts ~20 PathParamGated entries to active Probe by resolving:
#   {subscriptionId} {resourceGroupName} {workspaceName} {workspaceId} {tenantId}
# Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws>
$workspaceContext = @{
    subscriptionId    = ''
    resourceGroupName = ''
    workspaceName     = ''
    workspaceId       = ''
    tenantId          = ''
}
if ($env:WORKSPACE_RESOURCE_ID) {
    $parts = $env:WORKSPACE_RESOURCE_ID -split '/'
    if ($parts.Count -ge 9 -and $parts[1] -eq 'subscriptions' -and $parts[3] -eq 'resourceGroups') {
        $workspaceContext.subscriptionId    = $parts[2]
        $workspaceContext.resourceGroupName = $parts[4]
        $workspaceContext.workspaceName     = $parts[8]
    }
}
if ($env:WORKSPACE_CUSTOMER_ID) { $workspaceContext.workspaceId = $env:WORKSPACE_CUSTOMER_ID }
if ($env:AZURE_TENANT_ID) { $workspaceContext.tenantId = $env:AZURE_TENANT_ID }
Write-Information ("P4 workspace-context resolver: subId={0} rg={1} ws={2} wsId={3} tid={4}" -f `
    ($workspaceContext.subscriptionId -ne '' -as [bool]), `
    ($workspaceContext.resourceGroupName -ne '' -as [bool]), `
    ($workspaceContext.workspaceName -ne '' -as [bool]), `
    ($workspaceContext.workspaceId -ne '' -as [bool]), `
    ($workspaceContext.tenantId -ne '' -as [bool])) -InformationAction Continue

# ── Telemetry (correlation-ID for cycle-wide trace) ──────────────────────────
$correlationId = Set-XdrCorrelationId
$tsStart = Get-Date
Write-Information "Xdr-Poll: cycle start $($tsStart.ToString('o')) correlation=$correlationId" -InformationAction Continue

# ── DLQ handler · writes terminal-4xx rows to XdrIngestDlq Storage Table ─────
# Plan ε.B (HB-2): rows on terminal 4xx ingest fail are otherwise counted as
# failed but lost. With this handler · operator can inspect XdrIngestDlq for
# what was dropped + why. SAMI Storage Table Data Contributor (ε.A · HB-1)
# enables the INSERT. Cycle-scoped scriptblock captures $tenantId + $correlationId.
$storageAccount = $env:STORAGE_ACCOUNT_NAME
$dlqHandler = $null
if ($storageAccount) {
    $dlqHandler = {
        param($Rows, $StatusCode, $Body)
        try {
            foreach ($r in @($Rows)) {
                $partKey = if ($r.PSObject.Properties['Portal'] -and $r.Portal) { [string]$r.Portal } else { 'unknown' }
                $rowKey  = [guid]::NewGuid().ToString()
                $entity  = @{
                    PartitionKey  = $partKey
                    RowKey        = $rowKey
                    FailedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
                    StatusCode    = [int]$StatusCode
                    Slug          = if ($r.PSObject.Properties['Slug']) { [string]$r.Slug } else { '' }
                    SubArea       = if ($r.PSObject.Properties['SubArea']) { [string]$r.SubArea } else { '' }
                    Endpoint      = if ($r.PSObject.Properties['Endpoint']) { [string]$r.Endpoint } else { '' }
                    CorrelationId = if ($r.PSObject.Properties['CorrelationId']) { [string]$r.CorrelationId } else { '' }
                    BodySnippet   = if ($Body) { ([string]$Body).Substring(0, [math]::Min(8192, ([string]$Body).Length)) } else { '' }
                }
                $null = Invoke-XdrStorageTableEntity -Verb INSERT `
                    -StorageAccount $storageAccount -Table 'XdrIngestDlq' `
                    -PartitionKey $partKey -RowKey $rowKey -Entity $entity
            }
        } catch {
            Write-Warning ("Xdr-Poll DLQ write failed: " + $_.Exception.Message)
        }
    }
}

# ── Heartbeat helper (always emit · success or failure) ──────────────────────
function Send-XdrHeartbeat {
    param(
        [string]$Status = 'OK',
        [string]$Note   = '',
        [int]$Sent      = 0,
        [int]$Failed    = 0,
        [int]$Reauth    = 0,
        [int]$Skipped   = 0,
        [bool]$CircuitOpen = $false,
        [hashtable]$Capabilities,
        [string]$Portal = 'Defender',  # φ.AUTH.11 · multi-portal warm-up emits per-portal heartbeats
        [string[]]$OpenCircuits = @()  # Π11.4g · sub-areas with Open circuit at cycle end (surfaces in heartbeat row)
    )
    try {
        $hbParams = @{
            DceEndpoint      = $dce
            DcrImmutableId   = $dcrId
            Status           = $Status
            Portal           = $Portal
            Note             = $Note
            ConnectorVersion = $ver
            SentLastCycle    = $Sent
            FailedLastCycle  = $Failed
            CircuitOpen      = $CircuitOpen
            ReauthCount      = $Reauth
            SkippedThisCycle = $Skipped
            OpenCircuits     = $OpenCircuits   # Π11.4g
        }
        if ($PSBoundParameters.ContainsKey('Capabilities') -and $Capabilities) { $hbParams.Capabilities = $Capabilities }
        Write-Heartbeat @hbParams | Out-Null
    } catch {
        Write-Warning "Xdr-Poll: heartbeat emit failed: $($_.Exception.Message)"
    }
}

# ── 64KB truncation guard for RawJson (DCR field-value limit · Plan §3.5) ────
function Get-TruncatedRawJson {
    param([Parameter(Mandatory)][AllowNull()]$Parsed)
    if ($null -eq $Parsed) { return '' }
    $json = $Parsed | ConvertTo-Json -Depth 50 -Compress
    $maxBytes = 64KB
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
    if ($bytes -le $maxBytes) { return $json }
    # Truncate carefully · keep valid UTF-8 prefix · suffix with ellipsis marker
    return $json.Substring(0, [math]::Min($json.Length, [int]($maxBytes * 0.95))) + '"...TRUNCATED"}'
}

# ── Compose Plan §3.3 row from response + manifest entry ─────────────────────
function New-XdrRow {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$SuccessKind,
        [hashtable]$ProjectedData
    )
    $sc = if ($Response -and $Response.PSObject.Properties['StatusCode']) { [int]$Response.StatusCode } else { -1 }
    $parsed = if ($Response -and $Response.PSObject.Properties['Parsed']) { $Response.Parsed } else { $null }
    $rawJson = Get-TruncatedRawJson -Parsed $parsed
    $pd = if ($ProjectedData) { $ProjectedData } else { @{} }
    [pscustomobject]@{
        TimeGenerated    = (Get-Date).ToUniversalTime().ToString('o')
        Portal           = if ($Entry.ContainsKey('Portal') -and $Entry.Portal) { $Entry.Portal } else { 'Defender' }
        SubArea          = $Entry.SubArea
        Slug             = $Entry.Slug
        Endpoint         = $Entry.Path
        SuccessKind      = $SuccessKind                            # live | live-empty | rate-limited | error
        StatusCode       = $sc
        LicenseHint      = if ($Entry.ContainsKey('LicenseHint')) { [string]$Entry.LicenseHint } else { '' }
        IngestionMode    = if ($Entry.ContainsKey('IngestionMode')) { [string]$Entry.IngestionMode } else { 'SNAPSHOT' }
        ConnectorVersion = $ver
        CorrelationId    = $correlationId
        ProjectedData    = $pd                                     # R-A · primary operator query surface
        RawJson          = $rawJson                                # R-A · 64KB-capped debug fallback
    }
}

# ── φ.E · Runtime helpers (Plan §13 φ.7) ─────────────────────────────────────
# Cadence string → TimeSpan (6-bucket vocabulary · D-2026-05-18p)
function ConvertTo-XdrCadenceTimespan {
    param([string]$Cadence)
    switch ($Cadence) {
        '10m'    { return [timespan]::FromMinutes(10) }
        '30m'    { return [timespan]::FromMinutes(30) }
        '1h'     { return [timespan]::FromHours(1) }
        '6h'     { return [timespan]::FromHours(6) }
        '24h'    { return [timespan]::FromHours(24) }
        'weekly' { return [timespan]::FromDays(7) }
        default  { return [timespan]::FromHours(6) }  # safe default
    }
}

# Parse DCR_IMMUTABLE_ID_MAP app setting (JSON array of {subArea, immutableId, streamName}) into a hashtable
# Π11 · throws on malformed JSON or empty map · caller MUST fail-fast so cycle doesn't run with bad config
# (silent null/empty would cause all rows to drop to DLQ with no clear cause).
function ConvertFrom-XdrDcrImmutableIdMap {
    param([string]$Json)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "DCR_IMMUTABLE_ID_MAP is empty or missing · ARM deployment incomplete · cannot route rows"
    }
    try {
        $arr = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-XdrTelemetry -Level Critical -EventName 'Runtime.DcrMapInvalid' `
            -Message ("DCR_IMMUTABLE_ID_MAP JSON parse failed: {0}" -f $_.Exception.Message) `
            -Properties @{ Length=$Json.Length; First200Chars=$Json.Substring(0,[Math]::Min(200,$Json.Length)); Error=$_.Exception.Message }
        throw "DCR_IMMUTABLE_ID_MAP JSON parse failed · cannot route rows: $($_.Exception.Message)"
    }
    foreach ($item in @($arr)) {
        if ($item -and $item.PSObject.Properties['subArea'] -and $item.PSObject.Properties['immutableId']) {
            $map[[string]$item.subArea] = @{
                ImmutableId = [string]$item.immutableId
                StreamName  = if ($item.PSObject.Properties['streamName']) { [string]$item.streamName } else { ("Custom-Defender_{0}_CL" -f $item.subArea) }
            }
        }
    }
    if ($map.Count -eq 0) {
        Write-XdrTelemetry -Level Critical -EventName 'Runtime.DcrMapEmpty' `
            -Message "DCR_IMMUTABLE_ID_MAP parsed but produced 0 entries · expected >=1 (one per sub-area)" `
            -Properties @{ RawLength=$Json.Length; ParsedItemCount=@($arr).Count }
        throw "DCR_IMMUTABLE_ID_MAP parsed but produced 0 routing entries · check ARM output template"
    }
    return $map
}

# Build pagination next-URL based on $entry.Pagination strategy + continuation token from response
function Get-XdrPaginationContinuation {
    param($Response, [string]$Strategy)
    if (-not $Response -or -not $Response.Parsed) { return $null }
    switch ($Strategy) {
        'nextlink'     { if ($Response.Parsed.PSObject.Properties['nextLink']) { return [string]$Response.Parsed.nextLink } }
        'odata-link'   { if ($Response.Parsed.PSObject.Properties['@odata.nextLink']) { return [string]$Response.Parsed.'@odata.nextLink' } }
        'skip-token'   { if ($Response.Parsed.PSObject.Properties['skipToken']) { return [string]$Response.Parsed.skipToken } }
        'continuation' { if ($Response.Parsed.PSObject.Properties['continuationToken']) { return [string]$Response.Parsed.continuationToken } }
    }
    return $null
}

# Append a query param to URL (handles existing ? vs &)
function Add-XdrUrlQueryParam {
    param([string]$Url, [string]$Name, [string]$Value)
    if (-not $Url -or -not $Name -or -not $Value) { return $Url }
    $sep = if ($Url -match '\?') { '&' } else { '?' }
    "$Url$sep$Name=$([uri]::EscapeDataString($Value))"
}

# ── Main cycle ────────────────────────────────────────────────────────────────
$totalSent = 0; $totalFailed = 0; $reauthCount = 0; $skippedCount = 0; $capabilitiesEmitted = $false
$cadenceSkipped = 0; $circuitSkipped = 0; $pagesProcessed = 0
# CRIT2 (ITER11) · Parse DCR_IMMUTABLE_ID_MAP INSIDE a guarded try so malformed/empty
# env var emits an explicit DcrMapInvalid heartbeat row before terminating · prior
# version threw OUTSIDE the cycle try{} block (L290) → worker died silently · no row
# in XdrConnectorHealth_CL · operator had to read FA logs to root-cause. The
# DcrMapInvalid / DcrMapEmpty telemetry already inside ConvertFrom-XdrDcrImmutableIdMap
# is preserved; this wrapper ALSO emits a visible heartbeat then re-throws.
$dcrMap = $null
try {
    $dcrMap = ConvertFrom-XdrDcrImmutableIdMap -Json $env:DCR_IMMUTABLE_ID_MAP
    Write-Information ("Xdr-Poll: DCR_IMMUTABLE_ID_MAP loaded · {0} sub-areas mapped" -f $dcrMap.Count) -InformationAction Continue
} catch {
    $dcrMapErr = $_.Exception.Message
    Write-Warning ("Xdr-Poll: DCR_IMMUTABLE_ID_MAP parse failed: " + $dcrMapErr)
    try { Send-XdrHeartbeat -Status 'AuthFatal' -Note ("DCR_IMMUTABLE_ID_MAP parse failure · cycle aborted · " + $dcrMapErr) } catch {}
    throw   # re-raise · cycle MUST NOT proceed without DCR routing
}
# Π11.4-EXT C4 · Cross-cycle circuit-breaker state · seed in-memory hashtable from XdrTierState Storage Table
# so Open circuits survive FA recycle. 30-min cooldown logic in the loop body half-opens automatically when
# (now - OpenedAt) > 30min (see L394-409). Failure to query the table is non-fatal — empty $circuitState just
# means we start fresh (matches pre-Π11 behavior · safe degradation).
$circuitState = @{}
if ($storageAccount) {
    try {
        $tsQuery = Invoke-XdrStorageTableEntity -Verb QUERY -StorageAccount $storageAccount -Table 'XdrTierState' -ErrorAction SilentlyContinue
        if ($tsQuery -and $tsQuery.StatusCode -eq 200 -and $tsQuery.Entities) {
            foreach ($ent in @($tsQuery.Entities)) {
                if ($ent -and $ent.PSObject.Properties['RowKey']) {
                    $openedAt = $null
                    if ($ent.PSObject.Properties['OpenedAt'] -and $ent.OpenedAt) {
                        try { $openedAt = [datetime]::Parse([string]$ent.OpenedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch {}
                    }
                    $circuitState[[string]$ent.RowKey] = @{
                        State    = if ($ent.PSObject.Properties['State']) { [string]$ent.State } else { 'Closed' }
                        Failures = if ($ent.PSObject.Properties['Failures']) { [int]$ent.Failures } else { 0 }
                        OpenedAt = $openedAt
                    }
                }
            }
            Write-Information ("Xdr-Poll: XdrTierState cycle-start read · {0} circuit entries restored" -f $circuitState.Count) -InformationAction Continue
        }
    } catch {
        Write-Warning ("Xdr-Poll: XdrTierState query failed (non-fatal · starting with empty circuit state): " + $_.Exception.Message)
    }
}
try {
    # Π11.4-EXT Π11.4j · Manifest mtime cache · skip re-parse when file unchanged across warm cycles.
    # Saves ~50ms/cycle on Y1 Linux Consumption · also makes re-deploy with new manifest hot-reloadable
    # (mtime change → re-parse). $script:* scope persists across runspace invocations of the same FA instance.
    $mfMTime = (Get-Item -LiteralPath $mfPath).LastWriteTimeUtc
    $cacheHit = $false
    if ((Get-Variable -Name 'Manifest' -Scope Script -ErrorAction SilentlyContinue) -and (Get-Variable -Name 'ManifestMTime' -Scope Script -ErrorAction SilentlyContinue)) {
        if ($script:ManifestMTime -eq $mfMTime -and $script:Manifest) {
            $manifest = $script:Manifest
            $cacheHit = $true
        }
    }
    if (-not $cacheHit) {
        # Load manifest · scriptblock evaluator handles dynamic $true that Import-PowerShellDataFile rejects
        $manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $mfPath)))
        $script:Manifest = $manifest
        $script:ManifestMTime = $mfMTime
    }
    $entries = @($manifest.Entries)
    Write-Information ("Xdr-Poll: {0} manifest entries loaded · cache {1}" -f $entries.Count, ($(if ($cacheHit) { 'hit' } else { 'miss' }))) -InformationAction Continue

    # ITER10 · Dependency-topological sort · list-style endpoints first so $entityCache populates
    # before RequiresEntity/PathParamGated entries that may consume those IDs. Heuristic ordering:
    #   1. Probe-mode GET endpoints (lists + simple queries · seed cache)
    #   2. ReadOnlyPost (POST telemetry-query · may also seed)
    #   3. PathParamGated (workspace-context resolver fills 5-tuple)
    #   4. SubPortalAuth (Defender sccauth attempt · license-gated row if 401/403)
    #   5. RequiresEntity (consume cache · pivot endpoints)
    # Note: this is a STABLE sort — within each tier, manifest order preserved.
    $probeModeOrder = @{ 'Probe'=1; 'ReadOnlyPost'=2; 'PathParamGated'=3; 'SubPortalAuth'=4; 'RequiresEntity'=5; 'Excluded'=99 }
    $entries = @($entries | Sort-Object -Property `
        @{Expression={ $probeModeOrder[[string]$_.ProbeMode] }}, `
        @{Expression={ $_.SubArea }}, `
        @{Expression={ $_.Slug }})

    # ITER10 · In-cycle $entityCache · keyed by SourceEntryKey · stores extracted IDs
    # from list-endpoint 2xx responses. RequiresEntity/PathParamGated entries can opt-in
    # via manifest EntitySourceMap field (added by tools/Inject-EntitySources.ps1) to
    # pivot per-ID. Cap 100 IDs/source/cycle to bound runtime + DCR rate. Empty when no
    # EntitySourceMap defined · safe degradation · entries probe with manifest body.
    $entityCache = @{}
    $entityCapPerSource = 100

    # Auth · cache-aware · burns TOTP only on real expiry
    $creds = Get-XdrAuthFromKeyVault -KeyVaultName $kvName
    $portalSession = Connect-DefenderPortal -Credentials $creds
    $session = $portalSession.Session

    # φ.AUTH.11 · D-16 TenantId fallback chain (5 sources · stops at first hit)
    # Plan §10 #12 · D-16 chain · cookie JWT → response header → operator param →
    # TenantContext endpoint → [guid]::Empty
    function Resolve-XdrTenantId {
        param($Session, $PortalSession)
        # 1. Connect-* session.TenantId (operator-passed or extracted by Connect-*)
        if ($PortalSession -and $PortalSession.PSObject.Properties['TenantId'] -and $PortalSession.TenantId) {
            return [string]$PortalSession.TenantId
        }
        # 2. sccauth cookie JWT claim (extract from cookie value if it's JWT-shaped)
        try {
            if ($Session -and $Session.Cookies) {
                $scc = @($Session.Cookies.GetAllCookies() | Where-Object Name -eq 'sccauth' | Select-Object -First 1)
                if ($scc -and $scc[0].Value -and $scc[0].Value -match '^[A-Za-z0-9_-]+\.([A-Za-z0-9_-]+)\.') {
                    $payloadB64 = $Matches[1]
                    $pad = $payloadB64.Replace('-','+').Replace('_','/'); $mod = $pad.Length % 4
                    if ($mod) { $pad = $pad + ('=' * (4 - $mod)) }
                    $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pad))
                    $payload = $payloadJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($payload -and $payload.PSObject.Properties['tid'] -and $payload.tid) {
                        return [string]$payload.tid
                    }
                }
            }
        } catch { }
        # 3. $env:AZURE_TENANT_ID (mainTemplate.json appSetting via subscription().tenantId)
        if ($env:AZURE_TENANT_ID) { return [string]$env:AZURE_TENANT_ID }
        # 4. TenantContext endpoint result (already-fetched by capability discovery · fallback only)
        # 5. [guid]::Empty.ToString() · keeps cache-key shape stable · operator can grep for empty
        [guid]::Empty.ToString()
    }
    $tenantId = Resolve-XdrTenantId -Session $session -PortalSession $portalSession

    # φ.AUTH.11 · Cross-portal cold-start warm-up · scaffold for v0.3.0 active polling
    # 4 non-Defender portals connect ONCE at cold-start · per-portal Capability heartbeat
    # · failure of any single portal does NOT fail the cycle (Status=Degraded for that one)
    # · BLOCKS v0.3.0 active polling work which extends each portal to per-cycle iteration
    $warmUpResults = @{}
    foreach ($portalSpec in @(
        @{ Portal='Purview';         Fn='Connect-PurviewPortal';        Params=@{} }
        @{ Portal='Entra';           Fn='Connect-EntraPortal';          Params=@{ SubPortal='IAM' } }
        @{ Portal='Intune';          Fn='Connect-IntunePortal';         Params=@{ SubPortal='Portal' } }
        @{ Portal='SecurityCopilot'; Fn='Connect-SecurityCopilotPortal'; Params=@{} }
    )) {
        $pName = $portalSpec.Portal
        try {
            $fn = Get-Command $portalSpec.Fn -ErrorAction Stop
            $paramSet = @{ Credentials = $creds }
            foreach ($k in $portalSpec.Params.Keys) { $paramSet[$k] = $portalSpec.Params[$k] }
            $pSess = & $fn @paramSet
            $warmUpResults[$pName] = @{ Status = 'Capability'; RefreshType = $pSess.RefreshType }
            Write-XdrTelemetry -Level Information -EventName 'Auth.MultiPortalWarmUp.Ok' `
                -Message "Cold-start warm-up succeeded for $pName" `
                -Properties @{ Portal=$pName; RefreshType=$pSess.RefreshType }
        } catch {
            $warmUpResults[$pName] = @{ Status = 'Degraded'; Error = $_.Exception.Message }
            Write-XdrTelemetry -Level Warning -EventName 'Auth.MultiPortalWarmUp.Degraded' `
                -Message "Cold-start warm-up failed for $pName : $($_.Exception.Message)" `
                -Properties @{ Portal=$pName; Error=$_.Exception.Message }
        }
    }
    # Emit one Capability heartbeat per non-Defender portal · operators can detect missing portals
    foreach ($pName in $warmUpResults.Keys) {
        $r = $warmUpResults[$pName]
        $note = "warm-up: $pName · status=$($r.Status)"
        if ($r.Status -eq 'Capability') { $note += " · refresh=$($r.RefreshType)" }
        if ($r.Status -eq 'Degraded')   { $note += " · err=$($r.Error)" }
        try { Send-XdrHeartbeat -Status $r.Status -Note $note -Portal $pName } catch {}
    }

    $capSnapshot = Discover-XdrPortalCapabilities -TenantId $tenantId
    # Emit Capability heartbeat row once per cold-start
    if ($capSnapshot -and -not $capabilitiesEmitted) {
        $capProducts = @{}
        if ($capSnapshot.PSObject.Properties['Portals'] -and $capSnapshot.Portals) {
            foreach ($k in $capSnapshot.Portals.Keys) {
                # Π10 · Guard against missing ProductsAvailable property under StrictMode
                $portal = $capSnapshot.Portals[$k]
                $products = if ($portal -and $portal.PSObject.Properties['ProductsAvailable']) { @($portal.ProductsAvailable) } else { @() }
                $capProducts[$k] = $products
            }
        }
        Send-XdrHeartbeat -Status 'Capability' -Note 'cold-start discovery' -Capabilities $capProducts
        $capabilitiesEmitted = $true
    }

    # Per-entry iteration (φ.E · pagination + checkpoint + cadence-skip + time-filter + circuit + stream router)
    foreach ($e in $entries) {
        try {
            # ITER10 · ProbeMode gate · only Excluded is HARD skip (mutations · destructive · never call)
            #   Probe          = GET endpoint · run as-is
            #   ReadOnlyPost   = POST telemetry-query endpoint · BodyTemplate from Postman canonical (P5)
            #   PathParamGated = GET/POST with {placeholder} · workspace-context resolver fills 5-tuple · others soft-skip (sc=-2)
            #   SubPortalAuth  = needs sub-portal cookie · attempts with Defender sccauth · 401/403 = license-gated row · manifest ProjectionMap doc-only
            #   RequiresEntity = needs entity ID in body/path · in-cycle $entityCache fills when source list endpoint ran first · else probes with manifest body (may 4xx)
            #   Excluded       = side-effect endpoint (Create/Update/Delete/Invoke/Run) · NEVER call · connector is read-only
            $probeMode = if ($e.ContainsKey('ProbeMode') -and $e.ProbeMode) { [string]$e.ProbeMode } else { 'Probe' }
            if ($probeMode -eq 'Excluded') {
                $skippedCount++
                Write-XdrTelemetry -Level Verbose -EventName 'Runtime.ProbeModeSkip' `
                    -Message ("ProbeMode-skip {0}::{1} · mode=Excluded · method={2} · destructive · never-call invariant" -f $e.SubArea, $e.Slug, $e.Method) `
                    -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; Method=$e.Method; ProbeMode=$probeMode; NodocRoute=$e.NodocRoute }
                continue
            }

            # Π11 · R-C capability filter BYPASSED for v0.1.0 · real Discover-XdrPortalCapabilities
            # is a stub (Xdr.Poll.psm1:239-286 · ProductsAvailable=@()) · the filter would reject
            # all 410 license-gated entries. Bypass returns $true unconditionally · endpoints
            # attempt naturally · API-level 401/403/404 handles license-blocked at runtime · DLQ
            # catches errors. Real R-C implementation deferred to v0.2.0 with operator probe.
            if (-not (Test-XdrEndpointAllowedByCapabilities -ManifestEntry $e -CapabilitySnapshot $capSnapshot)) {
                $skippedCount++
                continue
            }

            # ── φ.E · Checkpoint read (Plan §13 φ.7) ──
            # ITER6 R1 · Invoke-XdrStorageTableEntity -Verb GET returns [pscustomobject]@{StatusCode;Entity;Error}
            # The actual table-row fields live on $cp.Entity · NOT on $cp directly. Prior code checked
            # `$cp.PSObject.Properties['LastPolledUtc']` which is always $false · cadence-skip + time-filter
            # + resume-from-checkpoint were ALL silently no-ops. Unwrap to $cp.Entity (when 200) or $null.
            $cpEntity = $null
            if ($storageAccount) {
                try {
                    $cpResp = Invoke-XdrStorageTableEntity -Verb GET `
                        -StorageAccount $storageAccount -Table 'XdrCheckpoint' `
                        -PartitionKey $e.Portal -RowKey $e.Slug -ErrorAction SilentlyContinue
                    if ($cpResp -and $cpResp.PSObject.Properties['StatusCode'] -and $cpResp.StatusCode -eq 200 -and $cpResp.Entity) {
                        $cpEntity = $cpResp.Entity
                    }
                } catch { $cpEntity = $null }
            }
            $lastPolledUtc     = if ($cpEntity -and $cpEntity.PSObject.Properties['LastPolledUtc']) { [string]$cpEntity.LastPolledUtc } else { $null }
            $lastCompletedPage = if ($cpEntity -and $cpEntity.PSObject.Properties['LastCompletedPage']) { [int]$cpEntity.LastCompletedPage } else { 0 }
            $resumeContinuationToken = if ($cpEntity -and $cpEntity.PSObject.Properties['ContinuationToken']) { [string]$cpEntity.ContinuationToken } else { $null }

            # ── φ.E · Cadence-skip (D-2026-05-18p) ──
            $cadenceVal = if ($e.ContainsKey('Cadence') -and $e.Cadence) { [string]$e.Cadence } else { '6h' }
            $cadenceTs = ConvertTo-XdrCadenceTimespan -Cadence $cadenceVal
            if ($lastPolledUtc) {
                try {
                    # Π10 · AssumeUniversal+AdjustToUniversal prevents double-convert on local TZ != UTC
                    $lastPolledDt = [datetime]::Parse($lastPolledUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind -bor [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                    $age = [datetime]::UtcNow - $lastPolledDt
                    if ($age -lt $cadenceTs) {
                        $cadenceSkipped++
                        Write-XdrTelemetry -Level Verbose -EventName 'Runtime.CadenceSkip' `
                            -Message ("Cadence-skip {0}::{1} · cadence={2} · ageSec={3}" -f $e.SubArea, $e.Slug, $cadenceVal, [int]$age.TotalSeconds) `
                            -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; Cadence=$cadenceVal; AgeSeconds=[int]$age.TotalSeconds }
                        continue
                    }
                } catch {
                    # Non-fatal · LastPolledUtc malformed → treat as never-polled · proceed with cycle
                    Write-XdrTelemetry -Level Verbose -EventName 'Runtime.CadenceSkipParseFail' `
                        -Message ("LastPolledUtc parse failed for {0}::{1} · {2}" -f $e.SubArea, $e.Slug, $_.Exception.Message) `
                        -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; LastPolledUtc=[string]$lastPolledUtc }
                }
            }

            # ── φ.E · Per-sub-area circuit-breaker (D-18) ──
            $cb = if ($circuitState.ContainsKey($e.SubArea)) { $circuitState[$e.SubArea] } else { @{ State='Closed'; Failures=0; OpenedAt=$null } }
            # Π11 ITER2-R3 · capture prior state · used at success-branch to detect Open/HalfOpen→Closed
            # transition and UPSERT XdrTierState recovery row (stale Open survived cold-start otherwise).
            $priorCbState = [string]$cb.State
            if ($cb.State -eq 'Open' -and $cb.OpenedAt) {
                $cooldownSec = ([datetime]::UtcNow - $cb.OpenedAt).TotalSeconds
                if ($cooldownSec -lt 1800) {  # 30-min cooldown
                    $circuitSkipped++
                    Write-XdrTelemetry -Level Warning -EventName 'Runtime.CircuitOpenSkip' `
                        -Message ("Circuit OPEN for SubArea={0} · cooldown {1}s remaining" -f $e.SubArea, (1800 - [int]$cooldownSec)) `
                        -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; CooldownRemainSec=(1800 - [int]$cooldownSec) }
                    continue
                }
                # cooldown elapsed · half-open · try again
                $cb.State = 'HalfOpen'
            }

            # ── φ.E · Stream router (per-sub-area DCR) ──
            $dcrRoute = if ($dcrMap.ContainsKey($e.SubArea)) { $dcrMap[$e.SubArea] } else { $null }
            if (-not $dcrRoute) {
                Write-XdrTelemetry -Level Error -EventName 'Runtime.DcrLookupMiss' `
                    -Message ("No DCR for SubArea={0} · check DCR_IMMUTABLE_ID_MAP app setting" -f $e.SubArea) `
                    -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug }
                $totalFailed++
                continue
            }
            $perSubAreaDcrId  = $dcrRoute.ImmutableId
            $perSubAreaStream = $dcrRoute.StreamName

            # ── φ.E · Pagination loop (D-19 · resume from LastCompletedPage) ──
            # Π10 · Guard against empty-string continuation token from checkpoint replay
            # ($resumeContinuationToken==='' would cause infinite re-fetch of page 1 url)
            $page = if ($lastCompletedPage -gt 0 -and -not [string]::IsNullOrEmpty($resumeContinuationToken)) { $lastCompletedPage + 1 } else { 1 }
            $continuation = if ([string]::IsNullOrEmpty($resumeContinuationToken)) { $null } else { $resumeContinuationToken }
            $loopGuard = 0; $entrySent = 0; $entryFailed = 0
            # Π10 · Hoist paginationKey OUT of if($continuation) branch so TF self-heal
            # can reference it on first-page rejection without StrictMode PropertyNotFoundException
            $paginationKey = switch ([string]$e.Pagination) {
                'skip-token'   { '$skipToken' }
                'continuation' { 'continuationToken' }
                'nextlink'     { 'nextLink' }
                'odata-link'   { '$skiptoken' }
                default        { '' }
            }
            do {
                $loopGuard++
                # Π10 · Raised 100→1000 · production tenants can have 1000+ pages (vuln_mgmt 50K items)
                # Checkpoint resumability still handles cycle-overrun (next cycle continues from LastCompletedPage)
                if ($loopGuard -gt 1000) {
                    Write-XdrTelemetry -Level Warning -EventName 'Runtime.PaginationLoopGuardHit' `
                        -Message ("Endpoint {0}::{1} hit 1000-page per-cycle cap · checkpoint persists for next cycle resume" -f $e.SubArea, $e.Slug) `
                        -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; PagesProcessed=$loopGuard; ContinuationToken=[string]$continuation }
                    break
                }

                # Build URL · inject TimeFilter param on first page · continuation token on subsequent
                $url = [string]$e.Path
                $tfSupported = $e.ContainsKey('TimeFilter') -and $e.TimeFilter -eq 'Supported'
                $tfParam = if ($e.ContainsKey('TimeFilterParam') -and $e.TimeFilterParam) { [string]$e.TimeFilterParam } else { 'since' }
                $tfInjected = $false
                if ($tfSupported -and $lastPolledUtc -and $loopGuard -eq 1) {
                    try {
                        # Π10 · Use ParseExact-equivalent with AssumeUniversal+AdjustToUniversal · prevents double-convert when local TZ != UTC
                        $sinceUtc = [datetime]::Parse($lastPolledUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind -bor [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                        $sinceStr = $sinceUtc.AddMinutes(-5).ToString('o')  # 5-min overlap safety
                        $url = Add-XdrUrlQueryParam -Url $url -Name $tfParam -Value $sinceStr
                        $tfInjected = $true
                    } catch {
                        Write-XdrTelemetry -Level Verbose -EventName 'Runtime.TimeFilterParseFail' `
                            -Message ("Could not parse LastPolledUtc='{0}' · {1}" -f $lastPolledUtc, $_.Exception.Message) `
                            -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; LastPolledUtc=[string]$lastPolledUtc }
                    }
                }
                if ($continuation -and $paginationKey) {
                    $url = Add-XdrUrlQueryParam -Url $url -Name $paginationKey -Value $continuation
                }

                # ITER5 C1+C3 + P4 · Build per-entry Query (from Postman) + Workspace-context PathParams
                $entryQuery = if ($e.ContainsKey('Query') -and $e.Query) { $e.Query } else { @{} }
                $entryHeaders = if ($e.ContainsKey('Headers') -and $e.Headers) { $e.Headers.Clone() } else { @{} }
                $entryPathParams = @{
                    'subscriptionId'    = $workspaceContext.subscriptionId
                    'resourceGroupName' = $workspaceContext.resourceGroupName
                    'workspaceName'     = $workspaceContext.workspaceName
                    'workspaceId'       = $workspaceContext.workspaceId
                    'tenantId'          = if ($workspaceContext.tenantId) { $workspaceContext.tenantId } else { $tenantId }
                }
                # ITER10 · Entity-chain · if entry has EntitySourceMap, fill first cached ID for each
                # placeholder. For multi-ID fan-out, runtime stays simple (1 call per entry/cycle)
                # · v0.2.0 can extend to per-ID fan-out with cap_per_source=100 + paginated emit.
                if ($e.ContainsKey('EntitySourceMap') -and $e.EntitySourceMap) {
                    foreach ($phName in $e.EntitySourceMap.Keys) {
                        $esmEntry = $e.EntitySourceMap[$phName]
                        if (-not $esmEntry -or -not $esmEntry.ContainsKey('SourceEntryKey')) { continue }
                        $srcKey = [string]$esmEntry.SourceEntryKey
                        if ($entityCache.ContainsKey($srcKey) -and @($entityCache[$srcKey]).Count -gt 0) {
                            $entryPathParams[$phName] = [string]@($entityCache[$srcKey])[0]
                        }
                    }
                }
                # P5 · ReadOnlyPost active polling · wire BodyTemplate as JSON body for POST endpoints
                $entryBody = $null
                if ($e.Method -eq 'POST' -and $e.ContainsKey('BodyTemplate') -and $e.BodyTemplate) {
                    try {
                        # BodyTemplate is JSON string from Postman canonical · pass through to Invoke-XdrAuthHttp
                        $entryBody = [string]$e.BodyTemplate
                    } catch { $entryBody = $null }
                }
                $invokeArgs = @{
                    Path        = $url
                    Session     = $session
                    Method      = $e.Method
                    Headers     = $entryHeaders
                    Query       = $entryQuery
                    PathParams  = $entryPathParams
                    MaxRetries  = 1
                }
                if ($null -ne $entryBody) { $invokeArgs.Body = $entryBody }
                $response = Invoke-DefenderApiproxy @invokeArgs
                $sc = [int]$response.StatusCode

                # Pi8d · TimeFilter self-healing · if endpoint 400-rejects time-filter param
                # (Pi2 heuristic guessed wrong · G-D14 mitigation) · retry once WITHOUT the
                # time-filter param · log telemetry for operator visibility · operator can
                # demote via manifest edit + re-deploy if pattern persists.
                if ($sc -eq 400 -and $tfInjected) {
                    Write-XdrTelemetry -Level Warning -EventName 'Runtime.TimeFilterRejected' `
                        -Message ("Endpoint {0}::{1} 400-rejected ?{2}=<utc> · retrying without time-filter" -f $e.SubArea, $e.Slug, $tfParam) `
                        -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; TimeFilterParam=$tfParam; Strategy='self-heal-retry-without-tf' }
                    # Rebuild URL without time-filter · preserve continuation if present
                    $urlNoTF = [string]$e.Path
                    if ($continuation -and $paginationKey) {
                        $urlNoTF = Add-XdrUrlQueryParam -Url $urlNoTF -Name $paginationKey -Value $continuation
                    }
                    $response = Invoke-DefenderApiproxy -Path $urlNoTF -Session $session -Method $e.Method -Headers $entryHeaders -Query $entryQuery -PathParams $entryPathParams -MaxRetries 1
                    $sc = [int]$response.StatusCode
                }

                # ITER6 R2 · Path-param-missing soft-skip (Invoke-DefenderApiproxy returns StatusCode=-2 sentinel
                # when {placeholders} can't be filled · DON'T trip circuit · log Runtime.PathParamMissing + skip)
                if ($sc -eq -2) {
                    $unresolved = if ($response.PSObject.Properties['UnresolvedParams']) { @($response.UnresolvedParams) } else { @() }
                    Write-XdrTelemetry -Level Information -EventName 'Runtime.PathParamMissing' `
                        -Message ("Path-param soft-skip {0}::{1} · unresolved={2}" -f $e.SubArea, $e.Slug, ($unresolved -join ',')) `
                        -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; Path=[string]$e.Path; Unresolved=($unresolved -join ',') }
                    $skippedCount++
                    break    # exit pagination loop · go to next entry
                }

                # ITER5 C5 · Refined 4xx classification (operator-corrected · license-gated soft-skip · 400=our-fault DLQ)
                #   2xx          → live or live-empty (normal flow)
                #   401 / 403    → license-gated · emit 'license-blocked' row w/ ProjectionMap from manifest fallback (works in production tenant)
                #   404          → endpoint-deprecated · emit 'not-found' row with empty ProjectedData · soft-skip
                #   429          → rate-limited · backoff (handled in Invoke-DefenderApiproxy)
                #   400 / 405    → OUR request wrong · DLQ + Runtime.BadRequest telemetry · operator MUST fix manifest
                #   5xx          → service-side · emit 'error' row · normal circuit-breaker logic
                $successKind = if ($sc -eq 429) { 'rate-limited' }
                               elseif ($sc -ge 200 -and $sc -lt 300 -and $response.Parsed) { 'live' }
                               elseif ($sc -ge 200 -and $sc -lt 300) { 'live-empty' }
                               elseif ($sc -in 401,403) { 'license-blocked' }
                               elseif ($sc -eq 404) { 'not-found' }
                               elseif ($sc -in 400,405) { 'bad-request' }
                               else { 'error' }
                if ($successKind -eq 'license-blocked') {
                    Write-XdrTelemetry -Level Information -EventName 'Auth.LicenseGated' `
                        -Message ("License gate {0}::{1} · StatusCode={2} · LicenseHint={3} · soft-skip · row emitted with manifest ProjectionMap (works in licensed tenant)" -f $e.SubArea, $e.Slug, $sc, $e.LicenseHint) `
                        -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; StatusCode=$sc; LicenseHint=[string]$e.LicenseHint }
                } elseif ($successKind -eq 'bad-request') {
                    Write-XdrTelemetry -Level Warning -EventName 'Runtime.BadRequest' `
                        -Message ("400/405 on {0}::{1} · StatusCode={2} · request shape wrong · operator fix manifest Query/Headers/Method/Path" -f $e.SubArea, $e.Slug, $sc) `
                        -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; StatusCode=$sc; Method=$e.Method; HasQuery=$e.ContainsKey('Query'); HasHeaders=$e.ContainsKey('Headers') }
                } elseif ($successKind -eq 'not-found') {
                    Write-XdrTelemetry -Level Information -EventName 'Runtime.EndpointNotFound' `
                        -Message ("404 on {0}::{1} · endpoint deprecated or feature-disabled in tenant" -f $e.SubArea, $e.Slug) `
                        -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug; Method=$e.Method }
                }

                # Apply ProjectionMap · emit ProjectedData primary
                $projected = @{}
                if ($e.ContainsKey('ProjectionMap') -and @($e.ProjectionMap.Keys).Count -gt 0 -and $response.Parsed) {
                    $projected = Apply-XdrProjectionMap -Response $response.Parsed -ProjectionMap $e.ProjectionMap
                }

                # ITER10 · Entity-cache seeding · on 2xx response from a Probe/ReadOnlyPost entry,
                # extract common ID fields and cache by EntryKey so downstream RequiresEntity entries
                # in this cycle can pivot. Heuristic: look for 'id|machineId|deviceId|sha256|alertId|
                # incidentId|outbreakId|userId|aadId|resourceId|caseId|ruleId' fields in arrays.
                if ($successKind -eq 'live' -and $response.Parsed -and $e.ContainsKey('EntryKey')) {
                    try {
                        $arr = $null
                        if ($response.Parsed -is [System.Collections.IEnumerable] -and -not ($response.Parsed -is [string])) {
                            $arr = @($response.Parsed)
                        } elseif ($response.Parsed.PSObject.Properties['value'] -and $response.Parsed.value) {
                            $arr = @($response.Parsed.value)
                        } elseif ($response.Parsed.PSObject.Properties['Results'] -and $response.Parsed.Results) {
                            $arr = @($response.Parsed.Results)
                        } elseif ($response.Parsed.PSObject.Properties['results'] -and $response.Parsed.results) {
                            $arr = @($response.Parsed.results)
                        } elseif ($response.Parsed.PSObject.Properties['data'] -and $response.Parsed.data) {
                            $arr = @($response.Parsed.data)
                        }
                        if ($arr -and @($arr).Count -gt 0) {
                            $idFields = @('id','machineId','deviceId','sha256','sha1','fileHash','alertId','incidentId','outbreakId','userId','aadId','objectId','resourceId','caseId','ruleId','appId','policyId','assetId','cveId','recommendationId','templateId','actionId')
                            $extracted = [System.Collections.Generic.List[string]]::new()
                            foreach ($item in @($arr) | Select-Object -First $entityCapPerSource) {
                                if ($null -eq $item) { continue }
                                if ($item -is [string]) { [void]$extracted.Add($item); continue }
                                foreach ($f in $idFields) {
                                    if ($item.PSObject.Properties[$f] -and $item.$f) { [void]$extracted.Add([string]$item.$f); break }
                                }
                            }
                            if ($extracted.Count -gt 0) {
                                $entityCache[[string]$e.EntryKey] = $extracted.ToArray()
                            }
                        }
                    } catch {
                        # non-fatal · entity-chain is best-effort · runtime continues
                        Write-XdrTelemetry -Level Verbose -EventName 'Runtime.EntityCacheExtractFail' `
                            -Message ("Entity extraction failed for {0}::{1} · {2}" -f $e.SubArea, $e.Slug, $_.Exception.Message) `
                            -Properties @{ SubArea=$e.SubArea; Slug=$e.Slug }
                    }
                }

                $row = New-XdrRow -Entry $e -Response $response -SuccessKind $successKind -ProjectedData $projected
                $sendParams = @{
                    DceEndpoint    = $dce
                    DcrImmutableId = $perSubAreaDcrId
                    StreamName     = $perSubAreaStream
                    Rows           = @($row)
                }
                if ($dlqHandler) { $sendParams.DlqHandler = $dlqHandler }
                $send = Send-ToDce @sendParams
                $entrySent   += [int]$send.Sent
                $entryFailed += [int]$send.Failed
                $pagesProcessed++

                # Read continuation for next iteration
                $continuation = Get-XdrPaginationContinuation -Response $response -Strategy ([string]$e.Pagination)

                # Update checkpoint (resume safety · D-19)
                if ($storageAccount) {
                    try {
                        $null = Invoke-XdrStorageTableEntity -Verb UPSERT `
                            -StorageAccount $storageAccount -Table 'XdrCheckpoint' `
                            -PartitionKey $e.Portal -RowKey $e.Slug `
                            -Entity @{
                                PartitionKey      = $e.Portal
                                RowKey            = $e.Slug
                                LastPolledUtc     = [datetime]::UtcNow.ToString('o')
                                LastCompletedPage = $page
                                ContinuationToken = if ($continuation) { $continuation } else { '' }
                                SubArea           = $e.SubArea
                            } -ErrorAction SilentlyContinue
                    } catch { }
                }
                $page++

                # R-B telemetry · tally reauth signal
                if ($response.PSObject.Properties['Reauthed'] -and $response.Reauthed) { $reauthCount++ }
            } while ($continuation)

            # Endpoint success → close circuit (in-memory)
            $cb.State = 'Closed'; $cb.Failures = 0; $cb.OpenedAt = $null
            $circuitState[$e.SubArea] = $cb
            # Π11 ITER2-R3 · recovery write-back · clear XdrTierState Storage Table row when
            # prior state was Open/HalfOpen. Without this · stale Open row survives cold-start,
            # FA re-loads it at L242-256, and the next 30-min cooldown elapses needlessly on
            # what is actually a healthy sub-area. Idempotent UPSERT · non-fatal on transient.
            if ($storageAccount -and $priorCbState -in @('Open','HalfOpen')) {
                try {
                    $null = Invoke-XdrStorageTableEntity -Verb UPSERT `
                        -StorageAccount $storageAccount -Table 'XdrTierState' `
                        -PartitionKey $e.Portal -RowKey $e.SubArea `
                        -Entity @{
                            PartitionKey = $e.Portal
                            RowKey       = $e.SubArea
                            State        = 'Closed'
                            Failures     = 0
                            OpenedAt     = ''
                            RecoveredAtUtc = ([datetime]::UtcNow.ToString('o'))
                        } -ErrorAction SilentlyContinue
                    Write-XdrTelemetry -Level Information -EventName 'Runtime.CircuitRecovered' `
                        -Message ("Circuit RECOVERED for SubArea={0} (was {1} · now Closed · XdrTierState write-back)" -f $e.SubArea, $priorCbState) `
                        -Properties @{ SubArea=$e.SubArea; PriorState=$priorCbState }
                } catch { }
            }
            $totalSent   += $entrySent
            $totalFailed += $entryFailed
        } catch [AuthChainBrokenException] {
            # φ.AUTH.5 · R-B stage-aware HTML at data-stage = chain broken · attempt
            # mid-cycle reauth (KMSI SSO when possible · zero TOTP) + 1× retry of the
            # failing endpoint. If retry still fails → tally as failed and continue ·
            # the cycle-end heartbeat will reflect the failure count.
            $stage = $_.Exception.Stage
            Write-Warning "Xdr-Poll: AuthChainBroken on $($e.Slug) · stage=$stage · attempting -Force reauth"
            $reauthOk = $false
            $reauthStartUtc = [datetime]::UtcNow
            try {
                $portalSession = Connect-DefenderPortal -Credentials $creds -Force
                $session = $portalSession.Session
                $reauthOk = $true
                Write-XdrTelemetry -Level Information -EventName 'Auth.MidCycleReauth.Succeeded' `
                    -Message "Mid-cycle -Force reauth succeeded · refreshType=$($portalSession.RefreshType)" `
                    -Properties @{ Slug=$e.Slug; Stage=$stage; RefreshType=$portalSession.RefreshType; LatencyMs=[int](([datetime]::UtcNow - $reauthStartUtc).TotalMilliseconds) }
            } catch {
                Write-XdrTelemetry -Level Error -EventName 'Auth.MidCycleReauth.Failed' `
                    -Message "Mid-cycle -Force reauth failed: $($_.Exception.Message)" `
                    -Properties @{ Slug=$e.Slug; Stage=$stage; Error=$_.Exception.Message }
            }
            if ($reauthOk) {
                try {
                    # ITER5 C1+C3 + P4 · retry path also passes manifest Query/Headers/PathParams + workspace context
                    $retryQuery = if ($e.ContainsKey('Query') -and $e.Query) { $e.Query } else { @{} }
                    $retryHeaders = if ($e.ContainsKey('Headers') -and $e.Headers) { $e.Headers.Clone() } else { @{} }
                    $retryPathParams = @{
                        'subscriptionId'    = $workspaceContext.subscriptionId
                        'resourceGroupName' = $workspaceContext.resourceGroupName
                        'workspaceName'     = $workspaceContext.workspaceName
                        'workspaceId'       = $workspaceContext.workspaceId
                        'tenantId'          = if ($workspaceContext.tenantId) { $workspaceContext.tenantId } else { $tenantId }
                    }
                    $retryResp = Invoke-DefenderApiproxy -Path $e.Path -Session $session -Method $e.Method -Headers $retryHeaders -Query $retryQuery -PathParams $retryPathParams -MaxRetries 1
                    $sc2 = [int]$retryResp.StatusCode
                    $sk2 = if ($sc2 -eq 429) { 'rate-limited' }
                           elseif ($sc2 -ge 200 -and $sc2 -lt 300 -and $retryResp.Parsed) { 'live' }
                           elseif ($sc2 -ge 200 -and $sc2 -lt 300) { 'live-empty' }
                           else { 'error' }
                    $proj2 = @{}
                    if ($e.ContainsKey('ProjectionMap') -and @($e.ProjectionMap.Keys).Count -gt 0 -and $retryResp.Parsed) {
                        $proj2 = Apply-XdrProjectionMap -Response $retryResp.Parsed -ProjectionMap $e.ProjectionMap
                    }
                    $retryRow = New-XdrRow -Entry $e -Response $retryResp -SuccessKind $sk2 -ProjectedData $proj2
                    # φ.E · per-sub-area stream router on retry path
                    $retryRoute = if ($dcrMap.ContainsKey($e.SubArea)) { $dcrMap[$e.SubArea] } else { $null }
                    if ($retryRoute) {
                        $sendRetryParams = @{
                            DceEndpoint    = $dce
                            DcrImmutableId = $retryRoute.ImmutableId
                            StreamName     = $retryRoute.StreamName
                            Rows           = @($retryRow)
                        }
                        if ($dlqHandler) { $sendRetryParams.DlqHandler = $dlqHandler }
                        $sendRetry = Send-ToDce @sendRetryParams
                        $totalSent   += [int]$sendRetry.Sent
                        $totalFailed += [int]$sendRetry.Failed
                        Write-XdrTelemetry -Level Information -EventName 'Auth.MidCycleReauth.RetryOk' `
                            -Message "Endpoint retried successfully after reauth · sk=$sk2" `
                            -Properties @{ Slug=$e.Slug; Stage=$stage; StatusCode=$sc2; SuccessKind=$sk2; SubArea=$e.SubArea }
                    } else {
                        Write-XdrTelemetry -Level Error -EventName 'Runtime.DcrLookupMiss' `
                            -Message ("Retry path · no DCR for SubArea={0}" -f $e.SubArea) `
                            -Properties @{ Slug=$e.Slug; SubArea=$e.SubArea }
                        $totalFailed++
                    }
                } catch {
                    Write-XdrTelemetry -Level Warning -EventName 'Auth.MidCycleReauth.RetryFail' `
                        -Message "Endpoint still failed after reauth: $($_.Exception.Message)" `
                        -Properties @{ Slug=$e.Slug; Stage=$stage; Error=$_.Exception.Message }
                    $totalFailed++
                }
            } else {
                $totalFailed++
            }
            $reauthCount++
        } catch {
            # φ.E · Per-sub-area circuit-breaker (D-18 · open at 3 consecutive failures)
            Write-Warning "Xdr-Poll: $($e.Slug) raised: $($_.Exception.Message)"
            $totalFailed++
            $cb = if ($circuitState.ContainsKey($e.SubArea)) { $circuitState[$e.SubArea] } else { @{ State='Closed'; Failures=0; OpenedAt=$null } }
            $cb.Failures = [int]$cb.Failures + 1
            if ($cb.Failures -ge 3 -and $cb.State -ne 'Open') {
                $cb.State = 'Open'; $cb.OpenedAt = [datetime]::UtcNow
                Write-XdrTelemetry -Level Error -EventName 'Runtime.CircuitTripped' `
                    -Message ("Circuit TRIPPED for SubArea={0} after {1} failures" -f $e.SubArea, $cb.Failures) `
                    -Properties @{ SubArea=$e.SubArea; Failures=$cb.Failures; OpenedAt=$cb.OpenedAt.ToString('o') }
                if ($storageAccount) {
                    try {
                        $null = Invoke-XdrStorageTableEntity -Verb UPSERT `
                            -StorageAccount $storageAccount -Table 'XdrTierState' `
                            -PartitionKey $e.Portal -RowKey $e.SubArea `
                            -Entity @{
                                PartitionKey = $e.Portal
                                RowKey       = $e.SubArea
                                State        = 'Open'
                                Failures     = $cb.Failures
                                OpenedAt     = $cb.OpenedAt.ToString('o')
                            } -ErrorAction SilentlyContinue
                    } catch { }
                }
            }
            $circuitState[$e.SubArea] = $cb
        }
    }

    $dur = ((Get-Date) - $tsStart).TotalSeconds
    # Π11.4g · enumerate OpenCircuits for heartbeat surface (operator visibility · no App Insights grep needed)
    $openCircuitList = [string[]]@($circuitState.Keys | Where-Object { $circuitState[$_].State -eq 'Open' })
    $anyCircuitOpen = $openCircuitList.Count -gt 0
    $openNote = if ($anyCircuitOpen) { " openCircuits=" + ($openCircuitList -join ',') } else { '' }
    Send-XdrHeartbeat -Status 'OK' `
        -Note "sent=$totalSent failed=$totalFailed reauth=$reauthCount skipped=$skippedCount cadenceSkipped=$cadenceSkipped circuitSkipped=$circuitSkipped pages=$pagesProcessed elapsedSec=$([int]$dur)$openNote" `
        -Sent $totalSent -Failed $totalFailed -Reauth $reauthCount -Skipped ($skippedCount + $cadenceSkipped + $circuitSkipped) -CircuitOpen $anyCircuitOpen -OpenCircuits $openCircuitList
    Write-Information "Xdr-Poll: cycle end sent=$totalSent failed=$totalFailed reauth=$reauthCount skipped=$skippedCount cadenceSkipped=$cadenceSkipped circuitSkipped=$circuitSkipped pages=$pagesProcessed elapsed=${dur}s" -InformationAction Continue
} catch {
    $msg = $_.Exception.Message
    # ITER6 R6 · AuthFatal classifier · prior regex matched literal string 'AuthChainBrokenException'
    # in exception messages but messages don't carry the type name. Now check the exception TYPE
    # directly (catches AuthChainBrokenException class) · fall back to regex for AADSTS/KMSI/TOTP/sccauth patterns.
    $authFatalRegex = '\bAADSTS\d{5,}\b|Authentication failed|TOTP rejected|KMSI SSO failed|sccauth cookie expired|sccauth not present|AuthChainBroken|circuit OPEN'
    $isAuthChainBroken = $false
    try { $isAuthChainBroken = $_.Exception -is [AuthChainBrokenException] } catch {}
    $status = if ($isAuthChainBroken -or $msg -match $authFatalRegex) { 'AuthFatal' } else { 'Error' }
    # Π11 ITER3 · symmetry with success-branch heartbeat at L713 · also surface any partially-discovered
    # open circuits (cycle aborted mid-loop) so operators see them without App Insights grep.
    $catchOpenCircuits = if (Get-Variable -Name circuitState -Scope Local -ErrorAction SilentlyContinue) {
        [string[]]@($circuitState.Keys | Where-Object { $circuitState[$_].State -eq 'Open' })
    } else { @() }
    Send-XdrHeartbeat -Status $status -Note ($msg.Substring(0, [math]::Min(200, $msg.Length))) `
        -Sent $totalSent -Failed $totalFailed -Reauth $reauthCount -Skipped $skippedCount `
        -OpenCircuits $catchOpenCircuits
    Write-Error "Xdr-Poll: cycle failed: $msg"
    throw
}
