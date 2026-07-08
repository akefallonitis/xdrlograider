# XdrLogRaider · Xdr.Defender.Auth · Defender XDR portal auth (ACTIVE for v0.1.0).
#
# ADOPTS the proven, real-tenant-verified cookie-OIDC chain from the prior repos
# (xdrlograider-prod/-final · ChainSuccess against the operator lab tenant service account · sccauth len 2923),
# ADAPTED to this repo's idiom (single per-portal .psm1 · Connect-XdrPortal dispatch · hashtable
# session · Track-XdrEvent telemetry · all-REST/MSI · no Az modules). NOT a copy of the prior file
# structure — re-homed flow logic.
#
# Flow (the proven sequence):
#   1. Portal-home entry: GET https://security.microsoft.com/ and FOLLOW redirects to the converged
#      login page. The portal drives its OWN OAuth with its registered redirect_uri — this is the fix
#      for AADSTS50011 (the prior hand-built /authorize?redirect_uri=https://security.microsoft.com
#      used a reply URL not registered on the public client).
#   2. Parse $Config (canary/sFT/sCtx/urlPost/pgid + RawConfig for arrUserProofs enrollment guard).
#   3. CredentialPost: POST urlPost with LoginOptions=3 (KMSI request → ESTSAUTHPERSISTENT 90d).
#   4. SAS-TOTP MFA: BeginAuth(Method='BeginAuth') → EndAuth(Method='EndAuth' + AdditionalAuthData=TOTP,
#      ctx from BeginAuth response, retry on totp-duplicate) → ProcessAuth(type=22 · form-urlencoded).
#      CRITICAL: SAS `Method` is the STAGE NAME literal · NOT the AuthMethodId (=PhoneAppOTP) · else
#      AADSTS500121. (proven Complete-TotpMfa)
#   5. Interrupt walker: KMSI(LoginOptions=1,type=28,i19=4130) / CMSI / ConvergedProofUpRedirect, ≤10 hops.
#   6. form_post submit: parse the terminal <form action=...> + hidden inputs, POST to the portal OIDC
#      callback → the portal mints sccauth + XSRF-TOKEN. (This step was MISSING in the prior rewrite →
#      "sccauth not issued".)
#   7. sccauth + XSRF capture (XSRF URL-decoded for the header) + Decision-16 TenantId resolution.
#   8. DYNAMIC session expiry from the real Set-Cookie Expires (sccauth ~hours · ESTSAUTHPERSISTENT 90d) —
#      NOT a hardcoded TTL. Portal-agnostic so it serves all portals.
#
# Transport: Invoke-WebRequest + WebRequestSession (built-in cmdlet · follows redirects + accumulates
# the cookie jar natively · NOT an Az module). StrictMode -Version Latest throughout (indexer/Properties
# guards · the proven design's StrictMode-safe patterns).

Set-StrictMode -Version Latest

$script:DefenderClientId   = '80ccca67-54bd-44ab-8625-4b79c4dc7775'   # Microsoft public client (proven)
$script:DefenderPortalHost = 'security.microsoft.com'

# Register with Xdr.Common.Auth at module load (Connect-XdrPortal dispatches here).
Register-XdrPortalHandler -Portal 'Defender' -Handler {
    param([hashtable]$Credentials)
    Connect-DefenderPortal -Credentials $Credentials
}

# ─── Lean forensic HTTP wrapper (Invoke-WebRequest · Gate-L body guard · classification-light) ──
function script:Invoke-XdrAuthHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Stage,
        [Parameter(Mandatory)][string] $Uri,
        [string] $Method = 'GET',
        $Body = $null,
        [string] $ContentType,
        [Microsoft.PowerShell.Commands.WebRequestSession] $WebSession,
        [hashtable] $Headers = @{},
        [int] $TimeoutSec = 60,
        [int] $MaxRedirection = 10,
        [bool] $ExpectJson = $true
    )
    # Gate L: `[string] -is [pscustomobject]` is TRUE (PSObject wraps everything) → guard `-isnot [string]`
    # FIRST so pre-encoded strings aren't double-encoded (AADSTS50080). Honor caller ContentType: JSON
    # objects → ConvertTo-Json; form-urlencoded objects → key=value& pairs.
    $bodyToSend = $null
    $resolvedCt = $ContentType
    if ($null -ne $Body) {
        if ($Body -isnot [string] -and ($Body -is [hashtable] -or $Body -is [System.Collections.IDictionary])) {
            if ($resolvedCt -and $resolvedCt -match 'x-www-form-urlencoded') {
                $pairs = @(); foreach ($k in $Body.Keys) { $pairs += "$([uri]::EscapeDataString([string]$k))=$([uri]::EscapeDataString([string]$Body[$k]))" }
                $bodyToSend = $pairs -join '&'
            } else {
                $bodyToSend = ($Body | ConvertTo-Json -Depth 10 -Compress)
                if (-not $resolvedCt) { $resolvedCt = 'application/json' }
            }
        } else {
            $bodyToSend = [string]$Body
        }
    }
    $params = @{
        Uri = $Uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = $TimeoutSec
        MaximumRedirection = $MaxRedirection; SkipHttpErrorCheck = $true; ErrorAction = 'Stop'
        SslProtocol = 'Tls12, Tls13'   # TLS-1.2+ pinned code-side (§3 · disallow TLS 1.0/1.1 on the ESTS auth chain)
    }
    if ($WebSession) { $params.WebSession = $WebSession }
    if ($Headers.Count -gt 0) { $params.Headers = $Headers }
    if ($null -ne $bodyToSend) { $params.Body = $bodyToSend; if ($resolvedCt) { $params.ContentType = $resolvedCt } }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null; $err = $null
    try { $resp = Invoke-WebRequest @params } catch { $err = $_ }
    $sw.Stop()

    $status = 0; $rawBody = ''
    if ($resp) {
        try { $status = [int]$resp.StatusCode } catch { $status = 0 }
        try { $rawBody = [string]$resp.Content } catch { $rawBody = '' }
    } elseif ($err) {
        throw "Invoke-XdrAuthHttp[$Stage]: transport error · $($err.Exception.Message)"
    }
    $parsed = $null
    if ($ExpectJson -and $status -ge 200 -and $status -lt 300 -and $rawBody) {
        try { $parsed = $rawBody | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    }
    [pscustomobject]@{
        Stage = $Stage; Status = $status; ResponseBody = $rawBody
        BodyPreview = if ($rawBody.Length -gt 0) { $rawBody.Substring(0, [Math]::Min(400, $rawBody.Length)) } else { '' }
        ParsedJson = $parsed; DurationMs = [int]$sw.ElapsedMilliseconds; Session = $WebSession
    }
}

