# Enrich-Entities-Parsing-Value.ps1
#
# Phase 0 prep: walk all metadata.json + live.json and add:
#   1. entities[]            — which canonical Sentinel entity types appear in this endpoint's response (for cross-table joins)
#   2. parsingNotes[]        — per-endpoint quirks operator + dev need to know
#   3. operationalReference  — XDRInternals cmdlet that wraps this endpoint (downstream of nodoc)
#   4. historicalReference   — DefenderHarvester path match (paths now HARDENED by Microsoft; reference only)
#
# Plus per-sub-area aggregation in _SUBAREA.json:
#   - valueProp              — security-ops use case for this sub-area
#   - entitiesAvailable      — entities that appear in any endpoint in this sub-area
#   - paginationStyles       — distinct pagination styles
#   - timeFilterCoverage     — count of endpoints with time-filter support

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ReferencesRoot = "$PSScriptRoot\..\references"
)

# ---------------------------------------------------------------------------
# Canonical Sentinel entity types — what we use for cross-table joins (Architecture J in v1)
# Pattern: regex on field name OR field value
# ---------------------------------------------------------------------------
$entityPatterns = @(
    @{ Name='Host.MdatpId';        FieldPattern='^(machineId|MachineId|deviceId|DeviceId|senseClientId)$' }
    @{ Name='Host.AadDeviceId';    FieldPattern='^(aadDeviceId|aadId|azureAdDeviceId|AadDeviceId)$' }
    @{ Name='Host.FullName';       FieldPattern='^(computerDnsName|ComputerDnsName|machineDnsName|hostName|deviceName|dnsName)$' }
    @{ Name='Host.OsPlatform';     FieldPattern='^(osPlatform|OsPlatform|operatingSystem)$' }
    @{ Name='Host.RiskScore';      FieldPattern='^(riskScore|RiskScore|exposureScore|ExposureScore)$' }
    @{ Name='Host.HealthStatus';   FieldPattern='^(healthStatus|HealthStatus|machineHealthStatus)$' }

    @{ Name='Account.UPN';         FieldPattern='^(userPrincipalName|UserPrincipalName|upn|UPN|accountUpn|emailAddress)$' }
    @{ Name='Account.AadId';       FieldPattern='^(userId|accountObjectId|aadUserId|azureAdUserId|AccountObjectId)$' }
    @{ Name='Account.SamName';     FieldPattern='^(samAccountName|SamAccountName|accountName|AccountName)$' }
    @{ Name='Account.Sid';         FieldPattern='^(accountSid|AccountSid|sid|userSid|SID)$' }

    @{ Name='IP.Address';          FieldPattern='^(ipAddress|IpAddress|publicIp|PublicIP|sourceIp|destinationIp|remoteIP)$' }

    @{ Name='File.Sha256';         FieldPattern='^(sha256|SHA256|fileSha256|hashSha256|hash256)$' }
    @{ Name='File.Sha1';           FieldPattern='^(sha1|SHA1|fileSha1|hashSha1)$' }
    @{ Name='File.Md5';            FieldPattern='^(md5|MD5|fileMd5|hashMd5)$' }
    @{ Name='File.Name';           FieldPattern='^(fileName|FileName|originalFileName)$' }
    @{ Name='File.Path';           FieldPattern='^(filePath|FilePath|folderPath|directory|fileLocation)$' }

    @{ Name='Process.Id';          FieldPattern='^(processId|ProcessId|pid|PID)$' }
    @{ Name='Process.CommandLine'; FieldPattern='^(commandLine|CommandLine|processCommandLine|ProcessCommandLine)$' }

    @{ Name='Url.Path';            FieldPattern='^(url|URL|requestUrl|Url)$' }
    @{ Name='Url.Domain';          FieldPattern='^(domain|Domain|dnsDomain|DnsDomain|fqdn|FQDN)$' }

    @{ Name='Vuln.CveId';          FieldPattern='^(cveId|CveId|cve|CVE|cvesId|cveNumber)$' }
    @{ Name='Software.Vendor';     FieldPattern='^(softwareVendor|vendor|productVendor)$' }
    @{ Name='Software.Name';       FieldPattern='^(softwareName|productName|product)$' }
    @{ Name='Software.Version';    FieldPattern='^(softwareVersion|version|productVersion)$' }

    @{ Name='Alert.Id';            FieldPattern='^(alertId|AlertId)$' }
    @{ Name='Incident.Id';         FieldPattern='^(incidentId|IncidentId)$' }
    @{ Name='Investigation.Id';    FieldPattern='^(investigationId|InvestigationId|aIRId)$' }
    @{ Name='Action.Id';           FieldPattern='^(actionId|ActionId)$' }
    @{ Name='Rule.Id';             FieldPattern='^(ruleId|RuleId|suppressionRuleId|detectionRuleId)$' }
    @{ Name='Policy.Id';           FieldPattern='^(policyId|PolicyId|configId)$' }

    @{ Name='Tenant.Id';           FieldPattern='^(tenantId|TenantId)$' }
    @{ Name='Time.Generated';      FieldPattern='^(timeGenerated|TimeGenerated|eventTime|EventTime|reportedTime|createdTime|startTime|endTime|lastSeen|firstSeen)$' }
)

