#Requires -Modules Pester

<#
.SYNOPSIS
    iter-14.0 Phase 1 architectural test gate: enforces the L1/L2 boundary
    between Xdr.Common.Auth (portal-generic Entra layer) and the L2 portal
    modules (Xdr.Defender.Auth today; Xdr.Purview.Auth / Xdr.Intune.Auth /
    Xdr.Entra.Auth in v0.2.0).

.DESCRIPTION
    Xdr.Common.Auth MUST NOT contain Defender-specific strings. If a future
    refactor accidentally re-introduces a portal-specific cookie name,
    hostname, OIDC callback path, or apiproxy route into the L1 module, this
    gate fires immediately so the boundary stays clean.

    Allowed exceptions in Xdr.Common.Auth:
      * Get-XdrAuthFromKeyVault.ps1 mentions sccauth/xsrf cookie names AS DOCUMENTATION
        for the DirectCookies branch (which is the legacy v0.1.0 Defender-only
        method — explicitly called out in the function's .NOTES). This is
        the single tolerated cross-layer leak; v0.2.0 will move DirectCookies
        out to Xdr.Defender.Auth's own KV loader.
      * The 'login.microsoft.com' / 'login.microsoftonline.com' Entra hosts
        are L1-by-design — that's where Entra LIVES and is portal-agnostic.

    The gate scans every .ps1 file in src/Modules/Xdr.Common.Auth/{Public,Private}
    for the forbidden tokens and fails on any match outside the allowed
    exception files.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:CommonAuthRoot = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth'

    # Files inside Xdr.Common.Auth where DOCUMENTED references to Defender
    # strings are tolerated. Each entry is the file's basename (no path).
    # Anything matching a forbidden token in these files is reviewed manually
    # in PR; the test will skip these. Keep this list as small as possible —
    # ideally empty after v0.2.0.
    $script:AllowedExceptionFiles = @(
        # Get-XdrAuthFromKeyVault.ps1 documents the legacy mde-portal/sccauth/xsrf
        # secret names because v0.1.0 deployments used a single KV-loader. The
        # function still works for the Defender DirectCookies branch — explicitly
        # called out in its comment header. v0.2.0 will split per-portal loaders.
        'Get-XdrAuthFromKeyVault.ps1'
    )

    # Forbidden tokens — if ANY of these appear in Xdr.Common.Auth source
    # files (outside the exception list), the boundary is violated.
    # Note: tokens are case-sensitive matches via Select-String defaults.
    $script:ForbiddenTokens = @(
        # Defender-specific cookie + header names
        'sccauth'                  # Defender session cookie name
        'X-XSRF-TOKEN'             # Defender CSRF header name (case-sensitive)
        # Portal hostnames (these are L2 concerns)
        'security.microsoft.com'   # Defender XDR portal
        'compliance.microsoft.com' # Purview portal (future L2)
        'intune.microsoft.com'     # Intune portal (future L2)
        # OIDC callback paths
        'signin-oidc'              # Defender's OIDC callback path
        # Defender apiproxy routes
        'apiproxy/mtp'
        'sccManagement'
    )
}