# ─── $Config parse (proven Get-EntraFields · RawConfig + relative-URL resolve) ──
function script:Get-XdrEntraFields {
    [CmdletBinding()] param([Parameter(Mandatory)][AllowEmptyString()][string] $Html)
    $empty = [pscustomobject]@{ Canary=''; FlowToken=''; Context=''; UrlPost=''; Pgid='';
        UrlBeginAuth=''; UrlEndAuth=''; UrlProcessAuth=''; HpgRequestId=''; ErrorCode=''; ErrorText=''; RawConfig=$null }
    if ([string]::IsNullOrWhiteSpace($Html)) { return $empty }
    $config = $null
    foreach ($pat in @('\$Config\s*=\s*(\{[\s\S]*?\})\s*;', '\bConfig\s*=\s*(\{[\s\S]*?\})\s*;')) {
        $m = [regex]::Match($Html, $pat)
        if ($m.Success) {
            try { $config = $m.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop; break } catch { continue }
        }
    }
    if ($null -eq $config) { return $empty }
    $gp = { param($o,$n) if ($o -and $o.PSObject.Properties[$n]) { [string]$o.$n } else { '' } }
    $ru = {
        param($u)
        if ([string]::IsNullOrWhiteSpace($u)) { return '' }
        $t = $u.Trim()
        if ($t.StartsWith('http://') -or $t.StartsWith('https://')) { return $t }
        if ($t.StartsWith('//')) { return "https:$t" }
        if ($t.StartsWith('/'))  { return "https://login.microsoftonline.com$t" }
        return "https://login.microsoftonline.com/$t"
    }
    [pscustomobject]@{
        Canary         = (& $gp $config 'canary')
        FlowToken      = (& $gp $config 'sFT')
        Context        = (& $gp $config 'sCtx')
        UrlPost        = (& $ru (& $gp $config 'urlPost'))
        Pgid           = (& $gp $config 'pgid')
        UrlBeginAuth   = (& $ru (& $gp $config 'urlBeginAuth'))
        UrlEndAuth     = (& $ru (& $gp $config 'urlEndAuth'))
        UrlProcessAuth = (& $ru (& $gp $config 'urlPost'))
        HpgRequestId   = (& $gp $config 'sessionId')
        ErrorCode      = (& $gp $config 'sErrorCode')
        ErrorText      = (& $gp $config 'sErrTxt')
        RawConfig      = $config
    }
}

function script:Get-XdrTotpCode {
    # RFC 6238 (HMAC-SHA1 · 30s step · 6-digit). Verified vs RFC 6238 Appendix B (kept from prior clean impl).
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory)][string] $Base32Seed, [int64] $UnixTimeSecondsOverride = -1)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $normalized = $Base32Seed.ToUpperInvariant().TrimEnd('=').Replace(' ', '')
    $bits = [System.Text.StringBuilder]::new()
    foreach ($c in $normalized.ToCharArray()) {
        $idx = $alphabet.IndexOf($c)
        if ($idx -lt 0) { throw "Invalid base32 character: $c" }
        $null = $bits.Append([Convert]::ToString($idx, 2).PadLeft(5, '0'))
    }
    $bitStr = $bits.ToString()
    $byteList = [System.Collections.Generic.List[byte]]::new()
    for ($i = 0; $i + 8 -le $bitStr.Length; $i += 8) { $byteList.Add([byte][Convert]::ToInt32($bitStr.Substring($i, 8), 2)) }
    $key = $byteList.ToArray()
    $t = if ($UnixTimeSecondsOverride -lt 0) { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } else { $UnixTimeSecondsOverride }
    $counter = [BitConverter]::GetBytes([int64]([math]::Floor($t / 30.0)))
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($counter) }
    $hmac = [System.Security.Cryptography.HMACSHA1]::new($key)
    try { $hash = $hmac.ComputeHash($counter) } finally { $hmac.Dispose() }
    $offset = $hash[$hash.Length - 1] -band 0x0F
    $bin = (([int]$hash[$offset] -band 0x7F) -shl 24) -bor (([int]$hash[$offset + 1] -band 0xFF) -shl 16) -bor `
           (([int]$hash[$offset + 2] -band 0xFF) -shl 8) -bor ([int]$hash[$offset + 3] -band 0xFF)
    return ($bin % 1000000).ToString('D6')
}

function script:Test-XdrMfaSuccess {
    [CmdletBinding()][OutputType([bool])] param([Parameter(Mandatory)][AllowNull()] $EndAuth)
    if ($null -eq $EndAuth -or -not $EndAuth.PSObject) { return $false }
    $props = @($EndAuth.PSObject.Properties.Name)
    if ($props -contains 'Success' -and $EndAuth.Success -eq $true) { return $true }
    if ($props -contains 'ResultValue' -and ([string]$EndAuth.ResultValue) -in @('AuthenticationSucceeded','Success')) { return $true }
    return $false
}

# ─── CredentialPost (LoginOptions=3 KMSI request) ──
function script:Complete-XdrCredentialsFlow {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string] $Upn,
        [Parameter(Mandatory)][string] $Password,
        [Parameter(Mandatory)][pscustomobject] $InitialFields,
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession
    )
    if ([string]::IsNullOrWhiteSpace($InitialFields.UrlPost)) { throw "CredentialsFlow: InitialFields.UrlPost empty" }
    $form = @{
        login = $Upn; loginfmt = $Upn; passwd = $Password; type = '11'; ps = '2'
        LoginOptions = '3'; flowToken = $InitialFields.FlowToken; ctx = $InitialFields.Context
        canary = $InitialFields.Canary; hpgrequestid = $InitialFields.HpgRequestId
    }
    $body = ($form.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
    Invoke-XdrAuthHttp -Stage 'CredentialPost' -Uri $InitialFields.UrlPost -Method POST -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -WebSession $WebSession -MaxRedirection 5 -ExpectJson $false
}

# ─── SAS-TOTP MFA (BeginAuth → EndAuth → ProcessAuth · Method=STAGE-NAME) ──
function script:Complete-XdrTotpMfa {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string] $TotpBase32,
        [Parameter(Mandatory)][pscustomobject] $TfaFields,
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession
    )
    $beginUri = if ($TfaFields.UrlBeginAuth) { $TfaFields.UrlBeginAuth } else { 'https://login.microsoftonline.com/common/SAS/BeginAuth' }
    $beginResp = Invoke-XdrAuthHttp -Stage 'BeginAuth' -Uri $beginUri -Method POST -WebSession $WebSession `
        -ContentType 'application/json' -ExpectJson $true -Body @{ AuthMethodId='PhoneAppOTP'; Method='BeginAuth'; ctx=$TfaFields.Context; flowToken=$TfaFields.FlowToken }
    $bj = $beginResp.ParsedJson
    $bjOk = ($null -ne $bj) -and (@($bj.PSObject.Properties.Name) -contains 'Success') -and ([bool]$bj.Success)
    if (-not $bjOk) { throw "BeginAuth failed · status=$($beginResp.Status) · body=$($beginResp.BodyPreview)" }
    $bp = @($bj.PSObject.Properties.Name)
    $sessionId    = if ($bp -contains 'SessionId') { [string]$bj.SessionId } else { '' }
    $newFlowToken = if ($bp -contains 'FlowToken') { [string]$bj.FlowToken } else { $TfaFields.FlowToken }
    $ctxFromBegin = if ($bp -contains 'Ctx')       { [string]$bj.Ctx }       else { $TfaFields.Context }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw "BeginAuth response missing SessionId" }

    $endUri = if ($TfaFields.UrlEndAuth) { $TfaFields.UrlEndAuth } else { 'https://login.microsoftonline.com/common/SAS/EndAuth' }
    $endJson = $null; $attempt = 0; $maxAttempts = 3; $lastEnd = $null
    while ($attempt -lt $maxAttempts) {
        $attempt++
        if ($attempt -gt 1) {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $wait = [math]::Max(1, ([math]::Floor($now/30)*30 + 31) - $now)
            Start-Sleep -Seconds $wait
        }
        $totp = Get-XdrTotpCode -Base32Seed $TotpBase32
        $lastEnd = Invoke-XdrAuthHttp -Stage 'EndAuth' -Uri $endUri -Method POST -WebSession $WebSession `
            -ContentType 'application/json' -ExpectJson $true `
            -Body @{ AuthMethodId='PhoneAppOTP'; Method='EndAuth'; SessionId=$sessionId; FlowToken=$newFlowToken; Ctx=$ctxFromBegin; AdditionalAuthData=$totp; PollCount=$attempt }
        $endJson = $lastEnd.ParsedJson
        if (Test-XdrMfaSuccess -EndAuth $endJson) { break }
        # retry only when the rejection looks like a duplicate-code-in-same-window
        $rv = if ($endJson -and (@($endJson.PSObject.Properties.Name) -contains 'ResultValue')) { [string]$endJson.ResultValue } else { '' }
        if ($rv -match 'Duplicate' -and $attempt -lt $maxAttempts) { continue }
        if (-not (Test-XdrMfaSuccess -EndAuth $endJson)) { throw "EndAuth attempt $attempt failed · status=$($lastEnd.Status) · ResultValue=$rv · body=$($lastEnd.BodyPreview)" }
    }
    if (-not (Test-XdrMfaSuccess -EndAuth $endJson)) { throw "EndAuth exhausted $maxAttempts attempts" }

    $ep = @($endJson.PSObject.Properties.Name)
    $finalFlow = if ($ep -contains 'FlowToken') { [string]$endJson.FlowToken } else { $newFlowToken }
    $finalCtx  = if ($ep -contains 'Ctx')       { [string]$endJson.Ctx }       else { $ctxFromBegin }
    $procUri = if ($TfaFields.UrlProcessAuth) { $TfaFields.UrlProcessAuth } else { 'https://login.microsoftonline.com/common/SAS/ProcessAuth' }
    $procFields = @{ type='22'; FlowToken=$finalFlow; request=$finalCtx; ctx=$finalCtx }
    $procBody = ($procFields.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
    Invoke-XdrAuthHttp -Stage 'ProcessAuth' -Uri $procUri -Method POST -Body $procBody `
        -ContentType 'application/x-www-form-urlencoded' -WebSession $WebSession -MaxRedirection 5 -ExpectJson $false
}

# ─── Interrupt walker (KMSI/CMSI/ProofUp · ≤10 hops) ──
function script:Resolve-XdrInterruptPage {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $InitialHtml,
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession,
        [int] $MaxHops = 10
    )
    $currentHtml = $InitialHtml; $hops = 0; $kmsiAccepted = $false; $finalPgid = ''
    while ($hops -lt $MaxHops) {
        $f = Get-XdrEntraFields -Html $currentHtml
        $pgid = $f.Pgid
        if ([string]::IsNullOrWhiteSpace($pgid)) { $finalPgid = '(none)'; break }
        if ($pgid -notin @('ConvergedProofUpRedirect','CmsiInterrupt','KmsiInterrupt')) { $finalPgid = $pgid; break }
        $hops++
        $stage = $null; $uri = $null; $body = @{}
        switch ($pgid) {
            'ConvergedProofUpRedirect' { $stage='ProcessAuth'; $uri = if ($f.UrlProcessAuth) { $f.UrlProcessAuth } else { 'https://login.microsoftonline.com/common/SAS/ProcessAuth' }; $body = @{ type=22; request=$f.Context; flowToken=$f.FlowToken; canary=$f.Canary } }
            'CmsiInterrupt'            { $stage='CmsiInterrupt'; $uri='https://login.microsoftonline.com/appverify'; $body = @{ ContinueAuth='true'; ctx=$f.Context; flowToken=$f.FlowToken; canary=$f.Canary } }
            'KmsiInterrupt'            { $stage='KmsiInterrupt'; $uri = if ($f.UrlPost) { $f.UrlPost } else { 'https://login.microsoftonline.com/kmsi' }; $body = @{ LoginOptions=1; type=28; i19=4130; flowToken=$f.FlowToken; ctx=$f.Context; canary=$f.Canary }; $kmsiAccepted = $true }
        }
        $resp = Invoke-XdrAuthHttp -Stage $stage -Uri $uri -Method POST -Body $body `
            -ContentType 'application/x-www-form-urlencoded' -WebSession $WebSession -MaxRedirection 5 -ExpectJson $false
        $currentHtml = $resp.ResponseBody
    }
    if ($hops -ge $MaxHops) { throw "Resolve-XdrInterruptPage exceeded MaxHops=$MaxHops · last pgid='$finalPgid'" }
    [pscustomobject]@{ FinalHtml = $currentHtml; FinalPgid = $finalPgid; HopsWalked = $hops; KmsiAccepted = $kmsiAccepted }
}