function Extract-EntitiesFromSample {
    param([object]$Sample)
    $hits = New-Object System.Collections.Generic.HashSet[string]
    if (-not $Sample) { return @() }
    # Walk JSON tree breadth-first, collecting property names
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($Sample)
    $maxNodes = 500
    $count = 0
    while ($stack.Count -gt 0 -and $count -lt $maxNodes) {
        $count++
        $node = $stack.Pop()
        if ($null -eq $node) { continue }
        if ($node -is [System.Collections.IDictionary] -or $node -is [pscustomobject]) {
            $props = if ($node -is [System.Collections.IDictionary]) { $node.Keys } else { $node.PSObject.Properties.Name }
            foreach ($k in $props) {
                foreach ($ep in $entityPatterns) {
                    if ($k -match $ep.FieldPattern) { [void]$hits.Add($ep.Name); break }
                }
                # Recurse into nested
                $v = if ($node -is [System.Collections.IDictionary]) { $node[$k] } else { $node.$k }
                if ($v -is [System.Collections.IDictionary] -or $v -is [pscustomobject] -or $v -is [System.Collections.IEnumerable]) {
                    if (-not ($v -is [string])) { $stack.Push($v) }
                }
            }
        } elseif ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            foreach ($item in $node) { $stack.Push($item); if ($count -ge $maxNodes) { break } }
        }
    }
    return @($hits)
}

