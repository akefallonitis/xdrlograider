#Requires -Version 7.0
# Determinism probe: run each generator twice, compare hashes.
# Build-FunctionApp.ps1 is a VERIFIER (not a generator) post-Phase-A1 — the 4
# Durable Function dirs (Xdr-Refresh / Xdr-PollOrchestrator / Xdr-PollStream /
# Connector-Heartbeat) are hand-authored and source-of-truth, so they are not
# in the determinism file list.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot
try {
    $files = @(
        'manifests/defender.psd1'
        'deploy/mainTemplate.json'
        'deploy/sentinelContent.json'
        'deploy/dcrs/Defender_ActionCenter_dcr.json'
        'deploy/dcrs/XdrConnectorHealth_dcr.json'
    )
    $builds = @(
        './tools/Build-Manifest.ps1'
        './tools/Build-DcrJson.ps1'
        './tools/Build-FunctionApp.ps1'
        './tools/Build-ArmTemplate.ps1'
        './tools/Build-SentinelSolution.ps1'
    )
    foreach ($b in $builds) { & pwsh -NoProfile -File $b 2>&1 | Out-Null }
    $h1 = @{}
    foreach ($f in $files) { if (Test-Path $f) { $h1[$f] = (Get-FileHash $f -Algorithm SHA256).Hash } }
    foreach ($b in $builds) { & pwsh -NoProfile -File $b 2>&1 | Out-Null }
    $h2 = @{}
    foreach ($f in $files) { if (Test-Path $f) { $h2[$f] = (Get-FileHash $f -Algorithm SHA256).Hash } }
    $hasDrift = $false
    foreach ($f in $files) {
        $status = if ($h1[$f] -eq $h2[$f]) { 'OK   ' } else { $hasDrift = $true; 'DRIFT' }
        Write-Host "  $status  $f"
    }
    if ($hasDrift) { exit 1 }
} finally {
    Pop-Location
}
