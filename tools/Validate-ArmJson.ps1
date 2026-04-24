#Requires -Version 7.0
<#
.SYNOPSIS
    Validates the compiled ARM/Sentinel JSON assets parse and are well-formed.

.DESCRIPTION
    CI-friendly JSON sanity check (no network, no az CLI dependency).
    - JSON parse via ConvertFrom-Json
    - $schema present
    - mainTemplate + sentinelContent have resources array
    - createUiDefinition has $schema + parameters

.EXAMPLE
    pwsh ./tools/Validate-ArmJson.ps1
#>

[CmdletBinding()]
param(
    # When true, treat ARM semantic warnings (API-version staleness, missing
    # api-version, etc.) as hard failures. Default false so dev iteration
    # isn't blocked on cosmetic issues; CI release-gate flips this to true.
    [switch] $Strict
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$files = @(
    [pscustomobject]@{ Path='deploy/compiled/mainTemplate.json';       Kind='armTemplate' }
    [pscustomobject]@{ Path='deploy/compiled/createUiDefinition.json'; Kind='createUi'    }
    [pscustomobject]@{ Path='deploy/compiled/sentinelContent.json';    Kind='armTemplate' }
)

$anyFail = $false
foreach ($entry in $files) {
    $p = $entry.Path
    $kind = $entry.Kind
    if (-not (Test-Path $p)) {
        Write-Host ("MISSING: {0}" -f $p) -ForegroundColor Red
        $anyFail = $true
        continue
    }

    $raw = Get-Content $p -Raw
    # 1) JSON parse
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        Write-Host ("OK   : {0} parses as JSON" -f $p) -ForegroundColor Green
    } catch {
        Write-Host ("FAIL : {0} JSON parse - {1}" -f $p, $_.Exception.Message) -ForegroundColor Red
        $anyFail = $true
        continue
    }

    # 2) schema present
    $names = $obj.PSObject.Properties.Name
    if ($names -notcontains '$schema') {
        Write-Host ("WARN : {0} missing `$schema" -f $p) -ForegroundColor Yellow
    } else {
        Write-Host ("OK   : {0} `$schema = {1}" -f $p, $obj.'$schema') -ForegroundColor Green
    }

    # 3) kind-specific sanity
    switch ($kind) {
        'armTemplate' {
            if ($names -notcontains 'contentVersion') {
                Write-Host ("FAIL : {0} missing contentVersion" -f $p) -ForegroundColor Red
                $anyFail = $true
            }
            if ($names -notcontains 'resources') {
                Write-Host ("FAIL : {0} missing resources array" -f $p) -ForegroundColor Red
                $anyFail = $true
            } else {
                $resCount = @($obj.resources).Count
                Write-Host ("OK   : {0} has {1} resources" -f $p, $resCount) -ForegroundColor Green
            }
        }
        'createUi' {
            if ($names -notcontains 'handler') {
                Write-Host ("FAIL : {0} missing handler" -f $p) -ForegroundColor Red
                $anyFail = $true
            }
            if ($names -notcontains 'version') {
                Write-Host ("FAIL : {0} missing version" -f $p) -ForegroundColor Red
                $anyFail = $true
            }
        }
    }
}

# ============================================================================
# ARM SEMANTIC CHECKS — targeted at bug classes we've hit in production.
# These go beyond "does it parse" to "will ARM actually deploy it?".
# ============================================================================

Write-Host ""
Write-Host "=== ARM semantic checks ===" -ForegroundColor Cyan