function Get-ParsingNotes {
    param([object]$Meta)
    $notes = @()
    # Shape notes
    if ($Meta.live -and $Meta.live.responseShape) {
        if ($Meta.live.responseShape -match '^wrapper:') { $notes += "ResponseShape=Wrapper — UnwrapProperty='$(($Meta.live.responseShape -replace 'wrapper:', '') -replace '\[\]$','')' for projection" }
        elseif ($Meta.live.responseShape -eq 'array')   { $notes += "ResponseShape=Array — no UnwrapProperty; iterate top-level items" }
        elseif ($Meta.live.responseShape -eq 'object')  { $notes += "ResponseShape=SingleObject — use SingleObjectAsRow=true in v2 projection" }
    }
    # POST endpoints
    if ($Meta.methods -and ($Meta.methods -contains 'post')) { $notes += "Method=POST — likely needs request body (often a filter object); review nodoc requestBody" }
    # Path templates
    if ($Meta.path -match '\{[^}]+\}') { $notes += "PathTemplate — '$($Meta.path)' has {placeholders}; v2 manifest needs PerEntityFanout or path-param resolution" }
    # Pagination quirks
    if ($Meta.pagination.style -eq 'pageIndex0Based') { $notes += "Pagination=pageIndex0Based — index starts at 0 (some MS endpoints reject 0; verify per endpoint)" }
    elseif ($Meta.pagination.style -eq 'pageIndex1Based') { $notes += "Pagination=pageIndex1Based — index starts at 1" }
    elseif ($Meta.pagination.style -eq 'continuationToken') { $notes += "Pagination=continuationToken — read token from response; manifest needs TokenPath" }
    elseif ($Meta.pagination.style -eq 'offsetLimit') { $notes += "Pagination=offsetLimit — accumulate offset by pageSize" }
    # Time filters
    if ($Meta.timeFilter.supported) {
        $tf = @()
        if ($Meta.timeFilter.startParam)    { $tf += "startParam=$($Meta.timeFilter.startParam)" }
        if ($Meta.timeFilter.endParam)      { $tf += "endParam=$($Meta.timeFilter.endParam)" }
        if ($Meta.timeFilter.lookbackParam) { $tf += "lookbackParam=$($Meta.timeFilter.lookbackParam)" }
        $notes += "DeltaPoll=supported — wire LastPolledUtc state in Storage Table; pass via $($tf -join '/')"
    } else {
        $notes += "DeltaPoll=NOT supported — every poll re-fetches full snapshot (cost: $($Meta.suggestedCadence) cadence × full inventory)"
    }
    # Live-error notes
    if ($Meta.live) {
        switch ($Meta.live.successKind) {
            'error'      {
                $code = if ($Meta.live.httpStatus) { $Meta.live.httpStatus } else { '0' }
                if ($code -eq 400)      { $notes += "LiveProbe=400 — usually license-gated (e.g., TvmPremium/MDI/MCAS absent); operators with full licenses will see different result" }
                elseif ($code -eq 403)  { $notes += "LiveProbe=403 — RBAC scope or feature license absent in lab tenant" }
                elseif ($code -eq 404)  { $notes += "LiveProbe=404 — endpoint may be MDI-license-gated OR Microsoft renamed/retired the path" }
                elseif ($code -ge 500)  { $notes += "LiveProbe=5xx — transient Microsoft-side; retry-on-cadence will recover" }
                else                    { $notes += "LiveProbe=error/$code — operator should check live response body for diagnosis" }
            }
            'live-empty' { $notes += "LiveProbe=live-empty — endpoint works, tenant has no data of this type (boundary-marker row only)" }
            'rate-limited' { $notes += "LiveProbe=rate-limited — backoff via Rate429Count" }
            'live'       { $notes += "LiveProbe=live ($($Meta.live.rowCount) rows) — production-grade data flow" }
            default      { }
        }
    }
    # Nodoc completeness
    if ($Meta.sourceFile -and $Meta.PSObject.Properties['operationId']) {
        # No-op for now; could detect 'pending' in YamlBlock
    }
    return $notes
}

# ---------------------------------------------------------------------------
# Value-proposition map per sub-area (security-ops use case)
# ---------------------------------------------------------------------------
$valueProps = @{
    'action_center'           = 'Audit trail of automated investigation responses + pending operator approvals (compliance: who approved what response and when)'
    'attack_simulator'        = 'Inventory of phishing simulation campaigns + training completion (security-awareness program metrics)'
    'cloud_apps'              = 'MCAS app inventory + governance policies (shadow IT discovery, OAuth app sprawl, DLP enforcement)'
    'configuration'           = 'Tenant-wide config drift detection: suppression rules, alert tuning, custom detections, RBAC, threat indicators — the audit gap Microsoft does not close'
    'data_lake'               = 'Defender Data Lake state + advanced hunting data lifecycle (data residency + retention compliance)'
    'endpoint_configuration'  = 'ASR rule modes, AV policy bodies, Tamper Protection state, EDR-block, web content filtering — endpoint security posture drift'
    'endpoint_devices'        = 'Device inventory with risk + exposure scores; foundation for cross-table joins (Architecture J — HostMdatpId is the universal join key)'
    'entity_pivots'           = 'On-demand entity context lookups (user/device timeline, alert evidence) — operator drill-down support'
    'exposure_management'     = 'XSPM attack paths + chokepoints + asset rules + posture metrics + secure score breakdown — proactive risk posture'
    'files'                   = 'File prevalence + reputation (forensic context for incidents involving binaries)'
    'identity'                = 'MDI surface: DSA, DC sensor coverage, dormant accounts, lateral movement paths, alert thresholds — identity-side drift'
    'multi_tenant'            = 'MTO tenant inventory + workload status across managed tenants (MSSP-grade visibility)'
    'portal_services'         = 'Portal-side service state (rarely-changed; informational)'
    'secure_score'            = 'Per-category secure score breakdown + historical trend (DCSPM cloud initiative, TVM SCA categories, V2 control profiles)'
    'sentinel_precision'      = 'Sentinel-Defender integration state (cross-portal correlation health)'
    'streaming'               = 'Defender XDR Streaming API destinations (audit data-egress: who configured what export to where)'
    'threat_analytics'        = 'Threat outbreaks + enriched data + top threats (proactive intel correlation with org assets)'
    'vulnerability_management'= 'CVE inventory + software inventory + recommendations + advisories + remediation tasks — TVM drift'
}

