#Requires -Version 7.4
<#
.SYNOPSIS
    Captures live /apiproxy/ responses for endpoints in manifests/<portal>.psd1
    into tests/fixtures/live/<slug>/{request.json,response.json,meta.json}.

.DESCRIPTION
    Phase 0h L-2 capture pass. Backs the WIRE-CAPTURE step of the 6-step iteration
    loop. Supports both legacy v0.0.1 manifest shape (.Endpoints + .Slug) and the
    v0.1.0 candidate shape emitted by Build-CandidateManifest (.Entries + NodocRoute).

    The cached ESTS session is reused across endpoints; the auth chain handles
    dynamic reauth internally (per Decision D-33 · TOTP not budget-constrained).

    For each entry:
      - GET (or POST per manifest)
      - request.json   (method · path · cookies/JWT/email redacted via Redact-PII)
      - response.json  (PII-redacted JSON or 'live-empty' marker · only when 2xx)
      - meta.json      (classification · statusCode · bytes · timing · pagination · time-filter hints)
      - unreachable.json (license-gated · path-params-required · etc.)

    Saves aggregate at tests/results/iter-<utc>/capture-summary.json for
    operator review + Phase 0i schema-derivation input.

.OUTPUTS
    Per-endpoint: tests/fixtures/live/<slug>/ (gitignored — fixtures are operator-local
    until redaction-reviewed for commit).

    Aggregate: tests/results/iter-<utc>/capture-summary.json

.EXAMPLE
    pwsh ./tools/Capture-EndpointSchemas.ps1                              # full Defender catalogue
    pwsh ./tools/Capture-EndpointSchemas.ps1 -Slug TenantContext          # one endpoint
    pwsh ./tools/Capture-EndpointSchemas.ps1 -SubArea PortalServices      # one sub-area
    pwsh ./tools/Capture-EndpointSchemas.ps1 -Smoke                       # 1 endpoint smoke
    pwsh ./tools/Capture-EndpointSchemas.ps1 -Portal Purview -Smoke       # smoke from sibling portal

.NOTES
    Depends on operator running Probe-Auth-Local once first (validates the auth
    chain works · primes session cache). For 519-entry capture, expect ~5 min at
    500ms pace plus dynamic reauth retries.
#>

[CmdletBinding()]
param(
    [ValidateSet('Defender','Purview','Entra','Intune','SecurityCopilot')]
    [string]$Portal       = 'Defender',
    [string]$SubPortal,                                     # bearer-portal sub: Entra IAM/PIM/IDGov/IGA/B2C · Intune Portal/Autopatch
    [string]$EnvFile      = (Join-Path $PSScriptRoot '..\tests\.env.local'),
    [string]$ManifestPath,                                  # auto-derived from -Portal if omitted
    [string]$Slug,                                          # filter to one endpoint (matches Slug or last-segment of NodocRoute)
    [string]$EntryKey,                                      # filter to one entry by exact EntryKey
    [string]$SubArea,                                       # filter to one sub-area
    [switch]$Smoke,                                         # capture 1 endpoint only (TenantContext or first available)
    [int]$MaxEntries     = 0,                               # 0 = no cap
    [string]$OutputDir   = (Join-Path $PSScriptRoot '..\tests\fixtures\live'),
    [string]$ResultsDir  = (Join-Path $PSScriptRoot '..\tests\results'),
    [int]$PaceMs         = 200,                             # 200ms safe rate · 519 entries → ~2 min pacing
    [switch]$IncludeSkippable,                              # opt-in: also try {} path-param + non-GET methods
    [switch]$Force                                          # re-capture endpoints already on disk
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Resolve manifest path from portal name if not explicit
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $PSScriptRoot ("..\manifests\{0}.psd1" -f $Portal.ToLowerInvariant())
}
if (-not (Test-Path $ManifestPath)) {
    throw "Capture-EndpointSchemas: manifest not found for portal '$Portal' at '$ManifestPath'"
}

# Load env.local (provides XDRLR_TEST_UPN, KV credentials)
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}

# Import modules + capture lib
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $repoRoot 'src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\Modules\Xdr.Poll\Xdr.Poll.psd1') -Force
. (Join-Path $PSScriptRoot 'lib\Capture-EndpointSchemas.lib.ps1')

# Load manifest via scriptblock evaluator (supports `$true` literal that
# Import-PowerShellDataFile in PS 7.x rejects as dynamic).
$manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
if (-not $manifest) { throw "Capture-EndpointSchemas: failed to parse manifest at '$ManifestPath'" }

# Shape-detect: legacy (Endpoints + Slug) vs candidate (Entries + EntryKey + NodocRoute)
$isCandidateShape = $manifest.ContainsKey('Entries')
$rawEntries = if ($isCandidateShape) { @($manifest.Entries) } else { @($manifest.Endpoints) }
if ($rawEntries.Count -eq 0) {
    throw "Capture-EndpointSchemas: manifest has 0 entries · run Build-CandidateManifest first?"
}