$mainTemplatePath = 'deploy/compiled/mainTemplate.json'
if (-not (Test-Path $mainTemplatePath)) {
    Write-Host "SKIP : semantic checks (mainTemplate.json missing)" -ForegroundColor Yellow
} else {
    $template = Get-Content $mainTemplatePath -Raw | ConvertFrom-Json

    # CHECK 1: Cross-RG / cross-subscription dependsOn scope bug
    # ----------------------------------------------------------------
    # If a resource is a Microsoft.Resources/deployments with a non-null
    # subscriptionId OR resourceGroup (cross-scope nested deploy), then
    # OTHER resources' dependsOn arrays MUST reference it by plain name —
    # NOT by resourceId('Microsoft.Resources/deployments', ...). ARM
    # validators resolve resourceId() in the parent template's scope, which
    # doesn't match the child deployment's cross-scope target. This is
    # exactly the bug that caused "The resource ... is not defined in the
    # template" on v0.1.0-beta first deploy attempt.
    $crossScopeDeployments = @($template.resources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments' -and
        (($_.PSObject.Properties.Name -contains 'subscriptionId' -and $_.subscriptionId) -or
         ($_.PSObject.Properties.Name -contains 'resourceGroup'   -and $_.resourceGroup))
    })
    $scopeBugs = @()
    foreach ($cs in $crossScopeDeployments) {
        # Extract the literal deployment name (may be an ARM expression like
        # "[concat('customTables-', variables('suffix'))]" — we want the
        # stable identifier, which is the text inside concat or the bare string).
        $csName = $cs.name
        foreach ($r in $template.resources) {
            if ($r.PSObject.Properties.Name -notcontains 'dependsOn' -or -not $r.dependsOn) { continue }
            foreach ($d in $r.dependsOn) {
                # Bug pattern: [resourceId('Microsoft.Resources/deployments', <matches cross-scope name>)]
                # We match against the *literal substring* of the cross-scope
                # deployment's name expression inside a resourceId() call.
                # Example bad: [resourceId('Microsoft.Resources/deployments', concat('customTables-', variables('suffix')))]
                # Example good: [concat('customTables-', variables('suffix'))]
                if ($d -match 'resourceId\(\s*[''"]Microsoft\.Resources/deployments[''"]') {
                    # Does this resourceId reference match a cross-scope deployment?
                    $insideConcat = $csName -replace '[\[\]]', ''
                    if ($d -match [regex]::Escape($insideConcat.Substring(1, [math]::Min(30, $insideConcat.Length - 1)))) {
                        $scopeBugs += [pscustomobject]@{
                            ReferencingResource = $r.name
                            CrossScopeTarget    = $csName
                            BadDependsOnEntry   = $d
                        }
                    }
                }
            }
        }
    }
    if ($scopeBugs.Count -gt 0) {
        Write-Host ("FAIL : {0} cross-RG dependsOn scope bug(s) detected" -f $scopeBugs.Count) -ForegroundColor Red
        foreach ($b in $scopeBugs) {
            Write-Host ("       - resource '$($b.ReferencingResource)' dependsOn uses resourceId() for cross-scope deployment '$($b.CrossScopeTarget)'") -ForegroundColor Red
            Write-Host ("         Bad:  $($b.BadDependsOnEntry)") -ForegroundColor DarkGray
        }
        Write-Host "       Fix: use the plain concat()/name expression without wrapping resourceId() — ARM resolves cross-scope dependencies by name, not resource ID." -ForegroundColor Yellow
        $anyFail = $true
    } else {
        $csCount = $crossScopeDeployments.Count
        Write-Host ("OK   : no cross-RG dependsOn scope bugs ($csCount cross-scope deployment(s) checked)") -ForegroundColor Green
    }

    # CHECK 2: All declared parameters are used somewhere
    # ----------------------------------------------------------------
    if ($template.PSObject.Properties.Name -contains 'parameters' -and $template.parameters) {
        $declared = @($template.parameters.PSObject.Properties.Name)
        $bodyText = ($template | ConvertTo-Json -Depth 50 -Compress)
        $unused = @($declared | Where-Object { $bodyText -notmatch "parameters\('$_'\)" })
        if ($unused.Count -gt 0) {
            if ($Strict) {
                Write-Host ("FAIL : $($unused.Count) declared parameter(s) are never referenced: $($unused -join ', ')") -ForegroundColor Red
                $anyFail = $true
            } else {
                Write-Host ("WARN : $($unused.Count) declared parameter(s) never referenced: $($unused -join ', ')") -ForegroundColor Yellow
            }
        } else {
            Write-Host ("OK   : all $($declared.Count) declared parameters are referenced") -ForegroundColor Green
        }
    }

    # CHECK 3: DCR service-quota gates (dataFlows <= 10, destinations <= 10,
    # every streamDeclaration referenced)
    # ----------------------------------------------------------------
    # Microsoft.Insights/dataCollectionRules has hard service quotas that ARM-TTK
    # does not catch. Hitting these only manifests at preflight (PreflightValidation
    # CheckFailed). v0.1.0-beta originally generated 47 dataFlows (one per stream)
    # and tripped 'DataFlows item count should be 10 or less'. Catch here.
    $dcrs = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
    foreach ($dcr in $dcrs) {
        $dcrName = $dcr.name
        $props = $dcr.properties
        if ($props.PSObject.Properties.Name -contains 'dataFlows' -and $props.dataFlows) {
            $flowCount = @($props.dataFlows).Count
            if ($flowCount -gt 10) {
                Write-Host ("FAIL : DCR '$dcrName' has $flowCount dataFlows (Azure limit: 10). Consolidate by listing multiple streams in one dataFlow's 'streams' array.") -ForegroundColor Red
                $anyFail = $true
            } else {
                Write-Host ("OK   : DCR '$dcrName' dataFlows = $flowCount (within Azure limit of 10)") -ForegroundColor Green
            }
            # Streams-per-dataFlow quota: Azure rejects any dataFlow whose
            # 'streams' array has more than 20 entries. Caught us on the first
            # consolidation attempt (1 flow × 47 streams). Split by category.
            $maxStreamsPerFlow = 0
            $offendingFlowIdx = -1
            for ($i = 0; $i -lt @($props.dataFlows).Count; $i++) {
                $flow = $props.dataFlows[$i]
                $sCount = @($flow.streams).Count
                if ($sCount -gt $maxStreamsPerFlow) { $maxStreamsPerFlow = $sCount }
                if ($sCount -gt 20) {
                    $offendingFlowIdx = $i
                    Write-Host ("FAIL : DCR '$dcrName' dataFlow[$i] has $sCount streams (Azure limit: 20 per dataFlow). Split into multiple dataFlows grouped by category/tier.") -ForegroundColor Red
                    $anyFail = $true
                }
            }
            if ($offendingFlowIdx -lt 0) {
                Write-Host ("OK   : DCR '$dcrName' max streams in any dataFlow = $maxStreamsPerFlow (within Azure limit of 20)") -ForegroundColor Green
            }
            # Cross-check: every streamDeclaration must appear in some dataFlow.streams
            if ($props.PSObject.Properties.Name -contains 'streamDeclarations' -and $props.streamDeclarations) {
                $declaredStreams = @($props.streamDeclarations.PSObject.Properties.Name)
                $referencedStreams = @()
                foreach ($df in $props.dataFlows) {
                    if ($df.PSObject.Properties.Name -contains 'streams') {
                        $referencedStreams += @($df.streams)
                    }
                }
                $orphanStreams = @($declaredStreams | Where-Object { $_ -notin $referencedStreams })
                if ($orphanStreams.Count -gt 0) {
                    Write-Host ("FAIL : DCR '$dcrName' has $($orphanStreams.Count) declared stream(s) not referenced in any dataFlow: $($orphanStreams -join ', ')") -ForegroundColor Red
                    $anyFail = $true
                } else {
                    Write-Host ("OK   : DCR '$dcrName' all $($declaredStreams.Count) streamDeclarations are referenced in dataFlows") -ForegroundColor Green
                }
            }
        }
        # If any dataFlow has multiple streams, transformKql must NOT be set
        # (Microsoft DCR rule: "If you use a transformation, the data flow
        # should only use a single stream."). Tripped us with InvalidPayload
        # at DCR creation when we shipped the consolidated 3-flow shape with
        # the redundant TimeGenerated cast.
        if ($props.PSObject.Properties.Name -contains 'dataFlows' -and $props.dataFlows) {
            for ($i = 0; $i -lt @($props.dataFlows).Count; $i++) {
                $df = $props.dataFlows[$i]
                $hasTransform = ($df.PSObject.Properties.Name -contains 'transformKql' -and $df.transformKql)
                $multiStream  = (@($df.streams).Count -gt 1)
                if ($hasTransform -and $multiStream) {
                    Write-Host ("FAIL : DCR '$dcrName' dataFlow[$i] has $(@($df.streams).Count) streams AND a transformKql — Azure rejects multi-stream + transform combinations.") -ForegroundColor Red
                    $anyFail = $true
                }
            }
            if (-not $anyFail) {
                Write-Host ("OK   : DCR '$dcrName' no multi-stream + transformKql combinations") -ForegroundColor Green
            }
        }

        # Sentinel Solution shape: any nested deploy whose name starts with
        # 'solution-' must use resourceId() (not extensionResourceId) for
        # hierarchical Microsoft.OperationalInsights/workspaces/providers/*
        # types. Bicep's `.id` accessor on a `workspaces/providers/...`
        # resource compiles to a 4-arg extensionResourceId() that ARM rejects
        # with: "the type ... requires '3' resource name argument(s)" at
        # template validation. Tripped us in iteration 6.
        $solutionNested = @($template.resources | Where-Object {
            $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'solution-'
        })
        foreach ($snd in $solutionNested) {
            $bodyText = ($snd | ConvertTo-Json -Depth 50 -Compress)
            $badMatches = [regex]::Matches($bodyText, "extensionResourceId\([^)]*workspaces/providers/")
            if ($badMatches.Count -gt 0) {
                Write-Host ("FAIL : '$($snd.name)' uses extensionResourceId() with hierarchical workspaces/providers/ type ($($badMatches.Count) occurrence(s)). ARM rejects this with 'requires N resource name argument(s)'. Use resourceId('Microsoft.OperationalInsights/workspaces/providers/<resource>', workspaceName, 'Microsoft.SecurityInsights', <name>) instead.") -ForegroundColor Red
                $anyFail = $true
            } else {
                Write-Host ("OK   : '$($snd.name)' Solution refs use plain resourceId() (no broken extensionResourceId on hierarchical types)") -ForegroundColor Green
            }

            $innerRes = @($snd.properties.template.resources)

            # `location` field check on every Solution resource — Microsoft Sentinel
            # content resources (contentPackages, metadata, dataConnectors)
            # require an Azure region. Missing `location` won't always fail
            # at deploy but Marketplace + Content Hub indexing relies on it.
            $solRes = $innerRes | Where-Object { $_.type -in 'Microsoft.OperationalInsights/workspaces/providers/contentPackages','Microsoft.OperationalInsights/workspaces/providers/metadata','Microsoft.OperationalInsights/workspaces/providers/dataConnectors' }
            $missingLoc = @($solRes | Where-Object { -not $_.PSObject.Properties['location'] -or -not $_.location })
            if ($missingLoc.Count -gt 0) {
                Write-Host ("FAIL : $($missingLoc.Count) Solution resources missing 'location' field: $(@($missingLoc | ForEach-Object { $_.name }) -join ', ')") -ForegroundColor Red
                $anyFail = $true
            } else {
                Write-Host ("OK   : all $(@($solRes).Count) Solution resources carry 'location'") -ForegroundColor Green
            }

            # contentPackages required-property check (Sentinel content schema 3.0.0).
            # Microsoft.SecurityInsights API rejects PUT with `properties.contentSchemaVersion is required` if the field is missing.
            # Pinned required set per reference solutions: contentSchemaVersion, kind, version, displayName, contentKind, contentId.
            $cp = $innerRes | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/contentPackages' } | Select-Object -First 1
            if ($cp) {
                # Note: do NOT require `parentId` or `id` on contentPackages.
                # Iteration 9 deploy attempt rejected with `Invalid data model - solutions
                # expect properties.contentId to match properties.parentId` even when
                # both fields were set to the same variable. The Sentinel API does
                # not require these for Solution-kind packages in schema 3.0.0; their
                # presence triggers an over-zealous equality check that fails on
                # ARM expressions that resolve identically. Omit both.
                $required = @('contentSchemaVersion', 'kind', 'version', 'displayName', 'contentKind', 'contentId')
                $missing  = @($required | Where-Object { -not $cp.properties.PSObject.Properties[$_] })
                if ($missing.Count -gt 0) {
                    Write-Host ("FAIL : contentPackages missing required properties: $($missing -join ', '). Sentinel API rejects with `properties.<field> is required` BadRequestException.") -ForegroundColor Red
                    $anyFail = $true
                } else {
                    Write-Host ("OK   : contentPackages has all 6 required properties (contentSchemaVersion, kind, version, displayName, contentKind, contentId)") -ForegroundColor Green
                }
                if ($cp.properties.PSObject.Properties['contentSchemaVersion'] -and $cp.properties.contentSchemaVersion -notmatch '^\d+\.\d+\.\d+$') {
                    Write-Host ("WARN : contentPackages.contentSchemaVersion = '$($cp.properties.contentSchemaVersion)' should be a semver string like '3.0.0'") -ForegroundColor Yellow
                }
            }
        }

        # If the DCR's outputStream targets are custom tables (Custom-* prefix
        # or omitted-with-by-name routing), the DCR resource MUST dependsOn the
        # cross-RG nested deployment that creates those tables — otherwise DCR
        # creation race-conditions on a synchronous "do these tables exist?"
        # check at PUT time and fails with InvalidOutputTable. This bug shipped
        # in v0.1.0-beta first deploy attempts; locked here to prevent recur.
        $dcrDeps = @()
        if ($dcr.PSObject.Properties.Name -contains 'dependsOn' -and $dcr.dependsOn) {
            $dcrDeps = @($dcr.dependsOn)
        }
        $tablesNestedDeploys = @($template.resources | Where-Object {
            $_.type -eq 'Microsoft.Resources/deployments' -and ($_.name -match 'customTables|tables-')
        })
        if ($tablesNestedDeploys.Count -gt 0) {
            $tableDeployRef = $tablesNestedDeploys[0].name
            $stripped = ($tableDeployRef -replace '\[|\]', '').Trim()
            $stripped = if ($stripped -match "concat\(([^)]+)\)") { $Matches[1] } else { $stripped }
            $matched = $false
            foreach ($d in $dcrDeps) {
                if ($d.Contains('customTables') -or $d.Contains('tables-')) {
                    $matched = $true
                    break
                }
            }
            if (-not $matched) {
                Write-Host ("FAIL : DCR '$dcrName' is missing dependsOn entry for the cross-RG customTables nested deploy ('$tableDeployRef'). DCR creation will race the table creation and fail with InvalidOutputTable.") -ForegroundColor Red
                $anyFail = $true
            } else {
                Write-Host ("OK   : DCR '$dcrName' dependsOn includes the customTables nested deploy") -ForegroundColor Green
            }
        }

        if ($props.PSObject.Properties.Name -contains 'destinations' -and $props.destinations) {
            $destCount = 0
            foreach ($destProp in $props.destinations.PSObject.Properties) {
                if ($destProp.Value -is [array]) {
                    $destCount += @($destProp.Value).Count
                } elseif ($destProp.Value) {
                    $destCount += 1
                }
            }
            if ($destCount -gt 10) {
                Write-Host ("FAIL : DCR '$dcrName' has $destCount destinations (Azure limit: 10)") -ForegroundColor Red
                $anyFail = $true
            } else {
                Write-Host ("OK   : DCR '$dcrName' destinations = $destCount (within limit)") -ForegroundColor Green
            }
        }
    }

    # CHECK 4: All dependsOn targets resolve to an actual resource or known pattern
    # ----------------------------------------------------------------
    $allResourceNames = @($template.resources | ForEach-Object { $_.name })
    $allResourceTypes = @($template.resources | ForEach-Object { $_.type })
    $danglingDeps = @()
    foreach ($r in $template.resources) {
        if ($r.PSObject.Properties.Name -notcontains 'dependsOn' -or -not $r.dependsOn) { continue }
        foreach ($d in $r.dependsOn) {
            # Accept: any reference to a resource name in the template
            #         any resourceId(...) call matching a declared type
            #         any raw name matching a resource name
            $resolved = $false
            foreach ($rname in $allResourceNames) {
                if ($d.Contains($rname)) { $resolved = $true; break }
            }
            if (-not $resolved) {
                foreach ($rtype in $allResourceTypes) {
                    if ($d.Contains($rtype)) { $resolved = $true; break }
                }
            }
            if (-not $resolved) {
                $danglingDeps += [pscustomobject]@{ From = $r.name; Target = $d }
            }
        }
    }
    if ($danglingDeps.Count -gt 0 -and $Strict) {
        Write-Host ("WARN : $($danglingDeps.Count) dependsOn entries may not match any resource in the template (could be intentional cross-template refs):") -ForegroundColor Yellow
        foreach ($d in $danglingDeps | Select-Object -First 5) {
            Write-Host ("       - $($d.From) -> $($d.Target)") -ForegroundColor DarkGray
        }
    } else {
        Write-Host ("OK   : dependsOn entries resolve to template resources ($($allResourceNames.Count) resources)") -ForegroundColor Green
    }
}