# ---------------------------------------------------------------------------
# Walk catalogue
# ---------------------------------------------------------------------------
$total = 0
$entStats = @{}
Get-ChildItem -Path $ReferencesRoot -Filter 'metadata.json' -Recurse | ForEach-Object {
    $f = $_.FullName
    try {
        $m = Get-Content $f -Raw | ConvertFrom-Json -Depth 30
    } catch { return }
    $total++

    # Entities — read from live.json sample if present
    $entities = @()
    $liveJson = Join-Path (Split-Path $f) 'live.json'
    if (Test-Path $liveJson) {
        try {
            $lj = Get-Content $liveJson -Raw | ConvertFrom-Json -Depth 30
            if ($lj.sample) { $entities = Extract-EntitiesFromSample -Sample $lj.sample }
        } catch {}
    }
    # If no live sample, derive entities from nodoc YAML response schema (heuristic: look for property names in YAML)
    if (@($entities).Count -eq 0) {
        $nodocPath = Join-Path (Split-Path $f) 'nodoc.yml'
        if (Test-Path $nodocPath) {
            $yaml = Get-Content $nodocPath -Raw
            $entitySet = New-Object System.Collections.Generic.HashSet[string]
            foreach ($ep in $entityPatterns) {
                # match field name pattern in YAML schema lines
                $bareAlternation = $ep.FieldPattern.Substring(1, $ep.FieldPattern.Length-2)
                if ($yaml -match "\b($bareAlternation)\b") {
                    [void]$entitySet.Add($ep.Name)
                }
            }
            $entities = @($entitySet | Sort-Object)
        }
    }
    # Coerce to array (PowerShell can collapse single-element to string)
    $entities = @($entities)

    # Parsing notes
    $parsingNotes = Get-ParsingNotes -Meta $m

    # Reframe XDRInternals / DefenderHarvester
    $opRef = $null
    if ($m.PSObject.Properties['xdrInternalsCmdlet'] -and $m.xdrInternalsCmdlet) {
        $opRef = [ordered]@{
            xdrInternalsCmdlet = $m.xdrInternalsCmdlet
            note = 'XDRInternals provides an operational PowerShell wrapper for this endpoint (downstream of nodoc — not authoritative)'
        }
    }
    $histRef = $null
    if ($m.PSObject.Properties['defenderHarvesterMatch'] -and $m.defenderHarvesterMatch) {
        $histRef = [ordered]@{
            defenderHarvesterPath = $m.defenderHarvesterMatch.Path
            description = $m.defenderHarvesterMatch.Description
            status = 'HARDENED — Microsoft added protection that breaks the historic DefenderHarvester probe; this matched path is reference-only, NOT a working endpoint pattern. Our nodoc-discovered path is the canonical one.'
        }
    }

    # Update + clean up
    $m | Add-Member -NotePropertyName 'entities' -NotePropertyValue $entities -Force
    $m | Add-Member -NotePropertyName 'parsingNotes' -NotePropertyValue $parsingNotes -Force
    $m | Add-Member -NotePropertyName 'operationalReference' -NotePropertyValue $opRef -Force
    $m | Add-Member -NotePropertyName 'historicalReference' -NotePropertyValue $histRef -Force
    if ($m.PSObject.Properties['xdrInternalsCmdlet']) { $m.PSObject.Properties.Remove('xdrInternalsCmdlet') }
    if ($m.PSObject.Properties['defenderHarvesterMatch']) { $m.PSObject.Properties.Remove('defenderHarvesterMatch') }
    if ($m.PSObject.Properties['xdrInternalsHint']) { $m.PSObject.Properties.Remove('xdrInternalsHint') }
    if ($m.PSObject.Properties['defenderHarvester']) { $m.PSObject.Properties.Remove('defenderHarvester') }

    $m | ConvertTo-Json -Depth 30 | Set-Content -Path $f

    # Tally
    foreach ($e in $entities) {
        if (-not $entStats.ContainsKey($e)) { $entStats[$e] = 0 }
        $entStats[$e]++
    }
}

