#Requires -Version 7.4
<#
.SYNOPSIS
WS4.4 · THE live-estate reconcile driver (the operator's "update/override/sync only what changed + cleanup/merge").
Compares the LIVE estate against REPO INTENT and drives the internal iteration model end-to-end:

  1. SCHEMA PARITY (BLOCKING) — tools/Assert-LiveSchemaParity.ps1 per shipped category (live table + DCR
     getschema vs deploy/per-category-schemas, case-sensitive). Drift → exit 2 with the surgical fix command
     (tools/Onboard-CategorySurgical.ps1 -Apply). This is the wired, blocking home of the parity gate.
  2. STALE-COMPONENT REPORT — live Defender_*_CL tables / xdrlr-dcr-* DCRs / XDRLR_DCR_* appsettings with no
     repo counterpart are REPORTED with the explicit per-item delete command for the OPERATOR. This tool NEVER
     deletes anything and NEVER touches role assignments (operator locks).
  3. FRONTIER SEEDING (R-DEPLOY-IDEMPOTENT · -Apply only) — for each CURSOR op whose XdrCheckpoint row is
     ABSENT while the live table already holds its rows (the redeploy/checkpoint-loss state that produced the
     live 4x duplication), seed the checkpoint at the LIVE frontier: Cursor = max(CursorField), BoundaryKeys =
     natural keys at that exact max. The next poll then continues from the frontier instead of re-ingesting
     the full window. (The documented alternative at re-baseline is purge-then-reingest — rollback runbook §3.)

Default = REPORT-ONLY (plan-first, like Onboard-CategorySurgical). -Apply executes ADDITIVE fixes only
(frontier seeds). Synchronous az only · AuthorizationFailed = STOP · no --no-wait · Sysmon_CL never listed.

.PARAMETER ResourceGroup
Connector resource group (FA + DCRs). Required for live operations.

.PARAMETER WorkspaceResourceId
Log Analytics workspace resource id (tables live there). Required for live operations.

.PARAMETER Apply
Execute additive fixes (frontier seeding). Without it: report-only.

.PARAMETER SkipParity
Skip step 1 (diagnostics only — parity is otherwise BLOCKING).
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup,
    [string] $WorkspaceResourceId,
    [switch] $Apply,
    [switch] $SkipParity,
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── PURE planning core (Pester-driven · no Azure) ────────────────────────────────────────────────
function Get-XdrEstateDiffPlan {
    <#
    .SYNOPSIS
    PURE · diff repo intent vs live inventory. Inputs are plain collections; output is the action plan.
    Repo intent: $RepoCategories (tokenized category names) — each implies table Defender_<C>_CL, a DCR
    matching xdrlr-dcr-<c-lower>-*, and an appsetting XDRLR_DCR_DEFENDER_<C-UPPER>.
    Live: $LiveTables (table names) · $LiveDcrs (DCR names) · $LiveAppSettings (setting names).
    Output: @{ MissingLive = @(per-category gaps to fix additively); Stale = @(live items with no repo
    counterpart · operator-delete candidates); Protected = @(live items NEVER listed for deletion). }
    #>
    [CmdletBinding()]
    param(
        [string[]] $RepoCategories,
        [string[]] $LiveTables = @(),
        [string[]] $LiveDcrs = @(),
        [string[]] $LiveAppSettings = @(),
        [string]   $Portal = 'Defender'
    )
    $protectedTables = @('Sysmon_CL')   # operator lock · never self-deployed · NEVER touched/listed
    $wantTables = @{}; $wantDcrPrefixes = @{}; $wantSettings = @{}
    foreach ($c in $RepoCategories) {
        $wantTables["${Portal}_${c}_CL"] = $c
        $wantDcrPrefixes["xdrlr-dcr-$($c.ToLowerInvariant())-"] = $c
        $wantSettings["XDRLR_DCR_$($Portal.ToUpper())_$($c.ToUpper())"] = $c
    }
    $missing = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $RepoCategories) {
        $t = "${Portal}_${c}_CL"
        $dcrHit = @($LiveDcrs | Where-Object { $_ -like "xdrlr-dcr-$($c.ToLowerInvariant())-*" }).Count -gt 0
        $setHit = $LiveAppSettings -contains "XDRLR_DCR_$($Portal.ToUpper())_$($c.ToUpper())"
        $tblHit = $LiveTables -contains $t
        if (-not ($dcrHit -and $setHit -and $tblHit)) {
            $missing.Add([pscustomobject]@{ Category = $c; Table = $tblHit; Dcr = $dcrHit; AppSetting = $setHit
                Fix = "pwsh tools/Onboard-CategorySurgical.ps1 -Portal $Portal -Category $c -Apply" })
        }
    }
    $stale = [System.Collections.Generic.List[object]]::new()
    $protected = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $LiveTables) {
        if ($t -in $protectedTables) { $protected.Add($t); continue }
        # Self-deployed namespaces: per-category `<Portal>_*_CL` AND the legacy `Xdr*_CL` (old-architecture
        # health/aux tables, e.g. XdrConnectorHealth_CL). Anything else (customer tables) is never listed.
        $selfDeployed = ($t -like "${Portal}_*_CL") -or ($t -like 'Xdr*_CL')
        if ($selfDeployed -and -not $wantTables.ContainsKey($t)) {
            $stale.Add([pscustomobject]@{ Kind = 'table'; Name = $t
                OperatorDelete = "az monitor log-analytics workspace table delete --workspace-name <ws> --resource-group <wsRg> --name $t" })
        }
    }
    foreach ($d in $LiveDcrs) {
        $owned = $false
        foreach ($p in $wantDcrPrefixes.Keys) { if ($d -like "$p*") { $owned = $true; break } }
        if (-not $owned -and $d -like 'xdrlr-dcr-*') {
            $stale.Add([pscustomobject]@{ Kind = 'dcr'; Name = $d
                OperatorDelete = "az monitor data-collection rule delete --resource-group <rg> --name $d" })
        }
    }
    foreach ($s in $LiveAppSettings) {
        if ($s -like 'XDRLR_DCR_*' -and -not $wantSettings.ContainsKey($s)) {
            $stale.Add([pscustomobject]@{ Kind = 'appsetting'; Name = $s
                OperatorDelete = "az functionapp config appsettings delete --resource-group <rg> --name <fa> --setting-names $s" })
        }
    }
    return @{ MissingLive = @($missing); Stale = @($stale); Protected = @($protected) }
}

