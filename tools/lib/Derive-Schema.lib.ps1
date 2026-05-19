# Phase 0 Step 8 · schema + entity + projection derivation helpers.
# Pure functions · dot-sourceable from script + Pester tests · no I/O.

# ─── ISO-8601 datetime detection (best-effort regex · KQL datetime type) ──────
$script:Iso8601Regex = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+\-]\d{2}:\d{2})?$'
$script:Iso8601DateOnlyRegex = '^\d{4}-\d{2}-\d{2}$'

# ─── 13 canonical Sentinel entity heuristics (path-segment keyword match) ─────
$script:EntityKeywords = @{
    devices    = @('DeviceId','MachineId','DeviceName','Hostname','ComputerName','DnsName','ClientName','Endpoint')
    users      = @('UserName','UserPrincipalName','Upn','AccountName','AccountSid','UserId','UserSid','LoggedOnUser','InitiatingUser','RequestedFor','Subject','Principal')
    ips        = @('IpAddress','SourceIp','DestinationIp','RemoteIp','LocalIp','ClientIp')
    urls       = @('Url','Uri','Domain','WebUrl','TargetUrl')
    files      = @('FileName','FilePath','FileHash','Sha256','Sha1','Md5','FileSize','ImageFile')
    processes  = @('ProcessName','ProcessId','ParentProcessId','InitiatingProcess','ImageFileName')
    alerts     = @('AlertId','IncidentId','ThreatId','DetectionId','InvestigationId')
    mails      = @('MessageId','InternetMessageId','EmailAddress','SenderAddress','SmtpMessageId')
    mailboxes  = @('Mailbox','MailboxUpn','MailboxOwner','MailboxAddress')
    cloudApps  = @('AppId','AppName','ApplicationName','SaasApp','ServiceName')
    azureRes   = @('ResourceId','ResourceType','SubscriptionId','ResourceGroup','TenantId')
    registry   = @('RegistryKey','RegistryValueName','RegistryValueData')
    malware    = @('MalwareName','ThreatName','ThreatFamily','VirusName','DetectionName')
}

# ─── JSON-type → KQL-type table ───────────────────────────────────────────────
function ConvertTo-KqlType {
    param([string] $JsonType, [string] $SampleValue)
    switch ($JsonType) {
        'string' {
            if ($SampleValue -match $script:Iso8601Regex)            { return 'datetime' }
            elseif ($SampleValue -match $script:Iso8601DateOnlyRegex) { return 'datetime' }
            elseif ($SampleValue -match '^[0-9a-fA-F]{32,64}$' -and $SampleValue.Length -in 32,40,64) { return 'string' }   # hash literal
            else { return 'string' }
        }
        'integer'  { return 'long' }
        'number'   { return 'real' }
        'boolean'  { return 'bool' }
        'object'   { return 'dynamic' }
        'array'    { return 'dynamic' }
        'datetime' { return 'datetime' }   # PowerShell-parsed [datetime] preserved
        'null'     { return 'string' }
        default    { return 'string' }
    }
}

# ─── JSON-type → ProjectionMap DSL operator ───────────────────────────────────
function Resolve-ProjectionOp {
    param([string] $KqlType)
    switch ($KqlType) {
        'string'   { return '$tostring' }
        'long'     { return '$tolong' }
        'real'     { return '$todouble' }
        'bool'     { return '$tobool' }
        'datetime' { return '$todatetime' }
        'dynamic'  { return '$tojson' }
        default    { return '$tostring' }
    }
}