# ─── ESTS pick + TenantId candidates (Decision-16 sources #2) ──
function script:Get-XdrAuthArtifacts {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession,
        [Parameter(Mandatory)][AllowEmptyString()][string] $FinalHtml,
        [bool] $KmsiAccepted = $false
    )
    $loginUris = @('https://login.microsoftonline.com','https://login.microsoft.com')
    $tenantCandidates = @()
    foreach ($u in $loginUris) {
        try {
            foreach ($c in $WebSession.Cookies.GetCookies([uri]$u)) {
                if ($c.Name -eq 'ESTSAUTHPERSISTENT' -and $c.Value) {
                    $parts = $c.Value.Split('.')
                    if ($parts.Count -ge 2) {
                        $p = $parts[1]; $rem = $p.Length % 4; if ($rem -gt 0) { $p += ('=' * (4 - $rem)) }
                        $p = $p.Replace('-','+').Replace('_','/')
                        try {
                            $payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json -ErrorAction Stop
                            if ($payload.PSObject.Properties['tid'])       { $tenantCandidates += [string]$payload.tid }
                            elseif ($payload.PSObject.Properties['tenant_id']) { $tenantCandidates += [string]$payload.tenant_id }
                        } catch { }
                    }
                }
            }
        } catch { }
    }
    if ($FinalHtml -match 'action="[^"]*[?&]tid=([0-9a-fA-F-]{36})')      { $tenantCandidates += $Matches[1] }
    if ($FinalHtml -match 'action="[^"]*[?&]tenantId=([0-9a-fA-F-]{36})') { $tenantCandidates += $Matches[1] }
    [pscustomobject]@{ TenantIdCandidates = @($tenantCandidates | Select-Object -Unique); KmsiAccepted = $KmsiAccepted; FinalHtml = $FinalHtml }
}

# ─── Extract the ESTSAUTHPERSISTENT (KMSI 90d) cookie value · drives the T2 silent-refresh path (F2 · §31.4) ──
function Get-XdrKmsiCookieValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession)
    foreach ($u in @('https://login.microsoftonline.com', 'https://login.microsoft.com')) {
        try {
            foreach ($c in $WebSession.Cookies.GetCookies([uri]$u)) {
                if ($c.Name -eq 'ESTSAUTHPERSISTENT' -and $c.Value) { return [string]$c.Value }
            }
        } catch { }  # INTENTIONAL-FAIL-SAFE: cookie-store read error → return '' → next reauth uses T3 (no crash)
    }
    return ''
}

