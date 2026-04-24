# Xdr.Portal.Auth — portal-agnostic auth chain
# Dot-source private + public functions, export public.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath  = Join-Path $PSScriptRoot 'Public'

$private = @(Get-ChildItem -Path $privatePath -Filter *.ps1 -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path $publicPath  -Filter *.ps1 -ErrorAction SilentlyContinue)

foreach ($file in $private + $public) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to load $($file.FullName): $_"
        throw
    }
}

# Module-level session cache. Keyed by UPN. Holds WebRequestSession (cookies) + metadata.
# Lifetime: ~1h for sccauth. XSRF rotates on every portal response.
$script:SessionCache = @{}

Export-ModuleMember -Function $public.BaseName