# ─── Walk a JSON object → emit list of {Path, JsonType, KqlType, SampleValue} ─
function Get-JsonFieldInventory {
    [CmdletBinding()]
    param(
        # AllowNull · recursion descends into object props whose value may be JSON null.
        [Parameter(Mandatory)]
        [AllowNull()]
        $Node,
        [string] $PathPrefix = '',
        [int] $MaxDepth = 6,
        [int] $CurrentDepth = 0
    )
    $fields = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($CurrentDepth -ge $MaxDepth) { return $fields }

    # Detect type
    $jsonType = switch ($true) {
        ($null -eq $Node)              { 'null';    break }
        ($Node -is [bool])             { 'boolean'; break }
        # PowerShell ConvertFrom-Json may auto-parse ISO-8601 strings into [datetime] · treat as 'string' tagged datetime
        ($Node -is [datetime])         { 'datetime'; break }
        ($Node -is [int] -or $Node -is [long] -or $Node -is [System.Int64] -or $Node -is [System.Int32]) { 'integer'; break }
        ($Node -is [double] -or $Node -is [decimal] -or $Node -is [float]) { 'number'; break }
        ($Node -is [string])           { 'string';  break }
        ($Node -is [System.Collections.IDictionary]) { 'object'; break }
        ($Node -is [System.Collections.IEnumerable]) { 'array';  break }
        ($Node -is [pscustomobject])   { 'object';  break }
        default { 'string' }
    }

    # Compute sample value (truncated for safety)
    $sample = switch ($jsonType) {
        'object' { '' }
        'array'  { '' }
        'null'   { 'null' }
        default  {
            $s = [string]$Node
            if ($s.Length -gt 200) { $s.Substring(0,200) + '…' } else { $s }
        }
    }
    $kql = ConvertTo-KqlType -JsonType $jsonType -SampleValue $sample

    # Emit this node (unless it's the root with no path)
    if ($PathPrefix) {
        $fields.Add([pscustomobject]@{
            Path        = $PathPrefix
            JsonType    = $jsonType
            KqlType     = $kql
            SampleValue = $sample
        }) | Out-Null
    }

    # Recurse
    if ($jsonType -eq 'object') {
        $props = if ($Node -is [pscustomobject]) { $Node.PSObject.Properties } else { $Node.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name=$_.Key; Value=$_.Value } } }
        foreach ($prop in $props) {
            $childPath = if ($PathPrefix) { "$PathPrefix.$($prop.Name)" } else { $prop.Name }
            $childFields = Get-JsonFieldInventory -Node $prop.Value -PathPrefix $childPath -MaxDepth $MaxDepth -CurrentDepth ($CurrentDepth + 1)
            foreach ($cf in $childFields) { $fields.Add($cf) | Out-Null }
        }
    } elseif ($jsonType -eq 'array') {
        # Use first item as representative · annotate path with [] suffix
        $first = $null
        try { $first = @($Node)[0] } catch {}
        if ($null -ne $first) {
            $childPath = "$PathPrefix[]"
            $childFields = Get-JsonFieldInventory -Node $first -PathPrefix $childPath -MaxDepth $MaxDepth -CurrentDepth ($CurrentDepth + 1)
            foreach ($cf in $childFields) { $fields.Add($cf) | Out-Null }
        }
    }
    return @($fields)
}

# ─── Entity extraction · heuristic match against field path tokens ────────────
function Get-EntityHints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $FieldInventory
    )
    $hints = @{}
    foreach ($entity in $script:EntityKeywords.Keys) { $hints[$entity] = [System.Collections.Generic.List[string]]::new() }

    foreach ($field in $FieldInventory) {
        $leaf = ($field.Path -split '\.')[-1] -replace '\[\]$',''
        foreach ($entity in $script:EntityKeywords.Keys) {
            foreach ($kw in $script:EntityKeywords[$entity]) {
                if ($leaf -ieq $kw -or $leaf.EndsWith($kw, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if (-not $hints[$entity].Contains($field.Path)) {
                        $hints[$entity].Add($field.Path) | Out-Null
                    }
                    break
                }
            }
        }
    }
    # Return an [ordered]@{} with alphabetically-sorted keys · ensures Test-Determinism byte-equal output.
    $out = [ordered]@{}
    foreach ($k in ($hints.Keys | Sort-Object)) { $out[$k] = @($hints[$k]) }
    return $out
}

# ─── ProjectionMap candidate · scalar leaves only ─────────────────────────────
function Get-ProjectionCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $FieldInventory
    )
    $cands = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($field in $FieldInventory) {
        # Only emit scalar leaves · object/array are typically dynamic/json columns
        if ($field.KqlType -in @('string','long','real','bool','datetime')) {
            $colName = ($field.Path -split '\.|\[\]')[-1]
            if (-not $colName) { continue }
            $op = Resolve-ProjectionOp -KqlType $field.KqlType
            $cands.Add([pscustomobject]@{
                ColumnName = $colName
                DslOp      = $op
                Path       = $field.Path
                KqlType    = $field.KqlType
                SampleValue= $field.SampleValue
            }) | Out-Null
        }
    }
    return @($cands)
}

# ─── Stable schema fingerprint (SHA1 of sorted path,type) ─────────────────────
function Get-SchemaFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $FieldInventory)
    $serialized = ($FieldInventory | ForEach-Object { "$($_.Path):$($_.KqlType)" } | Sort-Object) -join '|'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($serialized)
    $hash  = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-','').ToLowerInvariant()
}
