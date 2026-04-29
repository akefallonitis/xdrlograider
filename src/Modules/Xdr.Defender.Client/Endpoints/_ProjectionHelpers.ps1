# iter-14.0 Phase 4 — typed-column ingest projection helpers.
#
# Design:
#   Manifest ProjectionMap is a hashtable @{ TargetColumn = JSONPath-or-typed-hint }.
#   At ingest time, ConvertTo-MDEIngestRow walks the ProjectionMap and produces
#   typed columns alongside the existing RawJson dynamic blob. Operators query
#   typed columns directly (`MDE_ActionCenter_CL | where ActionStatus == "Completed"`)
#   instead of writing `parse_json(RawJson) | extend …`.
#
# Type-cast hints (left side of ':' in hint string):
#   $tostring:      cast to string (default if no hint)
#   $toint:         cast to long (KQL int columns are 64-bit)
#   $tobool:        cast to bool
#   $todatetime:    parse as ISO 8601 + cast to datetime
#   $todouble:      cast to double
#   $json:          serialize sub-object as JSON string (for nested-object columns)
#
# Path syntax (right side of ':' or whole hint if no ':'):
#   FieldName               top-level property
#   Parent.Child            nested-object dot-notation
#   Parent.Child[0].Field   array indexing inside nested
#   Parent.*.Field          flatten all elements (joins to comma-separated string)
#
# Examples (manifest ProjectionMap entries):
#   ActionStatus  = '$tostring:Status'
#   CreatedTime   = '$todatetime:CreatedTime'
#   ActionId      = 'ActionId'                        # default $tostring
#   AffectedDevices = '$toint:Targets.length'
#   IsSuccessful  = '$tobool:Success'
#   PolicyDetails = '$json:Policy'                    # serialize nested object as JSON
#   FirstAffected = '$tostring:Targets[0].DeviceName'
#   AllAffected   = '$tostring:Targets.*.DeviceName'  # comma-separated DeviceName values

function Project-EntityField {
    <#
    .SYNOPSIS
        Resolves a single ProjectionMap hint against an entity object and returns
        the typed value. Pure function — no external state.

    .DESCRIPTION
        Takes one (TargetColumn, Hint) pair from a manifest ProjectionMap and
        the entity object. Parses the hint's type prefix + JSONPath, walks the
        path, applies the type cast, returns the value (or $null if path
        unresolvable).

        Returns the typed value directly (not a hashtable). Caller wraps it
        into the row's typed-column position.

    .PARAMETER Hint
        The right-hand side of the ProjectionMap entry. Examples:
          '$tostring:ActionId'
          '$todatetime:CreatedTime'
          '$tobool:Policy.IsEnabled'
          'ActionId'                      # default $tostring
          '$json:Policy'

    .PARAMETER Entity
        The entity object (typically a [pscustomobject] from ConvertFrom-Json).

    .OUTPUTS
        Object — the typed value, or $null if the path is unresolvable.
        Type depends on the hint:
          $tostring → [string]
          $toint    → [long]
          $tobool   → [bool]
          $todatetime → [datetime]
          $todouble → [double]
          $json     → [string] (JSON-serialized)

    .EXAMPLE
        Project-EntityField -Hint '$tostring:ActionId' -Entity $entity
        # returns 'a-001'

    .EXAMPLE
        Project-EntityField -Hint '$todatetime:CreatedTime' -Entity $entity
        # returns [datetime]'2026-04-29T10:15:00Z'

    .EXAMPLE
        Project-EntityField -Hint '$json:Policy' -Entity $entity
        # returns '{"IsEnabled":true,"Targets":[…]}'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Hint,
        # NOT [Parameter(Mandatory)] — null entity must return $null defensively
        # (production responses with shape variation; missing fields cannot break ingest).
        $Entity = $null
    )

    if ($null -eq $Entity) { return $null }

    # --- Parse hint into (TypeCast, Path) ---
    $typeCast = '$tostring'
    $path     = $Hint
    if ($Hint -match '^\$(tostring|toint|tobool|todatetime|todouble|todecimal|tolong|toguid|json):(.+)$') {
        $typeCast = '$' + $Matches[1]
        $path     = $Matches[2]
    }

    # --- Walk the JSONPath ---
    $value = Resolve-EntityPath -Entity $Entity -Path $path
    if ($null -eq $value) { return $null }

    # --- Apply type cast ---
    switch ($typeCast) {
        '$tostring'   { return [string]$value }
        '$toint'      { try { return [long]$value } catch { return $null } }
        '$tolong'     { try { return [long]$value } catch { return $null } }
        '$tobool'     {
            if ($value -is [bool]) { return $value }
            if ($value -is [string]) {
                $lower = $value.ToLowerInvariant()
                if ($lower -in @('true','1','yes','enabled','on'))  { return $true }
                if ($lower -in @('false','0','no','disabled','off')) { return $false }
            }
            try { return [bool]$value } catch { return $null }
        }
        '$todatetime' {
            if ($value -is [datetime]) { return $value }
            try { return [datetime]::Parse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
            catch { return $null }
        }
        '$todouble'   { try { return [double]$value } catch { return $null } }
        '$todecimal'  { try { return [decimal]$value } catch { return $null } }
        '$toguid'     {
            try { return [guid]$value } catch { return $null }
        }
        '$json'       {
            if ($null -eq $value) { return $null }
            try { return ($value | ConvertTo-Json -Depth 10 -Compress) } catch { return [string]$value }
        }
        default       { return [string]$value }
    }
}