# ─── form_post submit → mints sccauth (THE step missing in the prior rewrite) ──
function script:Submit-XdrAuthFormPost {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $FormPostHtml,
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession,
        [string] $ExpectedActionHostname
    )
    if ([string]::IsNullOrWhiteSpace($FormPostHtml)) { throw "Submit-XdrAuthFormPost: FormPostHtml empty" }
    $am = [regex]::Match($FormPostHtml, '<form[^>]*?action="(?<action>[^"]+)"[^>]*?>', 'IgnoreCase')
    if (-not $am.Success) { $am = [regex]::Match($FormPostHtml, '<form[^>]*?action=(?<action>[^\s>]+)', 'IgnoreCase') }
    if (-not $am.Success) {
        # No terminal <form action=..> here means we did NOT reach the portal-OIDC callback. Before treating it
        # as a malformed page, check for the KNOWN auth-CHAIN interrupt signatures: a ProofUp/MFA re-enrollment
        # prompt, a KMSI/CMSI session-continuation interrupt the ≤10-hop walker didn't resolve, an explicit
        # SessionRevoked, or an AADSTS error code. These are AUTH-LOSS (a broken chain · the session/MFA state
        # the engine must re-mint), NOT a parse failure — so throw the TYPED AuthChainBrokenException with the
        # right portal + FailureStage so it routes into Invoke-XdrAuthenticated's reauth + the breaker
        # classification (a raw string throw would surface as an unclassified AppException and never self-heal).
        # Extending the interrupt WALKER (resolving these in-flight) needs live evidence → out of scope here;
        # this only re-CLASSIFIES the already-terminal failure. An UNRECOGNIZED page keeps the plain-string throw.
        # Use the New-XdrException FACTORY (not [AuthChainBrokenException]::new) — a PS class TYPE defined in
        # Xdr.Common.Exceptions is NOT visible by type-literal across the module boundary without `using module`
        # (same constraint Runtime.psm1:1743 notes), but the EXPORTED factory function resolves fine and builds
        # the identical typed exception the engine's name-walk handler keys on.
        $evidence = $FormPostHtml.Substring(0, [Math]::Min(256, $FormPostHtml.Length))
        # Portal label from the action-host hint (Defender's host or absent → 'Defender'; else the registered
        # sub-domain label e.g. 'Purview' from purview.microsoft.com) — keeps the exception portal-correct for
        # the shared Defender/Purview chain without re-Defender-izing this generic helper.
        $portalLabel = if ([string]::IsNullOrWhiteSpace($ExpectedActionHostname) -or $ExpectedActionHostname -eq $script:DefenderPortalHost) {
            'Defender'
        } else {
            $h = ($ExpectedActionHostname -split '\.')[0]
            if ($h) { (([string]$h).Substring(0,1).ToUpperInvariant() + ([string]$h).Substring(1)) } else { 'Defender' }
        }
        if ($FormPostHtml -match '(?i)(ProofUp|AADSTS)') {
            throw (New-XdrException -Type AuthChainBroken -Message "Submit-XdrAuthFormPost: auth-chain interrupt (MFA/ProofUp) · evidence=$evidence" -Properties @{ Portal = $portalLabel; FailureStage = 'MFA' })
        }
        if ($FormPostHtml -match '(?i)(KMSI|cmsi|SessionRevoked)') {
            throw (New-XdrException -Type AuthChainBroken -Message "Submit-XdrAuthFormPost: auth-chain interrupt (KMSI/session) · evidence=$evidence" -Properties @{ Portal = $portalLabel; FailureStage = 'Cookie' })
        }
        throw "Submit-XdrAuthFormPost: no <form action=..> · evidence=$evidence"
    }
    $actionUri = ($am.Groups['action'].Value.Trim('"').Trim("'")) -replace '&amp;','&'
    if ($ExpectedActionHostname) {
        try { if (([uri]$actionUri).Host -ne $ExpectedActionHostname) { throw "form action host '$(([uri]$actionUri).Host)' != expected '$ExpectedActionHostname'" } }
        catch { throw "Submit-XdrAuthFormPost: invalid action URI '$actionUri' · $($_.Exception.Message)" }
    }
    $im = [regex]::Matches($FormPostHtml, '<input[^>]*?type="hidden"[^>]*?name="(?<name>[^"]+)"[^>]*?value="(?<value>[^"]*)"', 'IgnoreCase')
    if ($im.Count -eq 0) { $im = [regex]::Matches($FormPostHtml, '<input[^>]*?name="(?<name>[^"]+)"[^>]*?value="(?<value>[^"]*)"', 'IgnoreCase') }
    if ($im.Count -eq 0) { throw "Submit-XdrAuthFormPost: no hidden inputs found" }
    $kvps = @(); foreach ($m in $im) { $kvps += "$([uri]::EscapeDataString($m.Groups['name'].Value))=$([uri]::EscapeDataString(($m.Groups['value'].Value -replace '&amp;','&')))" }
    Invoke-XdrAuthHttp -Stage 'FormPost' -Uri $actionUri -Method POST -Body ($kvps -join '&') `
        -ContentType 'application/x-www-form-urlencoded' -WebSession $WebSession -MaxRedirection 10 -ExpectJson $false
}

# ─── DYNAMIC cookie expiry (real Set-Cookie Expires · per-portal · NOT hardcoded) ──
function script:Get-XdrCookieExpiry {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession,
        [Parameter(Mandatory)][string] $PortalHost,
        # Configurable session-TTL floor (kills the hardcoded magic number). Drives the sccauth-ttl-cap that
        # forces a T2 KMSI silent re-mint before the portal expires the real (Expires-less) sccauth cookie.
        # Default 110 = unchanged behavior; raise via XDRLR_SESSION_TTL_MINUTES once sccauth's real lifetime is discovered.
        [int] $DefaultTtlMinutes = $(if ($env:XDRLR_SESSION_TTL_MINUTES -match '^\d+$') { [int]$env:XDRLR_SESSION_TTL_MINUTES } else { 110 }),
        [datetime] $AcquiredUtc = [datetime]::UtcNow
    )
    $uris = @("https://$PortalHost", 'https://login.microsoftonline.com', 'https://login.microsoft.com')
    $priority = @('ESTSAUTHPERSISTENT','sccauth','ESTSAUTH')
    $byName = @{}; $total = 0
    foreach ($u in $uris) {
        try { foreach ($c in $WebSession.Cookies.GetCookies([uri]$u)) { $total++; if ($priority -contains $c.Name -and -not $byName.ContainsKey($c.Name) -and -not [string]::IsNullOrWhiteSpace($c.Value)) { $byName[$c.Name] = $c } } } catch { }
    }
    $earliest = $null; $source = 'default-ttl'; $kmsiExp = $null
    foreach ($name in $priority) {
        if (-not $byName.ContainsKey($name)) { continue }
        $c = $byName[$name]
        if ($c.Expires -eq [datetime]::MinValue) { continue }
        $exp = if ($c.Expires.Kind -eq [System.DateTimeKind]::Utc) { $c.Expires } else { $c.Expires.ToUniversalTime() }
        if ($name -eq 'ESTSAUTHPERSISTENT') { $kmsiExp = $exp }
        if ($null -eq $earliest -or $exp -lt $earliest) { $earliest = $exp; $source = $name }
    }
    if ($null -eq $earliest) { $earliest = $AcquiredUtc.AddMinutes($DefaultTtlMinutes) }
    # NO static sccauth cap — TTL is genuinely dynamic per-cookie. Verified LIVE (2026-06-11): `sccauth` is an opaque,
    # non-JWT SESSION cookie with NO server-declared Expires (MinValue → skipped above), so its lifetime cannot be read
    # from anywhere; ESTSAUTHPERSISTENT's REAL ~90d KMSI expiry legitimately becomes ExpiresUtc. sccauth's shorter
    # server-side death is handled REACTIVELY (401/440 → AuthChainBroken → Invoke-XdrAuthenticated self-heals via a T2
    # KMSI SILENT re-mint · NO TOTP · then retries) — the correctness guarantee, not a magic-number floor. The reactive
    # self-heal PRESERVES KMSI (Runtime · L1-only invalidation) so the re-mint stays TOTP-free until KMSI itself expires
    # (~90d). This replaces the old static 110-min cap (which proactively re-minted to dodge a 440-storm that only existed
    # because the self-heal used to destroy KMSI → T3 burn · both root causes now fixed).
    [pscustomobject]@{ ExpiresUtc = $earliest; KmsiExpiresUtc = $kmsiExp; CookieCount = $total; EarliestExpirySource = $source }
}

# ─── sccauth + XSRF capture + Decision-16 TenantId ──
function script:Get-XdrDefenderSccauth {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession,
        [string] $PortalHost = 'security.microsoft.com',
        [string] $TenantId,
        [pscustomobject] $Artifacts
    )
    $cookies = $WebSession.Cookies.GetCookies("https://$PortalHost")
    $sccauth = $cookies | Where-Object Name -eq 'sccauth'    | Select-Object -First 1
    $xsrf    = $cookies | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
    if (-not $sccauth -or [string]::IsNullOrWhiteSpace($sccauth.Value)) {
        throw "Auth completed but sccauth not issued · portal cookies: $((@($cookies | ForEach-Object Name)) -join ', ') · (CA policy / bad creds / TOTP drift / locked)"
    }
    if (-not $xsrf -or [string]::IsNullOrWhiteSpace($xsrf.Value)) {
        try { $null = Invoke-XdrAuthHttp -Stage 'PortalSettle' -Uri "https://$PortalHost/" -Method GET -WebSession $WebSession -ExpectJson $false } catch { }
        $xsrf = $WebSession.Cookies.GetCookies("https://$PortalHost") | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
    }
    $xsrfVal = if ($xsrf -and -not [string]::IsNullOrWhiteSpace($xsrf.Value)) { [System.Net.WebUtility]::UrlDecode($xsrf.Value) } else { '' }
    # Decision-16 TenantId: operator/env → ESTS artifacts → 'organizations' fallback
    $tid = ''; $src = ''
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $tid = $TenantId; $src = 'operator-param' }
    elseif ($Artifacts -and $Artifacts.TenantIdCandidates -and @($Artifacts.TenantIdCandidates).Count -gt 0) { $tid = @($Artifacts.TenantIdCandidates)[0]; $src = 'ests-artifacts' }
    if (-not $tid -and $xsrfVal) {
        try {
            $tc = Invoke-XdrAuthHttp -Stage 'TenantContext' -Uri "https://$PortalHost/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true" `
                -Method GET -WebSession $WebSession -Headers @{ 'X-XSRF-TOKEN' = $xsrfVal } -ExpectJson $true
            $ctx = $tc.ParsedJson
            if ($ctx -and $ctx.PSObject.Properties['AuthInfo'] -and $ctx.AuthInfo.PSObject.Properties['TenantId']) { $tid = [string]$ctx.AuthInfo.TenantId; $src = 'tenant-context' }
        } catch { }
    }
    [pscustomobject]@{ Sccauth = $sccauth.Value; XsrfToken = $xsrfVal; TenantId = $tid; TenantIdSource = $src; AcquiredUtc = [datetime]::UtcNow }
}