Describe 'Xdr.Common.Auth L1/L2 boundary — no Defender-specific strings (iter-14.0 gate)' {
    BeforeAll {
        $script:CommonFiles = @()
        foreach ($sub in @('Public', 'Private')) {
            $dir = Join-Path $script:CommonAuthRoot $sub
            if (Test-Path -LiteralPath $dir) {
                $script:CommonFiles += @(Get-ChildItem -LiteralPath $dir -Filter *.ps1 -File)
            }
        }
        # Also include the .psm1
        $psm1 = Join-Path $script:CommonAuthRoot 'Xdr.Common.Auth.psm1'
        if (Test-Path -LiteralPath $psm1) {
            $script:CommonFiles += @(Get-Item -LiteralPath $psm1)
        }
    }

    It 'has Xdr.Common.Auth files to scan (sanity)' {
        @($script:CommonFiles).Count | Should -BeGreaterThan 0 -Because 'the L1 module must exist with at least its .psm1'
    }

    It 'no Xdr.Common.Auth file (outside the exception list) contains a forbidden Defender-specific token in CODE' {
        # The gate scans CODE (not comments). Doc-strings and comment-block
        # references are tolerated because they explain the boundary itself
        # (e.g., the .psm1 banner enumerating what L1 MUST NOT contain;
        # Get-EntraEstsAuth's .PARAMETER ClientId examples).
        #
        # We strip:
        #   - Lines whose first non-whitespace char is '#'  (single-line comments)
        #   - Inline trailing '# ...' comments on each line
        #   - Comment-help blocks delimited by '<#' ... '#>'
        $violations = @()
        foreach ($file in $script:CommonFiles) {
            if ($script:AllowedExceptionFiles -contains $file.Name) { continue }
            $rawContent = Get-Content -LiteralPath $file.FullName -Raw
            if ($null -eq $rawContent) { continue }

            # Strip <# ... #> block comments (non-greedy multiline).
            $stripped = [regex]::Replace($rawContent, '<#[\s\S]*?#>', '', [System.Text.RegularExpressions.RegexOptions]::None)

            # Walk line-by-line, removing single-line + inline trailing # comments.
            # A '#' inside a quoted string is NOT a comment — for our token
            # heuristic we accept the simplification of stripping anything that
            # *looks* like a trailing comment. Any forbidden token genuinely
            # in a string literal will still be caught.
            $codeLines = New-Object 'System.Collections.Generic.List[string]'
            $lineIdx = 0
            $rawLines = $stripped -split "`r?`n"
            foreach ($line in $rawLines) {
                $lineIdx++
                # Whole-line comment (whitespace then #).
                if ($line -match '^\s*#') {
                    $codeLines.Add('') | Out-Null
                    continue
                }
                # Trailing inline comment — strip from a '#' that is preceded by
                # whitespace (avoiding stripping inside strings is hard with regex
                # and not worth the complexity here; if a string contains a token
                # followed by ' # comment-text' the strip is harmless).
                $stripIdx = -1
                $inSingle = $false
                $inDouble = $false
                for ($i = 0; $i -lt $line.Length; $i++) {
                    $ch = $line[$i]
                    if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle; continue }
                    if ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble; continue }
                    if ($ch -eq '#' -and -not $inSingle -and -not $inDouble) {
                        # Require '#' preceded by whitespace OR at start (already handled).
                        if ($i -gt 0 -and ($line[$i-1] -match '\s')) { $stripIdx = $i; break }
                    }
                }
                if ($stripIdx -ge 0) {
                    $codeLines.Add($line.Substring(0, $stripIdx)) | Out-Null
                } else {
                    $codeLines.Add($line) | Out-Null
                }
            }

            # Now scan the code-only view, using line numbers from the original file
            # via $codeLines index (1-based).
            for ($i = 0; $i -lt $codeLines.Count; $i++) {
                $line = $codeLines[$i]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                foreach ($token in $script:ForbiddenTokens) {
                    if ($line -ccontains $token) { continue }  # never true — kept for clarity
                    if ($line.Contains($token)) {
                        # Case-sensitive verification.
                        if ($line -cmatch [regex]::Escape($token)) {
                            $violations += "$($file.Name):$($i+1) found forbidden token '$token' in CODE: $($line.Trim())"
                        }
                    }
                }
            }
        }
        if ($violations.Count -gt 0) {
            $msg = "L1/L2 boundary violations:`n  - " + ($violations -join "`n  - ")
            $msg | Out-Host
        }
        $violations.Count | Should -Be 0 -Because (
            "Xdr.Common.Auth is the L1 portal-generic Entra layer. Defender-specific " +
            "strings (sccauth, X-XSRF-TOKEN, security.microsoft.com, signin-oidc, " +
            "apiproxy/mtp, sccManagement) in CODE belong in Xdr.Defender.Auth (L2). " +
            "Doc-comments referencing these strings to explain the boundary are tolerated. " +
            "If a code violation is intentional and time-limited, add the file to " +
            "tests/unit/AuthLayerBoundaries.Tests.ps1 \$AllowedExceptionFiles."
        )
    }

    It 'each AllowedExceptionFiles entry actually exists in Xdr.Common.Auth' {
        # Stop the exception list from drifting (e.g., a file rename removes
        # the file but we still carry the stale exception entry).
        foreach ($name in $script:AllowedExceptionFiles) {
            $matchingFile = $script:CommonFiles | Where-Object Name -eq $name
            $matchingFile | Should -Not -BeNullOrEmpty -Because (
                "AllowedExceptionFiles entry '$name' must correspond to a real " +
                "file under src/Modules/Xdr.Common.Auth/{Public,Private} — if " +
                "the file moved, update this list or remove the entry."
            )
        }
    }
}

Describe 'Xdr.Common.Auth manifest does not advertise Defender-specific tags' {
    It 'manifest tags do not include Defender, MDE, or Sentinel (L2 concerns only)' {
        $manifestPath = Join-Path $script:CommonAuthRoot 'Xdr.Common.Auth.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $tags = $manifest.PrivateData.PSData.Tags
        # L1 Entra layer tags should reflect 'Entra', 'TOTP', 'Passkey' etc, not Defender.
        $tags | Should -Not -Contain 'Defender'
        $tags | Should -Not -Contain 'MDE'
        $tags | Should -Not -Contain 'Sentinel'
        $tags | Should -Contain 'Entra' -Because 'L1 module is the Entra layer; tag must reflect that'
    }
}

Describe 'Xdr.Defender.Auth is the home for Defender-specific concerns' {
    It "Defender's psm1 explicitly references the Defender public client + portal host (proves L2 ownership)" {
        $defenderPsm1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psm1'
        $content = Get-Content -LiteralPath $defenderPsm1 -Raw
        $content | Should -Match '80ccca67-54bd-44ab-8625-4b79c4dc7775' -Because 'Defender public-client ID is L2'
        $content | Should -Match 'security.microsoft.com' -Because 'Defender portal hostname is L2'
    }

    It "Defender's manifest tags include Defender / MDE (L2 portal-specific)" {
        $manifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $tags = $manifest.PrivateData.PSData.Tags
        $tags | Should -Contain 'Defender'
        $tags | Should -Contain 'MDE'
    }
}
