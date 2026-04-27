#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.8 doc-consistency gate: every doc that mentions service-account
    role requirements must say `Security Reader + Defender XDR Analyst`,
    NOT `Security Administrator` or any over-privileged alternative.

.DESCRIPTION
    Live evidence — operator deployed with Security Administrator instead
    of Security Reader. The docs were correct (PERMISSIONS.md, AUTH.md,
    DEPLOYMENT.md, GETTING-AUTH-MATERIAL.md, README.md all say "Security
    Reader") but a single drift in a future PR would re-open the over-
    privileged hole.

    These tests scan the docs and assert:

      1. Every doc that mentions the SA role uses the canonical pair
         (Security Reader + Defender XDR Analyst), NOT Security Administrator.
      2. PERMISSIONS.md contains the explicit "do not use Security
         Administrator" warning + the per-endpoint role-gated breakdown.
      3. The 9 gated endpoints in the manifest are consistent with the
         PERMISSIONS.md per-stream table.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe 'Service-account role consistency across docs' {

    It 'no doc recommends Security Administrator for the service account' {
        $docs = @(
            'docs/PERMISSIONS.md'
            'docs/DEPLOYMENT.md'
            'docs/AUTH.md'
            'docs/GETTING-AUTH-MATERIAL.md'
            'README.md'
        )
        $offenders = @()
        foreach ($d in $docs) {
            $path = Join-Path $script:RepoRoot $d
            if (-not (Test-Path $path)) { continue }
            $content = Get-Content $path -Raw
            # Match "Security Administrator" only when it's RECOMMENDED for SA setup.
            # Mentions in a "do NOT use" warning are fine.
            $lines = $content -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                # Skip lines that explicitly warn against / forbid the role
                if ($line -match '(?i)(do not|don''?t|never|wrong|over-?privileged|forbid|warning|red flag|⚠|excluded|NOT recommended)') { continue }
                # Skip lines mentioning Security Administrator only in tabular comparisons or quotes
                if ($line -match '(?i)`Security Administrator`.*(write capability|leak|attacker)') { continue }
                # Skip explanatory / comparative / instructional mentions (iter-13.8)
                if ($line -match '(?i)(even Security Administrator|auto-grants|previously[- ]tagged|previously-tagged|counter[- ]example|downgrade|cannot be role[- ]blocking|wasn''?t role[- ]blocking|live audit|returned 403|returned 4xx|returned 4\d\d)') { continue }
                # Match plain "Security Administrator" only — NOT compound roles
                # like "Cloud App Security Administrator" (legitimate MCAS role for
                # the previously-role-gated stream). Use negative-lookbehind on the prefix.
                if ($line -match '(?i)(?<!Cloud App |Cloud Application |Privileged Authentication |Information Protection )\bSecurity Administrator\b' -and
                    $line -match '(?i)(assign|grant|use|should|needs?|require[ds]?|add)') {
                    $offenders += "$d:L$($i+1) :: $($line.Trim())"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because ('Service account must be Security READER not Security ADMINISTRATOR for least-privilege. Offenders:' + [Environment]::NewLine + ($offenders -join [Environment]::NewLine))
    }

    It 'every key doc names the canonical SA-role pair (Security Reader + Defender XDR Analyst)' {
        $docs = @(
            'docs/PERMISSIONS.md'
            'docs/AUTH.md'
            'docs/GETTING-AUTH-MATERIAL.md'
            'docs/DEPLOYMENT.md'
            'README.md'
        )
        $missing = @()
        foreach ($d in $docs) {
            $path = Join-Path $script:RepoRoot $d
            if (-not (Test-Path $path)) {
                $missing += "$d (file not found)"
                continue
            }
            $content = Get-Content $path -Raw
            if ($content -notmatch '(?i)Security Reader') {
                $missing += "$d (no 'Security Reader' mention)"
            }
            # Defender XDR Analyst — accept either the canonical name OR the
            # "Microsoft Defender Analyst" alias used in some Microsoft docs.
            if ($content -notmatch '(?i)(Defender XDR Analyst|Microsoft Defender Analyst)') {
                $missing += "$d (no 'Defender XDR Analyst' mention)"
            }
        }
        $missing | Should -BeNullOrEmpty -Because ('every key doc must name the canonical SA-role pair. Missing: ' + ($missing -join '; '))
    }

    It 'PERMISSIONS.md contains the over-privileged warning + per-endpoint detail' {
        $path = Join-Path $script:RepoRoot 'docs/PERMISSIONS.md'
        $content = Get-Content $path -Raw

        $content | Should -Match '(?i)least-privilege' -Because 'PERMISSIONS.md must explicitly call out the least-privilege model'
        $content | Should -Match '(?i)downgrade to' -Because 'PERMISSIONS.md must instruct operators to downgrade if they have over-privileged'
        $content | Should -Match '(?i)`Security Administrator`' -Because 'must explicitly name the wrong role as a counter-example'
        # Per-endpoint detail (iter-13.8: previously role-gated streams now in tenant-gated table with feature names)
        $content | Should -Match '(?i)MDE_CustomCollection_CL.*(MDE Custom Collection|Custom Collection feature|Custom Collection model)' -Because 'iter-13.8: CustomCollection should appear in tenant-gated table with the feature name'
        $content | Should -Match '(?i)MDE_CloudAppsConfig_CL.*(MCAS|Defender for Cloud Apps)' -Because 'iter-13.8: CloudAppsConfig should appear in tenant-gated table with the feature name'
        # Tenant feature detail
        $content | Should -Match '(?i)MDE_DCCoverage_CL.*(MDI|Defender for Identity)' -Because 'tenant-gated stream detail must name the underlying feature'
    }

    It 'iter-13.8 manifest has zero role-gated streams (category retired)' {
        $manifestPath = Join-Path $script:RepoRoot 'src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        # Strict-mode-safe: enumerate first, THEN .Count. The .Stream chain
        # produces $null when zero matches, and $null.Count crashes under strict.
        $roleGated = @($manifest.Endpoints | Where-Object { $_.Availability -eq 'role-gated' })
        @($roleGated).Count | Should -Be 0 -Because 'iter-13.8: Microsoft Learn confirms Security Admin auto-grants Full Access in MCAS + MDE settings, so 403 cannot be role-blocking. All previously role-gated streams have been re-categorised to tenant-gated.'
    }

    It 'manifest tenant-gated streams match the PERMISSIONS.md tenant-feature detail table' {
        $manifestPath = Join-Path $script:RepoRoot 'src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1'
        $permPath     = Join-Path $script:RepoRoot 'docs/PERMISSIONS.md'

        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $permContent = Get-Content $permPath -Raw

        $tenantGatedStreams = @($manifest.Endpoints | Where-Object { $_.Availability -eq 'tenant-gated' }).Stream
        $missing = @()
        foreach ($s in $tenantGatedStreams) {
            if ($permContent -notmatch [regex]::Escape($s)) {
                $missing += $s
            }
        }
        $missing | Should -BeNullOrEmpty -Because ('every tenant-gated stream must be named in PERMISSIONS.md so operators know which feature unlocks it. Missing: ' + ($missing -join ', '))
    }
}
