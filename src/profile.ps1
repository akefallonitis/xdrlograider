# XdrLogRaider · profile.ps1 · cold-start initialization
#
# Runs once per FA worker cold-start. Responsibilities:
#   1. Strict mode + error preferences.
#   2. Import every module under src/Modules/.
#   3. Preload every manifest under src/manifests/ into $script:LoadedManifests.
#   4. Probe tenant context + capabilities (R3) so per-cycle workers get a warm module HotCache.
#   5. Emit Boot.VersionProbe to AppInsights so operators can confirm deployed commit.
#
# Why R3 probe runs here (not lazily on first cycle): the very first TimerTrigger fires within
# 60s of warm-up; calling Get-XdrTenantCapabilities here populates the module's HotCache so
# subsequent runspaces see it without re-probing (failing-open is preferable to fail-closed on
# capability gate but the warm cache eliminates 99% of fail-opens after the first cold-start).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ─── Boot timer ────────────────────────────────────────────────────────────────
$script:BootStartedUtc = [DateTime]::UtcNow

# Resolve paths (FA root → modules + manifests)
$script:FunctionAppRoot = $PSScriptRoot
$script:ModulesRoot     = Join-Path $PSScriptRoot 'Modules'
$script:ManifestsRoot   = Join-Path $PSScriptRoot 'manifests'

# Export the manifests root as a PROCESS-scoped env var. Unlike $script: (per-runspace), $env: is
# visible to ALL pooled runspaces — so the TimerTrigger's runspace (which never runs this profile) can
# still locate the manifests via Get-XdrManifests. This closes the count=0 dispatch bug where the cycle
# enumerated 1 entry only on the cold-start runspace and 0 on every pooled runspace after. (plan §23)
$env:XDRLR_MANIFESTS_ROOT = $script:ManifestsRoot

# ─── Load every Modules/<Name>/<Name>.psd1 (TOPOLOGICAL · dependency-closure first) ────────────
# Why topological, not a flat dir-enumeration: each leaf module (Telemetry/Storage/Cache/Lease)
# EXPORTS unapproved-verb functions (Track-*/Ensure-*/Acquire-*/Release-*/Renew-*/Invalidate-*).
# Importing a DEPENDENT manifest (e.g. Xdr.Common.Runtime) makes PowerShell's RequiredModules
# resolver transitively auto-import those leaves — and a resolver-driven transitive import does NOT
# inherit the parent Import-Module's -DisableNameChecking, so each unapproved verb emits a Sev2
# "unapproved verb" warning (268× at boot · audit). Fix: import the dependency CLOSURE ourselves in
# topological order (every RequiredModules target loaded, WITH -DisableNameChecking, BEFORE any module
# that needs it) so the resolver always finds the leaf already-loaded at the matching 0.1.0 version and
# never performs an unflagged transitive import. Generic: the order is DERIVED from each .psd1's declared
# RequiredModules (no brittle hardcoded list) — adding a module/dependency needs no change here.
$script:LoadedModules = @()
if (Test-Path $script:ModulesRoot) {
    $moduleDirs = Get-ChildItem -Path $script:ModulesRoot -Directory -ErrorAction SilentlyContinue

    # Build name → @{ Psd1; Requires } from each manifest. RequiredModules entries may be a bare string
    # name OR a @{ ModuleName=..; ModuleVersion=.. } hashtable — normalize to the bare name. Only in-repo
    # dependencies are edges we must order; external/absent names are ignored (the resolver handles those).
    $moduleInfo = @{}
    foreach ($md in $moduleDirs) {
        $psd1 = Join-Path $md.FullName "$($md.Name).psd1"
        if (-not (Test-Path $psd1)) { continue }
        $requires = @()
        try {
            $manifest = Import-PowerShellDataFile -Path $psd1 -ErrorAction Stop
            foreach ($req in @($manifest['RequiredModules'])) {
                if ($null -eq $req) { continue }
                $reqName = if ($req -is [hashtable]) { [string]$req['ModuleName'] } else { [string]$req }
                if ($reqName) { $requires += $reqName }
            }
        } catch {
            # A manifest that can't be parsed for its RequiredModules still gets imported below (with no
            # edges) — fail-safe: never let a metadata read drop a module from the load set.
            Write-Warning "Manifest RequiredModules read failed: $($md.Name) · $($_.Exception.Message)"
        }
        $moduleInfo[$md.Name] = @{ Psd1 = $psd1; Requires = $requires }
    }

    # Topological order (Kahn / DFS post-order): a module is imported only after every in-repo dependency
    # it declares is already loaded. Cycle-safe (PS module deps are a DAG; a stray cycle just degrades to
    # best-effort order and the resolver still completes the import).
    $ordered  = [System.Collections.Generic.List[string]]::new()
    $visited  = @{}   # 2 = done · 1 = in-progress (cycle sentinel)
    $visit    = $null
    $visit    = {
        param($name)
        if ($visited[$name] -eq 2 -or $visited[$name] -eq 1) { return }
        if (-not $moduleInfo.ContainsKey($name)) { return }   # external/unknown dep · resolver owns it
        $visited[$name] = 1
        foreach ($dep in $moduleInfo[$name].Requires) { & $visit $dep }
        $visited[$name] = 2
        $ordered.Add($name)
    }
    foreach ($name in $moduleInfo.Keys) { & $visit $name }

    foreach ($name in $ordered) {
        try {
            Import-Module -Name $moduleInfo[$name].Psd1 -Force -DisableNameChecking -ErrorAction Stop
            $script:LoadedModules += $name
        } catch {
            # Module load failure is fail-safe: the cycle will see Get-Command misses and
            # surface the gap via the per-function Track-XdrEvent stream. Don't crash boot —
            # FA host would mark the worker unhealthy and continuous restart loops follow.
            Write-Warning "Module load failed: $name · $($_.Exception.Message)"
        }
    }
}

