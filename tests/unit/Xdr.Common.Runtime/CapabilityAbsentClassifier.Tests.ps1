#Requires -Version 7.4
# License-independence (§3 · operator-locked 2026-06-10 · capability-absent → posture, never hard-refuse):
# Test-XdrIsCapabilityAbsent classifies "this tenant cannot serve the op" so the runtime postures it (visible
# Capability.OpUnavailable telemetry · no DLQ). Response-driven + GENERIC (no per-op list): 403/404, OR a 400 whose
# body is the apiproxy "InvalidProxyPrefix" (a DOCUMENTED route — e.g. /mtoapi Multi-Tenant-Org — that a tenant
# WITHOUT the product cannot route). A 400 with a REAL contract error must stay terminal (LOUD · breaker-bounded).

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Auth',
                     'Xdr.Common.OAuthBearer','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Capabilities',
                     'Xdr.Common.Runtime')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
    function script:NewTerminal { param([int]$Sc, [string]$Body)
        New-XdrException -Type PortalTerminal -Message "HTTP $Sc" -Properties @{ StatusCode = $Sc; ResponseBody = $Body }
    }
}

Describe 'License-independence · Test-XdrIsCapabilityAbsent (capability-absent → posture, never DLQ)' {
    It 'TRUE on 400 + InvalidProxyPrefix body (documented MTO route not routable for a non-MTO tenant = license gate)' {
        Test-XdrIsCapabilityAbsent -Exception (script:NewTerminal 400 '{"Error":"Failed with error: InvalidProxyPrefix"}') | Should -BeTrue
    }
    It 'TRUE on 400 + "licenses are required" body (product/license absent on THIS tenant = capability-absent · F18 · live-caught 2026-06-25 ListExtensions/ListCertificates · TvmPremium)' {
        Test-XdrIsCapabilityAbsent -Exception (script:NewTerminal 400 '"The following licenses are required to be on: TvmPremium"') | Should -BeTrue
    }
    It 'TRUE on 400 + "requires a ... license" body (phrasing-robust · the license marker is order-independent)' {
        Test-XdrIsCapabilityAbsent -Exception (script:NewTerminal 400 '{"error":"This operation requires a Defender Vulnerability Management license"}') | Should -BeTrue
    }
    It 'FALSE on 400 "Wrong pagination parameters" (NO license marker → stays LOUD · the marker must NOT mask the pagination-400 the engine precision fix surfaces · zero-masking)' {
        Test-XdrIsCapabilityAbsent -Exception (script:NewTerminal 400 '{"error":"Wrong pagination parameters"}') | Should -BeFalse
    }
    It 'FALSE on 400 with a real contract error (stays terminal → LOUD · breaker-bounded)' {
        Test-XdrIsCapabilityAbsent -Exception (script:NewTerminal 400 '{"Error":"InvalidParameter: foo"}') | Should -BeFalse
    }
    It 'TRUE on 403 (capability-absent)' {
        Test-XdrIsCapabilityAbsent -Exception (script:NewTerminal 403 '') | Should -BeTrue
    }
    It 'TRUE on 404 (capability/data-absent)' {
        Test-XdrIsCapabilityAbsent -Exception (script:NewTerminal 404 '') | Should -BeTrue
    }
    It 'FALSE on 500 (transient, not capability-absent)' {
        Test-XdrIsCapabilityAbsent -Exception (script:NewTerminal 500 '') | Should -BeFalse
    }
    It 'FALSE on $null and on a non-PortalTerminal exception' {
        Test-XdrIsCapabilityAbsent -Exception $null | Should -BeFalse
        Test-XdrIsCapabilityAbsent -Exception ([System.InvalidOperationException]::new('x')) | Should -BeFalse
    }
}