# Normalize entries to a uniform shape: { Slug, EntryKey, SubArea, Path, Method }
function ConvertTo-NormalizedEntry {
    param([Parameter(Mandatory)] $Entry, [bool] $IsCandidate)
    if ($IsCandidate) {
        # Slug = last segment of NodocRoute (e.g. 'PortalServices.TenantContext' → 'TenantContext').
        # Special-case: NodocRoute 'GetTenantContext' / '.TenantContext' canonicalize to 'TenantContext'
        # to preserve the v0.0.1 smoke-endpoint contract (E2E.Replay.TenantContext.Tests.ps1).
        $slug = if ($Entry.ContainsKey('Slug') -and $Entry.Slug) {
            $Entry.Slug
        } elseif ($Entry.ContainsKey('NodocRoute') -and $Entry.NodocRoute) {
            $leaf = ($Entry.NodocRoute -split '\.')[-1]
            if ($leaf -match 'TenantContext$') { 'TenantContext' } else { $leaf }
        } else {
            ConvertTo-Slug $Entry.EntryKey
        }
        return [pscustomobject]@{
            Slug          = $slug
            EntryKey      = $Entry.EntryKey
            SubArea       = $Entry.SubArea
            Path          = $Entry.Path
            Method        = $Entry.Method
            IngestionMode = $Entry.IngestionMode
            NodocRoute    = $Entry.NodocRoute
            Capability    = if ($Entry.ContainsKey('Capability')) { $Entry.Capability } else { '' }
            LicenseHint   = if ($Entry.ContainsKey('LicenseHint')) { $Entry.LicenseHint } else { '' }
        }
    } else {
        return [pscustomobject]@{
            Slug          = $Entry.Slug
            EntryKey      = $Entry.Slug
            SubArea       = $Entry.SubArea
            Path          = $Entry.Path
            Method        = $Entry.Method
            IngestionMode = if ($Entry.PSObject.Properties['IngestionMode']) { $Entry.IngestionMode } else { '' }
            NodocRoute    = if ($Entry.PSObject.Properties['NodocRoute']) { $Entry.NodocRoute } else { '' }
            Capability    = ''
            LicenseHint   = ''
        }
    }
}

$normEntries = $rawEntries | ForEach-Object { ConvertTo-NormalizedEntry -Entry $_ -IsCandidate $isCandidateShape }

# Apply filters
$selected = $normEntries
if ($Smoke) {
    # Prefer Configuration::TenantContext (single-tenant Defender · v0.0.1 smoke contract),
    # then any TenantContext, then any Configuration-sub-area entry, else first available.
    $cfgTC  = $selected | Where-Object { $_.Slug -eq 'TenantContext' -and $_.SubArea -eq 'Configuration' } | Select-Object -First 1
    $anyTC  = $selected | Where-Object { $_.Slug -eq 'TenantContext' } | Select-Object -First 1
    $anyCfg = $selected | Where-Object { $_.SubArea -eq 'Configuration' } | Select-Object -First 1
    $pick = $cfgTC; if (-not $pick) { $pick = $anyTC }; if (-not $pick) { $pick = $anyCfg }
    $selected = if ($pick) { @($pick) } else { @($selected | Select-Object -First 1) }
} else {
    if ($EntryKey) { $selected = $selected | Where-Object { $_.EntryKey -eq $EntryKey } }
    if ($Slug)     { $selected = $selected | Where-Object { $_.Slug -eq $Slug } }
    if ($SubArea)  { $selected = $selected | Where-Object { $_.SubArea -eq $SubArea } }
}
if ($MaxEntries -gt 0) { $selected = $selected | Select-Object -First $MaxEntries }

$selectedArr = @($selected)
if ($selectedArr.Count -eq 0) {
    throw "Capture-EndpointSchemas: no entries match filters (Slug=$Slug · EntryKey=$EntryKey · SubArea=$SubArea · Smoke=$Smoke)"
}

Write-Host "Capture-EndpointSchemas · Portal=$Portal · entries=$($selectedArr.Count)" -ForegroundColor Cyan
Write-Host "  Manifest: $ManifestPath ($($rawEntries.Count) total · shape=$(if ($isCandidateShape) { 'candidate' } else { 'legacy' }))" -ForegroundColor DarkGray
Write-Host "  Pace: $PaceMs ms between requests · output → $OutputDir" -ForegroundColor DarkGray
Write-Host ""

# Ensure output dir
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Resolve credentials + open portal session
# Cookie portals (Defender/Purview) use Connect-*Portal + Invoke-DefenderApiproxy
# Bearer portals (Entra/Intune/SecurityCopilot) use Connect-*Portal + Invoke-XdrPortalRequest
#   · sub-portal optional via $SubPortal param (default first valid)
$creds = Get-XdrAuthFromKeyVault -FromEnvLocal
$isBearer = $Portal -in @('Entra','Intune','SecurityCopilot')
$portalSession = switch ($Portal) {
    'Defender'        { Connect-DefenderPortal        -Credentials $creds }
    'Purview'         { Connect-PurviewPortal         -Credentials $creds }
    'Entra'           { Connect-EntraPortal           -Credentials $creds -SubPortal $(if ($SubPortal) { $SubPortal } else { 'IAM' }) }
    'Intune'          { Connect-IntunePortal          -Credentials $creds -SubPortal $(if ($SubPortal) { $SubPortal } else { 'Portal' }) }
    'SecurityCopilot' { Connect-SecurityCopilotPortal -Credentials $creds }
    default           { throw "Capture-EndpointSchemas: unknown portal '$Portal'" }
}
# Cookie portals: $portalSession.Session = WebRequestSession · Bearer portals: $portalSession IS the bearer bag
$session = if ($isBearer) { $portalSession } else { $portalSession.Session }

