#Requires -Version 7.4
# Inspect failure samples · 2 examples per classification with request/response details
[CmdletBinding()]
param([string]$FixturesRoot = (Join-Path $PSScriptRoot '..\tests\fixtures\live'))

$ErrorActionPreference = 'Continue'

$metas = Get-ChildItem $FixturesRoot -Filter 'meta.json' -Recurse | ForEach-Object {
    try {
        $m = Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
        # Pull EntryKey/Path/Method from request.json (meta.json lacks them)
        $reqPath = Join-Path $_.DirectoryName 'request.json'
        if (Test-Path $reqPath) {
            $req = Get-Content -Raw -LiteralPath $reqPath | ConvertFrom-Json
            Add-Member -InputObject $m -NotePropertyName '_EntryKey' -NotePropertyValue ($req.entryKey) -Force
            Add-Member -InputObject $m -NotePropertyName '_Path'     -NotePropertyValue ($req.path) -Force
            Add-Member -InputObject $m -NotePropertyName '_Method'   -NotePropertyValue ($req.method) -Force
        }
        Add-Member -InputObject $m -NotePropertyName '_Dir' -NotePropertyValue $_.DirectoryName -Force
        $m
    } catch { $null }
} | Where-Object { $_ }

foreach ($cls in @('error-400','unresolved-path-params','html-terminal','error-500','error-405','exception','error--1')) {
    $samples = @($metas | Where-Object { $_.classification -eq $cls } | Select-Object -First 3)
    if ($samples.Count -eq 0) { continue }
    Write-Host ""
    Write-Host "=== [$cls] ===" -ForegroundColor Yellow
    foreach ($s in $samples) {
        $method = if ($s.PSObject.Properties['_Method']) { [string]$s._Method } else { '?' }
        $path = if ($s.PSObject.Properties['_Path']) { [string]$s._Path } else { '?' }
        $sc = if ($s.PSObject.Properties['statusCode']) { [string]$s.statusCode } else { '?' }
        $entryKey = if ($s.PSObject.Properties['_EntryKey']) { [string]$s._EntryKey } else { '?' }
        Write-Host (" EntryKey:  $entryKey")
        Write-Host (" Method/Status:  $method  $sc")
        Write-Host (" Path: $path")
        $respPath = Join-Path $s._Dir 'response.json'
        if (Test-Path $respPath) {
            $raw = Get-Content -Raw -LiteralPath $respPath -ErrorAction SilentlyContinue
            if ($raw) {
                $compact = ($raw -replace '\s+', ' ').Trim()
                if ($compact.Length -gt 200) { $compact = $compact.Substring(0, 200) + '...' }
                Write-Host (" Response: $compact") -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }
}