# ---------------------------------------------------------------------------
# Per-portal sub-area enrichment: aggregate entities + value-prop into _SUBAREA.json
# ---------------------------------------------------------------------------
Get-ChildItem -Path $ReferencesRoot -Directory | ForEach-Object {
    $portalDir = $_.FullName
    Get-ChildItem -Path $portalDir -Directory | ForEach-Object {
        $saDir = $_.FullName
        $saName = $_.Name
        $saIndexPath = Join-Path $saDir '_SUBAREA.json'
        if (-not (Test-Path $saIndexPath)) { return }
        try {
            $sa = Get-Content $saIndexPath -Raw | ConvertFrom-Json -Depth 30
        } catch { return }

        $allEntities = New-Object System.Collections.Generic.HashSet[string]
        $allPaginationStyles = New-Object System.Collections.Generic.HashSet[string]
        $tfCount = 0; $totalEp = 0
        Get-ChildItem -Path $saDir -Directory | ForEach-Object {
            $mPath = Join-Path $_.FullName 'metadata.json'
            if (Test-Path $mPath) {
                $totalEp++
                try {
                    $mm = Get-Content $mPath -Raw | ConvertFrom-Json -Depth 30
                    if ($mm.entities) { foreach ($e in $mm.entities) { [void]$allEntities.Add($e) } }
                    if ($mm.pagination -and $mm.pagination.style -ne 'none') { [void]$allPaginationStyles.Add($mm.pagination.style) }
                    if ($mm.timeFilter -and $mm.timeFilter.supported) { $tfCount++ }
                } catch {}
            }
        }
        $sa | Add-Member -NotePropertyName 'valueProp' -NotePropertyValue ($valueProps[$saName] | ForEach-Object { $_ } | Select-Object -First 1) -Force
        if (-not $sa.valueProp) { $sa.valueProp = "(no value-prop defined; sub-area for sub-portal $saName)" }
        $sa | Add-Member -NotePropertyName 'entitiesAvailable' -NotePropertyValue (@($allEntities) | Sort-Object) -Force
        $sa | Add-Member -NotePropertyName 'paginationStyles' -NotePropertyValue (@($allPaginationStyles) | Sort-Object) -Force
        $sa | Add-Member -NotePropertyName 'timeFilterEndpointCount' -NotePropertyValue $tfCount -Force
        $sa | ConvertTo-Json -Depth 30 | Set-Content $saIndexPath
    }
}

Write-Host ""
Write-Host "=== Entity + parsing-notes + value-prop enrichment complete ===" -ForegroundColor Cyan
Write-Host ("  Total metadata files scanned: {0}" -f $total)
Write-Host ""
Write-Host "  Entity occurrence counts (across all endpoints):" -ForegroundColor DarkGray
$entStats.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 25 | ForEach-Object {
    "{0,-25} {1}" -f $_.Key, $_.Value | Write-Host
}
