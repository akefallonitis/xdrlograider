# tools/Validate-Scope.ps1
# BINDING scope validator · applies discipline rules 19/20/21 to manifests.
# Generic · runs against any manifest psd1 · emits IN/OUT verdict per Operation.
#
# Filter 19 · PORTAL-INTERNAL ONLY (no public API alternative)
# Filter 20 · NO PathParam segments {placeholder} in Path
# Filter 21 · READ-ONLY (GET · or whitelisted ReadOnlyPost · no action verbs)
#
# Usage:
#   Validate-Scope.ps1                                    # all manifests
#   Validate-Scope.ps1 -Portal Defender                   # one portal
#   Validate-Scope.ps1 -Portal Defender -Category ActionCenter  # one Category
#
# Exit codes:
#   0 = ALL manifest entries IN scope (read-only · portal-internal · no PathParam)
#   1 = at least one entry violates a filter (BLOCKING · every catalog Op is dispatch-eligible per §4.18 4-gate · NO IsActive flag)

[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string] $Portal,
    [string] $Category,
    [switch] $JsonOutput
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── RULE 19 · DYNAMIC PER-OP COVERAGE DELTA (NO hardcoded blocklist) ──────────
# The scope decision is made DURING §3.2 6-step research per Op · captured in manifest.
#
# Public API existence ≠ full coverage. Internal /apiproxy/* often returns fields the
# public API omits (analyst comments · enrichments · custom relations · portal-only metadata).
# Per-Op the operator/researcher does a COVERAGE DELTA analysis:
#   - Does the public API return the SAME fields and rows? → OUT (use Microsoft's connector)
#   - Does internal /apiproxy/* return MORE (extra fields, richer data, portal-only relations)? → IN with cited delta
#
# Manifest Provenance fields (Rule 19 enforces presence + consistency · NOT the decision itself):
#   PublicApiAlternative    · empty=no public API · OR cite the public endpoint URL
#   PublicApiCoverageDelta  · required when PublicApiAlternative set · what internal returns that public omits
#   Justification           · required when PublicApiAlternative set · why we keep it as value-add
#
# Rule 19 BLOCKS only when: PublicApiAlternative cited AND (CoverageDelta missing OR Justification missing).

# ─── ACTION VERB BLOCK LIST (Rule 21) ──────────────────────────────────────────
$script:ActionVerbs = @(
    'approve','cancel','isolate','unisolate','restart','runliveresponse','run',
    'execute','stop','start','submit','escalate','block','unblock','delete','undo',
    'trigger','collect','quarantine','release','restore','reset','rotate','rerun',
    'forcefetch','enable','disable','create','update','set','put','add','remove'
)

