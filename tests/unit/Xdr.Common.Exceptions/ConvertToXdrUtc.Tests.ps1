#Requires -Version 7.4
# AU1 (audit 2026-06-12) · ConvertTo-XdrUtc is THE shared culture-safe time parser. Proves: a value that is
# ALREADY a [DateTime] (the ConvertFrom-Json -AsHashtable shape) is NEVER stringify-reparsed (the old
# [DateTime]::Parse([string]$v) swapped month/day on a dd/MM host — el-GR/de-DE — corrupting TTLs + cursors);
# ISO strings parse invariant; bad input → $null fail-safe.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    Import-Module (Join-Path $repo 'src\Modules\Xdr.Common.Exceptions\Xdr.Common.Exceptions.psd1') -Force -DisableNameChecking
}

Describe 'AU1 · ConvertTo-XdrUtc culture-safety + datetime short-circuit' {
    It 'a [DateTime] value (the -AsHashtable shape) is NOT stringify-reparsed — no month/day swap on a dd/MM host' {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $dtIn = [DateTime]::new(2026, 9, 10, 14, 30, 0, [DateTimeKind]::Utc)   # September 10
            $out = ConvertTo-XdrUtc $dtIn
            $out.Month | Should -Be 9
            $out.Day   | Should -Be 10
            $out.Hour  | Should -Be 14
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
    It 'an ISO-8601 string parses invariant (Z preserved) regardless of host culture' {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $out = ConvertTo-XdrUtc '2026-09-10T14:30:00.0000000Z'
            $out.Month | Should -Be 9
            $out.Day   | Should -Be 10
            $out.Hour  | Should -Be 14
            $out.Kind  | Should -Be ([System.DateTimeKind]::Utc)
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
    It 'sub-second precision survives (cursor ties must compare exactly)' {
        $out = ConvertTo-XdrUtc '2026-05-06T01:51:53.7605698Z'
        $out.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Match '^2026-05-06T01:51:53\.7605698'
    }
    It 'null / blank / garbage → $null (fail-safe · callers treat null as cold/expired)' {
        ConvertTo-XdrUtc $null        | Should -BeNullOrEmpty
        ConvertTo-XdrUtc ''           | Should -BeNullOrEmpty
        ConvertTo-XdrUtc '   '        | Should -BeNullOrEmpty
        ConvertTo-XdrUtc 'not-a-date' | Should -BeNullOrEmpty
    }
    # WS-A (audit 2026-06-12) · NAIVE (no-Z / no-offset) values must be treated as UTC, NOT host-local. The old
    # RoundtripKind+ToUniversalTime ASSUMED Local on a naive value → on a non-UTC host (el-GR/de-DE, the operator's
    # dev machine · UTC+2/+3) it SHIFTED the value into the past → cursors/windows regressed → re-ingestion. The FA
    # is UTC so the pilot didn't expose it, but "generic across all cases/hosts" REQUIRES the assume-UTC contract.
    It 'a NAIVE ISO string (no Z, no offset) is treated as UTC — NOT shifted by the host offset' {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('el-GR')
            $out = ConvertTo-XdrUtc '2026-06-12T14:30:00'   # naive · no tz info
            $out.Hour   | Should -Be 14    # NOT 11/12 (the host-offset shift the old code produced)
            $out.Minute | Should -Be 30
            $out.Kind   | Should -Be ([System.DateTimeKind]::Utc)
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
    It 'a NAIVE [DateTime] (Kind=Unspecified · e.g. a parse without tz) is treated as UTC — not host-local' {
        $naive = [DateTime]::new(2026, 6, 12, 14, 30, 0, [DateTimeKind]::Unspecified)
        $out = ConvertTo-XdrUtc $naive
        $out.Hour | Should -Be 14
        $out.Kind | Should -Be ([System.DateTimeKind]::Utc)
    }
    It 'a Z-terminated string still converts correctly under a non-UTC host (the assume-UTC change must not regress it)' {
        $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('el-GR')
            $out = ConvertTo-XdrUtc '2026-06-12T14:30:00.0000000Z'
            $out.Hour | Should -Be 14
            $out.Kind | Should -Be ([System.DateTimeKind]::Utc)
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
    }
}
