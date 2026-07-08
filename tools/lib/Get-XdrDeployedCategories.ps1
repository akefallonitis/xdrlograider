#Requires -Version 7.4
# PURE · dot-sourceable. The deployed-category list for a Portal, DERIVED from the committed manifests
# (manifests/<Portal>/*.psd1) — the SAME source the FA loads (Get-XdrManifests auto-discovers portal dirs then
# *.psd1) and the gauntlet enumerates (Run-PrePushGauntlet / Validate-Manifests). Single source so the per-round
# drivers (Run-PostDeployVerify, Invoke-XdrRoundReprove) loop the REAL deployed categories data-driven, never a
# hand-typed list (which would silently drift as categories are added — the "only-data-expands" property).
Set-StrictMode -Version Latest

function Get-XdrDeployedCategories {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string] $Portal = 'Defender',
        # repo root: tools/lib/ → ..\.. ; overridable for tests.
        [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    )
    $manifestDir = Join-Path $RepoRoot "manifests/$Portal"
    if (-not (Test-Path $manifestDir)) { return @() }
    return @(Get-ChildItem -Path $manifestDir -Filter '*.psd1' -File -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { $_.BaseName })
}