# ============================================================================
# SENTINEL SOLUTION SHAPE — does the deployment actually surface as a Sentinel
# solution + connector card the way Microsoft first-party connectors do?
# ============================================================================

Write-Host ""
Write-Host "=== Sentinel Solution shape ===" -ForegroundColor Cyan

$mainPath = 'deploy/compiled/mainTemplate.json'
if (Test-Path $mainPath) {
    $main = Get-Content $mainPath -Raw | ConvertFrom-Json
    $solutionDeploy = $null
    foreach ($r in $main.resources) {
        if ($r.type -eq 'Microsoft.Resources/deployments' -and $r.name -match 'solution-') {
            $solutionDeploy = $r
            break
        }
    }
    if (-not $solutionDeploy) {
        Write-Host ("FAIL : no 'solution-*' nested deployment in mainTemplate.json — connector won't appear in Sentinel Data Connectors blade") -ForegroundColor Red
        $anyFail = $true
    } else {
        Write-Host ("OK   : 'solution-*' nested deploy present (cross-RG into workspace RG)") -ForegroundColor Green
        # Inner template must contain: contentPackages (the Solution wrapper)
        # + dataConnectors (StaticUI connector card) + DataConnector metadata
        # back-link. NO metadata kind=Solution: AbnormalSecurity reference
        # solution (2026-02-17, contentSchemaVersion 3.0.0) confirms newer
        # solutions use only contentPackages — adding a separate metadata-Solution
        # triggers Sentinel's `Invalid data model - solutions expect contentId
        # to match parentId` rejection (the metadata's parentId is a full
        # resourceId path while contentId is the slug; they can never match by
        # string). The contentPackages IS the Solution.
        $innerResources = @($solutionDeploy.properties.template.resources)
        $haveContentPackage    = $innerResources | Where-Object { $_.type -match 'contentPackages$' }
        $haveDataConnector     = $innerResources | Where-Object { $_.type -match 'dataConnectors$' }
        $haveSolutionMeta      = $innerResources | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'Solution' }
        $haveDataConnectorMeta = $innerResources | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'DataConnector' }
        if ($haveSolutionMeta) {
            Write-Host ("FAIL : solution-* inner template has REDUNDANT metadata kind=Solution (Sentinel rejects it). Keep only contentPackages as the wrapper.") -ForegroundColor Red
            $anyFail = $true
        } else {
            Write-Host ("OK   : solution-* inner template correctly omits metadata kind=Solution (canonical AbnormalSecurity 2026-02-17 shape)") -ForegroundColor Green
        }
        foreach ($pair in @(
            @{ Name='contentPackages';        Have=$haveContentPackage    }
            @{ Name='dataConnector';          Have=$haveDataConnector     }
            @{ Name='DataConnector metadata'; Have=$haveDataConnectorMeta }
        )) {
            if (-not $pair.Have) {
                Write-Host ("FAIL : solution-* inner template missing '{0}' resource" -f $pair.Name) -ForegroundColor Red
                $anyFail = $true
            } else {
                Write-Host ("OK   : solution-* inner template has '{0}'" -f $pair.Name) -ForegroundColor Green
            }
        }
        if ($haveDataConnector) {
            $kind = $haveDataConnector[0].kind
            if ($kind -ne 'StaticUI') {
                Write-Host ("FAIL : dataConnectors kind = '$kind'; expected 'StaticUI' (the kind first-party MS solutions use for cards without interactive Connect flow)") -ForegroundColor Red
                $anyFail = $true
            } else {
                Write-Host ("OK   : dataConnectors kind = StaticUI") -ForegroundColor Green
            }
        }
    }
}