# ─── Passkey (FIDO2) headless assertion · WebAuthn §7.2 ECDSA-P256 (Φ1 · §3 · ported from prior repos) ──
function script:New-XdrPasskeyAssertion {
    # Signs the Entra FIDO challenge with the SA's KV-stored P-256 private key (PEM). PURE crypto · no HTTP · fully
    # unit-testable. Returns the base64url assertion fields the type=23 credential POST carries. Build:
    #   clientDataJSON = {type:webauthn.get, challenge, origin, crossOrigin} · clientDataHash = SHA256(clientDataJSON)
    #   authenticatorData = SHA256(rpId)[32] || flags 0x05 (UP|UV) || signCount[4] · signed = authData || clientDataHash
    #   signature = ECDSA-P256-SHA256(signed) DER (RFC 3279) · Entra accepts DER.
    [CmdletBinding()][OutputType([pscustomobject])] param(
        [Parameter(Mandatory)][string] $Challenge,        # base64url (as Entra provides)
        [Parameter(Mandatory)][string] $PrivateKeyPem,    # ECDSA P-256 PEM
        [Parameter(Mandatory)][string] $CredentialId,
        [string] $RpId   = 'login.microsoft.com',
        [string] $Origin = 'https://login.microsoft.com'
    )
    if ([string]::IsNullOrWhiteSpace($PrivateKeyPem)) { throw "New-XdrPasskeyAssertion: PrivateKeyPem is empty — cannot sign the assertion" }
    if ([string]::IsNullOrWhiteSpace($CredentialId))  { throw "New-XdrPasskeyAssertion: CredentialId is empty" }
    if ([string]::IsNullOrWhiteSpace($Challenge))     { throw "New-XdrPasskeyAssertion: Challenge is empty" }
    $b64url = { param([byte[]] $b) if (-not $b -or $b.Length -eq 0) { return '' }; ([Convert]::ToBase64String($b)).Replace('+', '-').Replace('/', '_').TrimEnd('=') }
    $clientData      = [ordered]@{ type = 'webauthn.get'; challenge = $Challenge; origin = $Origin; crossOrigin = $false }
    $clientDataJson  = ($clientData | ConvertTo-Json -Compress)
    $clientDataBytes = [System.Text.Encoding]::UTF8.GetBytes($clientDataJson)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $clientDataHash = $sha.ComputeHash($clientDataBytes)
        $rpIdHash       = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RpId))
    } finally { $sha.Dispose() }
    $authData = [byte[]]::new(37)
    [Array]::Copy($rpIdHash, 0, $authData, 0, 32)
    $authData[32] = [byte]0x05                                   # UP (0x01) | UV (0x04)
    [Array]::Copy([byte[]]@(0, 0, 0, 1), 0, $authData, 33, 4)    # signCount
    $signed = [byte[]]::new(69)
    [Array]::Copy($authData, 0, $signed, 0, 37)
    [Array]::Copy($clientDataHash, 0, $signed, 37, 32)
    $ecdsa = [System.Security.Cryptography.ECDsa]::Create()
    try {
        $ecdsa.ImportFromPem($PrivateKeyPem)
        $sig = $ecdsa.SignData($signed, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
    } finally { $ecdsa.Dispose() }
    $idEnc = if ($CredentialId -match '^[A-Za-z0-9_\-]+={0,2}$') { $CredentialId.TrimEnd('=') } else { & $b64url ([System.Text.Encoding]::UTF8.GetBytes($CredentialId)) }
    [pscustomobject]@{
        Id                = $idEnc
        ClientDataJSON    = (& $b64url $clientDataBytes)
        AuthenticatorData = (& $b64url $authData)
        Signature         = (& $b64url $sig)
    }
}