function Get-XdrFrontierSeedPlan {
    <#
    .SYNOPSIS
    PURE · R-DEPLOY-IDEMPOTENT seed plan. For each CURSOR op: if no checkpoint row exists AND the live table
    already holds rows for it (LiveMax non-null), plan a seed at the live frontier so the next poll CONTINUES
    instead of re-ingesting the full window (the live-proven 4x-duplication mechanism: checkpoint loss after a
    redeploy → cold start → full re-ingest over existing rows). SNAPSHOT/WINDOW ops are never seeded (SNAPSHOT
    re-emits by design; WINDOW continues from WindowEndUtc which purge governs). Existing checkpoints are
    NEVER overwritten (seeding only fills the cold-start hole).
    Inputs: $Ops = @(@{ OperationKey; IngestionMode; CursorField; Category }) · $ExistingCheckpointKeys =
    @('<PartitionKey>|<OperationKey>') · $LiveMax = @{ '<OperationKey>' = @{ MaxCursor='<iso>'; BoundaryKeys='k1,k2' } }.
    #>
    [CmdletBinding()]
    param(
        [array] $Ops,
        [string[]] $ExistingCheckpointKeys = @(),
        [hashtable] $LiveMax = @{},
        [string] $Portal = 'Defender'
    )
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($op in $Ops) {
        if ([string]$op.IngestionMode -ne 'CURSOR') { continue }
        if (-not $op.CursorField) { continue }
        $pk = "${Portal}_$($op.Category)"
        if ($ExistingCheckpointKeys -contains "$pk|$($op.OperationKey)") { continue }   # never overwrite
        if (-not $LiveMax.ContainsKey([string]$op.OperationKey)) { continue }           # no live rows → true cold start (correct)
        $lm = $LiveMax[[string]$op.OperationKey]
        if (-not $lm -or -not $lm['MaxCursor']) { continue }
        $plan.Add([pscustomobject]@{
            PartitionKey = $pk; OperationKey = [string]$op.OperationKey
            Cursor = [string]$lm['MaxCursor']; BoundaryKeys = [string]($lm['BoundaryKeys'] ?? '')
            Reason = 'R-DEPLOY-IDEMPOTENT · checkpoint absent + live rows present → adopt live frontier (no re-ingest)'
        })
    }
    return ,@($plan)
}

