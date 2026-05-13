function Get-DefenderTenantContext {
    <#
    .SYNOPSIS
        Fetches the Defender XDR portal TenantContext document (region, datacenter,
        tenant capabilities) via the apiproxy + sccauth+XSRF chain.

    .DESCRIPTION
        Hits GET /apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true on
        security.microsoft.com. The response carries region/datacenter/SKU
        information that drives:
          - DCE region selection (workspace co-locality)
          - per-tenant capability gating in manifest dispatcher
          - operator-visible regionality in XdrConnectorHealth_CL
        Per Rule 21 this is the canonical mechanism for dynamic regionality;
        no region is ever hardcoded in this connector.

        Result is cached in the WebRequestSession object as $Session.TenantContext
        with TTL 24h. Re-fetch automatic after expiry.

    .PARAMETER Session
        WebRequestSession from Connect-DefenderPortal. Must carry an active
        sccauth cookie and XSRF-TOKEN.

    .PARAMETER ForceRefresh
        Bypass the 24h cache and re-fetch.

    .OUTPUTS
        [pscustomobject] with:
          Region          — Azure region code (e.g. 'weu', 'eus')
          Datacenter      — datacenter identifier
          TenantId        — tenant GUID
          SkuId           — top-level SKU identifier
          RawResponse     — full JSON response from the portal
          FetchedUtc      — when this was fetched
          ExpiresUtc      — fetched + 24h
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession] $Session,

        [switch] $ForceRefresh
    )

    if (-not $ForceRefresh -and $Session.PSObject.Properties['TenantContext']) {
        $cached = $Session.TenantContext
        if ($cached -and $cached.ExpiresUtc -gt [DateTime]::UtcNow) {
            Write-Verbose "TenantContext cache hit (expires $($cached.ExpiresUtc.ToString('o')))"
            return $cached
        }
    }

    $xsrf = ''
    $cookie = $Session.Cookies.GetCookies('https://security.microsoft.com') |
        Where-Object { $_.Name -eq 'XSRF-TOKEN' } |
        Select-Object -First 1
    if ($cookie) { $xsrf = [System.Net.WebUtility]::UrlDecode($cookie.Value) }

    $headers = @{
        'X-XSRF-TOKEN' = $xsrf
        'Accept'       = 'application/json'
    }

    $uri = 'https://security.microsoft.com/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true'
    Write-Verbose "Fetching TenantContext from $uri"

    $resp = Invoke-WebRequest -Uri $uri -WebSession $Session -Headers $headers `
        -Method Get -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

    if ($resp.StatusCode -ne 200) {
        throw "TenantContext fetch failed: HTTP $($resp.StatusCode)"
    }

    $body = $null
    try {
        $body = $resp.Content | ConvertFrom-Json -Depth 20
    } catch {
        throw "TenantContext response parse failed: $_"
    }

    function script:Get-FieldOrEmpty {
        param([Parameter(Mandatory)]$Obj, [Parameter(Mandatory)][string]$Name)
        if ($null -eq $Obj) { return '' }
        try {
            if ($Obj -is [System.Collections.IDictionary] -and $Obj.Contains($Name)) { return [string]$Obj[$Name] }
            $prop = $Obj.PSObject.Properties[$Name]
            if ($prop) { return [string]$prop.Value }
        } catch {}
        return ''
    }
    $now = [DateTime]::UtcNow
    $ctx = [pscustomobject]@{
        Region       = Get-FieldOrEmpty -Obj $body -Name 'region'
        Datacenter   = Get-FieldOrEmpty -Obj $body -Name 'datacenter'
        TenantId     = Get-FieldOrEmpty -Obj $body -Name 'tenantId'
        SkuId        = Get-FieldOrEmpty -Obj $body -Name 'sku'
        RawResponse  = $body
        FetchedUtc   = $now
        ExpiresUtc   = $now.AddHours(24)
    }

    $Session | Add-Member -NotePropertyName 'TenantContext' -NotePropertyValue $ctx -Force
    return $ctx
}
