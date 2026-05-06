#Requires -Version 7.4
<#
.SYNOPSIS
    Verify Sigstore-cosign signatures on all 6 release artifacts in one shot.

.DESCRIPTION
    Downloads + verifies the 6 cosign-signed artifacts published by
    .github/workflows/release.yml on every v* tag push:

      function-app.zip           (FA package)
      mainTemplate.json          (ARM template)
      createUiDefinition.json    (Deploy-to-Azure UI)
      sentinelContent.json       (Sentinel content ARM)
      xdrlograider-solution-<ver>.zip  (Sentinel Solution Gallery)
      xdrlograider-sbom.spdx.json      (SBOM)

    Each artifact has accompanying .sig (signature) and .bundle (Sigstore
    bundle with cert + tlog entry). Verification asserts:
      - Artifact was built by the akefallonitis/xdrlograider GitHub workflow
      - Signed via Sigstore Fulcio (keyless, OIDC-attested)
      - Recorded in the public Rekor transparency log

    Requires `cosign` CLI (https://github.com/sigstore/cosign).

.PARAMETER Tag
    Git tag to verify. Default: v0.1.0.

.PARAMETER WorkDir
    Directory to download artifacts into. Default: temp directory.

.EXAMPLE
    pwsh tools/Verify-CosignArtifacts.ps1 -Tag v0.1.0

    Verifies all 6 artifacts from the v0.1.0 release. Operators should
    run this after `git tag` + release.yml to confirm supply-chain
    integrity before deploying.
#>
[CmdletBinding()]
param(
    [string] $Tag    = 'v0.1.0',
    [string] $WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-cosign-verify-" + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command cosign -ErrorAction SilentlyContinue)) {
    throw 'cosign CLI not found. Install from https://github.com/sigstore/cosign/releases'
}

# Strip the 'v' for the version-based asset names
$ver = $Tag.TrimStart('v')

$artifacts = @(
    'function-app.zip',
    'mainTemplate.json',
    'createUiDefinition.json',
    'sentinelContent.json',
    "xdrlograider-solution-$ver.zip",
    'xdrlograider-sbom.spdx.json'
)

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Set-Location $WorkDir
Write-Host ""
Write-Host "===== Cosign verification for $Tag =====" -ForegroundColor Cyan
Write-Host "  Working directory: $WorkDir"
Write-Host ""

$base = "https://github.com/akefallonitis/xdrlograider/releases/download/$Tag"
$failures = @()

foreach ($a in $artifacts) {
    Write-Host ("---- {0} ----" -f $a) -ForegroundColor Yellow

    # Download artifact + .sig + .bundle
    $files = @($a, "$a.sig", "$a.bundle")
    foreach ($f in $files) {
        $url = "$base/$f"
        try {
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $WorkDir $f) -ErrorAction Stop
        } catch {
            Write-Host ("  SKIP: {0} not in release (asset may not exist)" -f $f) -ForegroundColor Yellow
            $failures += $a
            continue 2
        }
    }

    # Run cosign verify-blob
    $cmd = @(
        'verify-blob',
        '--certificate-identity-regexp', 'github\.com/akefallonitis/xdrlograider',
        '--certificate-oidc-issuer', 'https://token.actions.githubusercontent.com',
        '--signature', "$a.sig",
        '--bundle', "$a.bundle",
        $a
    )

    & cosign @cmd 2>&1 | ForEach-Object { Write-Host ("    {0}" -f $_) }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  FAIL: cosign verify exited {0}" -f $LASTEXITCODE) -ForegroundColor Red
        $failures += $a
    } else {
        Write-Host "  PASS" -ForegroundColor Green
    }
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "===== ALL $($artifacts.Count) ARTIFACTS VERIFIED =====" -ForegroundColor Green
    Write-Host "All release artifacts confirmed signed by github.com/akefallonitis/xdrlograider via Sigstore Fulcio + Rekor transparency log."
    Write-Host ""
    Write-Host "Cleanup: Remove-Item $WorkDir -Recurse -Force"
    exit 0
} else {
    Write-Host ("===== {0} ARTIFACT(S) FAILED VERIFICATION =====" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