# ─── Preload manifests/<Portal>/<Category>.psd1 ────────────────────────────────
$script:LoadedManifests = @{}
if (Test-Path $script:ManifestsRoot) {
    $portalDirs = Get-ChildItem -Path $script:ManifestsRoot -Directory -ErrorAction SilentlyContinue
    foreach ($pd in $portalDirs) {
        $portalKey = $pd.Name
        $catFiles  = Get-ChildItem -Path $pd.FullName -Filter '*.psd1' -ErrorAction SilentlyContinue
        $script:LoadedManifests[$portalKey] = @{}
        foreach ($cf in $catFiles) {
            try {
                $catData = Import-PowerShellDataFile -Path $cf.FullName -ErrorAction Stop
                $catKey  = $cf.BaseName
                $script:LoadedManifests[$portalKey][$catKey] = $catData
            } catch {
                Write-Warning "Manifest parse failed: $($cf.FullName) · $($_.Exception.Message)"
            }
        }
    }
}

# ─── Git commit + connector version (WS4.3 · ARTIFACT-FIRST identity) ──────────
# The zip itself carries BUILD_SHA at package root (written by Build-FunctionAppZip from git HEAD), so the
# deployed build's identity comes FROM THE ARTIFACT — not from an app setting someone may forget to stamp.
# Precedence: BUILD_SHA file (artifact truth) > XDRLR_GIT_COMMIT_SHA env (deploy-tool stamp) > 'unknown'.
# Boot.VersionProbe emits this value; tools/Verify-DeployedVersion.ps1 compares it to HEAD (exit 2 = drift).
$script:GitCommitSha = $(
    $shaFile = Join-Path $PSScriptRoot 'BUILD_SHA'
    if (Test-Path $shaFile) { ([string](Get-Content $shaFile -Raw)).Trim() }
    elseif ($env:XDRLR_GIT_COMMIT_SHA) { $env:XDRLR_GIT_COMMIT_SHA }
    else { 'unknown' }
)
$script:ConnectorVersion = if ($env:XDRLR_CONNECTOR_VERSION) { $env:XDRLR_CONNECTOR_VERSION } else { '0.1.0' }