function script:Complete-XdrPasskeyFlow {
    # FIDO2 passkey assertion flow (headless SA · Φ1). (1) GET /common/fido/get challenge · (2) sign via
    # New-XdrPasskeyAssertion · (3) POST type=23 with the assertion (LoginOptions=3 KMSI). Returns the login response
    # for the interrupt walker — same downstream as the TOTP flow. PasskeySecret = the KV 'PasskeyPem' secret: either
    # a raw ECDSA-P256 PEM (credentialId then from XDRLR_PASSKEY_CREDENTIAL_ID) OR a JSON {credentialId,privateKeyPem,rpId}.
    [CmdletBinding()][OutputType([pscustomobject])] param(
        [Parameter(Mandatory)][string] $PasskeySecret,
        [Parameter(Mandatory)][string] $Upn,
        [Parameter(Mandatory)][pscustomobject] $InitialFields,
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession] $WebSession
    )
    $credentialId = ''; $privateKeyPem = ''; $rpId = 'login.microsoft.com'
    if ($PasskeySecret.TrimStart().StartsWith('{')) {
        $pj = $PasskeySecret | ConvertFrom-Json
        $pjp = @($pj.PSObject.Properties.Name)
        if ($pjp -contains 'credentialId')  { $credentialId  = [string]$pj.credentialId }
        if ($pjp -contains 'privateKeyPem') { $privateKeyPem = [string]$pj.privateKeyPem }
        if (($pjp -contains 'rpId') -and $pj.rpId) { $rpId = [string]$pj.rpId }
    } else {
        $privateKeyPem = $PasskeySecret                                        # raw PEM
        if ($env:XDRLR_PASSKEY_CREDENTIAL_ID) { $credentialId = $env:XDRLR_PASSKEY_CREDENTIAL_ID }
    }
    if ([string]::IsNullOrWhiteSpace($privateKeyPem)) { throw "Complete-XdrPasskeyFlow: PasskeyPem secret has no private key (expected ECDSA-P256 PEM or JSON{privateKeyPem})" }
    if ([string]::IsNullOrWhiteSpace($credentialId))  { throw "Complete-XdrPasskeyFlow: no credentialId (expected in the PasskeyPem JSON or XDRLR_PASSKEY_CREDENTIAL_ID)" }

    $chResp = Invoke-XdrAuthHttp -Stage 'Authorize' -Uri 'https://login.microsoft.com/common/fido/get?uiflavor=Web' -Method GET -WebSession $WebSession -ExpectJson $true
    $chJson = $chResp.ParsedJson
    if (-not $chJson -or -not (@($chJson.PSObject.Properties.Name) -contains 'Challenge')) { throw "Complete-XdrPasskeyFlow: FIDO challenge GET returned no Challenge · status=$($chResp.Status) · body=$($chResp.BodyPreview)" }
    $assertion = New-XdrPasskeyAssertion -Challenge ([string]$chJson.Challenge) -PrivateKeyPem $privateKeyPem -CredentialId $credentialId -RpId $rpId

    $postUri = if ($InitialFields.UrlPost) { $InitialFields.UrlPost } else { 'https://login.microsoftonline.com/common/login' }
    $form = @{
        login = $Upn; loginfmt = $Upn; type = '23'; ps = '2'; LoginOptions = '3'
        flowToken = $InitialFields.FlowToken; ctx = $InitialFields.Context; canary = $InitialFields.Canary
        id = $assertion.Id; clientDataJSON = $assertion.ClientDataJSON; authenticatorData = $assertion.AuthenticatorData; signature = $assertion.Signature; userHandle = ''
    }
    $body = ($form.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
    Invoke-XdrAuthHttp -Stage 'CredentialPost' -Uri $postUri -Method POST -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -WebSession $WebSession -MaxRedirection 5 -ExpectJson $false
}

