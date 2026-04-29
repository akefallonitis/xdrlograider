# Entra HTML/JSON $Config blob field accessors.
# Portal-agnostic: parses the structure that login.microsoftonline.com emits
# regardless of which portal is the calling RP.

function Test-EntraField {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    return (@($Object.PSObject.Properties.Name) -contains $Name)
}

function Get-EntraField {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)] [string] $Name, $Default = $null)
    if (Test-EntraField -Object $Object -Name $Name) { return $Object.$Name }
    return $Default
}

function Get-EntraFieldNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param($Object)
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties.Name)
}

function Get-EntraConfigBlob {
    <#
    .SYNOPSIS
        Extracts `$Config = {...};` from Entra login HTML.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Html)

    if ([string]::IsNullOrEmpty($Html)) { return $null }

    $patterns = @(
        '\$Config\s*=\s*(\{.*?\});\s*\n',
        '\$Config\s*=\s*(\{.*?\});\s*</script>'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($match.Success) {
            try { return $match.Groups[1].Value | ConvertFrom-Json }
            catch { Write-Verbose "Get-EntraConfigBlob: `$Config parse failed: $($_.Exception.Message)" }
        }
    }

    # Fallback — outer-brace match (larac2shell pattern).
    if ($Html -match '\{(.*)\}') {
        try { return $Matches[0] | ConvertFrom-Json }
        catch { Write-Verbose "Get-EntraConfigBlob: fallback parse failed: $($_.Exception.Message)" }
    }
    return $null
}

function Get-EntraErrorMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Code, [string] $DefaultText)
    $messages = @{
        '50126'  = 'Invalid username or password.'
        '50053'  = 'Account is locked (too many failed sign-in attempts).'
        '50057'  = 'Account is disabled.'
        '50055'  = 'Password has expired.'
        '50056'  = 'Invalid or null password.'
        '50034'  = 'User account not found in this directory.'
        '50058'  = 'Session information is not sufficient for single-sign-on (ESTS cookie too narrow-scoped).'
        '53003'  = 'Access blocked by a Conditional Access policy.'
        '500121' = 'MFA authentication failed.'
        '700016' = 'Application not found in directory.'
        '900144' = 'Malformed login request (missing client_id). Auth-chain bug.'
    }
    if ($messages.ContainsKey($Code)) { return $messages[$Code] }
    if ($DefaultText) { return $DefaultText }
    return "Entra error $Code"
}

function Test-MfaEndAuthSuccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $EndAuth)
    if ($null -eq $EndAuth) { return $false }
    $success = Get-EntraField -Object $EndAuth -Name 'Success'
    if ($success -eq $true) { return $true }
    $rv = Get-EntraField -Object $EndAuth -Name 'ResultValue'
    if ($rv -in @('AuthenticationSucceeded', 'Success')) { return $true }
    return $false
}