# ─── Live driver (az · synchronous · report-first) ───────────────────────────────────────────────
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ResourceGroup -or -not $WorkspaceResourceId) {
        Write-Host '[Sync-LiveEstate] -ResourceGroup + -WorkspaceResourceId required for live reconcile (pure planning functions are dot-sourceable for tests).'
        exit 0
    }
    $wsName = ($WorkspaceResourceId -split '/')[-1]
    $wsRg   = ($WorkspaceResourceId -split '/')[4]

    # Repo intent = shipped manifests.
    $manifestRoot = Join-Path $RepoRoot 'manifests'
    $repoCats = @(Get-ChildItem (Join-Path $manifestRoot 'Defender') -Filter '*.psd1' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
    if (-not $repoCats) { Write-Error 'no manifests found — nothing to reconcile against'; exit 1 }
    Write-Host "[Sync-LiveEstate] repo intent: $($repoCats -join ', ')"

    # 1 · BLOCKING schema parity per category (Assert-LiveSchemaParity contract: -SchemaPath -Table -Workspace
    #     where Workspace = the LA customerId GUID; exit 0=PASS · 1=DRIFT(block) · 2=CI-refusal · 3=inconclusive).
    # resolve the LA customerId. az monitor (extension) can transiently return empty (throttle/init): IsNullOrWhiteSpace
    # is null-SAFE (a bare .Trim() on a null az result throws — that masqueraded as a parity FAIL), one retry, then
    # refuse CLEARLY as INCONCLUSIVE (exit 3) — an empty customerId must NOT become a SCHEMA PARITY FAIL (Assert-Live
    # SchemaParity would error on the missing -Workspace and Sync-LiveEstate would mislabel the resolution failure as drift).
    $wsCustomerId = az monitor log-analytics workspace show --resource-group $wsRg --workspace-name $wsName --query customerId -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace([string]$wsCustomerId)) {
        Start-Sleep -Seconds 4
        $wsCustomerId = az monitor log-analytics workspace show --resource-group $wsRg --workspace-name $wsName --query customerId -o tsv 2>$null
    }
    if ([string]::IsNullOrWhiteSpace([string]$wsCustomerId)) { Write-Error "[Sync-LiveEstate] could NOT resolve the WS customerId (az returned empty for RG=$wsRg WS=$wsName · transient/auth?) — cannot run the parity gate; INCONCLUSIVE, not a parity failure"; exit 3 }
    $wsCustomerId = ([string]$wsCustomerId).Trim()
    if (-not $SkipParity) {
        foreach ($cat in $repoCats) {
            Write-Host "[Sync-LiveEstate] parity gate · Defender/$cat"
            & pwsh -NoProfile -File (Join-Path $RepoRoot 'tools\Assert-LiveSchemaParity.ps1') `
                -SchemaPath (Join-Path $RepoRoot "deploy\per-category-schemas\Defender-$cat.json") `
                -Table "Defender_${cat}_CL" -Workspace $wsCustomerId
            $parityExit = $LASTEXITCODE
            if ($parityExit -eq 3) {
                Write-Host "  WARN · parity INCONCLUSIVE for Defender/$cat (live table empty/no rows — nothing can drift yet)" -ForegroundColor DarkYellow
            } elseif ($parityExit -ne 0) {
                Write-Error "SCHEMA PARITY FAIL for Defender/$cat (exit $parityExit) — apply via: pwsh tools/Onboard-CategorySurgical.ps1 -Portal Defender -Category $cat -Apply"
                exit 2
            }
        }
        Write-Host '[Sync-LiveEstate] parity gate GREEN (all categories · case-sensitive vs live getschema)'
    }

    # 2 · live inventory (read-only) → diff plan.
    $faName = az resource list --resource-group $ResourceGroup --resource-type 'Microsoft.Web/sites' --query '[0].name' -o tsv
    $liveSettings = @(az functionapp config appsettings list --resource-group $ResourceGroup --name $faName --query '[].name' -o tsv)
    $liveDcrs     = @(az monitor data-collection rule list --resource-group $ResourceGroup --query '[].name' -o tsv)
    $liveTables   = @(az monitor log-analytics workspace table list --resource-group $wsRg --workspace-name $wsName --query "[?contains(name, '_CL')].name" -o tsv)
    $diff = Get-XdrEstateDiffPlan -RepoCategories $repoCats -LiveTables $liveTables -LiveDcrs $liveDcrs -LiveAppSettings $liveSettings
    Write-Host ''
    Write-Host "─── estate diff ─── missing-live: $(@($diff.MissingLive).Count) · stale: $(@($diff.Stale).Count) · protected: $(@($diff.Protected) -join ', ')"
    foreach ($m in $diff.MissingLive) { Write-Host "  MISSING  $($m.Category) (table=$($m.Table) dcr=$($m.Dcr) appsetting=$($m.AppSetting)) → $($m.Fix)" }
    foreach ($s in $diff.Stale)       { Write-Host "  STALE    [$($s.Kind)] $($s.Name)`n           operator-only: $($s.OperatorDelete)" }
    if (@($diff.Stale).Count -gt 0) { Write-Host '  (deletes are OPERATOR-ONLY · this tool never deletes · role assignments are never listed)' }

    # 3 · R-DEPLOY-IDEMPOTENT frontier seeding (additive · -Apply only).
    Write-Host ''
    Write-Host '[Sync-LiveEstate] frontier check (R-DEPLOY-IDEMPOTENT)'
    $saName = az storage account list --resource-group $ResourceGroup --query '[0].name' -o tsv
    $ops = @()
    foreach ($cat in $repoCats) {
        $man = Import-PowerShellDataFile (Join-Path $manifestRoot "Defender\$cat.psd1")
        foreach ($o in @($man.Operations)) { $ops += [pscustomobject]@{ OperationKey = $o.OperationKey; IngestionMode = $o.IngestionMode; CursorField = $o.CursorField; Category = $cat; NaturalKey = @($o.NaturalKey); Table = $o.WorkspaceTable } }
    }
    $existingKeys = @()
    $cpRows = az storage entity query --account-name $saName --table-name XdrCheckpoint --auth-mode login --query 'items[].{p:PartitionKey,r:RowKey}' -o json 2>$null | ConvertFrom-Json
    foreach ($r in @($cpRows)) { $existingKeys += "$($r.p)|$($r.r)" }
    $liveMax = @{}
    foreach ($o in ($ops | Where-Object { $_.IngestionMode -eq 'CURSOR' -and $_.CursorField })) {
        $q = "$($o.Table) | where OperationKey == '$($o.OperationKey)' | summarize MaxCursor=max($($o.CursorField)) | project MaxCursor"
        $res = az monitor log-analytics query --workspace (az monitor log-analytics workspace show --resource-group $wsRg --workspace-name $wsName --query customerId -o tsv) --analytics-query $q -o json 2>$null | ConvertFrom-Json
        $mx = if (@($res).Count -gt 0 -and $res[0].PSObject.Properties['MaxCursor']) { [string]$res[0].MaxCursor } else { $null }
        if ($mx) {
            $bq = "$($o.Table) | where OperationKey == '$($o.OperationKey)' and $($o.CursorField) == datetime('$mx') | distinct $(@($o.NaturalKey)[0] ?? 'ActionId')"
            $bk = ''
            try { $bres = az monitor log-analytics query --workspace (az monitor log-analytics workspace show --resource-group $wsRg --workspace-name $wsName --query customerId -o tsv) --analytics-query $bq -o json 2>$null | ConvertFrom-Json; $bk = (@($bres) | ForEach-Object { $_.PSObject.Properties.Value } ) -join ',' } catch { $bk = '' }
            $liveMax[$o.OperationKey] = @{ MaxCursor = $mx; BoundaryKeys = $bk }
        }
    }
    $seeds = Get-XdrFrontierSeedPlan -Ops $ops -ExistingCheckpointKeys $existingKeys -LiveMax $liveMax
    if (@($seeds).Count -eq 0) { Write-Host '  no frontier seeds needed (checkpoints present or table empty — cold start is correct)' }
    foreach ($s in $seeds) {
        Write-Host "  SEED $($s.PartitionKey)/$($s.OperationKey) → Cursor=$($s.Cursor) BoundaryKeys=[$($s.BoundaryKeys)]"
        if ($Apply) {
            az storage entity insert --account-name $saName --table-name XdrCheckpoint --auth-mode login --if-exists fail --entity `
                "PartitionKey=$($s.PartitionKey)" "RowKey=$($s.OperationKey)" "Cursor=$($s.Cursor)" "BoundaryKeys=$($s.BoundaryKeys)" `
                "ResumePage=0" "ResumeCursor=" "ResumeHighWater=" "ResumeBoundaryKeys=" "LastItemCount=0" `
                "LastUpdatedUtc=$([DateTime]::UtcNow.ToString('o'))" "CorrelationId=sync-live-estate-frontier-seed" --output none
            if ($LASTEXITCODE -ne 0) { Write-Error "frontier seed FAILED for $($s.OperationKey)"; exit 3 }
            Write-Host '    seeded.'
        }
    }
    if (-not $Apply -and @($seeds).Count -gt 0) { Write-Host '  (report-only · re-run with -Apply to seed)' }

    Write-Host ''
    Write-Host "[Sync-LiveEstate] DONE · parity=$(if($SkipParity){'skipped'}else{'GREEN'}) · missing=$(@($diff.MissingLive).Count) · stale=$(@($diff.Stale).Count) · seeds=$(@($seeds).Count) · applied=$([bool]$Apply)"
}