# ─── L1 ESTS orchestrator (portal-home entry → credential → MFA → walker → artifacts) ──
function script:Get-XdrEntraEstsAuth {
    # §36.1/§36.6 · ONE shared interactive ESTS+MFA chain for BOTH families. Stages 2-5 (credential · TOTP/Passkey ·
    # interrupt walker · artifacts) are auth-profile-AGNOSTIC; only Stage 1 differs:
    #   AuthProfile=Cookie (DEFAULT · Defender/Purview)  → portal-home entry (byte-identical to pre-§36 behavior).
    #   AuthProfile=Bearer (Entra/Intune/SecurityCopilot) → /oauth2/v2.0/authorize?response_type=code&response_mode=form_post
    #     so FinalHtml carries the auth `code` for the caller's token exchange (NOT ROPC · §36.1).
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidateSet('CredentialsTotp','Passkey')][string] $Method,
        [Parameter(Mandatory)][hashtable] $Credential,
        [string] $PortalHost = 'security.microsoft.com',
        [string] $TenantId,
        [ValidateSet('Cookie','Bearer')][string] $AuthProfile = 'Cookie',
        [string] $ClientId,
        [string] $RedirectUri,
        [string] $Scope,
        [string] $CodeChallenge,
        [ValidateSet('v1','v2')][string] $AuthVersion = 'v2',
        [string] $Resource
    )
    $upn = [string]$Credential['UPN']
    if ([string]::IsNullOrWhiteSpace($upn)) { throw "Get-XdrEntraEstsAuth: Credential.UPN empty" }
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $session.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) XdrLogRaider/0.1.0'

    # Per-stage Write-Host markers (A-OBSERVABILITY · plan §30/§31.4): workspace-mode App Insights drops the
    # Track-XdrEvent /v2/track custom events, but Write-Host lands in AppTraces — so a live auth failure shows the
    # LAST stage reached (the breakpoint). Cheap · no secrets emitted (UPN only · already in other events).

    # Stage 1: entry (profile-specific · §36.6). Both yield the ESTS login page carrying the $Config blob.
    if ($AuthProfile -eq 'Bearer') {
        # Bearer: authorize-with-code. The token exchange (caller) redeems the `code` from FinalHtml.
        if ([string]::IsNullOrWhiteSpace($ClientId))    { throw "Get-XdrEntraEstsAuth: AuthProfile=Bearer requires ClientId" }
        if ([string]::IsNullOrWhiteSpace($RedirectUri)) { throw "Get-XdrEntraEstsAuth: AuthProfile=Bearer requires RedirectUri" }
        $authTenant = if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $TenantId } else { 'organizations' }
        $q = "client_id=$ClientId&response_type=code&response_mode=form_post" +
             "&redirect_uri=$([uri]::EscapeDataString($RedirectUri))" +
             "&login_hint=$([uri]::EscapeDataString($upn))&prompt=login"
        if (-not [string]::IsNullOrWhiteSpace($CodeChallenge)) { $q += "&code_challenge=$CodeChallenge&code_challenge_method=S256" }
        if ($AuthVersion -eq 'v1') {
            # v1 authorize for portal-internal admin APIs · resource= (the v2 .default scope on a generic public
            # client returns AADSTS500011 'resource principal not found' · live-confirmed §37.7). Endpoint /oauth2/authorize.
            $res = if (-not [string]::IsNullOrWhiteSpace($Resource)) { $Resource } else { $Scope }
            $q += "&resource=$([uri]::EscapeDataString($res))"
            $entryUri = "https://login.microsoftonline.com/$authTenant/oauth2/authorize?$q"
        } else {
            $q += "&scope=$([uri]::EscapeDataString(($Scope, 'openid profile offline_access' -ne '' | Select-Object -First 1)))"
            $entryUri = "https://login.microsoftonline.com/$authTenant/oauth2/v2.0/authorize?$q"
        }
        Write-Host "[Defender.Auth.Step1] bearer authorize-code entry (v=$AuthVersion) · client=$ClientId · tenant=$authTenant · upn=$upn"
        $authResp = Invoke-XdrAuthHttp -Stage 'Authorize' -Uri $entryUri -Method GET -WebSession $session -ExpectJson $false -MaxRedirection 10
    } else {
        # Cookie (DEFAULT · Defender/Purview): portal-home entry (AADSTS50011 fix · portal drives its own OAuth).
        Write-Host "[Defender.Auth.Step1] portal-home entry · host=$PortalHost · upn=$upn"
        $authResp = Invoke-XdrAuthHttp -Stage 'Authorize' -Uri "https://$PortalHost/" -Method GET -WebSession $session -ExpectJson $false -MaxRedirection 10
    }
    $fields = Get-XdrEntraFields -Html $authResp.ResponseBody
    if ([string]::IsNullOrWhiteSpace($fields.UrlPost)) { throw "Get-XdrEntraEstsAuth: $AuthProfile entry did not yield `$Config.urlPost (status=$($authResp.Status) · body=$($authResp.BodyPreview))" }

    # Stage 2/3: credential + MFA (CredentialsTotp) OR passkey
    $credResp = $null
    if ($Method -eq 'CredentialsTotp') {
        $pw = [string]$Credential['Password']
        if ([string]::IsNullOrWhiteSpace($pw)) { throw "Get-XdrEntraEstsAuth: CredentialsTotp requires Password" }
        Write-Host "[Defender.Auth.Step2] credential POST (LoginOptions=3 · KMSI request)"
        $credResp = Complete-XdrCredentialsFlow -Upn $upn -Password $pw -InitialFields $fields -WebSession $session
        $tfa = Get-XdrEntraFields -Html $credResp.ResponseBody
        if ($tfa.Pgid -eq 'ConvergedTFA') {
            # enrollment guard: SA must have PhoneAppOTP (Software OATH)
            if ($tfa.RawConfig -and (@($tfa.RawConfig.PSObject.Properties.Name) -contains 'arrUserProofs')) {
                $proofs = @($tfa.RawConfig.arrUserProofs)
                $hasOtp = $proofs | Where-Object { (@($_.PSObject.Properties.Name) -contains 'authMethodId') -and $_.authMethodId -eq 'PhoneAppOTP' } | Select-Object -First 1
                if (-not $hasOtp) { throw "SA '$upn' has no PhoneAppOTP (Software OATH) enrolled · enrol at https://mysignins.microsoft.com/security-info" }
            }
            $seed = [string]$Credential['TotpSeed']
            if ([string]::IsNullOrWhiteSpace($seed)) { throw "Get-XdrEntraEstsAuth: CredentialsTotp requires TotpSeed" }
            Write-Host "[Defender.Auth.Step3] TOTP MFA (SAS BeginAuth/EndAuth/ProcessAuth)"
            $credResp = Complete-XdrTotpMfa -TotpBase32 $seed -TfaFields $tfa -WebSession $session
        }
    } else {
        # Passkey (FIDO2 · headless · §3/§7 GA-bar/Φ1): KV ECDSA-P256 PEM signs the FIDO challenge → type=23 assertion POST.
        $pkSecret = [string]$Credential['PasskeyPem']
        if ([string]::IsNullOrWhiteSpace($pkSecret)) { throw "Get-XdrEntraEstsAuth: Method=Passkey requires the 'PasskeyPem' KV secret (ECDSA-P256 PEM, or JSON {credentialId,privateKeyPem,rpId})" }
        Write-Host "[Defender.Auth.Step2] passkey FIDO2 assertion flow (headless)"
        $credResp = Complete-XdrPasskeyFlow -PasskeySecret $pkSecret -Upn $upn -InitialFields $fields -WebSession $session
    }

    # Stage 4: interrupt walker
    Write-Host "[Defender.Auth.Step4] interrupt walker (KMSI/CMSI/ProofUp · <=10 hops)"
    $walker = Resolve-XdrInterruptPage -InitialHtml $credResp.ResponseBody -WebSession $session
    # Stage 5: artifacts (tenant candidates)
    Write-Host "[Defender.Auth.Step5] ESTS artifacts · KmsiAccepted=$($walker.KmsiAccepted) · hops=$($walker.HopsWalked)"
    $artifacts = Get-XdrAuthArtifacts -WebSession $session -FinalHtml $walker.FinalHtml -KmsiAccepted $walker.KmsiAccepted
    [pscustomobject]@{ Session = $session; FinalHtml = $walker.FinalHtml; KmsiAccepted = $walker.KmsiAccepted; TenantIdCandidates = $artifacts.TenantIdCandidates; Upn = $upn }
}