function Resolve-EntityPath {
    <#
    .SYNOPSIS
        Walks a dot-notation JSONPath against an entity object. Supports nested
        objects, array indexing ([N]), and array-flatten ([*]).

    .DESCRIPTION
        Pure function. Supports:
          'FieldName'                 → entity.FieldName
          'Parent.Child'              → entity.Parent.Child
          'Parent.Child.Sub'          → entity.Parent.Child.Sub
          'Targets[0].DeviceName'     → entity.Targets[0].DeviceName
          'Targets[*].DeviceName'     → entity.Targets[*].DeviceName (joined CSV)
          'Targets.*.DeviceName'      → same as above (alt syntax)
          'Targets.length'            → array.Count

        Returns $null if any segment can't be resolved (defensive — never throws
        on missing fields).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entity,
        [Parameter(Mandatory)] [string] $Path
    )

    if ($null -eq $Entity) { return $null }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Entity }

    # Normalize array-flatten syntax: convert .* to [*] for unified parsing
    $normalized = $Path -replace '\.\*\.', '[*].'
    $normalized = $normalized -replace '\.\*$', '[*]'

    # Split into segments. Segment can be 'Field', 'Field[N]', 'Field[*]'.
    $segments = $normalized -split '\.'
    $current = $Entity

    foreach ($seg in $segments) {
        if ($null -eq $current) { return $null }
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }

        # Check for array indexing
        $field = $seg
        $index = $null
        $flatten = $false
        if ($seg -match '^([^[]+)\[(\d+|\*)\]$') {
            $field = $Matches[1]
            if ($Matches[2] -eq '*') { $flatten = $true } else { $index = [int]$Matches[2] }
        }

        # Special: 'length' / 'Count' on array
        if ($field -in @('length','Length','count','Count') -and ($current -is [array] -or $current -is [System.Collections.IList])) {
            $current = @($current).Count
            continue
        }

        # Property access
        $next = $null
        if ($current -is [hashtable]) {
            if ($current.ContainsKey($field)) { $next = $current[$field] }
        } elseif ($current -is [pscustomobject]) {
            if ($current.PSObject.Properties[$field]) { $next = $current.$field }
        } else {
            # Try generic property access (last resort)
            try { $next = $current.$field } catch { return $null }
        }
        if ($null -eq $next) { return $null }

        # Apply array index / flatten
        if ($null -ne $index) {
            $arr = @($next)
            if ($index -ge 0 -and $index -lt $arr.Count) {
                $current = $arr[$index]
            } else {
                return $null
            }
        } elseif ($flatten) {
            # Array-flatten: take remaining path and apply per-element, join CSV.
            # Rebuild remaining segments after this one.
            $thisSegIdx = $segments.IndexOf($seg)
            $remaining = $segments[($thisSegIdx + 1)..($segments.Count - 1)] -join '.'
            $arr = @($next)
            if ([string]::IsNullOrWhiteSpace($remaining)) {
                # Just flattening the array values themselves
                return ($arr | ForEach-Object { [string]$_ }) -join ','
            }
            $values = $arr | ForEach-Object {
                Resolve-EntityPath -Entity $_ -Path $remaining
            } | Where-Object { $null -ne $_ }
            return ($values | ForEach-Object { [string]$_ }) -join ','
        } else {
            $current = $next
        }
    }

    return $current
}