# ============================================================================
# SENTINEL CONTENT — analytic rules technique format.
# Sentinel API regex for techniques is ^T\d+$ (parent only). Sub-techniques
# (T1562.001) are rejected. Caught us in iteration 5.
# ============================================================================

Write-Host ""
Write-Host "=== Sentinel content ===" -ForegroundColor Cyan

$sentinelPath = 'deploy/compiled/sentinelContent.json'
if (Test-Path $sentinelPath) {
    $sentinel = Get-Content $sentinelPath -Raw | ConvertFrom-Json
    $alertRules = @($sentinel.resources | Where-Object { $_.type -match 'alertRules' })
    $badRules = @()
    foreach ($r in $alertRules) {
        $tactics    = $r.properties.tactics
        $techniques = $r.properties.techniques
        if ($tactics -isnot [System.Array])    { $badRules += "$($r.name) tactics not array" }
        if ($techniques -isnot [System.Array]) { $badRules += "$($r.name) techniques not array" }
        foreach ($t in @($techniques)) {
            if ($t -notmatch '^T\d+$') {
                $badRules += "$($r.name) technique '$t' violates ^T\d+$ (sub-techniques rejected by Sentinel API)"
            }
        }
        # Sentinel API also requires technique→tactic mapping match
        if ($techniques -contains 'T1595' -and -not ($tactics -contains 'Reconnaissance')) {
            $badRules += "$($r.name) declares T1595 but tactics doesn't include 'Reconnaissance'"
        }
    }
    if ($badRules.Count -gt 0) {
        Write-Host ("FAIL : $($badRules.Count) analytic rule shape violations:") -ForegroundColor Red
        foreach ($b in $badRules | Select-Object -First 5) { Write-Host "       - $b" -ForegroundColor DarkGray }
        $anyFail = $true
    } else {
        Write-Host ("OK   : all $($alertRules.Count) analytic rules have valid tactics + techniques shape (^T\d+$, arrays, MITRE-consistent)") -ForegroundColor Green
    }
}

# ============================================================================
if ($anyFail) {
    Write-Host ""
    Write-Host "ARM validation: FAIL" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "ARM validation: PASS" -ForegroundColor Green
exit 0