function Connect-DefenderPortal {
    <#
    .SYNOPSIS
    Defender session handler (T3 fresh auth). Returns a clean HASHTABLE session for Connect-XdrPortal
    (which owns L1/L2 cache + single-flight lease). Adopts the proven cookie-OIDC chain.
    #>
    [CmdletBinding()][OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable] $Credentials)

    # T1 · cache hit (alive) → return immediately. Indexer reads (StrictMode-safe partial sessions).
    # SKIP T1 when __ForceFresh (Connect-XdrPortal -Force · self-heal reauth) — else a forced reauth re-returns the SAME
    # stale session that just 440'd, re-looping. T2 (KMSI silent re-mint) below still fires → fresh sccauth, no TOTP.
    $cached = Get-XdrCachedSession -Portal 'Defender' -UPN $Credentials['UPN']
    if (-not $Credentials['__ForceFresh'] -and $cached -and $cached['Sccauth'] -and $cached['ExpiresUtc']) {
        try {
            if ((ConvertTo-XdrUtc $cached['ExpiresUtc']) -gt [DateTime]::UtcNow.AddMinutes(5)) { return $cached }
        } catch { <# parse fail → fall through · INTENTIONAL-FAIL-SAFE #> }
    }
    # T2 · KMSI silent refresh (re-mint sccauth from ESTSAUTHPERSISTENT · no TOTP)
    if ($cached -and $cached['KmsiCookie']) {
        try { $r = Refresh-DefenderSccauth -CachedSession $cached; if ($r.Success) { return $r.Session } }
        catch { Track-XdrEvent -Name 'Defender.Auth.T2.Swallowed' -Properties @{ UPN = $Credentials['UPN']; Reason = $_.Exception.Message } }  # INTENTIONAL-FAIL-SAFE (B8/§31.5): T2 KMSI refresh failed -> fall through to T3 full auth · now observable
    }

    # T3 · fresh chain
    $method = switch (([string]$Credentials['AuthMethod'])) {
        'TOTP'            { 'CredentialsTotp' }
        'CredentialsTotp' { 'CredentialsTotp' }
        'credentials_totp'{ 'CredentialsTotp' }
        'Passkey'         { 'Passkey' }
        'passkey'         { 'Passkey' }
        default           { 'CredentialsTotp' }
    }
    $tenantHint = if ($Credentials['TenantId']) { [string]$Credentials['TenantId'] } elseif ($env:XDRLR_TENANT_ID) { $env:XDRLR_TENANT_ID } else { '' }

    Track-XdrEvent -Name 'Defender.Auth.T3.Started' -Properties @{ UPN = $Credentials['UPN']; AuthMethod = $method }
    $ests = Get-XdrEntraEstsAuth -Method $method -Credential $Credentials -PortalHost $script:DefenderPortalHost -TenantId $tenantHint

    # form_post submit → mints sccauth + XSRF on the portal
    Write-Host "[Defender.Auth.Step6] form_post submit → portal ($script:DefenderPortalHost)"
    $null = Submit-XdrAuthFormPost -FormPostHtml $ests.FinalHtml -WebSession $ests.Session -ExpectedActionHostname $script:DefenderPortalHost

    Write-Host "[Defender.Auth.Step7] capture sccauth + XSRF (Decision-16 tenant resolve)"
    $scc = Get-XdrDefenderSccauth -WebSession $ests.Session -PortalHost $script:DefenderPortalHost -TenantId $tenantHint -Artifacts $ests
    Write-Host "[Defender.Auth.Step8] dynamic cookie expiry (real Set-Cookie Expires)"
    $expiry = Get-XdrCookieExpiry -WebSession $ests.Session -PortalHost $script:DefenderPortalHost -AcquiredUtc $scc.AcquiredUtc

    # T2-KMSI (F2 · §31.4): persist the ESTSAUTHPERSISTENT (90d KMSI) cookie VALUE so the NEXT reauth can silently
    # re-mint sccauth via Refresh-DefenderSccauth instead of a full T3 TOTP burn. Was never stored → the T2 gate
    # (`$cached['KmsiCookie']`) was always empty → every reauth fell through to T3 (a TOTP burn each time).
    $kmsiCookieVal = Get-XdrKmsiCookieValue -WebSession $ests.Session

    $session = @{
        UPN                  = $ests.Upn
        Sccauth              = $scc.Sccauth
        XsrfToken            = $scc.XsrfToken
        Cookie               = "sccauth=$($scc.Sccauth)"
        Portal               = 'Defender'
        TenantId             = $scc.TenantId
        TenantIdSource       = $scc.TenantIdSource
        KmsiActive           = [bool]$ests.KmsiAccepted
        KmsiCookie           = $kmsiCookieVal
        ExpiresUtc           = $expiry.ExpiresUtc.ToString('o')
        KmsiExpiresUtc       = if ($expiry.KmsiExpiresUtc) { $expiry.KmsiExpiresUtc.ToString('o') } else { '' }
        EarliestExpirySource = $expiry.EarliestExpirySource
        SavedUtc             = (Get-Date).ToUniversalTime().ToString('o')
        CreatedBy            = 'T3-cookie-oidc'
    }
    Track-XdrEvent -Name 'Defender.Auth.T3.Succeeded' -Properties @{ UPN = $ests.Upn; AuthMethod = $method; TenantIdSource = $scc.TenantIdSource; ExpirySource = $expiry.EarliestExpirySource; Kmsi = $session.KmsiActive }
    return $session
}

function Refresh-DefenderSccauth {
    <#
    .SYNOPSIS
    T2 · re-mint sccauth using the cached ESTSAUTHPERSISTENT (KMSI) cookie · no TOTP burn.
    Returns @{ Success; Session; ErrorMessage }. Best-effort: on any failure the caller falls to T3.
    #>
    # -PortalHost/-Portal default to Defender (Defender behavior UNCHANGED) · Purview T2 passes its own host/portal.
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable] $CachedSession, [string] $PortalHost = $script:DefenderPortalHost, [string] $Portal = 'Defender')
    try {
        $kmsi = [string]$CachedSession['KmsiCookie']
        if ([string]::IsNullOrWhiteSpace($kmsi)) { return @{ Success = $false; Session = $null; ErrorMessage = 'no KMSI cookie' } }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $session.Cookies.Add([System.Uri]::new('https://login.microsoftonline.com'), [System.Net.Cookie]::new('ESTSAUTHPERSISTENT', $kmsi, '/', '.login.microsoftonline.com'))
        # Portal-home entry with KMSI present → SSO completes without credential prompt → form_post.
        $r = Invoke-XdrAuthHttp -Stage 'Authorize' -Uri "https://$PortalHost/" -Method GET -WebSession $session -ExpectJson $false -MaxRedirection 10
        # If the response is a form_post, submit it; otherwise KMSI didn't carry → fail to T3.
        if ($r.ResponseBody -match '<form[^>]*action=') {
            $null = Submit-XdrAuthFormPost -FormPostHtml $r.ResponseBody -WebSession $session -ExpectedActionHostname $PortalHost
        }
        $scc = Get-XdrDefenderSccauth -WebSession $session -PortalHost $PortalHost -TenantId ([string]$CachedSession['TenantId'])
        $expiry = Get-XdrCookieExpiry -WebSession $session -PortalHost $PortalHost -AcquiredUtc $scc.AcquiredUtc
        $newSession = @{
            UPN = [string]$CachedSession['UPN']; Sccauth = $scc.Sccauth; XsrfToken = $scc.XsrfToken
            Cookie = "sccauth=$($scc.Sccauth)"; Portal = $Portal; TenantId = $scc.TenantId; TenantIdSource = $scc.TenantIdSource
            KmsiActive = $true; KmsiCookie = $kmsi; ExpiresUtc = $expiry.ExpiresUtc.ToString('o')
            KmsiExpiresUtc = if ($expiry.KmsiExpiresUtc) { $expiry.KmsiExpiresUtc.ToString('o') } else { '' }
            EarliestExpirySource = $expiry.EarliestExpirySource; SavedUtc = (Get-Date).ToUniversalTime().ToString('o'); CreatedBy = 'T2-kmsi'
        }
        Track-XdrEvent -Name 'Defender.Auth.T2.Succeeded' -Properties @{ UPN = $newSession.UPN }
        return @{ Success = $true; Session = $newSession; ErrorMessage = $null }
    } catch {
        return @{ Success = $false; Session = $null; ErrorMessage = $_.Exception.Message }
    }
}

Export-ModuleMember -Function Connect-DefenderPortal, Refresh-DefenderSccauth, `
    Get-XdrEntraEstsAuth, Submit-XdrAuthFormPost, Get-XdrDefenderSccauth, Get-XdrCookieExpiry, Get-XdrKmsiCookieValue