# ─── AppInsights cold-start emit (REST POST · no SDK · workspace-mode) ─────────
function script:Send-XdrBootTelemetry {
    param(
        [string]   $EventName,
        [hashtable]$Properties
    )
    try {
        $cs = $env:APPLICATIONINSIGHTS_CONNECTION_STRING
        if (-not $cs) { return }
        $iKey   = ($cs -split ';' | Where-Object { $_ -match '^InstrumentationKey=' }) -replace '^InstrumentationKey=', ''
        $ingest = ($cs -split ';' | Where-Object { $_ -match '^IngestionEndpoint=' }) -replace '^IngestionEndpoint=', ''
        if (-not $iKey -or -not $ingest) { return }
        $endpoint = ($ingest.TrimEnd('/')) + '/v2/track'
        $envelope = @{
            name = "Microsoft.ApplicationInsights.$($iKey -replace '-','').Event"
            time = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            iKey = $iKey
            data = @{
                baseType = 'EventData'
                baseData = @{
                    ver        = 2
                    name       = $EventName
                    properties = $Properties
                }
            }
        }
        # B-25 guard: envelope is a hashtable; serialize once.
        $body = $envelope | ConvertTo-Json -Depth 10 -Compress
        # TLS-1.2+ pinned code-side (§3) · AppInsights boot telemetry
        Invoke-RestMethod -Method Post -Uri $endpoint -Body $body -ContentType 'application/json' -TimeoutSec 10 -ErrorAction SilentlyContinue -SslProtocol 'Tls12, Tls13' | Out-Null
    } catch {
        # Boot telemetry is best-effort. AppInsights unreachable must NOT crash boot.
        Write-Warning "Send-XdrBootTelemetry failed: $($_.Exception.Message)"
    }
}

# ─── R3 · TenantContext + product/license discovery at cold-start ──────────────
# The Capabilities module HotCache is process-scoped (module $script:) so subsequent runspaces
# (TimerTrigger, Activity) see the cached value via Get-XdrTenantCapabilities lookups, even
# though profile's own $script: scope is per-runspace.
$script:TenantContext      = $null
$script:TenantCapabilities = $null

if (Get-Command Get-XdrTenantContext -ErrorAction SilentlyContinue) {
    try {
        $script:TenantContext = Get-XdrTenantContext -Portal 'Defender' -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Get-XdrTenantContext failed at cold-start: $($_.Exception.Message)"
    }
}

if (Get-Command Get-XdrTenantCapabilities -ErrorAction SilentlyContinue) {
    try {
        $script:TenantCapabilities = Get-XdrTenantCapabilities -Portal 'Defender' -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Get-XdrTenantCapabilities failed at cold-start: $($_.Exception.Message)"
    }
}

$bootDurationMs = [int]((([DateTime]::UtcNow) - $script:BootStartedUtc).TotalMilliseconds)

Send-XdrBootTelemetry -EventName 'Boot.VersionProbe' -Properties @{
    GitCommit                  = $script:GitCommitSha
    ConnectorVersion           = $script:ConnectorVersion
    BootDurationMs             = $bootDurationMs
    ModulesLoaded              = $script:LoadedModules.Count
    ManifestPortalsLoaded      = $script:LoadedManifests.Keys.Count
    PSVersion                  = $PSVersionTable.PSVersion.ToString()
    FunctionsExtensionVersion  = $env:FUNCTIONS_EXTENSION_VERSION
    FunctionsWorkerRuntime     = $env:FUNCTIONS_WORKER_RUNTIME
    TenantContextResolved      = ($null -ne $script:TenantContext)
    TenantCapabilitiesResolved = ($null -ne $script:TenantCapabilities)
    TenantProductCount         = if ($script:TenantCapabilities) { @($script:TenantCapabilities.Products).Count } else { 0 }
}

$tcSummary = if ($script:TenantCapabilities) { ($script:TenantCapabilities.Products -join ',') } else { '(none)' }
Write-Host "XdrLogRaider boot · v$($script:ConnectorVersion) · commit=$($script:GitCommitSha) · modules=$($script:LoadedModules.Count) · manifests=$($script:LoadedManifests.Keys.Count) · products=[$tcSummary] · ${bootDurationMs}ms"