# Bearer portals need PortalConfigEntry for Invoke-XdrPortalRequest dispatch
$portalConfigEntry = $null
if ($isBearer) {
    $effectiveSubPortal = if ($SubPortal) { $SubPortal } elseif ($Portal -eq 'Entra') { 'IAM' } elseif ($Portal -eq 'Intune') { 'Portal' } else { '' }
    $portalConfigEntry = Get-XdrPortalConfig -Portal $Portal -SubPortal $effectiveSubPortal
}

# Capture loop
$iterStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$iterDir = Join-Path $ResultsDir ("iter-{0}" -f $iterStamp)
New-Item -ItemType Directory -Path $iterDir -Force | Out-Null

# ── Cycle-level state for re-probe enhancements (Plan §10.4) ────────────────
# Auth-retry strategy: ONCE per cycle (not per endpoint). First 401/403/html-terminal
# triggers Connect-DefenderPortal -Force, refreshes $session, sets $cycleReauthDone.
# All subsequent endpoints reuse the refreshed session without re-burning TOTP.
# Without this gating, 519 endpoints × 100s reauth = ~14h cycle (per operator).
# With this gating, ~1× reauth per cycle = ~100s amortized.
$cycleReauthDone = $false

# ── Slug-collision detection (audit Phase α.3 fix) ────────────────────────────
# 10 slug collisions in manifest where >1 SubArea uses the same Slug (e.g.
# Configuration::TenantContext + MultiTenant::TenantContext both have Slug='TenantContext').
# Pre-scan to find them · ONLY those entries use SubArea_Slug dir-name; others stay flat.
# Backward-compatible: non-colliding slugs keep their existing fixture dir.
$slugCollisions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$slugSubareaCount = @{}
foreach ($entry in $normEntries) {
    if (-not $slugSubareaCount.ContainsKey($entry.Slug)) {
        $slugSubareaCount[$entry.Slug] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    [void]$slugSubareaCount[$entry.Slug].Add($entry.SubArea)
}
foreach ($slugKey in $slugSubareaCount.Keys) {
    if ($slugSubareaCount[$slugKey].Count -gt 1) { [void]$slugCollisions.Add($slugKey) }
}
function Get-FixtureDirName {
    param(
        [Parameter(Mandatory)]$Entry,
        [AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Collisions = ([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase))
    )
    if ($Collisions -and $Collisions.Contains([string]$Entry.Slug)) {
        # Use SubArea_Slug for disambiguation (10 collisions = 20 entries affected)
        return ($Entry.SubArea + '_' + $Entry.Slug) -replace '[^A-Za-z0-9_-]+','-'
    }
    return $Entry.Slug
}
if ($slugCollisions.Count -gt 0) {
    Write-Host "  Slug collisions detected: $($slugCollisions.Count) slugs · using SubArea_Slug for them" -ForegroundColor DarkYellow
    foreach ($c in $slugCollisions) { Write-Host "    · $c" -ForegroundColor DarkGray }
}

# Path-param substitution: cache TenantContext OrgId for {tenantId}/{TenantId}/{organizationId}/{orgId}/{realm}
# Resolve from the TenantContext live capture if it exists on disk; else fetch fresh.
$cachedOrgId = $null
$tcFixture = Join-Path $repoRoot 'tests\fixtures\live\TenantContext\response.json'
if (Test-Path $tcFixture) {
    try {
        $tc = Get-Content -Raw -LiteralPath $tcFixture | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($tc -and $tc.PSObject.Properties['OrgId'] -and $tc.OrgId) { $cachedOrgId = [string]$tc.OrgId }
    } catch { }
}
if ($cachedOrgId) {
    Write-Host "  Cached OrgId from TenantContext fixture: $cachedOrgId" -ForegroundColor DarkGray
} else {
    Write-Host "  No cached OrgId · path-param-required endpoints will skip {tenantId}/etc. substitution" -ForegroundColor DarkYellow
}

# Helper: substitute well-known path params with cached OrgId + Azure subscription/RG/workspace from env.local
# φ.A · D-2026-05-18s · expand substitution to lift live coverage beyond TenantContext.OrgId only
function Resolve-PathParams {
    param([Parameter(Mandatory)][string]$Path, [string]$OrgId)
    $resolved = $Path
    # 1. Tenant identity tokens (TenantContext.OrgId)
    if ($OrgId) {
        foreach ($token in @('{tenantId}','{TenantId}','{organizationId}','{orgId}','{realm}','{aadTenantId}','{aadOrganizationId}')) {
            $resolved = $resolved.Replace($token, $OrgId)
        }
    }
    # 2. Azure ARM tokens from env.local · used by Sentinel/Defender/ARM-bridge endpoints
    if ($env:XDRLR_SUBSCRIPTION_ID) {
        foreach ($token in @('{subscriptionId}','{subscriptionID}','{SubscriptionId}','{subId}')) {
            $resolved = $resolved.Replace($token, $env:XDRLR_SUBSCRIPTION_ID)
        }
    }
    if ($env:XDRLR_WORKSPACE_RG) {
        foreach ($token in @('{resourceGroupName}','{resourceGroup}','{rgName}','{ResourceGroupName}')) {
            $resolved = $resolved.Replace($token, $env:XDRLR_WORKSPACE_RG)
        }
    }
    # 3. Workspace name (derive from XDRLR_WORKSPACE_ID ARM ID · last segment)
    if ($env:XDRLR_WORKSPACE_ID) {
        $workspaceName = ($env:XDRLR_WORKSPACE_ID -split '/')[-1]
        if ($workspaceName) {
            foreach ($token in @('{workspaceName}','{workspace}','{WorkspaceName}')) {
                $resolved = $resolved.Replace($token, $workspaceName)
            }
        }
    }
    return $resolved
}

$results = [System.Collections.Generic.List[object]]::new()
$idx = 0
foreach ($e in $selectedArr) {
    $idx++
    # Slug-collision-safe dir: uses SubArea_Slug for 10 colliding slugs (audit α.3) · flat otherwise
    $endpointDir = Join-Path $OutputDir (Get-FixtureDirName -Entry $e -Collisions $slugCollisions)
    New-Item -ItemType Directory -Path $endpointDir -Force | Out-Null

    # Skip-decision (write a meta-only skip artefact so Phase 0i can audit which were not captured)
    $hasPathParam = $e.Path -match '\{[^}]+\}'
    $isMutationMethod = $e.Method -in @('PUT','PATCH','DELETE')
    # ITER6 D7 · Honor manifest ProbeMode reclassifications (introduced by Inject-RequestShapes):
    #   ReadOnlyPost   = POST telemetry-query · skip until v0.2.0 active polling lands
    #   PathParamGated = {xxx} placeholders we don't fill at v0.1.0
    #   SubPortalAuth  = m365appprotection / mdi / radius / medeina / mdc · different cookie scope
    #   RequiresEntity = entity-pivot · v0.3.0 cross-entity scope
    #   Excluded       = mutation (already handled by $isMutationMethod)
    # Capture probe should match runtime ProbeMode gate exactly · prevents misleading lab-tenant
    # error histogram pollution for endpoints we never poll in production.
    # Manifest entries are hashtables (psd1 @{...}) · use ContainsKey not PSObject.Properties
    $probeModeAttr = if ($e -is [hashtable] -and $e.ContainsKey('ProbeMode')) { [string]$e.ProbeMode }
                     elseif ($e.PSObject.Properties['ProbeMode']) { [string]$e.ProbeMode }
                     else { 'Probe' }
    $probeModeSkip = $probeModeAttr -in @('ReadOnlyPost','PathParamGated','SubPortalAuth','RequiresEntity','Excluded')
    # φ.A · ALWAYS skip mutation methods (DELETE/PATCH/PUT) regardless of -IncludeSkippable
    $shouldSkip = $isMutationMethod -or $probeModeSkip -or `
                  ((-not $IncludeSkippable) -and ($hasPathParam -or ($e.Method -eq 'POST' -and $e.Path -notmatch '/(list|search|filter|query|get|fetch|by|find|check|count)')))
    if ($shouldSkip) {
        $skipReason = if ($isMutationMethod) { 'skipped-mutation' }
                      elseif ($probeModeSkip) { "skipped-probemode-$($probeModeAttr.ToLower())" }
                      elseif ($hasPathParam) { 'skipped-pathparams' }
                      else                   { 'skipped-write-post' }
        @{
            method     = $e.Method
            path       = $e.Path
            subArea    = $e.SubArea
            entryKey   = $e.EntryKey
            nodocRoute = $e.NodocRoute
            cookies    = '<REDACTED · see tests/.env.local for SA creds>'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $endpointDir 'request.json') -Encoding UTF8
        @{
            classification = $skipReason
            statusCode     = $null
            note           = "Capture skipped: $skipReason. Use -IncludeSkippable to attempt anyway · Phase 0j authoring will fill from nodoc schema definition or live re-probe with substituted path values."
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $endpointDir 'unreachable.json') -Encoding UTF8
        @{
            capturedAt        = (Get-Date).ToUniversalTime().ToString('o')
            capturedBy        = $env:XDRLR_TEST_UPN
            classification    = $skipReason
            statusCode        = $null
            bytes             = 0
            elapsedMs         = 0
            ingestionMode     = $e.IngestionMode
            capability        = $e.Capability
            licenseHint       = $e.LicenseHint
            paginationHints   = @()
            timeFilterHints   = @()
            connectorVersion  = '0.1.0'
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $endpointDir 'meta.json') -Encoding UTF8
        $results.Add([pscustomobject]@{
            Index          = $idx
            Slug           = $e.Slug
            EntryKey       = $e.EntryKey
            SubArea        = $e.SubArea
            Classification = $skipReason
            StatusCode     = $null
            Bytes          = 0
            ElapsedMs      = 0
        }) | Out-Null
        Write-Host ("  [{0,4}/{1}] [{2,-20}] {3} (skipped · {4})" -f $idx, $selectedArr.Count, $skipReason, $e.Slug, $e.Method) -ForegroundColor DarkGray
        continue
    }

    # Resume-skip: don't re-capture if already on disk and not -Force
    $metaExists = Test-Path (Join-Path $endpointDir 'meta.json')
    if (-not $Force -and $metaExists) {
        $existingMeta = Get-Content -Raw -LiteralPath (Join-Path $endpointDir 'meta.json') | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($existingMeta -and $existingMeta.classification -in 'live','live-empty','license-gated','unreachable-404') {
            $results.Add([pscustomobject]@{
                Index          = $idx
                Slug           = $e.Slug
                EntryKey       = $e.EntryKey
                SubArea        = $e.SubArea
                Classification = $existingMeta.classification + '-resumed'
                StatusCode     = $existingMeta.statusCode
                Bytes          = $existingMeta.bytes
                ElapsedMs      = 0
            }) | Out-Null
            Write-Host ("  [{0,4}/{1}] [resumed]            {2} (from cached {3})" -f $idx, $selectedArr.Count, $e.Slug, $existingMeta.classification) -ForegroundColor DarkCyan
            continue
        }
    }

    $response = $null
    $classification = 'unknown'
    $statusCode = $null
    $bytes = 0
    $t0 = Get-Date

    # ── Path-param substitution (Plan §10.4 feature 3) ─────────────────────
    # If manifest path has {tenantId}/{TenantId}/{organizationId}/{orgId}/{realm},
    # substitute with cached OrgId (when available · IncludeSkippable bypassed)
    $effectivePath = if ($e.Path -match '\{[^}]+\}' -and $cachedOrgId) {
        Resolve-PathParams -Path $e.Path -OrgId $cachedOrgId
    } else { $e.Path }
    $stillHasUnresolvedParams = $effectivePath -match '\{[^}]+\}'

    try {
        # MaxRetries=0 disables Invoke-DefenderApiproxy's internal per-call reauth · we handle
        # reauth ONCE per cycle at the Capture level (Plan §10.4 feature 1).
        # Cookie vs bearer dispatch: Defender/Purview use Invoke-DefenderApiproxy ·
        # Entra/Intune/SecurityCopilot use Invoke-XdrPortalRequest facade.
        if ($isBearer) {
            $response = Invoke-XdrPortalRequest -PortalConfigEntry $portalConfigEntry -Path $effectivePath `
                -Session $session -Method $e.Method
        } else {
            $response = Invoke-DefenderApiproxy -Path $effectivePath -Session $session -Method $e.Method -MaxRetries 0
        }
        $statusCode = $response.StatusCode

        # ── Header-retry on 400/406 (Plan §10.4 feature 2) ────────────────
        # Cookie-only · bearer Invoke-XdrPortalRequest doesn't currently accept -Headers
        # (would need facade extension v0.2.0+).
        if (-not $isBearer -and $response.StatusCode -in 400,406) {
            try {
                $response2 = Invoke-DefenderApiproxy -Path $effectivePath -Session $session -Method $e.Method `
                    -Headers @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json' } -MaxRetries 0
                if ($response2 -and $response2.StatusCode -ge 200 -and $response2.StatusCode -lt 300) {
                    $response = $response2; $statusCode = $response.StatusCode
                }
            } catch { }
        }

        # ── φ.A · POST empty-body retry on 400 (closes ~30 error-400 entries) ───
        # Many Defender POST endpoints expect a JSON body even for "list" semantics.
        # If GET-style attempt returned 400 on a POST endpoint · retry with '{}' body.
        if (-not $isBearer -and $response.StatusCode -eq 400 -and $e.Method -eq 'POST') {
            try {
                $response3 = Invoke-DefenderApiproxy -Path $effectivePath -Session $session -Method 'POST' `
                    -Headers @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json' } `
                    -Body '{}' -MaxRetries 0
                if ($response3 -and $response3.StatusCode -ge 200 -and $response3.StatusCode -lt 300) {
                    $response = $response3; $statusCode = $response.StatusCode
                }
            } catch { }
        }

        # ── φ.A · Method-fallback on 405 (closes ~8 error-405 entries) ───────────
        # If manifest method (GET/POST) returns 405 Method Not Allowed · try the swap.
        # Defender sometimes documents wrong method · this auto-corrects.
        if (-not $isBearer -and $response.StatusCode -eq 405) {
            $swappedMethod = if ($e.Method -eq 'GET') { 'POST' } elseif ($e.Method -eq 'POST') { 'GET' } else { $null }
            if ($swappedMethod) {
                try {
                    $bodyParam = if ($swappedMethod -eq 'POST') { @{ Body = '{}' } } else { @{} }
                    $response4 = Invoke-DefenderApiproxy -Path $effectivePath -Session $session -Method $swappedMethod `
                        -Headers @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json' } `
                        @bodyParam -MaxRetries 0
                    if ($response4 -and $response4.StatusCode -ge 200 -and $response4.StatusCode -lt 300) {
                        $response = $response4; $statusCode = $response.StatusCode
                        Write-Host ("    [method-swap] {0} → {1} succeeded" -f $e.Method, $swappedMethod) -ForegroundColor DarkCyan
                    }
                } catch { }
            }
        }

        # ── φ.A · Postman request template retry (LARGEST coverage lift) ──────
        # 501/519 manifest entries have a Postman template at references/Defender/<sub>/<slug>/postman-request.json
        # Template carries: Method · Body · Headers · Path-var values · Query params.
        # If we still have a non-2xx response after Phase-1 retries · try the EXACT Postman request.
        # This closes error-400 (wrong body) · error-500 (wrong body) · error-405 (wrong method) ·
        # unresolved-path-params (Postman has {AlertId}={real-guid} etc.) in one shot.
        if (-not $isBearer -and ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300)) {
            # NOTE: $e is a PSCustomObject (from ConvertTo-NormalizedEntry) · use PSObject.Properties not ContainsKey
            $slugForLookup = if ($e.PSObject.Properties['Slug'] -and $e.Slug) { [string]$e.Slug } else { ($e.NodocRoute -split '\.')[-1] }
            $postmanReqPath = Join-Path $repoRoot ("references/Defender/{0}/{1}/postman-request.json" -f $e.SubArea, $slugForLookup)
            if (Test-Path $postmanReqPath) {
                try {
                    $pmTemplate = Get-Content -Raw -LiteralPath $postmanReqPath | ConvertFrom-Json
                    # Build path with Postman's path-variable values (closes unresolved-path-params)
                    $pmPath = $effectivePath
                    if ($pmTemplate.PSObject.Properties['Variables']) {
                        foreach ($vKey in $pmTemplate.Variables.PSObject.Properties.Name) {
                            $vVal = [string]$pmTemplate.Variables.$vKey
                            if ($vVal) {
                                $pmPath = $pmPath.Replace("{$vKey}", $vVal)
                            }
                        }
                    }
                    # Append query params if Postman has them and path doesn't already
                    $pmQueryAppend = ''
                    if ($pmTemplate.PSObject.Properties['Query'] -and @($pmTemplate.Query).Count -gt 0) {
                        $qParts = @()
                        foreach ($q in @($pmTemplate.Query)) {
                            if ($q.Value) { $qParts += "$($q.Key)=$($q.Value)" }
                        }
                        if ($qParts.Count -gt 0 -and $pmPath -notmatch '\?') {
                            $pmQueryAppend = '?' + ($qParts -join '&')
                        }
                    }
                    # Build headers
                    $pmHeaders = @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json' }
                    if ($pmTemplate.PSObject.Properties['Headers']) {
                        foreach ($hKey in $pmTemplate.Headers.PSObject.Properties.Name) {
                            $pmHeaders[$hKey] = [string]$pmTemplate.Headers.$hKey
                        }
                    }
                    # Use Postman's method + body
                    $pmMethod = if ($pmTemplate.PSObject.Properties['Method'] -and $pmTemplate.Method) { [string]$pmTemplate.Method } else { $e.Method }
                    $pmBody   = if ($pmTemplate.PSObject.Properties['Body'] -and $pmTemplate.Body) { [string]$pmTemplate.Body } else { $null }
                    $bodyParam = if ($pmBody) { @{ Body = $pmBody } } else { @{} }
                    $response5 = Invoke-DefenderApiproxy -Path ($pmPath + $pmQueryAppend) -Session $session -Method $pmMethod `
                        -Headers $pmHeaders @bodyParam -MaxRetries 0
                    if ($response5 -and $response5.StatusCode -ge 200 -and $response5.StatusCode -lt 300) {
                        $response = $response5; $statusCode = $response.StatusCode
                        Write-Host ("    [postman-template] retry succeeded ({0}→{1})" -f $e.Method, $pmMethod) -ForegroundColor Cyan
                    }
                } catch { }
            }
        }

        # ── Auth-retry on 401/403/html-terminal · cap 3 reauths per cycle (φ.A enhanced) ──
        # First occurrence: refresh session via Connect-*Portal -Force · retry · increment cycle counter.
        # Allow up to MAX_REAUTHS=3 reauths per cycle (handles cookie-expiry mid-cycle for 519-endpoint runs · ~30 min)
        # Subsequent html-terminal beyond MAX_REAUTHS: accept as 'html-terminal' classification.
        # Detect HTML response: Invoke-DefenderApiproxy sets $response.IsHtml when body starts with '<!DOCTYPE' or '<html'
        $needsReauth = ($response.PSObject.Properties['IsHtml'] -and $response.IsHtml) -or ($response.StatusCode -in 401,403,440)
        if (-not (Test-Path Variable:script:cycleReauthCount)) { $script:cycleReauthCount = 0 }
        $MAX_REAUTHS_PER_CYCLE = 3
        if ($needsReauth -and $script:cycleReauthCount -lt $MAX_REAUTHS_PER_CYCLE) {
            $script:cycleReauthCount++
            Write-Host ("    [auth-retry $($script:cycleReauthCount)/$MAX_REAUTHS_PER_CYCLE] 401/403/440/html · attempting KMSI SSO (zero-TOTP) or fallback to full chain") -ForegroundColor Yellow
            $cycleReauthDone = $true   # backward-compat flag (still set for downstream telemetry)
            try {
                # Per-portal reauth dispatch (matches initial portalSession resolution)
                $portalSession = switch ($Portal) {
                    'Defender'        { Connect-DefenderPortal -Credentials $creds -Force }
                    'Purview'         { Connect-PurviewPortal  -Credentials $creds -Force }
                    'Entra'           { Connect-EntraPortal    -Credentials $creds -SubPortal $(if ($SubPortal) { $SubPortal } else { 'IAM' }) -Force }
                    'Intune'          { Connect-IntunePortal   -Credentials $creds -SubPortal $(if ($SubPortal) { $SubPortal } else { 'Portal' }) -Force }
                    'SecurityCopilot' { Connect-SecurityCopilotPortal -Credentials $creds -Force }
                }
                # Report which reauth path actually ran (KMSI SSO no TOTP · or full TOTP chain)
                $rt = if ($portalSession.PSObject.Properties['RefreshType']) { [string]$portalSession.RefreshType } else { 'unknown' }
                $rtColor = if ($rt -eq 'kmsi-sso') { 'Green' } elseif ($rt -eq 'full-totp-chain') { 'DarkYellow' } else { 'Gray' }
                Write-Host ("    [auth-retry done] RefreshType=$rt") -ForegroundColor $rtColor
                $session = $portalSession.Session
                if ($isBearer) {
                    $response = Invoke-XdrPortalRequest -PortalConfigEntry $portalConfigEntry -Path $effectivePath `
                        -Session $session -Method $e.Method
                } else {
                    $response = Invoke-DefenderApiproxy -Path $effectivePath -Session $session -Method $e.Method -MaxRetries 0
                }
                $statusCode = $response.StatusCode
            } catch {
                Write-Host "    [auth-retry] reauth failed: $($_.Exception.Message)" -ForegroundColor DarkRed
            }
        }

        if ($null -ne $response) {
            # StrictMode-safe property guards · custom-object props always present on real responses
            $respRaw = $null
            if ($response.PSObject.Properties['RawContent']) { $respRaw = $response.RawContent }
            elseif ($response.PSObject.Properties['Raw'])    { $respRaw = $response.Raw }
            if ($respRaw) { $bytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$respRaw) }
            # Bearer Invoke-XdrPortalRequest doesn't return .Parsed · parse RawContent on the fly
            $respParsed = if ($response.PSObject.Properties['Parsed']) {
                $response.Parsed
            } elseif ($respRaw) {
                try { [string]$respRaw | ConvertFrom-Json -Depth 30 -ErrorAction Stop } catch { $null }
            } else { $null }
            $respIsHtml = if ($response.PSObject.Properties['IsHtml']) { $response.IsHtml } else { $false }
            $classification = if ($stillHasUnresolvedParams -and ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300)) {
                'unresolved-path-params'
            } elseif ($respIsHtml) {
                'html-terminal'
            } elseif ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300 -and $respParsed) {
                'live'
            } elseif ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                'live-empty'
            } elseif ($response.StatusCode -in 401,403) {
                'license-gated'
            } elseif ($response.StatusCode -eq 404) {
                'unreachable-404'
            } elseif ($response.StatusCode -eq 429) {
                'rate-limited'
            } else {
                "error-$($response.StatusCode)"
            }
        } else {
            $classification = 'exception-null-response'
        }
    } catch {
        $classification = "exception"
        $exceptionMessage = $_.Exception.Message
        Write-Host ("    [exception-debug] " + $exceptionMessage) -ForegroundColor DarkRed
    }
    $elapsedMs = [int]((Get-Date) - $t0).TotalMilliseconds

    # request.json (PII-redacted)
    @{
        method     = $e.Method
        path       = $e.Path
        subArea    = $e.SubArea
        entryKey   = $e.EntryKey
        nodocRoute = $e.NodocRoute
        cookies    = '<REDACTED · see tests/.env.local for SA creds>'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $endpointDir 'request.json') -Encoding UTF8

    # Strict-safe accessors (may be null when classification is exception/null)
    $respParsedSafe = if ($null -ne $response -and $response.PSObject.Properties['Parsed']) { $response.Parsed } else { $null }
    $respRawSafe = if ($null -ne $response) {
        if ($response.PSObject.Properties['RawContent']) { [string]$response.RawContent }
        elseif ($response.PSObject.Properties['Raw'])    { [string]$response.Raw }
        else { '' }
    } else { '' }

    # response.json (only for 'live') · PII-redacted
    if ($classification -eq 'live' -and $respParsedSafe) {
        $rawJson = $respParsedSafe | ConvertTo-Json -Depth 50
        $redacted = Redact-PII -Text $rawJson
        Set-Content -LiteralPath (Join-Path $endpointDir 'response.json') -Value $redacted -Encoding UTF8
    } elseif ($classification -eq 'live-empty') {
        '{}' | Set-Content -LiteralPath (Join-Path $endpointDir 'response.json') -Encoding UTF8
    } else {
        @{
            classification = $classification
            statusCode     = $statusCode
            note           = 'License-gated endpoints are NOT broken · the SA tenant needs the right SKU. Re-run on a licensed tenant or accept as unreachable.'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $endpointDir 'unreachable.json') -Encoding UTF8
    }

    # Pagination + time-filter hints from raw body / path
    $paginationHints = Get-PaginationHints -RawBody $respRawSafe -ParsedJson $respParsedSafe
    $timeFilterHints = Get-TimeFilterHints -Path $e.Path

    # meta.json
    @{
        capturedAt        = (Get-Date).ToUniversalTime().ToString('o')
        capturedBy        = $env:XDRLR_TEST_UPN
        classification    = $classification
        statusCode        = $statusCode
        bytes             = $bytes
        elapsedMs         = $elapsedMs
        ingestionMode     = $e.IngestionMode
        capability        = $e.Capability
        licenseHint       = $e.LicenseHint
        paginationHints   = $paginationHints
        timeFilterHints   = $timeFilterHints
        connectorVersion  = '0.1.0'
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $endpointDir 'meta.json') -Encoding UTF8

    # ── Dual-write to references/<portal>/<sub-area>/<slug>/ for Phase 0i derivation ──
    # Derive-Phase0Artifacts reads live.json (with Body+PaginationHints+TimeFilterHints)
    # and metadata.json (with classification + manifest fields).
    if ($e.SubArea) {
        $refDir = Join-Path $repoRoot ("references/{0}/{1}/{2}" -f $Portal, $e.SubArea, $e.Slug)
        New-Item -ItemType Directory -Path $refDir -Force | Out-Null
        # live.json · only for 2xx (live or live-empty)
        if ($classification -in 'live','live-empty') {
            $rawBodyForRef = if ($respParsedSafe) {
                Redact-PII -Text ($respParsedSafe | ConvertTo-Json -Depth 50 -Compress)
            } else { '{}' }
            $contentType = if ($null -ne $response -and $response.PSObject.Properties['ContentType']) { [string]$response.ContentType } else { 'application/json' }
            @{
                Body            = $rawBodyForRef
                StatusCode      = $statusCode
                ContentType     = $contentType
                PaginationHints = $paginationHints
                TimeFilterHints = $timeFilterHints
                CapturedAt      = (Get-Date).ToUniversalTime().ToString('o')
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $refDir 'live.json') -Encoding UTF8
        }
        # metadata.json · always
        @{
            Portal          = $Portal
            SubArea         = $e.SubArea
            Slug            = $e.Slug
            EntryKey        = $e.EntryKey
            Path            = $e.Path
            Method          = $e.Method
            NodocRoute      = $e.NodocRoute
            IngestionMode   = $e.IngestionMode
            Capability      = $e.Capability
            LicenseHint     = $e.LicenseHint
            Classification  = $classification
            StatusCode      = $statusCode
            CapturedAt      = (Get-Date).ToUniversalTime().ToString('o')
            ConnectorVersion = '0.1.0'
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $refDir 'metadata.json') -Encoding UTF8
    }

    $results.Add([pscustomobject]@{
        Index          = $idx
        Slug           = $e.Slug
        EntryKey       = $e.EntryKey
        SubArea        = $e.SubArea
        Classification = $classification
        StatusCode     = $statusCode
        Bytes          = $bytes
        ElapsedMs      = $elapsedMs
    }) | Out-Null

    $color = switch ($classification) {
        'live'           { 'Green' }
        'live-empty'     { 'Cyan' }
        'license-gated'  { 'Yellow' }
        default          { 'DarkYellow' }
    }
    Write-Host ("  [{0,4}/{1}] [{2}] {3} ({4}ms · {5} bytes)" -f $idx, $selectedArr.Count, $classification, $e.Slug, $elapsedMs, $bytes) -ForegroundColor $color
    Start-Sleep -Milliseconds $PaceMs
}

Write-Host ""
Write-Host "Capture complete. Aggregate by classification:" -ForegroundColor Cyan
$results | Group-Object Classification | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("  {0,15} · {1,4} endpoint(s)" -f $_.Name, $_.Count)
}

# Aggregate summary
$summary = [pscustomobject]@{
    Portal           = $Portal
    ManifestPath     = $ManifestPath
    CapturedAt       = (Get-Date).ToUniversalTime().ToString('o')
    EndpointsCaptured = $selectedArr.Count
    EndpointsTotal   = $rawEntries.Count
    FiltersApplied   = @{
        Slug     = $Slug
        EntryKey = $EntryKey
        SubArea  = $SubArea
        Smoke    = [bool]$Smoke
    }
    Classifications  = ($results | Group-Object Classification | ForEach-Object {
        @{ Name = $_.Name; Count = $_.Count }
    })
    Results          = $results
}
$summaryPath = Join-Path $iterDir 'capture-summary.json'
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host ""
Write-Host "Summary: $summaryPath" -ForegroundColor Green

$results