# ─── HELPER · classify single Operation entry ──────────────────────────────────
function Test-OperationScope {
    param([hashtable] $Op, [string] $PortalName, [string] $CategoryName)

    $violations = @()

    # Filter 19 · per-Op manifest-cited PUBLIC-API COVERAGE DELTA
    # If PublicApiAlternative cited · CoverageDelta + Justification both required (else BLOCK).
    if (-not $Op.ContainsKey('Provenance')) {
        $violations += "Rule19 · Provenance block missing · must cite 4-source research per discipline rule 3"
    } else {
        $prov = $Op.Provenance
        $hasPublic = $prov.ContainsKey('PublicApiAlternative') -and -not [string]::IsNullOrWhiteSpace($prov.PublicApiAlternative)
        if ($hasPublic) {
            $hasDelta = $prov.ContainsKey('PublicApiCoverageDelta') -and -not [string]::IsNullOrWhiteSpace($prov.PublicApiCoverageDelta)
            $hasJustification = $prov.ContainsKey('Justification') -and -not [string]::IsNullOrWhiteSpace($prov.Justification)
            if (-not $hasDelta) {
                $violations += "Rule19 · Provenance cites public API '$($prov.PublicApiAlternative)' but no PublicApiCoverageDelta · BLOCK · cite what internal returns that public omits"
            }
            if (-not $hasJustification) {
                $violations += "Rule19 · Provenance cites public API '$($prov.PublicApiAlternative)' but no Justification · BLOCK · why is this a value-add"
            }
        }
        # Always require at least one source cite (Live OR Postman OR OpenApi)
        $sourceCited = ($prov.ContainsKey('Live') -and $prov.Live) -or
                       ($prov.ContainsKey('Postman') -and $prov.Postman) -or
                       ($prov.ContainsKey('OpenApi') -and $prov.OpenApi)
        if (-not $sourceCited) {
            $violations += "Rule19 · Provenance missing source cite (Live/Postman/OpenApi) · derivation not auditable"
        }
    }

    # Filter 19b · path must be portal-internal (heuristic · path style of /apiproxy/{sub}/...)
    if ($Op.ContainsKey('Path') -and $Op.Path -notmatch '^/[a-z]') {
        $violations += "Rule19 · Path=$($Op.Path) does not look portal-internal (must start with /)"
    }

    # Filter 20 · no ENTITY-DAG PathParam {placeholder} in Path.
    # Rule 20's intent is to DEFER ops whose path needs an id DISCOVERED FROM A PARENT op's response (the
    # entity-DAG: {CaseId} from ListCases · {IncidentId} · {DeviceId} · …) — those can't be polled until the
    # parent linkage resolves (v0.2.0 entity-DAG). It must NOT block RUNTIME-CONTEXT tokens that the URL builder
    # already resolves from dispatcher context with no parent poll. Per New-XdrRequestUrl (Xdr.Common.Runtime ·
    # the path-token substitution block), {TenantId} is substituted from the R3 tenant context the dispatcher
    # seeds on every entry — so a {TenantId}-only path is POLLABLE NOW and legitimately in-scope (the catalogue
    # classifies these EntityResolution=NotEntity · ScopeDecision=Include · Shipped). Keep this list IDENTICAL to
    # the runtime's context-resolvable tokens so scope and runtime never disagree.
    $script:RuntimeContextTokens = @('{TenantId}')
    if ($Op.ContainsKey('Path') -and $Op.Path -match '\{[^}]+\}') {
        $allTokens = [regex]::Matches($Op.Path, '\{[^}]+\}') | ForEach-Object { $_.Value }
        $entityTokens = @($allTokens | Where-Object { $_ -notin $script:RuntimeContextTokens })
        if ($entityTokens.Count -gt 0) {
            # FH-9 · entity-DAG read-fanout ADVANCED to v0.1.0. A RESOLVED entity op is POLLABLE NOW: the runtime
            # Invoke-XdrEntityFanout polls the parent, harvests the id (DependsOn.EntityIdField), substitutes the
            # {ParamName} token, and polls the child under a composite-key checkpoint (fanout COMPLETE · EntityFanout.Tests
            # 19/19). So a non-{TenantId} placeholder is IN-SCOPE iff the op carries EntityResolution=Resolved with a
            # complete DependsOn edge (ParentOperationKey + EntityIdField + ParamName — the catalogue DEPEND stage only
            # sets Resolved when the parent linkage exists and the parent ships). UNRESOLVED/Pending entity ops STAY
            # deferred (no parent linkage → the child URL cannot be built). (Distinct from A15 2nd-portal active polling,
            # which remains post-GA.)
            $dep = if ($Op.ContainsKey('DependsOn')) { $Op['DependsOn'] } else { $null }
            # index access (not dot) so a half-resolved DependsOn missing a key returns $null, never a StrictMode throw
            $depComplete = $dep -and $dep['ParentOperationKey'] -and $dep['EntityIdField'] -and $dep['ParamName']
            $resolvedFanout = ([string]$Op['EntityResolution'] -eq 'Resolved') -and $depComplete
            if (-not $resolvedFanout) {
                $violations += "Rule20 · Path has UNRESOLVED entity-DAG PathParam placeholders: $($entityTokens -join ', ') · DEFER (no Resolved DependsOn parent linkage · the runtime cannot build the child URL)"
            }
        }
    }

    # Filter 21 · Method GET (or whitelisted ReadOnlyPost)
    $isReadOnly = $false
    if ($Op.Method -eq 'GET') { $isReadOnly = $true }
    elseif ($Op.Method -eq 'POST' -and $Op.ContainsKey('ProbeMode') -and $Op.ProbeMode -eq 'ReadOnlyPost') {
        $isReadOnly = $true
    }
    if (-not $isReadOnly) {
        $violations += "Rule21 · Method=$($Op.Method) not read-only · only GET or ReadOnlyPost allowed"
    }

    # Filter 21 · no action verbs in Path
    if ($Op.ContainsKey('Path')) {
        $pathLower = $Op.Path.ToLowerInvariant()
        foreach ($verb in $script:ActionVerbs) {
            # Match verb as a path segment (between /'s or at end)
            if ($pathLower -match "/$verb(\b|/|$)") {
                $violations += "Rule21 · Path contains action verb '$verb' · side-effect detected"
                break
            }
        }
    }

    return @{
        OperationKey = $Op.OperationKey
        InScope      = ($violations.Count -eq 0)
        Violations   = $violations
    }
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────
# Dot-sourced for unit tests (InvocationName '.') → expose the pure Test-OperationScope, skip the live manifest scan.
if ($MyInvocation.InvocationName -eq '.') { return }
$manifestRoot = Join-Path $RepoRoot 'manifests'
if (-not (Test-Path $manifestRoot)) { throw "Manifest root not found: $manifestRoot" }

$results = @()
$portalDirs = if ($Portal) { @(Get-Item (Join-Path $manifestRoot $Portal)) } else { Get-ChildItem $manifestRoot -Directory }

foreach ($pd in $portalDirs) {
    $catFiles = if ($Category) {
        @(Get-Item (Join-Path $pd.FullName "$Category.psd1"))
    } else {
        Get-ChildItem $pd.FullName -Filter '*.psd1' -ErrorAction SilentlyContinue
    }
    foreach ($cf in $catFiles) {
        try {
            $m = Import-PowerShellDataFile -Path $cf.FullName -ErrorAction Stop
            $portalName = $m.Portal
            $catName = $m.Category
            foreach ($op in $m.Operations) {
                $verdict = Test-OperationScope -Op $op -PortalName $portalName -CategoryName $catName
                $verdict['Portal'] = $portalName
                $verdict['Category'] = $catName
                $verdict['Method'] = $op.Method
                $verdict['Path'] = $op.Path
                $results += [pscustomobject]$verdict
            }
        } catch {
            Write-Warning "Manifest parse fail: $($cf.FullName) · $($_.Exception.Message)"
        }
    }
}

if ($JsonOutput) {
    $results | ConvertTo-Json -Depth 10
    if ($results | Where-Object { -not $_.InScope }) { exit 1 } else { exit 0 }
}

Write-Host '=== Validate-Scope · Rule 19/20/21 verdict ===' -ForegroundColor Cyan
# Every catalog Op is dispatch-eligible at runtime (§4.18 4-gate · NO IsActive flag), so ANY out-of-scope
# Op is BLOCKING · there is no "inactive · acceptable" tier.
$inScope = 0; $outBlocking = 0
foreach ($r in $results) {
    if ($r.InScope) { $inScope++; $tag = 'IN '; $color = 'Green' }
    else            { $outBlocking++; $tag = 'OUT [BLOCKING]'; $color = 'Red' }
    Write-Host ("  [$tag] $($r.Portal)/$($r.Category)/$($r.OperationKey) · $($r.Method) $($r.Path)") -ForegroundColor $color
    foreach ($v in $r.Violations) { Write-Host "      ! $v" -ForegroundColor Yellow }
}
Write-Host ''
Write-Host "Summary · IN scope: $inScope · OUT of scope (BLOCKING): $outBlocking" -ForegroundColor Yellow

if ($outBlocking -gt 0) { exit 1 } else { exit 0 }
